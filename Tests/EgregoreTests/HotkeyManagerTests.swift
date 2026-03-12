import XCTest
@testable import Egregore

final class HotkeyManagerTests: XCTestCase {

    private func makeSUT(bindings: HotkeyBindings = .default) -> NSEventHotkeyManager {
        NSEventHotkeyManager(bindings: bindings, installMonitors: false)
    }

    private func tapToggleKey(_ sut: NSEventHotkeyManager, bindings: HotkeyBindings = .default) async {
        await sut.processFlagsChanged(keyCode: bindings.toggleKey.keyCode,
                                       flags: [bindings.toggleKey.flag])
        await sut.processFlagsChanged(keyCode: bindings.toggleKey.keyCode, flags: [])
    }

    // MARK: - Toggle

    func testRightControlTapEmitsToggle() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await tapToggleKey(sut)

        let event = await iter.next()
        XCTAssertEqual(event, .toggle)
    }

    func testRightControlTapEmitsOnlyOncePerPress() async {
        let sut = makeSUT()
        var iter = sut.events.makeAsyncIterator()

        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.toggleKey.keyCode,
                                       flags: [HotkeyBindings.default.toggleKey.flag])
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.toggleKey.keyCode,
                                       flags: [HotkeyBindings.default.toggleKey.flag])
        await sut.processFlagsChanged(keyCode: HotkeyBindings.default.toggleKey.keyCode, flags: [])

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

        await tapToggleKey(sut)
        await tapToggleKey(sut)
        await tapToggleKey(sut)

        let first  = await iter.next()
        let second = await iter.next()
        let third  = await iter.next()

        XCTAssertEqual(first,  .toggle)
        XCTAssertEqual(second, .toggle)
        XCTAssertEqual(third,  .toggle)
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

    func testCustomBindingsToggleUsesConfiguredKeyCode() async {
        let custom = HotkeyBindings(
            toggleKey: KeyBinding(keyCode: 61, flag: .option, displayName: "Right Option")
        )
        let sut = makeSUT(bindings: custom)
        var iter = sut.events.makeAsyncIterator()

        await sut.processFlagsChanged(keyCode: 61, flags: .option)
        await sut.processFlagsChanged(keyCode: 61, flags: [])

        let event = await iter.next()
        XCTAssertEqual(event, .toggle)
    }

    func testCustomBindingsIgnoresDefaultToggleKey() async {
        let custom = HotkeyBindings(
            toggleKey: KeyBinding(keyCode: 61, flag: .option, displayName: "Right Option")
        )
        let sut = makeSUT(bindings: custom)

        // Default Right Control (62) should NOT trigger toggle
        await sut.processFlagsChanged(keyCode: 62, flags: .control)
        var count = 0
        let task = Task {
            for await _ in sut.events { count += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(count, 0)
    }

    func testBindingsExposedOnManager() async {
        let custom = HotkeyBindings(
            toggleKey: KeyBinding(keyCode: 59, flag: .control, displayName: "Left Control")
        )
        let sut = makeSUT(bindings: custom)
        let b = await sut.bindings
        XCTAssertEqual(b.toggleKey.displayName, "Left Control")
    }
}
