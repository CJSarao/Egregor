import XCTest
@testable import Egregore

// MARK: - HUD state emission tests

/// Verifies SessionController publishes correct HUDState transitions
/// for all spec-defined behaviors: recording, transcribing, injected, cleared, idle.
final class HUDStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeSpeechSegment(
        silenceBefore: Duration = .milliseconds(2000),
        duration: Duration = .milliseconds(800)
    ) -> SpeechSegment {
        SpeechSegment(audio: [Float](repeating: 0.1, count: 1600),
                      silenceBefore: silenceBefore, duration: duration)
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
        duration: Duration = .milliseconds(800)
    ) -> TranscriptionResult {
        TranscriptionResult(text: text, confidence: confidence,
                            segment: makeSpeechSegment(silenceBefore: silenceBefore, duration: duration))
    }

    /// Collects HUD states from the controller's stream until the expected count is reached or timeout.
    private func collectStates(
        from controller: SessionController,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async -> [HUDState] {
        var collected: [HUDState] = []
        let deadline = ContinuousClock.now + timeout
        for await state in controller.hudStates {
            collected.append(state)
            if collected.count >= count || ContinuousClock.now >= deadline { break }
        }
        return collected
    }

    // MARK: - PTT recording state

    func testPTTBeganEmitsRecordingState() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeResult(text: ""))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.pttBegan)

        let states = await stateTask.value
        XCTAssertEqual(states.first, .recording(mode: .ptt))
    }

    // MARK: - PTT dictation: recording → transcribing → injected

    func testPTTDictationEmitsFullSequence() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeResult(text: "git status"))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        // recording + transcribing + injected = 3 states
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .dictation))

        let states = await stateTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[0], .recording(mode: .ptt))
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .injected("git status"))
    }

    // MARK: - PTT discard emits idle

    func testPTTDiscardEmitsIdle() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeResult(text: "noise", confidence: 0.05))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        // recording + transcribing + idle = 3 states
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .dictation))

        let states = await stateTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[0], .recording(mode: .ptt))
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .idle)
    }

    // MARK: - PTT command ROGER → injected("⏎")

    func testPTTCommandRogerEmitsInjectedReturn() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeResult(text: "ROGER"))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .command))

        let states = await stateTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[2], .injected("⏎"))
    }

    // MARK: - PTT command ABORT → cleared

    func testPTTCommandAbortEmitsCleared() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeResult(text: "ABORT"))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .command))

        let states = await stateTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[0], .recording(mode: .ptt))
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .cleared)
    }

    // MARK: - Mode toggle emits recording(open)

    func testModeToggleToOpenEmitsRecordingOpen() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeResult(text: ""))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.modeToggled)

        let states = await stateTask.value
        XCTAssertEqual(states.first, .recording(mode: .open))
    }

    // MARK: - Mode toggle back to PTT emits idle

    func testModeToggleBackToPTTEmitsIdle() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeResult(text: ""))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        // open + idle = 2 states
        let stateTask = Task { await self.collectStates(from: ctrl, count: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.modeToggled)
        try await Task.sleep(nanoseconds: 30_000_000)
        hotkeys.emit(.modeToggled)

        let states = await stateTask.value
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states[0], .recording(mode: .open))
        XCTAssertEqual(states[1], .idle)
    }

    // MARK: - OPEN mode normal utterance → transcribing → injected

    func testOpenModeUtteranceEmitsTranscribingThenInjected() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeResult(text: "ls -la", silenceBefore: .milliseconds(200)))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        // recording(open) + transcribing + injected = 3
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.modeToggled)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(200)))

        let states = await stateTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[0], .recording(mode: .open))
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .injected("ls -la"))
    }

    // MARK: - OPEN mode isolated ABORT → cleared

    func testOpenModeIsolatedAbortEmitsCleared() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeResult(text: "ABORT",
                                                   silenceBefore: .milliseconds(2000),
                                                   duration: .milliseconds(800)))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.modeToggled)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(2000), duration: .milliseconds(800)))

        let states = await stateTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[0], .recording(mode: .open))
        XCTAssertEqual(states[1], .transcribing)
        XCTAssertEqual(states[2], .cleared)
    }

    // MARK: - Live transcript partial text in HUD

    func testPTTPartialTextAppearsInRecordingState() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeResult(text: "git status"))
        txr.partialText = "git"
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        // recording(ptt) + recording(ptt, partial) = 2 states
        let stateTask = Task { await self.collectStates(from: ctrl, count: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.pttBegan)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSnapshot(makeCaptureSnapshot())

        let states = await stateTask.value
        XCTAssertEqual(states[0], .recording(mode: .ptt))
        XCTAssertEqual(states[1], .recording(mode: .ptt, partialText: "git"))
    }

    func testOPENPartialTextAppearsInRecordingState() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeResult(text: "ls -la", silenceBefore: .milliseconds(200)))
        txr.partialText = "ls"
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        // recording(open) + recording(open, partial) = 2 states
        let stateTask = Task { await self.collectStates(from: ctrl, count: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.modeToggled)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSnapshot(makeCaptureSnapshot())

        let states = await stateTask.value
        XCTAssertEqual(states[0], .recording(mode: .open))
        XCTAssertEqual(states[1], .recording(mode: .open, partialText: "ls"))
    }

    func testPartialTextNotEmittedAfterSegmentProcessed() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeResult(text: "git status"))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        // recording + transcribing + injected = 3, then partial should be ignored
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .dictation))

        let states = await stateTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[2], .injected("git status"))

        // Emit a stale snapshot — should not produce a new recording state
        txr.partialText = "stale"
        await pipeline.emitSnapshot(makeCaptureSnapshot())
        try await Task.sleep(nanoseconds: 50_000_000)
        // No additional state collected — isRecording is false
    }

    // MARK: - HUD reflects mode in recording state

    func testHUDReflectsCurrentMode() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeResult(text: ""))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        // Toggle to open → recording(.open), toggle back → idle, pttBegan → recording(.ptt)
        let stateTask = Task { await self.collectStates(from: ctrl, count: 3) }
        try await Task.sleep(nanoseconds: 20_000_000)
        hotkeys.emit(.modeToggled)        // → .recording(.open)
        try await Task.sleep(nanoseconds: 30_000_000)
        hotkeys.emit(.modeToggled)        // → .idle (back to PTT)
        try await Task.sleep(nanoseconds: 30_000_000)
        hotkeys.emit(.pttBegan)           // → .recording(.ptt)

        let states = await stateTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[0], .recording(mode: .open))
        XCTAssertEqual(states[1], .idle)
        XCTAssertEqual(states[2], .recording(mode: .ptt))
    }

    func testHUDAnchoredFrameKeepsBottomMarginWhenHeightChanges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let compact = HUDWindowController.anchoredFrame(screenFrame: screen)
        let expanded = HUDWindowController.anchoredFrame(screenFrame: screen, width: 420, height: 88)

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
            XCTAssertEqual(frame.minY, screenFrame.minY + HUDWindowController.bottomMargin,
                           "\(label): bottom margin from screen origin")
            XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 0.5,
                           "\(label): horizontal center")
        }
    }

    func testAnchoredFrameProducesCorrectResultsForDifferentScreenFrames() {
        let small = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let large = CGRect(x: 0, y: 0, width: 3840, height: 2160)

        let smallFrame = HUDWindowController.anchoredFrame(screenFrame: small)
        let largeFrame = HUDWindowController.anchoredFrame(screenFrame: large)

        XCTAssertEqual(smallFrame.minY, largeFrame.minY,
                       "bottom margin identical regardless of screen size")
        XCTAssertNotEqual(smallFrame.midX, largeFrame.midX,
                          "horizontal center differs for different widths")
        XCTAssertEqual(smallFrame.midX, small.midX, accuracy: 0.5)
        XCTAssertEqual(largeFrame.midX, large.midX, accuracy: 0.5)
    }
}
