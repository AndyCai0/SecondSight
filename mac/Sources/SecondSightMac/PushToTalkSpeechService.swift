import AVFoundation
import Foundation
import Speech

@MainActor
final class PushToTalkSpeechService {
    enum SpeechError: LocalizedError {
        case unavailable
        case onDeviceUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable:
                localized("语音识别现在不可用。", "Speech recognition is currently unavailable.", for: .savedOrSystemDefault)
            case .onDeviceUnavailable:
                localized("这台 Mac 暂不支持离线中文语音识别。", "This Mac does not currently support offline Chinese speech recognition.", for: .savedOrSystemDefault)
            }
        }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var completion: ((Result<String, Error>) -> Void)?
    private var bestText = ""
    private(set) var isRecording = false

    func start(completion: @escaping (Result<String, Error>) -> Void) throws {
        guard !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw SpeechError.onDeviceUnavailable }
        self.completion = completion
        bestText = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.bestText = result.bestTranscription.formattedString }
                if result?.isFinal == true { self.complete(.success(self.bestText)) }
                else if let error { self.complete(.failure(error)) }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.completion != nil else { return }
            if self.bestText.isEmpty { self.complete(.failure(SpeechError.unavailable)) }
            else { self.complete(.success(self.bestText)) }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        task?.cancel(); task = nil
        request = nil
        isRecording = false
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}
