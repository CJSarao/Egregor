import AppKit
import Foundation

actor NSEventHotkeyManager: HotkeyManager {

    let bindings: HotkeyBindings

    private let outputContinuation: AsyncStream<HotkeyEvent>.Continuation
    nonisolated let events: AsyncStream<HotkeyEvent>

    private var pttKeyDown = false
    private var commandModifierDown = false
    private var pttCommandLatched = false
    private var modeToggleDown = false

    private var diagnosticsEnabled = false
    private var monitors: [Any] = []

    init(bindings: HotkeyBindings = .default, installMonitors: Bool = true) {
        self.bindings = bindings
        var cont: AsyncStream<HotkeyEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        outputContinuation = cont

        guard installMonitors else { return }
        Task { await self._installMonitors() }
    }

    func setDiagnostics(enabled: Bool) {
        diagnosticsEnabled = enabled
        RuntimeLogger.shared.log("Key diagnostics \(enabled ? "enabled" : "disabled")", category: .hotkey)
    }

    // MARK: - Internal (accessible from tests via @testable import)

    func processFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if diagnosticsEnabled {
            let flagNames = describeFlagsMask(flags)
            RuntimeLogger.shared.log("KEY EVENT keyCode=\(keyCode) flags=[\(flagNames)]", category: .hotkey)
        }

        if keyCode == bindings.pttKey.keyCode {
            let isDown = flags.contains(bindings.pttKey.flag)
            if isDown && !pttKeyDown {
                pttKeyDown = true
                pttCommandLatched = commandModifierDown
                RuntimeLogger.shared.log("\(bindings.pttKey.displayName) down → pttBegan", category: .hotkey)
                outputContinuation.yield(.pttBegan)
            } else if !isDown && pttKeyDown {
                pttKeyDown = false
                let inputMode: InputMode = pttCommandLatched ? .command : .dictation
                pttCommandLatched = false
                RuntimeLogger.shared.log("\(bindings.pttKey.displayName) up → pttEnded(\(inputMode))", category: .hotkey)
                outputContinuation.yield(.pttEnded(mode: inputMode))
            }
        } else if keyCode == bindings.commandModifier.keyCode {
            commandModifierDown = flags.contains(bindings.commandModifier.flag)
            if commandModifierDown && pttKeyDown {
                pttCommandLatched = true
            }
        } else if keyCode == bindings.modeToggle.keyCode {
            let isDown = flags.contains(bindings.modeToggle.flag)
            if isDown && !modeToggleDown {
                modeToggleDown = true
                RuntimeLogger.shared.log("\(bindings.modeToggle.displayName) tap → modeToggled", category: .hotkey)
                outputContinuation.yield(.modeToggled)
            } else if !isDown {
                modeToggleDown = false
            }
        }
    }

    // MARK: - Private

    private func _installMonitors() {
        let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            Task { await self?.processFlagsChanged(keyCode: keyCode, flags: flags) }
        }
        if let m { monitors.append(m) }
    }

    private func describeFlagsMask(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.capsLock) { parts.append("capsLock") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.control) { parts.append("control") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.command) { parts.append("command") }
        if flags.contains(.function) { parts.append("fn") }
        return parts.joined(separator: ", ")
    }
}
