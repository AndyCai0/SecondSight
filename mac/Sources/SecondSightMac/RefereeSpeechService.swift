import AVFoundation
import Foundation
import LiveKit
import Speech

final class RefereeSpeechService: NSObject, AudioRenderer, @unchecked Sendable {
    var onTranscript: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "study.secondsight.referee-speech")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private weak var track: RemoteAudioTrack?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var lastDelivered = ""

    func attach(to track: RemoteAudioTrack) {
        queue.async { [weak self] in
            guard let self else { return }
            self.track?.remove(audioRenderer: self)
            self.track = track
            track.add(audioRenderer: self)
            self.running = true
            self.beginSegment()
            self.startTimer()
        }
    }

    func pause() {
        queue.async { [weak self] in self?.stopRecognition(detach: false) }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, self.track != nil else { return }
            self.running = true
            self.beginSegment()
            self.startTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopRecognition(detach: true) }
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in self?.request?.append(pcmBuffer) }
    }

    private func beginSegment() {
        guard running, request == nil, let recognizer, recognizer.isAvailable else { return }
        guard recognizer.supportsOnDeviceRecognition else {
            onError?(SpeechError.onDeviceUnavailable)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let result, result.isFinal {
                    self.deliver(result.bestTranscription.formattedString)
                }
                if result?.isFinal == true || error != nil {
                    self.request = nil
                    self.task = nil
                    if self.running { self.beginSegment() }
                }
            }
        }
    }

    private func finishSegment() {
        request?.endAudio()
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.finishSegment() }
        self.timer = timer
        timer.resume()
    }

    private func deliver(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != lastDelivered else { return }
        lastDelivered = cleaned
        onTranscript?(cleaned)
    }

    private func stopRecognition(detach: Bool) {
        running = false
        timer?.cancel(); timer = nil
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        if detach {
            track?.remove(audioRenderer: self)
            track = nil
        }
    }

    enum SpeechError: LocalizedError {
        case onDeviceUnavailable
        var errorDescription: String? { "这台 Mac 暂不支持离线中文语音识别。" }
    }
}
