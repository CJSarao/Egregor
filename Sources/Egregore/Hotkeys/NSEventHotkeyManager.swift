import AppKit
import Foundation

actor NSEventHotkeyManager: HotkeyManager {
    // MARK: Lifecycle

    init(bindings: HotkeyBindings = .default, installMonitors: Bool = true) {
        self.bindings = bindings
        var cont: AsyncStream<HotkeyEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        outputContinuation = cont

        guard installMonitors else {
            return
        }
        Task { await self._installMonitors() }
    }

    // MARK: Internal

    let bindings: HotkeyBindings

    nonisolated let events: AsyncStream<HotkeyEvent>

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

        guard keyCode == bindings.toggleKey.keyCode else {
            return
        }

        let isDown = flags.contains(bindings.toggleKey.flag)
        if isDown, !toggleKeyDown {
            toggleKeyDown = true
            RuntimeLogger.shared.log("\(bindings.toggleKey.displayName) tap → toggle", category: .hotkey)
            outputContinuation.yield(.toggle)
        } else if !isDown {
            toggleKeyDown = false
        }
    }

    // MARK: Private

    private let outputContinuation: AsyncStream<HotkeyEvent>.Continuation

    private var toggleKeyDown = false

    private var diagnosticsEnabled = false
    private var monitors: [Any] = []

    private func _installMonitors() {
        let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            Task { await self?.processFlagsChanged(keyCode: keyCode, flags: flags) }
        }
        if let m {
            monitors.append(m)
        }
    }

    private func describeFlagsMask(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.capsLock) {
            parts.append("capsLock")
        }
        if flags.contains(.shift) {
            parts.append("shift")
        }
        if flags.contains(.control) {
            parts.append("control")
        }
        if flags.contains(.option) {
            parts.append("option")
        }
        if flags.contains(.command) {
            parts.append("command")
        }
        if flags.contains(.function) {
            parts.append("fn")
        }
        return parts.joined(separator: ", ")
    }
}
