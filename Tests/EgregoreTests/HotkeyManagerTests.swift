import XCTest
@testable import Egregore

final class HotkeyManagerTests: XCTestCase {

    private func makeSUT(bindings: HotkeyBindings = .default) -> NSEventHotkeyManager {
        NSEventHotkeyManager(bindings: bindings, installMonitors: false)
    }

    private func pressRightCommand(_ sut: NSEventHotkeyManager) async {
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.pttKey.keyCode,
                                       flags: HotkeyBindings.default.pttKey.flag)
    }

    private func releaseRightCommand(_ sut: NSEventHotkeyManager, withShift: Bool = false) async {
        let flags: NSEvent.ModifierFlags = withShift ? [HotkeyBindings.default.commandModifier.flag] : []
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.pttKey.keyCode, flags: flags)
    }

    private func pressRightShift(_ sut: NSEventHotkeyManager) async {
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.commandModifier.keyCode,
                                       flags: [HotkeyBindings.default.commandModifier.flag])
    }

    private func releaseRightShift(_ sut: NSEventHotkeyManager) async {
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.commandModifier.keyCode, flags: [])
    }

    private func tapRightControl(_ sut: NSEventHotkeyManager) async {
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.modeToggle.keyCode,
                                       flags: [HotkeyBindings.default.modeToggle.flag])
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.modeToggle.keyCode, flags: [])
    }

    // MARK: - PTT begin

    func testRightCommandPressEmitsPTTBegan() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightCommand(sut)

        let event = await iter.next()
        XCTAssertEqual(event, .pttBegan)
    }

    func testRepeatedRightCommandPressOnlyEmitsOnePTTBegan() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightCommand(sut)
        await pressRightCommand(sut)

        var collected: [HotkeyEvent] = []
        let task = Task {
            for await e in sut.events { collected.append(e) }
        }
        _ = await iter.next()
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()

        let began = collected.filter { $0 == .pttBegan }
        XCTAssertEqual(began.count, 0)
    }

    // MARK: - PTT end — dictation mode

    func testRightCommandReleaseWithoutShiftEmitsDictationEnd() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightCommand(sut)
        _ = await iter.next()

        await releaseRightCommand(sut, withShift: false)

        let event = await iter.next()
        XCTAssertEqual(event, .pttEnded(mode: .dictation))
    }

    // MARK: - PTT end — command mode

    func testRightShiftPlusRightCommandEmitsCommandModeEnd() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightShift(sut)
        await pressRightCommand(sut)
        _ = await iter.next()

        await releaseRightCommand(sut, withShift: true)

        let event = await iter.next()
        XCTAssertEqual(event, .pttEnded(mode: .command))
    }

    func testCommandModeRequiresRightShiftAtReleaseTime() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightShift(sut)
        await pressRightCommand(sut)
        _ = await iter.next()

        await releaseRightShift(sut)
        await releaseRightCommand(sut, withShift: false)

        let event = await iter.next()
        XCTAssertEqual(event, .pttEnded(mode: .dictation))
    }

    // MARK: - Right Shift alone emits no events

    func testRightShiftAloneEmitsNoEvents() async {
        let sut = makeSUT()
        await pressRightShift(sut)
        await releaseRightShift(sut)

        var count = 0
        let task = Task {
            for await _ in sut.events { count += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Mode toggle

    func testRightControlTapEmitsModeToggled() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await tapRightControl(sut)

        let event = await iter.next()
        XCTAssertEqual(event, .modeToggled)
    }

    func testRightControlTapEmitsOnlyOncePerPress() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.modeToggle.keyCode,
                                       flags: [HotkeyBindings.default.modeToggle.flag])
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.modeToggle.keyCode,
                                       flags: [HotkeyBindings.default.modeToggle.flag])
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.modeToggle.keyCode, flags: [])

        _ = await iter.next()

        var extra = 0
        let task = Task {
            for await _ in sut.events { extra += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(extra, 0)
    }

    func testMultipleRightControlTapsEmitMultipleToggles() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await tapRightControl(sut)
        await tapRightControl(sut)
        await tapRightControl(sut)

        let first  = await iter.next()
        let second = await iter.next()
        let third  = await iter.next()

        XCTAssertEqual(first,  .modeToggled)
        XCTAssertEqual(second, .modeToggled)
        XCTAssertEqual(third,  .modeToggled)
    }

    // MARK: - PTT begin/end sequence

    func testFullPTTCycleEmitsBothEvents() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightCommand(sut)
        await releaseRightCommand(sut)

        let first  = await iter.next()
        let second = await iter.next()

        XCTAssertEqual(first,  .pttBegan)
        XCTAssertEqual(second, .pttEnded(mode: .dictation))
    }

    func testMultiplePTTCyclesEmitCorrectSequence() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightCommand(sut)
        await releaseRightCommand(sut)
        await pressRightCommand(sut)
        await releaseRightCommand(sut)

        let e1 = await iter.next()
        let e2 = await iter.next()
        let e3 = await iter.next()
        let e4 = await iter.next()

        XCTAssertEqual(e1, .pttBegan)
        XCTAssertEqual(e2, .pttEnded(mode: .dictation))
        XCTAssertEqual(e3, .pttBegan)
        XCTAssertEqual(e4, .pttEnded(mode: .dictation))
    }

    // MARK: - Unknown key codes are silently ignored

    func testUnknownKeyCodeEmitsNoEvent() async {
        let sut = makeSUT()
        await sut.processFlagsChanged(keyCode: 99, flags: [.command])

        var count = 0
        let task = Task {
            for await _ in sut.events { count += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Custom bindings

    func testCustomBindingsIgnoresDefaultPTTKey() async {
        let custom = HotkeyBindings(
            pttKey: KeyBinding(keyCode: 61, flag: .option, displayName: "Right Option"),
            commandModifier: KeyBinding(keyCode: 60, flag: .shift, displayName: "Right Shift"),
            modeToggle: KeyBinding(keyCode: 62, flag: .control, displayName: "Right Control")
        )
        let sut = makeSUT(bindings: custom)

        // Default Right Command (54) should NOT trigger PTT
        await sut.processFlagsChanged(keyCode: 54, flags: .command)
        var count = 0
        let task = Task {
            for await _ in sut.events { count += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(count, 0)
    }

    func testCustomBindingsPTTUsesConfiguredKeyCode() async {
        let custom = HotkeyBindings(
            pttKey: KeyBinding(keyCode: 61, flag: .option, displayName: "Right Option"),
            commandModifier: KeyBinding(keyCode: 60, flag: .shift, displayName: "Right Shift"),
            modeToggle: KeyBinding(keyCode: 62, flag: .control, displayName: "Right Control")
        )
        let sut = makeSUT(bindings: custom)
        var iter = sut.events.makeAsyncIterator()

        await sut.processFlagsChanged(keyCode: 61, flags: .option)
        let event = await iter.next()
        XCTAssertEqual(event, .pttBegan)
    }

    func testCustomBindingsModeToggleUsesConfiguredKeyCode() async {
        let custom = HotkeyBindings(
            pttKey: KeyBinding(keyCode: 54, flag: .command, displayName: "Right Command"),
            commandModifier: KeyBinding(keyCode: 60, flag: .shift, displayName: "Right Shift"),
            modeToggle: KeyBinding(keyCode: 61, flag: .option, displayName: "Right Option")
        )
        let sut = makeSUT(bindings: custom)
        var iter = sut.events.makeAsyncIterator()

        // Tap custom mode toggle key
        await sut.processFlagsChanged(keyCode: 61, flags: .option)
        await sut.processFlagsChanged(keyCode: 61, flags: [])

        let event = await iter.next()
        XCTAssertEqual(event, .modeToggled)
    }

    func testBindingsExposedOnManager() async {
        let custom = HotkeyBindings(
            pttKey: KeyBinding(keyCode: 61, flag: .option, displayName: "Right Option"),
            commandModifier: KeyBinding(keyCode: 60, flag: .shift, displayName: "Right Shift"),
            modeToggle: KeyBinding(keyCode: 59, flag: .control, displayName: "Left Control")
        )
        let sut = makeSUT(bindings: custom)
        let b = await sut.bindings
        XCTAssertEqual(b.pttKey.displayName, "Right Option")
        XCTAssertEqual(b.modeToggle.displayName, "Left Control")
    }
}
