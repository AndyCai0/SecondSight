import AVFoundation

@MainActor
final class SpeechSynthesizer {
    private let synthesizer: AVSpeechSynthesizer
    private let voice: AVSpeechSynthesisVoice?

    init() {
        // Creating AVSpeechSynthesisVoice from a Swift async context triggers an
        // AXCore unsafeForcedSync path on macOS 26 and later. AppModel keeps this object for
        // the app lifetime, so resolve the voice once during synchronous startup.
        voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synthesizer = AVSpeechSynthesizer()
    }

    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.43
        synthesizer.speak(utterance)
    }
}
