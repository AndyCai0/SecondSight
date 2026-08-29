import CoreVideo
import Foundation
import LiveKit
import SecondSightCore

final class LiveKitTransport: NSObject, RoomDelegate, @unchecked Sendable {
    var onVolunteerJoined: (@Sendable (String) -> Void)?
    var onDataMessage: (@Sendable (DataMessage) -> Void)?
    var onRemoteAudioTrack: (@Sendable (RemoteAudioTrack) -> Void)?
    var onRemoteAudioTrackUnavailable: (@Sendable () -> Void)?
    var onDisconnected: (@Sendable () -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private lazy var room = Room(delegate: self)
    private let videoTrack = LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(fps: 12))
    private lazy var audioTrack = LocalAudioTrack.createTrack()
    private var videoPublication: LocalTrackPublication?
    private var audioPublication: LocalTrackPublication?
    private var isConnected = false
    private var publishing = false
    private var mediaEnabled = true

    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
        withState {
            isConnected = true
            mediaEnabled = true
            publishing = false
            videoPublication = nil
            audioPublication = nil
        }
    }

    func acceptRedactedFrame(_ frame: CVPixelBuffer) {
        guard let capturer = videoTrack.capturer as? BufferCapturer else { return }
        capturer.capture(frame)
        let shouldPublish = withState {
            let result = isConnected && mediaEnabled && !publishing && videoPublication == nil
            if result { publishing = true }
            return result
        }
        guard shouldPublish else { return }
        Task { [weak self] in await self?.publishMedia() }
    }

    func freezeMedia() async {
        withState { mediaEnabled = false }
        await room.localParticipant.unpublishAll()
        withState {
            videoPublication = nil
            audioPublication = nil
            publishing = false
        }
    }

    func resumeMedia() {
        withState {
            mediaEnabled = true
            publishing = false
        }
    }

    func publish(_ message: DataMessage, reliable: Bool = true) async throws {
        let data = try DataMessageCodec.encode(message)
        try await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: reliable))
    }

    func disconnect() async {
        withState { isConnected = false; mediaEnabled = false }
        await room.disconnect()
    }

    private func publishMedia() async {
        do {
            let video = try await room.localParticipant.publish(
                videoTrack: videoTrack,
                options: VideoPublishOptions(name: "screen-redacted", simulcast: false)
            )
            let audio = try await room.localParticipant.publish(audioTrack: audioTrack)
            withState {
                videoPublication = video
                audioPublication = audio
                publishing = false
            }
        } catch {
            withState { publishing = false }
            onError?(error)
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
        guard participant.identity?.stringValue.hasPrefix("volunteer:") == true else { return }
        onRemoteAudioTrackUnavailable?()
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue.hasPrefix("volunteer:") == true,
              let audio = publication.track as? RemoteAudioTrack
        else { return }
        onRemoteAudioTrack?(audio)
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue.hasPrefix("volunteer:") == true,
              publication.kind == .audio
        else { return }
        onRemoteAudioTrackUnavailable?()
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
            // Data-channel input is untrusted. A malformed or unknown message is not a
            // transport disconnect and must not turn off otherwise healthy protection.
            return
        }
    }

    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        onError?(error ?? TransportError.connectionFailed)
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        withState {
            isConnected = false
            mediaEnabled = false
            videoPublication = nil
            audioPublication = nil
            publishing = false
        }
        if let error {
            onError?(error)
        } else {
            onDisconnected?()
        }
    }

    enum TransportError: LocalizedError {
        case connectionFailed
        var errorDescription: String? { "无法连接到通话房间。" }
    }
}
