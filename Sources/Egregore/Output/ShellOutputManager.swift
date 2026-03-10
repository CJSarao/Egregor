import AppKit
import CoreGraphics
import Darwin

final class ShellOutputManager: OutputManager {
    struct FrontmostApplicationInfo {
        let pid: pid_t
        let name: String
    }

    private struct SessionTarget {
        let pipePath: String
        let shellPID: pid_t?
        let frontmostAppPID: pid_t?
        let frontmostAppName: String?
        let ancestry: [pid_t]
    }

    private struct SessionMatch {
        let pipePath: String
        let shellPID: pid_t
        let ancestry: [pid_t]
        let lastActivity: Date?
    }

    private let sessionResolver: () -> SessionTarget?
    private let log: RuntimeLogger

    init(registryURL: URL = URL.homeDirectory.appending(path: ".config/egregore/sessions"),
         activityURL: URL = URL.homeDirectory.appending(path: ".config/egregore/activity"),
         frontmostApplicationProvider: @escaping () -> FrontmostApplicationInfo? = {
             guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
             return FrontmostApplicationInfo(pid: pid_t(app.processIdentifier), name: app.localizedName ?? "unknown")
         },
         childPIDProvider: @escaping (pid_t) -> [pid_t] = ShellOutputManager.childPIDs(of:),
         logger: RuntimeLogger = .shared) {
        self.log = logger
        self.sessionResolver = {
            ShellOutputManager.resolveSession(
                registryURL: registryURL,
                activityURL: activityURL,
                frontmostApplicationProvider: frontmostApplicationProvider,
                childPIDProvider: childPIDProvider,
                logger: logger
            )
        }
    }

    init(sessionResolver: @escaping () -> String?, logger: RuntimeLogger = .shared) {
        self.sessionResolver = {
            sessionResolver().map {
                SessionTarget(pipePath: $0, shellPID: nil, frontmostAppPID: nil, frontmostAppName: nil, ancestry: [])
            }
        }
        self.log = logger
    }

    func append(_ text: String) {
        writeToPipe(action: "inject", text: text)
    }

