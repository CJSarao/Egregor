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

    func testLowConfidenceDiscardedInDictationMode() {
        let result = makeResult(text: "hello world", confidence: 0.1)
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .discard)
    }

    func testLowConfidenceDiscardedInCommandMode() {
        let result = makeResult(text: "ROGER", confidence: 0.1)
        XCTAssertEqual(resolver.resolve(result, mode: .command), .discard)
    }

    func testLowConfidenceVocabularyWordDiscardedBeforeInjection() {
        let result = makeResult(text: "ABORT", confidence: 0.05, silenceBefore: .milliseconds(2000), duration: .milliseconds(500))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .discard)
    }

    // MARK: - PTT command mode

    func testCommandModeRogerReturnsRoger() {
        let result = makeResult(text: "ROGER")
        XCTAssertEqual(resolver.resolve(result, mode: .command), .command(.roger))
    }

    func testCommandModeAbortReturnsAbort() {
        let result = makeResult(text: "ABORT")
        XCTAssertEqual(resolver.resolve(result, mode: .command), .command(.abort))
    }

    func testCommandModeLowercaseVocabularyMatches() {
        let result = makeResult(text: "roger")
        XCTAssertEqual(resolver.resolve(result, mode: .command), .command(.roger))
    }

    func testCommandModeNonVocabularyDiscardsRegardlessOfTiming() {
        for text in ["hello", "send", "clear", "go", "stop", "run tests"] {
            let result = makeResult(text: text)
            XCTAssertEqual(
                resolver.resolve(result, mode: .command),
                .discard,
                "Expected discard for '\(text)' in command mode"
            )
        }
    }

    func testCommandModeNeverInjects() {
        let result = makeResult(text: "hello world")
        let intent = resolver.resolve(result, mode: .command)
        if case .inject = intent { XCTFail("Command mode must never inject") }
    }

    // MARK: - PTT dictation mode / OPEN normal utterances

    func testDictationModeNonVocabularyInjects() {
        let result = makeResult(text: "git status", endedBySilence: false)
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .inject("git status"))
    }

    func testDictationModeNonVocabularyWithIsolationTimingStillInjects() {
        let result = makeResult(text: "hello", silenceBefore: .milliseconds(2000), duration: .milliseconds(500))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .inject("hello"))
    }

    func testPTTStyleVocabularyInjectsWhenUtteranceDidNotEndBySilence() {
        let result = makeResult(text: "ROGER",
                                silenceBefore: .milliseconds(2000),
                                duration: .milliseconds(800),
                                trailingSilenceAfter: .milliseconds(200),
                                endedBySilence: false)
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .inject("ROGER"))
    }

    // MARK: - OPEN mode isolation algorithm (dictation mode + timing)

    func testIsolatedRogerReturnsCommandInDictationMode() {
        let result = makeResult(text: "ROGER", silenceBefore: .milliseconds(2000), duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .command(.roger))
    }

    func testIsolatedAbortReturnsCommandInDictationMode() {
        let result = makeResult(text: "ABORT", silenceBefore: .milliseconds(2000), duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .command(.abort))
    }

    func testVocabularyWithLowSilenceBeforeStillResolvesCommand() {
        let result = makeResult(text: "ROGER", silenceBefore: .milliseconds(1000), duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .command(.roger))
    }

    func testVocabularyWithZeroSilenceBeforeStillResolvesCommand() {
        let result = makeResult(text: "ROGER", silenceBefore: .zero, duration: .milliseconds(800))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .command(.roger))
    }

    func testVocabularyWithDurationAtOrAboveThresholdInjects() {
        // duration must be LESS THAN 2000ms
        let result = makeResult(text: "ABORT", silenceBefore: .milliseconds(2000), duration: .milliseconds(2000))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .inject("ABORT"))
    }

    func testVocabularyWithLowTrailingSilenceStillResolvesCommand() {
        let result = makeResult(text: "ROGER",
                                silenceBefore: .milliseconds(2000),
                                duration: .milliseconds(800),
                                trailingSilenceAfter: .milliseconds(100))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .command(.roger))
    }

    func testVocabularyNotEndedBySilenceInjects() {
        let result = makeResult(text: "ROGER",
                                silenceBefore: .milliseconds(2000),
                                duration: .milliseconds(800),
                                endedBySilence: false)
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .inject("ROGER"))
    }

    func testVocabularyWithLongDurationInjects() {
        let result = makeResult(text: "ROGER", silenceBefore: .milliseconds(2000), duration: .milliseconds(3000))
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .inject("ROGER"))
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
            let intent = resolver.resolve(result, mode: .dictation)
            if case .command = intent {
                XCTFail("Non-vocabulary text must never resolve to command (silence=\(silence), duration=\(duration))")
            }
        }
    }

    func testPartialVocabularyMatchDoesNotCommand() {
        for text in ["ROGER that", "ABORT mission", "say ROGER", "ABORTED"] {
            let result = makeResult(text: text, silenceBefore: .milliseconds(2000), duration: .milliseconds(800))
            let intent = resolver.resolve(result, mode: .dictation)
            if case .command = intent {
                XCTFail("Partial vocabulary match '\(text)' must not resolve to command")
            }
        }
    }

    // MARK: - Confidence boundary

    func testConfidenceAtFloorIsAccepted() {
        // Exactly at the floor should be accepted (>=)
        let result = makeResult(text: "git status", confidence: 0.3)
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .inject("git status"))
    }

    func testConfidenceJustBelowFloorIsDiscarded() {
        let result = makeResult(text: "git status", confidence: 0.29)
        XCTAssertEqual(resolver.resolve(result, mode: .dictation), .discard)
    }
}

extension Intent: Equatable {
    public static func == (lhs: Intent, rhs: Intent) -> Bool {
        switch (lhs, rhs) {
        case (.discard, .discard): return true
        case (.inject(let a), .inject(let b)): return a == b
        case (.command(let a), .command(let b)): return a == b
        default: return false
        }
    }
}
