import XCTest
@testable import Egregore

final class IntentResolverTests: XCTestCase {
    let resolver = EgregoreIntentResolver()

    // MARK: - Helpers

    func makeResult(
        text: String,
        confidence: Float = 0.9,
        silenceBefore: Duration = .milliseconds(2000),
        duration: Duration = .milliseconds(800),
        trailingSilenceAfter: Duration = .milliseconds(800),
        endedBySilence: Bool = true
    ) -> TranscriptionResult {
        let segment = SpeechSegment(
            audio: [],
            silenceBefore: silenceBefore,
            duration: duration,
            trailingSilenceAfter: trailingSilenceAfter,
            endedBySilence: endedBySilence
        )
        return TranscriptionResult(text: text, confidence: confidence, segment: segment)
    }

    // MARK: - Low confidence → discard

    func testLowConfidenceDiscarded() {
        let result = makeResult(text: "hello world", confidence: 0.1)
        XCTAssertEqual(resolver.resolve(result), .discard)
    }

    func testLowConfidenceVocabularyWordDiscardedBeforeInjection() {
        let result = makeResult(text: "ABORT", confidence: 0.05, silenceBefore: .milliseconds(2000), duration: .milliseconds(500))
        XCTAssertEqual(resolver.resolve(result), .discard)
    }

    // MARK: - Dictation: non-vocabulary injects

    func testNonVocabularyInjects() {
        let result = makeResult(text: "git status", endedBySilence: false)
        XCTAssertEqual(resolver.resolve(result), .inject("git status"))
    }

    func testNonVocabularyWithIsolationTimingStillInjects() {
        let result = makeResult(text: "hello", silenceBefore: .milliseconds(2000), duration: .milliseconds(500))
        XCTAssertEqual(resolver.resolve(result), .inject("hello"))
    }

    func testVocabularyInjectsWhenUtteranceDidNotEndBySilence() {
        let result = makeResult(
            text: "ROGER",
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(200),
            endedBySilence: false
        )
        XCTAssertEqual(resolver.resolve(result), .inject("ROGER"))
    }

    // MARK: - Isolation algorithm: standalone command detection

    func testIsolatedRogerReturnsCommand() {
        let result = makeResult(text: "ROGER", silenceBefore: .milliseconds(2000), duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result), .command(.roger))
    }

    func testIsolatedRogerWithTrailingPunctuationReturnsCommand() {
        let result = makeResult(text: "ROGER.", silenceBefore: .milliseconds(2000), duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result), .command(.roger))
    }

    func testIsolatedAbortReturnsCommand() {
        let result = makeResult(text: "ABORT", silenceBefore: .milliseconds(2000), duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result), .command(.abort))
    }

    func testIsolatedAbortWithTrailingPunctuationReturnsCommand() {
        let result = makeResult(text: "ABORT!", silenceBefore: .milliseconds(2000), duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result), .command(.abort))
    }

    func testVocabularyWithLowSilenceBeforeStillResolvesCommand() {
        let result = makeResult(text: "ROGER", silenceBefore: .milliseconds(1000), duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result), .command(.roger))
    }

    func testVocabularyWithZeroSilenceBeforeStillResolvesCommand() {
        let result = makeResult(text: "ROGER", silenceBefore: .zero, duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result), .command(.roger))
    }

    func testVocabularyWithDurationAtOrAboveThresholdInjects() {
        let result = makeResult(text: "ABORT", silenceBefore: .milliseconds(2000), duration: .milliseconds(2000))
        XCTAssertEqual(resolver.resolve(result), .inject("ABORT"))
    }

    func testVocabularyWithLowTrailingSilenceStillResolvesCommand() {
        let result = makeResult(
            text: "ROGER",
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(100)
        )
        XCTAssertEqual(resolver.resolve(result), .command(.roger))
    }

    func testVocabularyNotEndedBySilenceInjects() {
        let result = makeResult(
            text: "ROGER",
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            endedBySilence: false
        )
        XCTAssertEqual(resolver.resolve(result), .inject("ROGER"))
    }

    func testVocabularyWithLongDurationInjects() {
        let result = makeResult(text: "ROGER", silenceBefore: .milliseconds(2000), duration: .milliseconds(3000))
        XCTAssertEqual(resolver.resolve(result), .inject("ROGER"))
    }

    // MARK: - Non-vocabulary never produces command

    func testNonVocabularyTextNeverReturnsCommandRegardlessOfTiming() {
        let timings: [(Duration, Duration)] = [
            (.milliseconds(2000), .milliseconds(500)),
            (.milliseconds(100), .milliseconds(500)),
            (.milliseconds(2000), .milliseconds(3000)),
        ]
        for (silence, duration) in timings {
            let result = makeResult(text: "hello world", silenceBefore: silence, duration: duration)
            let intent = resolver.resolve(result)
            if case .command = intent {
                XCTFail("Non-vocabulary text must never resolve to command (silence=\(silence), duration=\(duration))")
            }
        }
    }

    func testPartialVocabularyMatchDoesNotCommand() {
        for text in ["ROGER that", "ABORT mission", "say ROGER", "ABORTED"] {
            let result = makeResult(text: text, silenceBefore: .milliseconds(2000), duration: .milliseconds(800))
            let intent = resolver.resolve(result)
            if case .command = intent {
                XCTFail("Partial vocabulary match '\(text)' must not resolve to command")
            }
        }
    }

    // MARK: - Confidence boundary

    func testConfidenceAtFloorIsAccepted() {
        let result = makeResult(text: "git status", confidence: 0.3)
        XCTAssertEqual(resolver.resolve(result), .inject("git status"))
    }

    func testConfidenceJustBelowFloorIsDiscarded() {
        let result = makeResult(text: "git status", confidence: 0.29)
        XCTAssertEqual(resolver.resolve(result), .discard)
    }
}

final class TerminalTextNormalizerTests: XCTestCase {
    // MARK: Internal

    func testStripsTrailingCommandPunctuation() {
        XCTAssertEqual(normalizer.normalizeForInjection("git status."), "git status")
        XCTAssertEqual(normalizer.normalizeForInjection("npm run build!"), "npm run build")
        XCTAssertEqual(normalizer.normalizeForInjection("ls -la;"), "ls -la")
    }

    func testKeepsInternalPunctuation() {
        XCTAssertEqual(normalizer.normalizeForInjection("say hello, world"), "say hello, world")
        XCTAssertEqual(normalizer.normalizeForInjection("git commit -m fix: tests"), "git commit -m fix: tests")
    }

    func testTrimsWhitespaceWhileNormalizing() {
        XCTAssertEqual(normalizer.normalizeForInjection("  git status.  "), "git status")
    }

    // MARK: Private

    private let normalizer = TerminalTextNormalizer()
}

extension Intent: Equatable {
    public static func == (lhs: Intent, rhs: Intent) -> Bool {
        switch (lhs, rhs) {
        case (.discard, .discard): true
        case let (.inject(a), .inject(b)): a == b
        case let (.command(a), .command(b)): a == b
        default: false
        }
    }
}
