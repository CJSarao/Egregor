import AVFoundation

public final class Speaker: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    public private(set) var isPaused = false
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    private let voice: AVSpeechSynthesisVoice? = {
        AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return }

        // Resume any leaked continuation from a prior call
        continuation?.resume()
        continuation = nil

        let utterance = AVSpeechUtterance(string: stripped)
        utterance.rate = rate
        utterance.voice = voice
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            self.synthesizer.speak(utterance)
        }
    }

    public func pause() {
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
    }

    public func resume() {
        synthesizer.continueSpeaking()
        isPaused = false
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPaused = false
        // If no speech was active, didCancel won't fire — resume manually
        continuation?.resume()
        continuation = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }
}