    func clear() {
        writeToPipe(action: "clear", text: "")
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

    private func writeToPipe(action: String, text: String) {
        let message = "\(action)|\(text)\n"
        log.log(
            "writeToPipe: action=\(action) textBytes=\(text.utf8.count) payloadBytes=\(message.utf8.count)",
            category: .output
        )
        guard let target = sessionResolver() else {
            log.error("writeToPipe failed: no registered shell session found", category: .output)
            return
        }
        if !FileManager.default.fileExists(atPath: target.pipePath) {
            log.error(
                "writeToPipe failed: resolved pipe missing at \(target.pipePath) action=\(action) shellPID=\(Self.describe(target.shellPID)) frontmostApp=\(Self.describe(target.frontmostAppName)) frontPID=\(Self.describe(target.frontmostAppPID)) ancestry=\(Self.describe(target.ancestry))",
                category: .output
            )
            return
        }
        let fd = Darwin.open(target.pipePath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            log.error(
                "writeToPipe failed: could not open pipe at \(target.pipePath) action=\(action) shellPID=\(Self.describe(target.shellPID)) errno=\(errno)",
                category: .output
            )
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
                    log.error(
                        "writeToPipe failed: write error on \(target.pipePath) action=\(action) shellPID=\(Self.describe(target.shellPID)) errno=\(errno) wrote=\(offset)/\(total)",
                        category: .output
                    )
                    writeOk = false
                    return
                }
                offset += n
            }
        }
        if writeOk {
            log.log(
                "writeToPipe: delivered action=\(action) bytes=\(message.utf8.count) pipe=\(target.pipePath) shellPID=\(Self.describe(target.shellPID)) frontmostApp=\(Self.describe(target.frontmostAppName)) frontPID=\(Self.describe(target.frontmostAppPID)) ancestry=\(Self.describe(target.ancestry))",
                category: .output
            )
        }
    }

    private static func resolveSession(
        registryURL: URL,
        activityURL: URL,
        frontmostApplicationProvider: () -> FrontmostApplicationInfo?,
        childPIDProvider: (pid_t) -> [pid_t],
        logger: RuntimeLogger
    ) -> SessionTarget? {
        guard let frontApp = frontmostApplicationProvider() else {
            logger.error("session resolve: no frontmost application", category: .output)
            return nil
        }
        let frontPID = frontApp.pid
        let appName = frontApp.name
        logger.log("session resolve: frontmost app=\(appName) PID=\(frontPID)", category: .output)
        let matches = findRegisteredShells(
            from: frontPID,
            ancestry: [frontPID],
            registryURL: registryURL,
            activityURL: activityURL,
            childPIDProvider: childPIDProvider,
            logger: logger
        )
        if let match = chooseBestMatch(matches, logger: logger) {
            logger.log(
                "session resolve: found pipe \(match.pipePath) for shell PID \(match.shellPID) via ancestry \(describe(match.ancestry)) activity=\(describe(match.lastActivity))",
                category: .output
            )
            return SessionTarget(
                pipePath: match.pipePath,
                shellPID: match.shellPID,
                frontmostAppPID: frontPID,
                frontmostAppName: appName,
                ancestry: match.ancestry
            )
        } else {
            logger.error("session resolve: no registered shell under \(appName) (PID \(frontPID)), registry: \(registryURL.path())", category: .output)
        }
        return nil
    }

    private static func findRegisteredShells(
        from pid: pid_t,
        ancestry: [pid_t],
        registryURL: URL,
        activityURL: URL,
        childPIDProvider: (pid_t) -> [pid_t],
        logger: RuntimeLogger
    ) -> [SessionMatch] {
        var matches: [SessionMatch] = []
        let sessionFile = registryURL.appending(path: "\(pid)")
        if let path = try? String(contentsOf: sessionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            if path.isEmpty {
                logger.error("session resolve: empty registry entry for PID \(pid) at \(sessionFile.path())", category: .output)
            } else if !FileManager.default.fileExists(atPath: path) {
                logger.error("session resolve: stale registry entry PID \(pid) → \(path) via ancestry \(describe(ancestry))", category: .output)
            } else {
                let lastActivity = readLastActivity(for: pid, activityURL: activityURL)
                logger.log(
                    "session resolve: matched PID \(pid) via ancestry \(describe(ancestry)) → \(path) activity=\(describe(lastActivity))",
                    category: .output
                )
                matches.append(SessionMatch(pipePath: path, shellPID: pid, ancestry: ancestry, lastActivity: lastActivity))
            }
        }
        let children = childPIDProvider(pid)
        if !children.isEmpty {
            logger.log("session resolve: PID \(pid) has children \(children) via ancestry \(describe(ancestry))", category: .output)
        }
        for child in children {
            matches += findRegisteredShells(
                from: child,
                ancestry: ancestry + [child],
                registryURL: registryURL,
                activityURL: activityURL,
                childPIDProvider: childPIDProvider,
                logger: logger
            )
        }
        return matches
    }

    private static func chooseBestMatch(_ matches: [SessionMatch], logger: RuntimeLogger) -> SessionMatch? {
        guard !matches.isEmpty else { return nil }
        if matches.count > 1 {
            let summary = matches
                .sorted {
                    if $0.lastActivity != $1.lastActivity {
                        return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
                    }
                    if $0.ancestry.count != $1.ancestry.count {
                        return $0.ancestry.count > $1.ancestry.count
                    }
                    return $0.shellPID < $1.shellPID
                }
                .map { "pid=\($0.shellPID) activity=\(describe($0.lastActivity)) ancestry=\(describe($0.ancestry))" }
                .joined(separator: "; ")
            logger.log("session resolve: candidates \(summary)", category: .output)
        }
        return matches.max {
            let lhsActivity = $0.lastActivity ?? .distantPast
            let rhsActivity = $1.lastActivity ?? .distantPast
            if lhsActivity != rhsActivity {
                return lhsActivity < rhsActivity
            }
            if $0.ancestry.count != $1.ancestry.count {
                return $0.ancestry.count < $1.ancestry.count
            }
            return $0.shellPID > $1.shellPID
        }
    }

    private static func readLastActivity(for pid: pid_t, activityURL: URL) -> Date? {
        let fileURL = activityURL.appending(path: "\(pid)")
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Double(value) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
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

    private static func describe(_ pid: pid_t?) -> String {
        pid.map(String.init) ?? "unknown"
    }

    private static func describe(_ value: String?) -> String {
        value ?? "unknown"
    }

    private static func describe(_ value: Date?) -> String {
        guard let value else { return "unknown" }
        return RuntimeLogger.timestampString(for: value)
    }

    private static func describe(_ ancestry: [pid_t]) -> String {
        ancestry.map(String.init).joined(separator: "->")
    }
}
