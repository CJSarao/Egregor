import Foundation

struct EgregoreIntentResolver: IntentResolver {
    // MARK: Internal

    func resolve(_ result: TranscriptionResult) -> Intent {
        guard result.confidence >= Self.confidenceFloor else {
            return .discard
        }

        let normalized = result.text
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .uppercased()

        if looksLikeStandaloneCommand(result.segment), let cmd = vocabularyCommand(for: normalized) {
            return .command(cmd)
        }
        return .inject(result.text)
    }

    // MARK: Private

    private static let durationThreshold: Duration = .milliseconds(2000)
    private static let confidenceFloor: Float = 0.3

    private func looksLikeStandaloneCommand(_ segment: SpeechSegment) -> Bool {
        segment.endedBySilence && segment.duration < Self.durationThreshold
    }

    private func vocabularyCommand(for normalized: String) -> VoiceCommand? {
        switch normalized {
        case "ROGER": .roger
        case "ABORT": .abort
        default: nil
        }
    }
}
