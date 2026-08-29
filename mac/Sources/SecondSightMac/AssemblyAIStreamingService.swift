import AVFoundation
import Foundation
import LiveKit

struct StreamingTranscript: Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let turnOrder: Int
}

final class AssemblyAIStreamingService: NSObject, AudioRenderer, @unchecked Sendable {
    var onConnected: (@Sendable () -> Void)?
    var onTranscript: (@Sendable (StreamingTranscript) -> Void)?
    var onDisconnected: (@Sendable (Error) -> Void)?

    private struct ServerMessage: Decodable {
        let type: String
        let transcript: String?
        let endOfTurn: Bool?
        let turnOrder: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type, transcript, error
            case endOfTurn = "end_of_turn"
            case turnOrder = "turn_order"
        }
    }

    private struct AudioFormatSignature: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormat: AVAudioCommonFormat
        let interleaved: Bool

        init(_ format: AVAudioFormat) {
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            commonFormat = format.commonFormat
            interleaved = format.isInterleaved
        }
    }

    private let queue = DispatchQueue(label: "study.secondsight.assemblyai-streaming")
    private let urlSession: URLSession
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private weak var track: RemoteAudioTrack?
    private var socket: URLSessionWebSocketTask?
    private var sendTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var inputSignature: AudioFormatSignature?
    private var pendingPCM = Data()
    private var lastTranscriptByTurn: [Int: String] = [:]
    private var running = false
    private var ready = false
    private var stopRequested = false

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func start(track: RemoteAudioTrack, token: String) throws {
        guard let url = Self.websocketURL(token: token) else {
            throw StreamingError.invalidCredential
        }
        queue.sync {
            stopImmediately()
            let socket = urlSession.webSocketTask(with: url)
            self.socket = socket
            self.track = track
            running = true
            ready = false
            stopRequested = false
            converter = nil
            inputSignature = nil
            pendingPCM.removeAll(keepingCapacity: true)
            lastTranscriptByTurn.removeAll()
            track.add(audioRenderer: self)
            socket.resume()
            receiveMessages(from: socket)
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopGracefully() }
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in self?.accept(pcmBuffer) }
    }

    private static func websocketURL(token: String) -> URL? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "streaming.assemblyai.com"
        components.path = "/v3/ws"
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "speech_model", value: "universal-3-5-pro"),
            URLQueryItem(name: "token", value: trimmed),
        ]
        return components.url
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask) {
        Task { [weak self, weak socket] in
            guard let socket else { return }
            do {
                while true {
                    let message = try await socket.receive()
                    guard let self else { return }
                    let shouldContinue = self.queue.sync {
                        guard self.socket === socket else { return false }
                        self.handle(message, from: socket)
                        return self.socket === socket
                    }
                    if !shouldContinue { return }
                }
            } catch {
                self?.queue.async { [weak self] in self?.handleSocketFailure(error, socket: socket) }
            }
        }
    }

    private func handle(
        _ message: URLSessionWebSocketTask.Message,
        from socket: URLSessionWebSocketTask
    ) {
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(value): data = value
        @unknown default:
            handleSocketFailure(StreamingError.invalidServerMessage, socket: socket)
            return
        }

        guard let response = try? JSONDecoder().decode(ServerMessage.self, from: data) else {
            handleSocketFailure(StreamingError.invalidServerMessage, socket: socket)
            return
        }

        switch response.type {
        case "Begin":
            guard !ready else { return }
            ready = true
            onConnected?()
        case "Turn":
            guard let transcript = response.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty
            else { return }
            let isFinal = response.endOfTurn == true
            guard isFinal || Self.isStablePartial(transcript) else { return }
            let turnOrder = response.turnOrder ?? 0
            guard lastTranscriptByTurn[turnOrder] != transcript else { return }
            lastTranscriptByTurn[turnOrder] = transcript
            if lastTranscriptByTurn.count > 12 {
                let oldest = lastTranscriptByTurn.keys.sorted().prefix(lastTranscriptByTurn.count - 12)
                oldest.forEach { lastTranscriptByTurn.removeValue(forKey: $0) }
            }
            onTranscript?(.init(text: transcript, isFinal: isFinal, turnOrder: turnOrder))
        case "Termination":
            let wasRequested = stopRequested
            finish(socket: socket)
            if !wasRequested { onDisconnected?(StreamingError.serverEndedSession) }
        case "Error":
            handleSocketFailure(
                StreamingError.server(response.error ?? "Unknown streaming error"),
                socket: socket
            )
        default:
            break
        }
    }

    private static func isStablePartial(_ transcript: String) -> Bool {
        transcript.filter { !$0.isWhitespace && !$0.isPunctuation }.count >= 3
    }

    private func accept(_ input: AVAudioPCMBuffer) {
        guard running, ready, let socket, input.frameLength > 0 else { return }
        do {
            let pcm16 = try convertToPCM16(input)
            guard !pcm16.isEmpty else { return }
            pendingPCM.append(pcm16)
            let fiftyMilliseconds = 1_600
            while pendingPCM.count >= fiftyMilliseconds {
                let chunk = Data(pendingPCM.prefix(fiftyMilliseconds))
                pendingPCM.removeFirst(fiftyMilliseconds)
                enqueueAudio(chunk, socket: socket)
            }
        } catch {
            handleSocketFailure(error, socket: socket)
        }
    }

    private func enqueueAudio(_ data: Data, socket: URLSessionWebSocketTask) {
        let previous = sendTask
        sendTask = Task { [weak self, weak socket] in
            _ = await previous?.result
            guard !Task.isCancelled, let self, let socket else { return }
            do {
                try await socket.send(.data(data))
            } catch {
                self.queue.async { [weak self] in self?.handleSocketFailure(error, socket: socket) }
            }
        }
    }

    private func convertToPCM16(_ input: AVAudioPCMBuffer) throws -> Data {
        let signature = AudioFormatSignature(input.format)
        if converter == nil || signature != inputSignature {
            guard let next = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw StreamingError.unsupportedAudioFormat
            }
            converter = next
            inputSignature = signature
        }
        guard let converter else { throw StreamingError.unsupportedAudioFormat }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw StreamingError.unsupportedAudioFormat
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError ?? StreamingError.audioConversionFailed
        }
        guard output.frameLength > 0 else { return Data() }
        let buffer = output.audioBufferList.pointee.mBuffers
        guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { return Data() }
        return Data(bytes: bytes, count: Int(buffer.mDataByteSize))
    }

    private func stopGracefully() {
        guard let socket else {
            stopImmediately()
            return
        }
        stopRequested = true
        running = false
        ready = false
        detachTrack()
        let pendingSend = sendTask
        pendingSend?.cancel()
        sendTask = nil

        Task { [weak self, weak socket] in
            guard let socket else { return }
            _ = await pendingSend?.result
            try? await socket.send(.string(#"{"type":"Terminate"}"#))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.queue.async { [weak self] in
                guard let self, self.socket === socket else { return }
                self.finish(socket: socket)
            }
        }
    }

    private func stopImmediately() {
        sendTask?.cancel()
        sendTask = nil
        if let socket {
            socket.cancel(with: .goingAway, reason: nil)
        }
        socket = nil
        running = false
        ready = false
        stopRequested = true
        detachTrack()
    }

    private func finish(socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }
        socket.cancel(with: .normalClosure, reason: nil)
        self.socket = nil
        running = false
        ready = false
        sendTask?.cancel()
        sendTask = nil
        detachTrack()
    }

    private func handleSocketFailure(_ error: Error, socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }
        let shouldNotify = !stopRequested
        finish(socket: socket)
        if shouldNotify { onDisconnected?(error) }
    }

    private func detachTrack() {
        track?.remove(audioRenderer: self)
        track = nil
        converter = nil
        inputSignature = nil
        pendingPCM.removeAll(keepingCapacity: true)
    }

    enum StreamingError: LocalizedError {
        case invalidCredential
        case invalidServerMessage
        case serverEndedSession
        case server(String)
        case unsupportedAudioFormat
        case audioConversionFailed

        var errorDescription: String? {
            switch self {
            case .invalidCredential: "无法开始安全监听：临时凭证无效。"
            case .invalidServerMessage: "安全监听收到无法识别的转录数据。"
            case .serverEndedSession: "安全监听连接已由转录服务关闭。"
            case let .server(message): "安全监听服务错误：\(message)"
            case .unsupportedAudioFormat: "安全监听无法处理当前通话音频格式。"
            case .audioConversionFailed: "安全监听音频转换失败。"
            }
        }
    }
}
