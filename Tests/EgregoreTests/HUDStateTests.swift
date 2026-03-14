import XCTest
@testable import Egregore

final class HUDStateTests: XCTestCase {
    // MARK: Internal

    // MARK: - Toggle emits recording state

    func testToggleEmitsRecordingState() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: ""))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.toggle)

        let states = await stateTask.value
        XCTAssertEqual(states.first, .listening)
    }

    // MARK: - Dictation: recording → transcribing → injected

    func testDictationEmitsFullSequence() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "git status"))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        // listening + transcribing + injected = 3 states
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment())

        let states = await stateTask.value
        XCTAssertGreaterThanOrEqual(states.count, 3)
        XCTAssertEqual(states[0], .listening)
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .injected(continueListening: true))
    }

    // MARK: - Discard emits idle then recording (auto-restart)

    func testDiscardEmitsIdle() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "noise", confidence: 0.05))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        // listening + transcribing + listening = 3 states
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment())

        let states = await stateTask.value
        XCTAssertGreaterThanOrEqual(states.count, 3)
        XCTAssertEqual(states[0], .listening)
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .listening)
    }

    // MARK: - Toggle off emits idle

    func testToggleOffEmitsIdle() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: ""))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        // listening + idle = 2 states
        let stateTask = Task { await self.collectStates(from: ctrl, count: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        hotkeys.emit(.toggle)

        let states = await stateTask.value
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states[0], .listening)
        XCTAssertEqual(states[1], .idle)
    }

    // MARK: - Utterance → transcribing → injected

    func testUtteranceEmitsTranscribingThenInjected() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(
            text: "ls -la",
            silenceBefore: .milliseconds(200),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        // listening + transcribing + injected = 3
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(200),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        let states = await stateTask.value
        XCTAssertGreaterThanOrEqual(states.count, 3)
        XCTAssertEqual(states[0], .listening)
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .injected(continueListening: true))
    }

    // MARK: - Isolated ABORT → cleared

    func testIsolatedAbortEmitsCleared() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(
            text: "ABORT",
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        let states = await stateTask.value
        XCTAssertGreaterThanOrEqual(states.count, 3)
        XCTAssertEqual(states[0], .listening)
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .cleared(continueListening: true))
    }

    func testAppendFailureEmitsErrorState() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "git status"))
        let output = MockOutputManager()
        output.appendResult = .failure("No active terminal target")
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        txr.emitPartial("git status")

        let states = await stateTask.value
        XCTAssertEqual(states[0], .listening)
        XCTAssertEqual(states[1], .error("No active terminal target", continueListening: true))
    }

    func testSendFailureEmitsErrorState() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(
            text: "ROGER",
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
        let output = MockOutputManager()
        output.sendResult = .failure("Terminal session is busy")
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        let states = await stateTask.value
        XCTAssertEqual(states[2], .error("Terminal session is busy", continueListening: true))
    }

    // MARK: - Live transcript partial text in HUD

    func testPartialTextRoutedToOutput() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "git status"))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        txr.emitPartial("git")

        let states = await stateTask.value
        XCTAssertEqual(states[0], .listening)
        XCTAssertEqual(states[1], .recording)
        XCTAssertEqual(output.appended, ["git"])
    }

    func testMultiplePartialsDeltaAppendedToOutput() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "git status"))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        txr.emitPartial("g")
        try await Task.sleep(nanoseconds: 20_000_000)
        txr.emitPartial("git")
        try await Task.sleep(nanoseconds: 20_000_000)
        txr.emitPartial("git status")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(output.appended, ["g", "it", " status"])
    }

    func testStalePartialSuppressedAfterFinalization() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "git status"))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        // Collect the normal sequence: listening → partial → idle
        let stateTask = Task { await self.collectStates(from: ctrl, count: 4) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        txr.emitPartial("git")
        try await Task.sleep(nanoseconds: 20_000_000)
        // Toggle off to stop recording before segment
        hotkeys.emit(.toggle)

        let states = await stateTask.value
        XCTAssertGreaterThanOrEqual(states.count, 2)

        // After stopping, stale partials should not produce recording states
        let leakExp = expectation(description: "no stale partial leak")
        leakExp.isInverted = true
        let leakTask = Task {
            for await state in ctrl.hudStates {
                if case .recording = state {
                    leakExp.fulfill()
                }
                break
            }
        }
        txr.emitPartial("stale partial")
        await fulfillment(of: [leakExp], timeout: 0.3)
        leakTask.cancel()
    }

    func testPartialStreamDeliversBeforeSlowSnapshotDecode() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "hello world"))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)

        txr.emitPartial("hello")

        let states = await stateTask.value
        XCTAssertEqual(states[0], .listening)
        XCTAssertEqual(states[1], .recording)
        XCTAssertEqual(output.appended, ["hello"])
    }

    func testFinalResultDoesNotImmediatelyBounceBackToListeningState() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "git status"))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 3, timeout: .seconds(2)) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment())

        let states = await stateTask.value
        XCTAssertEqual(states, [
            .listening,
            .transcribing,
            .injected(continueListening: true),
        ])
    }

    func testPartialTextNotEmittedAfterSegmentProcessed() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeResult(text: "git status"))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        // recording + transcribing + injected = 3
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        // Toggle off first to stop recording
        hotkeys.emit(.toggle)

        let states = await stateTask.value
        XCTAssertGreaterThanOrEqual(states.count, 2)

        // Emit a stale snapshot — should not produce a new recording state
        txr.partialText = "stale"
        await pipeline.emitSnapshot(makeCaptureSnapshot())
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testHUDAnchoredFrameKeepsBottomMarginWhenHeightChanges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let compact = HUDWindowController.anchoredFrame(screenFrame: screen)
        let expanded = HUDWindowController.anchoredFrame(screenFrame: screen, width: 160, height: 44)

        XCTAssertEqual(compact.minY, HUDWindowController.bottomMargin)
        XCTAssertEqual(expanded.minY, HUDWindowController.bottomMargin)
        XCTAssertEqual(compact.midX, screen.midX, accuracy: 0.5)
        XCTAssertEqual(expanded.midX, screen.midX, accuracy: 0.5)
    }

    // MARK: - Anchored frame calculation for various screen sizes

    func testAnchoredFrameCalculationForVariousScreenSizes() {
        let screens: [(CGRect, String)] = [
            (CGRect(x: 0, y: 0, width: 1920, height: 1080), "1080p"),
            (CGRect(x: 0, y: 0, width: 2560, height: 1440), "1440p"),
            (CGRect(x: 0, y: 0, width: 3840, height: 2160), "4K"),
            (CGRect(x: 0, y: 23, width: 1440, height: 877), "MacBook with menu bar offset"),
            (CGRect(x: 1440, y: 0, width: 1920, height: 1080), "external monitor offset"),
        ]

        for (screenFrame, label) in screens {
            let frame = HUDWindowController.anchoredFrame(screenFrame: screenFrame)

            XCTAssertEqual(frame.width, HUDWindowController.width, "\(label): width")
            XCTAssertEqual(frame.height, HUDWindowController.height, "\(label): height")
            XCTAssertEqual(
                frame.minY,
                screenFrame.minY + HUDWindowController.bottomMargin,
                "\(label): bottom margin from screen origin"
            )
            XCTAssertEqual(
                frame.midX,
                screenFrame.midX,
                accuracy: 0.5,
                "\(label): horizontal center"
            )
        }
    }

    func testAnchoredFrameProducesCorrectResultsForDifferentScreenFrames() {
        let small = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let large = CGRect(x: 0, y: 0, width: 3840, height: 2160)

        let smallFrame = HUDWindowController.anchoredFrame(screenFrame: small)
        let largeFrame = HUDWindowController.anchoredFrame(screenFrame: large)

        XCTAssertEqual(
            smallFrame.minY,
            largeFrame.minY,
            "bottom margin identical regardless of screen size"
        )
        XCTAssertNotEqual(
            smallFrame.midX,
            largeFrame.midX,
            "horizontal center differs for different widths"
        )
        XCTAssertEqual(smallFrame.midX, small.midX, accuracy: 0.5)
        XCTAssertEqual(largeFrame.midX, large.midX, accuracy: 0.5)
    }

    // MARK: Private

    // MARK: - Helpers

    private func makeSpeechSegment(
        silenceBefore: Duration = .milliseconds(2000),
        duration: Duration = .milliseconds(800),
        trailingSilenceAfter: Duration = .zero,
        endedBySilence: Bool = false
    ) -> SpeechSegment {
        SpeechSegment(
            audio: [Float](repeating: 0.1, count: 1600),
            silenceBefore: silenceBefore,
            duration: duration,
            trailingSilenceAfter: trailingSilenceAfter,
            endedBySilence: endedBySilence
        )
    }

    private func makeCaptureSnapshot(
        duration: Duration = .milliseconds(300)
    ) -> SpeechCaptureSnapshot {
        SpeechCaptureSnapshot(audio: [Float](repeating: 0.1, count: 3200), duration: duration)
    }

    private func makeResult(
        text: String,
        confidence: Float = 0.9,
        silenceBefore: Duration = .milliseconds(2000),
        duration: Duration = .milliseconds(800),
        trailingSilenceAfter: Duration = .zero,
        endedBySilence: Bool = false
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            confidence: confidence,
            segment: makeSpeechSegment(
                silenceBefore: silenceBefore,
                duration: duration,
                trailingSilenceAfter: trailingSilenceAfter,
                endedBySilence: endedBySilence
            )
        )
    }

    private func collectStates(
        from controller: SessionController,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async -> [HUDState] {
        let task = Task {
            var states: [HUDState] = []
            for await state in controller.hudStates {
                states.append(state)
                if states.count >= count {
                    break
                }
            }
            return states
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            task.cancel()
        }
        let result = await task.value
        timer.cancel()
        return result
    }
}
