import XCTest
@testable import VoiceShell

// Tests inject events via processFlagsChanged — no hardware or NSEvent delivery needed.
// Each processFlagsChanged call is awaited on the actor before iter.next(), so emitted
// events are already buffered when we read from the stream.

final class HotkeyManagerTests: XCTestCase {

    private func makeSUT() -> NSEventHotkeyManager {
        NSEventHotkeyManager(installMonitors: false)
    }

    // Convenience: press Right Option (option flag set)
    private func pressRightOption(_ sut: NSEventHotkeyManager) async {
        await sut.processFlagsChanged(keyCode: 61, flags: .option)
    }

    // Release Right Option (no option flag)
    private func releaseRightOption(_ sut: NSEventHotkeyManager,
                                    withShift: Bool = false) async {
        let flags: NSEvent.ModifierFlags = withShift ? [.shift] : []
        await sut.processFlagsChanged(keyCode: 61, flags: flags)
    }

    private func pressRightShift(_ sut: NSEventHotkeyManager) async {
        await sut.processFlagsChanged(keyCode: 60, flags: [.shift])
    }

    private func releaseRightShift(_ sut: NSEventHotkeyManager) async {
        await sut.processFlagsChanged(keyCode: 60, flags: [])
    }

    private func tapRightControl(_ sut: NSEventHotkeyManager) async {
        await sut.processFlagsChanged(keyCode: 62, flags: [.control])
        await sut.processFlagsChanged(keyCode: 62, flags: [])
    }

    // MARK: - PTT begin

    func testRightOptionPressEmitsPTTBegan() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightOption(sut)

        let event = await iter.next()
        XCTAssertEqual(event, .pttBegan)
    }

    func testRepeatedRightOptionPressOnlyEmitsOnePTTBegan() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightOption(sut)
        await pressRightOption(sut)   // already down — should be ignored

        // Only one pttBegan should be in the stream.
        var collected: [HotkeyEvent] = []
        let task = Task {
            for await e in sut.events { collected.append(e) }
        }
        // First event already buffered.
        _ = await iter.next()
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()

        // Only one pttBegan ever emitted.
        let began = collected.filter { $0 == .pttBegan }
        XCTAssertEqual(began.count, 0)   // iter consumed the only one; none left
    }

    // MARK: - PTT end — dictation mode

    func testRightOptionReleaseWithoutShiftEmitsDictationEnd() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightOption(sut)
        _ = await iter.next()   // consume pttBegan

        await releaseRightOption(sut, withShift: false)

        let event = await iter.next()
        XCTAssertEqual(event, .pttEnded(mode: .dictation))
    }

    // MARK: - PTT end — command mode

    func testRightShiftPluRightOptionEmitsCommandModeEnd() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightShift(sut)
        await pressRightOption(sut)
        _ = await iter.next()   // consume pttBegan

        await releaseRightOption(sut, withShift: true)

        let event = await iter.next()
        XCTAssertEqual(event, .pttEnded(mode: .command))
    }

    func testCommandModeRequiresRightShiftAtReleaseTime() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        // Press shift, then option, then release shift before releasing option.
        await pressRightShift(sut)
        await pressRightOption(sut)
        _ = await iter.next()   // consume pttBegan

        await releaseRightShift(sut)            // shift gone before option release
        await releaseRightOption(sut, withShift: false)

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

        // Press and hold — should emit once.
        await sut.processFlagsChanged(keyCode: 62, flags: [.control])
        await sut.processFlagsChanged(keyCode: 62, flags: [.control]) // hold — ignored
        await sut.processFlagsChanged(keyCode: 62, flags: [])         // release

        _ = await iter.next()   // one modeToggled

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

        await pressRightOption(sut)
        await releaseRightOption(sut)

        let first  = await iter.next()
        let second = await iter.next()

        XCTAssertEqual(first,  .pttBegan)
        XCTAssertEqual(second, .pttEnded(mode: .dictation))
    }

    func testMultiplePTTCyclesEmitCorrectSequence() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await pressRightOption(sut)
        await releaseRightOption(sut)
        await pressRightOption(sut)
        await releaseRightOption(sut)

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
}
