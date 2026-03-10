import AppKit
import CoreGraphics
import Darwin

final class ShellOutputManager: OutputManager {
    private let sessionResolver: () -> String?

    init(registryURL: URL = URL.homeDirectory.appending(path: ".config/egregore/sessions")) {
        self.sessionResolver = { ShellOutputManager.resolveSession(registryURL: registryURL) }
    }

    init(sessionResolver: @escaping () -> String?) {
        self.sessionResolver = sessionResolver
    }

    func append(_ text: String) {
        writeToPipe("inject|\(text)\n")
    }

    func clear() {
        writeToPipe("clear|\n")
    }

    func send() {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private func writeToPipe(_ message: String) {
        guard let pipePath = sessionResolver() else { return }
        let fd = Darwin.open(pipePath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        _ = message.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    private static func resolveSession(registryURL: URL) -> String? {
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return findRegisteredShell(from: pid_t(frontPID), registryURL: registryURL)
    }

    private static func findRegisteredShell(from pid: pid_t, registryURL: URL) -> String? {
        let sessionFile = registryURL.appending(path: "\(pid)")
        if let path = try? String(contentsOf: sessionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return path
        }
        for child in childPIDs(of: pid) {
            if let found = findRegisteredShell(from: child, registryURL: registryURL) {
                return found
            }
        }
        return nil
    }

    private static func childPIDs(of parentPID: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        sysctl(&mib, 4, &procs, &size, nil, 0)
        return procs.filter { $0.kp_eproc.e_ppid == parentPID }.map { $0.kp_proc.p_pid }
    }
}
