import Foundation

struct EgregoreIntentResolver: IntentResolver {
    private static let silenceBeforeThreshold: Duration = .milliseconds(1500)
    private static let durationThreshold: Duration = .milliseconds(2000)
    private static let trailingSilenceThreshold: Duration = .milliseconds(800)
    private static let confidenceFloor: Float = 0.3

    func resolve(_ result: TranscriptionResult, mode: InputMode) -> Intent {
        guard result.confidence >= Self.confidenceFloor else { return .discard }

        let normalized = result.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch mode {
        case .command:
            return vocabularyCommand(for: normalized).map { .command($0) } ?? .discard
        case .dictation:
            if isIsolated(result.segment), let cmd = vocabularyCommand(for: normalized) {
                return .command(cmd)
            }
            return .inject(result.text)
        }
    }

    private func isIsolated(_ segment: SpeechSegment) -> Bool {
        segment.endedBySilence &&
        segment.silenceBefore > Self.silenceBeforeThreshold &&
        segment.duration < Self.durationThreshold &&
        segment.trailingSilenceAfter >= Self.trailingSilenceThreshold
    }

    private func vocabularyCommand(for normalized: String) -> VoiceCommand? {
        switch normalized {
        case "ROGER": return .roger
        case "ABORT": return .abort
        default: return nil
        }
    }
}
