import AppKit
import Foundation

// Right-side modifier key codes (macOS hardware constants).
private let keyCodeRightShift:   UInt16 = 60
private let keyCodeRightCommand: UInt16 = 54
private let keyCodeRightControl: UInt16 = 62

// Hides NSEvent global monitors, modifier-key state tracking, and right-side
// key disambiguation. Callers receive resolved HotkeyEvent values only.
actor NSEventHotkeyManager: HotkeyManager {

    private let outputContinuation: AsyncStream<HotkeyEvent>.Continuation
    nonisolated let events: AsyncStream<HotkeyEvent>

    // Modifier state — only Right-side keys tracked.
    private var rightCommandDown = false
    private var rightShiftDown   = false
    private var rightControlDown = false

    // Live monitors — nil in test context.
    private var monitors: [Any] = []

    // Production init installs global NSEvent monitors.
    // Pass installMonitors: false in tests to inject events via processFlagsChanged directly.
    init(installMonitors: Bool = true) {
        var cont: AsyncStream<HotkeyEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        outputContinuation = cont

        guard installMonitors else { return }
        // Defer monitor installation until after full init.
        Task { await self._installMonitors() }
    }

    // MARK: - Internal (accessible from tests via @testable import)

    func processFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        switch keyCode {
        case keyCodeRightCommand:
            let isDown = flags.contains(.command)
            if isDown && !rightCommandDown {
                rightCommandDown = true
                RuntimeLogger.shared.log("Right Command down → pttBegan", category: .hotkey)
                outputContinuation.yield(.pttBegan)
            } else if !isDown && rightCommandDown {
                rightCommandDown = false
                let inputMode: InputMode = rightShiftDown ? .command : .dictation
                RuntimeLogger.shared.log("Right Command up → pttEnded(\(inputMode))", category: .hotkey)
                outputContinuation.yield(.pttEnded(mode: inputMode))
            }

        case keyCodeRightShift:
            rightShiftDown = flags.contains(.shift)

        case keyCodeRightControl:
            let isDown = flags.contains(.control)
            if isDown && !rightControlDown {
                rightControlDown = true
                RuntimeLogger.shared.log("Right Control tap → modeToggled", category: .hotkey)
                outputContinuation.yield(.modeToggled)
            } else if !isDown {
                rightControlDown = false
            }

        default:
            break
        }
    }

    // MARK: - Private

    private func _installMonitors() {
        let cont = outputContinuation
        // Extract Sendable values from NSEvent before crossing actor boundary.
        let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            Task { await self?.processFlagsChanged(keyCode: keyCode, flags: flags) }
        }
        if let m { monitors.append(m) }
        _ = cont  // silence unused warning; cont captured via outputContinuation
    }
}
