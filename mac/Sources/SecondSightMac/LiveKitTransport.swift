import CoreVideo
import Foundation
import LiveKit
import SecondSightCore

final class LiveKitTransport: NSObject, RoomDelegate, @unchecked Sendable {
    var onVolunteerJoined: (@Sendable (String) -> Void)?
    var onVolunteerLeft: (@Sendable (String) -> Void)?
    var onDataMessage: (@Sendable (DataMessage) -> Void)?
    var onRemoteAudioTrack: (@Sendable (RemoteAudioTrack) -> Void)?
    var onRemoteCameraTrack: (@Sendable (RemoteVideoTrack) -> Void)?
    var onRemoteCameraTrackRemoved: (@Sendable () -> Void)?
    var onMediaError: (@Sendable (ElderMediaKind, Error) -> Void)?
    var onAllMediaReady: (@Sendable () -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private static let publicationOrder: [ElderMediaKind] = [.screen, .microphone, .camera]
    private let lock = NSLock()
    private lazy var room = Room(delegate: self)
    private let screenTrack = LocalVideoTrack.createBufferTrack(
        name: ElderMediaKind.screen.trackName,
        source: .screenShareVideo,
        options: BufferCaptureOptions(fps: 12)
    )
    private let cameraTrack = LocalVideoTrack.createCameraTrack(
        name: ElderMediaKind.camera.trackName,
        options: CameraCaptureOptions(dimensions: .h720_169, fps: 15)
    )
    private lazy var audioTrack = LocalAudioTrack.createTrack(name: ElderMediaKind.microphone.trackName)
    private var publications: [ElderMediaKind: LocalTrackPublication] = [:]
    private var failedMedia: Set<ElderMediaKind> = []
    private var isConnected = false
    private var publishPassRunning = false
    private var publishTask: Task<Void, Never>?
    private var mediaEnabled = true
    private var hasScreenFrame = false

    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
        withState {
            isConnected = true
            mediaEnabled = true
            publishPassRunning = false
            publishTask = nil
            publications.removeAll()
            failedMedia.removeAll()
            hasScreenFrame = false
        }
        schedulePublishPass()
    }

    func acceptRedactedFrame(_ frame: CVPixelBuffer) {
        guard let capturer = screenTrack.capturer as? BufferCapturer else { return }
        capturer.capture(frame)
        withState { hasScreenFrame = true }
        schedulePublishPass()
    }

    func freezeMedia() async {
        let task = withState {
            mediaEnabled = false
            return publishTask
        }
        task?.cancel()
        await task?.value
        await room.localParticipant.unpublishAll()
        withState {
            publications.removeAll()
            failedMedia.removeAll()
            publishPassRunning = false
            publishTask = nil
            hasScreenFrame = false
        }
    }

    func resumeMedia() {
        withState {
            mediaEnabled = true
            failedMedia.removeAll()
        }
        schedulePublishPass()
    }

    func retryFailedMedia() {
        withState { failedMedia.removeAll() }
        schedulePublishPass()
    }

    func publish(_ message: DataMessage, reliable: Bool = true) async throws {
        let data = try DataMessageCodec.encode(message)
        try await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: reliable))
    }

    func disconnect() async {
        let task = withState {
            isConnected = false
            mediaEnabled = false
            return publishTask
        }
        task?.cancel()
        await task?.value
        await room.disconnect()
        withState {
            publications.removeAll()
            failedMedia.removeAll()
            publishPassRunning = false
            publishTask = nil
        }
    }

    private func schedulePublishPass() {
        let shouldStart = withState {
            guard isConnected, mediaEnabled, !publishPassRunning else { return false }
            let hasMissingMedia = Self.publicationOrder.contains {
                isReadyToPublish($0) && publications[$0] == nil && !failedMedia.contains($0)
            }
            guard hasMissingMedia else { return false }
            publishPassRunning = true
            return true
        }
        guard shouldStart else { return }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.publishMissingMedia()
        }
        withState { publishTask = task }
    }

    private func publishMissingMedia() async {
        let kinds = withState {
            Self.publicationOrder.filter {
                isReadyToPublish($0) && publications[$0] == nil && !failedMedia.contains($0)
            }
        }

        for kind in kinds {
            guard !Task.isCancelled else { break }
            do {
                let publication = try await publish(kind)
                withState { publications[kind] = publication }
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                let shouldReport = withState {
                    guard isConnected, mediaEnabled else { return false }
                    failedMedia.insert(kind)
                    return true
                }
                if shouldReport { onMediaError?(kind, error) }
            }
        }

        let allMediaReady = withState {
            publishPassRunning = false
            publishTask = nil
            return Self.publicationOrder.allSatisfy { publications[$0] != nil }
        }
        if allMediaReady {
            onAllMediaReady?()
        } else {
            schedulePublishPass()
        }
    }

    private func isReadyToPublish(_ kind: ElderMediaKind) -> Bool {
        kind != .screen || hasScreenFrame
    }

    private func publish(_ kind: ElderMediaKind) async throws -> LocalTrackPublication {
        switch kind {
        case .screen:
            try await room.localParticipant.publish(
                videoTrack: screenTrack,
                options: VideoPublishOptions(
                    name: kind.trackName,
                    simulcast: false,
                    degradationPreference: .maintainResolution
                )
            )
        case .camera:
            try await room.localParticipant.publish(
                videoTrack: cameraTrack,
                options: VideoPublishOptions(
                    name: kind.trackName,
                    simulcast: false,
                    degradationPreference: .balanced
                )
            )
        case .microphone:
            try await room.localParticipant.publish(
                audioTrack: audioTrack,
                options: AudioPublishOptions(name: kind.trackName)
            )
        }
    }

    private func withState<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        guard identity.hasPrefix("volunteer:") else { return }
        onVolunteerJoined?(identity)
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        guard identity.hasPrefix("volunteer:") else { return }

        let shouldNotify = withState {
            guard isConnected, room.connectionState == .connected else { return false }
            return !room.remoteParticipants.values.contains {
                $0.identity?.stringValue.hasPrefix("volunteer:") == true
            }
        }
        if shouldNotify { onVolunteerLeft?(identity) }
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue.hasPrefix("volunteer:") == true else { return }
        if let audio = publication.track as? RemoteAudioTrack {
            onRemoteAudioTrack?(audio)
        } else if publication.source == .camera,
                  let camera = publication.track as? RemoteVideoTrack
        {
            onRemoteCameraTrack?(camera)
        }
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue.hasPrefix("volunteer:") == true,
              publication.source == .camera
        else { return }
        onRemoteCameraTrackRemoved?()
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        let identity = participant?.identity?.stringValue
        do {
            let message = try DataMessageCodec.decode(data, senderIdentity: identity)
            onDataMessage?(message)
        } catch DataMessageError.forbiddenVolunteerControl {
            return
        } catch {
            onError?(error)
        }
    }

    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        onError?(error ?? TransportError.connectionFailed)
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        guard let error else { return }
        onError?(error)
    }

    enum TransportError: LocalizedError {
        case connectionFailed
        var errorDescription: String? { "无法连接到通话房间。" }
    }
}
