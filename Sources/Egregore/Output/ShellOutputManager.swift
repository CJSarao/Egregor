import AppKit
import CoreGraphics
import Darwin

final class ShellOutputManager: OutputManager {
    private let sessionResolver: () -> String?
    private let log: RuntimeLogger

    init(registryURL: URL = URL.homeDirectory.appending(path: ".config/egregore/sessions"),
         logger: RuntimeLogger = .shared) {
        self.log = logger
        self.sessionResolver = { ShellOutputManager.resolveSession(registryURL: registryURL, logger: logger) }
    }

    init(sessionResolver: @escaping () -> String?, logger: RuntimeLogger = .shared) {
        self.sessionResolver = sessionResolver
        self.log = logger
    }

    func append(_ text: String) {
        log.log("append: \"\(text)\"", category: .output)
        writeToPipe("inject|\(text)\n")
    }

    func clear() {
        log.log("clear: resetting terminal buffer", category: .output)
        writeToPipe("clear|\n")
    }

    func send() {
        log.log("send (Return keystroke)", category: .output)
        if !AXIsProcessTrusted() {
            log.error("send: Accessibility not trusted — CGEvent posting will likely be blocked by macOS", category: .output)
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false) else {
            log.error("send failed: could not create CGEvent", category: .output)
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log.log("send: Return keystroke posted", category: .output)
    }

    private func writeToPipe(_ message: String) {
        guard let pipePath = sessionResolver() else {
            log.error("writeToPipe failed: no registered shell session found", category: .output)
            return
        }
        let fd = Darwin.open(pipePath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            log.error("writeToPipe failed: could not open pipe at \(pipePath) (errno \(errno))", category: .output)
            return
        }
        defer { Darwin.close(fd) }
        var writeOk = true
        message.withCString { ptr in
            let total = strlen(ptr)
            var offset = 0
            while offset < total {
                let n = Darwin.write(fd, ptr + offset, total - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    log.error("writeToPipe failed: write error on \(pipePath) (errno \(errno), wrote \(offset)/\(total))", category: .output)
                    writeOk = false
                    return
                }
                offset += n
            }
        }
        if writeOk {
            log.log("writeToPipe: delivered \(message.count) bytes to \(pipePath)", category: .output)
        }
    }

    private static func resolveSession(registryURL: URL, logger: RuntimeLogger) -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            logger.error("session resolve: no frontmost application", category: .output)
            return nil
        }
        let frontPID = frontApp.processIdentifier
        let appName = frontApp.localizedName ?? "unknown"
        logger.log("session resolve: frontmost app=\(appName) PID=\(frontPID)", category: .output)
        let result = findRegisteredShell(from: pid_t(frontPID), registryURL: registryURL, logger: logger)
        if let pipe = result {
            logger.log("session resolve: found pipe \(pipe)", category: .output)
        } else {
            logger.error("session resolve: no registered shell under \(appName) (PID \(frontPID)), registry: \(registryURL.path())", category: .output)
        }
        return result
    }

    private static func findRegisteredShell(from pid: pid_t, registryURL: URL, logger: RuntimeLogger) -> String? {
        let sessionFile = registryURL.appending(path: "\(pid)")
        if let path = try? String(contentsOf: sessionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            logger.log("session resolve: matched PID \(pid) → \(path)", category: .output)
            return path
        }
        let children = childPIDs(of: pid)
        if !children.isEmpty {
            logger.log("session resolve: PID \(pid) has children \(children)", category: .output)
        }
        for child in children {
            if let found = findRegisteredShell(from: child, registryURL: registryURL, logger: logger) {
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
