import AppKit
import CoreGraphics
import Darwin

final class ShellOutputManager: OutputManager {
    // MARK: Lifecycle

    init(
        registryURL: URL = URL.homeDirectory.appending(path: ".config/egregore/sessions"),
        activityURL: URL = URL.homeDirectory.appending(path: ".config/egregore/activity"),
        frontmostApplicationProvider: @escaping () -> FrontmostApplicationInfo? = {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            return FrontmostApplicationInfo(pid: pid_t(app.processIdentifier), name: app.localizedName ?? "unknown")
        },
        childPIDProvider: @escaping (pid_t) -> [pid_t] = ShellOutputManager.childPIDs(of:),
        visibleWindowPIDsProvider: @escaping () -> Set<pid_t> = ShellOutputManager.visibleWindowOwnerPIDs,
        logger: RuntimeLogger = .shared
    ) {
        log = logger
        sessionResolver = {
            Self.resolveSession(
                registryURL: registryURL,
                activityURL: activityURL,
                frontmostApplicationProvider: frontmostApplicationProvider,
                childPIDProvider: childPIDProvider,
                visibleWindowPIDsProvider: visibleWindowPIDsProvider,
                logger: logger
            )
        }
    }

    init(sessionResolver: @escaping () -> String?, logger: RuntimeLogger = .shared) {
        self.sessionResolver = {
            sessionResolver().map {
                SessionTarget(
                    pipePath: $0,
                    shellPID: nil,
                    frontmostAppPID: nil,
                    frontmostAppName: nil,
                    ancestry: [],
                    metadata: SessionMetadata(
                        pipePath: $0, lastPromptAt: nil, lastFocusAt: nil,
                        isFocused: nil, isAtPrompt: true, tty: nil
                    )
                )
            }
        }
        log = logger
    }

    // MARK: Internal

    struct FrontmostApplicationInfo {
        let pid: pid_t
        let name: String
    }

    var isAtPrompt: Bool {
        guard let target = sessionResolver() else { return false }
        return target.metadata?.effectivePrompt ?? false
    }

    func append(_ text: String) -> OutputResult {
        guard let target = sessionResolver() else {
            log.error("append failed: no registered shell session found", category: .output)
            return .failure("No active terminal target")
        }
        if let metadata = target.metadata, metadata.effectivePrompt {
            return writeToPipe(action: "inject", text: text, target: target)
        }
        hasInjectedSinceLastSend = true
        log.log("append: not confirmed at prompt, pasting via clipboard text=<<<\(text)>>>", category: .output)
        saveClipboardIfNeeded()
        return pasteViaClipboard(text)
    }

    func replace(_ newText: String) -> OutputResult {
        guard let target = sessionResolver() else {
            log.error("replace failed: no registered shell session found", category: .output)
            return .failure("No active terminal target")
        }
        if let metadata = target.metadata, metadata.effectivePrompt {
            let r1 = writeToPipe(action: "clear", text: "", target: target)
            if case .failure = r1 { return r1 }
            return writeToPipe(action: "inject", text: newText, target: target)
        }
        log.log("replace: clearing line + pasting via clipboard (\(newText.count) chars)", category: .output)
        saveClipboardIfNeeded()
        hasInjectedSinceLastSend = !newText.isEmpty
        return clearLineThenPaste(newText)
    }

    func clear() -> OutputResult {
        guard let target = sessionResolver() else {
            log.error("clear failed: no registered shell session found", category: .output)
            return .failure("No active terminal target")
        }
        if let metadata = target.metadata, metadata.effectivePrompt {
            return writeToPipe(action: "clear", text: "", target: target)
        }
        log.log("clear: not confirmed at prompt, posting Ctrl+U", category: .output)
        hasInjectedSinceLastSend = false
        scheduleClipboardRestore()
        return postKeyOnQueue(0x20, flags: .maskControl, label: "clear")
    }

    func send() -> OutputResult {
        guard let target = sessionResolver() else {
            log.error("send failed: no registered shell session found", category: .output)
            return .failure("No active terminal target")
        }
        if let metadata = target.metadata, metadata.effectivePrompt {
            return writeToPipe(action: "send", text: "", target: target)
        }
        log.log("send: not confirmed at prompt, posting Return key", category: .output)
        hasInjectedSinceLastSend = false
        scheduleClipboardRestore()
        return postKeyOnQueue(0x24, label: "send")
    }

    func resetKeyboardState() {
        hasInjectedSinceLastSend = false
        scheduleClipboardRestore()
    }

    // MARK: Private

    private struct SessionTarget {
        let pipePath: String
        let shellPID: pid_t?
        let frontmostAppPID: pid_t?
        let frontmostAppName: String?
        let ancestry: [pid_t]
        let metadata: SessionMetadata?
    }

    private struct SessionMatch {
        let pipePath: String
        let shellPID: pid_t
        let ancestry: [pid_t]
        let lastActivity: Date?
        let metadata: SessionMetadata
    }

    private struct SessionMetadata: Codable, Equatable {
        let pipePath: String
        let lastPromptAt: Double?
        let lastFocusAt: Double?
        let isFocused: Bool?
        let isAtPrompt: Bool?
        let tty: String?

        var promptDate: Date? {
            lastPromptAt.map(Date.init(timeIntervalSince1970:))
        }

        var focusDate: Date? {
            lastFocusAt.map(Date.init(timeIntervalSince1970:))
        }

        var effectiveFocus: Bool {
            isFocused ?? false
        }

        var effectivePrompt: Bool {
            isAtPrompt ?? false
        }

        static func legacy(pipePath: String, lastActivity: Date?) -> Self {
            let seconds = lastActivity?.timeIntervalSince1970
            return Self(
                pipePath: pipePath,
                lastPromptAt: seconds,
                lastFocusAt: seconds,
                isFocused: nil,
                isAtPrompt: nil,
                tty: nil
            )
        }
    }

    private static let pasteSettleDelay: UInt32 = 20_000

    private let sessionResolver: () -> SessionTarget?
    private let log: RuntimeLogger
    private let keyboardQueue = DispatchQueue(label: "egregore.keyboard", qos: .userInteractive)
    private var hasInjectedSinceLastSend = false
    private var savedClipboard: String?

    private func saveClipboardIfNeeded() {
        if savedClipboard == nil {
            savedClipboard = NSPasteboard.general.string(forType: .string)
        }
    }

    private func scheduleClipboardRestore() {
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        let logger = log
        keyboardQueue.async {
            usleep(100_000)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(saved, forType: .string)
            logger.log("restored clipboard after keyboard fallback", category: .output)
        }
    }

    private func pasteViaClipboard(_ text: String) -> OutputResult {
        let logger = log
        keyboardQueue.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            let source = CGEventSource(stateID: .hidSystemState)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            else {
                logger.error("pasteViaClipboard: failed to create Cmd+V event", category: .output)
                return
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
            usleep(Self.pasteSettleDelay)
            logger.log("pasteViaClipboard: pasted \(text.count) chars", category: .output)
        }
        return .success
    }

    private func clearLineThenPaste(_ text: String) -> OutputResult {
        let logger = log
        keyboardQueue.async {
            let source = CGEventSource(stateID: .hidSystemState)
            if let kd = CGEvent(keyboardEventSource: source, virtualKey: 0x20, keyDown: true),
               let ku = CGEvent(keyboardEventSource: source, virtualKey: 0x20, keyDown: false) {
                kd.flags = .maskControl
                ku.flags = .maskControl
                kd.post(tap: .cgSessionEventTap)
                ku.post(tap: .cgSessionEventTap)
            }
            usleep(10_000)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            else {
                logger.error("clearLineThenPaste: failed to create Cmd+V event", category: .output)
                return
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
            usleep(Self.pasteSettleDelay)
            logger.log("clearLineThenPaste: cleared line + pasted \(text.count) chars", category: .output)
        }
        return .success
    }

    private func postKeyOnQueue(_ virtualKey: CGKeyCode, flags: CGEventFlags = [], label: String) -> OutputResult {
        let logger = log
        keyboardQueue.async {
            let source = CGEventSource(stateID: .hidSystemState)
            guard let kd = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
                  let ku = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
            else {
                logger.error("\(label): failed to create CGEvent for key \(virtualKey)", category: .output)
                return
            }
            kd.flags = flags
            ku.flags = flags
            kd.post(tap: .cgSessionEventTap)
            ku.post(tap: .cgSessionEventTap)
            logger.log("\(label): posted key \(virtualKey)", category: .output)
        }
        return .success
    }

    private static func ttyPath(for pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return nil
        }
        let tdev = info.kp_eproc.e_tdev
        guard tdev != UInt32.max else {
            return nil
        }
        let major = Int(tdev >> 24) & 0xFF
        let minor = Int(tdev) & 0xFFFFFF
        guard major == 16 else {
            return nil
        }
        return String(format: "/dev/ttys%03d", minor)
    }

    private static func resolveSession(
        registryURL: URL,
        activityURL: URL,
        frontmostApplicationProvider: () -> FrontmostApplicationInfo?,
        childPIDProvider: (pid_t) -> [pid_t],
        visibleWindowPIDsProvider: () -> Set<pid_t>,
        logger: RuntimeLogger
    ) -> SessionTarget? {
        guard let frontApp = frontmostApplicationProvider() else {
            logger.error("session resolve: no frontmost application", category: .output)
            return nil
        }
        let frontPID = frontApp.pid
        let appName = frontApp.name
        logger.log("session resolve: frontmost app=\(appName) PID=\(frontPID)", category: .output)
        let visiblePIDs = visibleWindowPIDsProvider()
        guard visiblePIDs.isEmpty || visiblePIDs.contains(frontPID) else {
            logger.error("session resolve: frontmost app \(appName) PID \(frontPID) not visible on current space, skipping", category: .output)
            return nil
        }
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
                ancestry: match.ancestry,
                metadata: match.metadata
            )
        } else {
            logger.error(
                "session resolve: no registered shell under \(appName) (PID \(frontPID)), registry: \(registryURL.path())",
                category: .output
            )
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
        if let metadata = readSessionMetadata(from: sessionFile, activityURL: activityURL, pid: pid) {
            if metadata.pipePath.isEmpty {
                logger.error("session resolve: empty registry entry for PID \(pid) at \(sessionFile.path())", category: .output)
            } else if !FileManager.default.fileExists(atPath: metadata.pipePath) {
                logger.error(
                    "session resolve: stale registry entry PID \(pid) → \(metadata.pipePath) via ancestry \(describe(ancestry))",
                    category: .output
                )
            } else {
                logger.log(
                    "session resolve: matched PID \(pid) via ancestry \(describe(ancestry)) → \(metadata.pipePath) prompt=\(describe(metadata.promptDate)) focus=\(describe(metadata.focusDate)) isFocused=\(metadata.effectiveFocus) isAtPrompt=\(metadata.effectivePrompt) tty=\(describe(metadata.tty))",
                    category: .output
                )
                matches.append(SessionMatch(
                    pipePath: metadata.pipePath,
                    shellPID: pid,
                    ancestry: ancestry,
                    lastActivity: metadata.promptDate ?? metadata.focusDate,
                    metadata: metadata
                ))
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
        guard !matches.isEmpty else {
            return nil
        }
        if matches.count > 1 {
            let summary = matches
                .sorted(by: isPreferred(_:over:))
                .map {
                    "pid=\($0.shellPID) focused=\($0.metadata.effectiveFocus) prompt=\($0.metadata.effectivePrompt) focusAt=\(describe($0.metadata.focusDate)) promptAt=\(describe($0.metadata.promptDate)) ancestry=\(describe($0.ancestry)) tty=\(describe($0.metadata.tty))"
                }
                .joined(separator: "; ")
            logger.log("session resolve: candidates \(summary)", category: .output)
        }
        let sorted = matches.sorted(by: isPreferred(_:over:))
        guard let best = sorted.first else {
            return nil
        }
        if sorted.count > 1, samePriority(best, sorted[1]) {
            logger.error("session resolve: ambiguous top candidates; refusing to inject until focus is clearer", category: .output)
            return nil
        }
        return best
    }

    private static func readSessionMetadata(from sessionFile: URL, activityURL: URL, pid: pid_t) -> SessionMetadata? {
        guard let raw = try? String(contentsOf: sessionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        if raw.first == "{",
           let data = raw.data(using: .utf8),
           let metadata = try? JSONDecoder().decode(SessionMetadata.self, from: data) {
            return metadata
        }
        let lastActivity = readLastActivity(for: pid, activityURL: activityURL)
        return SessionMetadata.legacy(pipePath: raw, lastActivity: lastActivity)
    }

    private static func isPreferred(_ lhs: SessionMatch, over rhs: SessionMatch) -> Bool {
        if lhs.metadata.effectiveFocus != rhs.metadata.effectiveFocus {
            return lhs.metadata.effectiveFocus && !rhs.metadata.effectiveFocus
        }
        if lhs.metadata.effectivePrompt != rhs.metadata.effectivePrompt {
            return lhs.metadata.effectivePrompt && !rhs.metadata.effectivePrompt
        }
        let lhsFocus = lhs.metadata.focusDate ?? .distantPast
        let rhsFocus = rhs.metadata.focusDate ?? .distantPast
        if lhsFocus != rhsFocus {
            return lhsFocus > rhsFocus
        }
        let lhsPrompt = lhs.metadata.promptDate ?? lhs.lastActivity ?? .distantPast
        let rhsPrompt = rhs.metadata.promptDate ?? rhs.lastActivity ?? .distantPast
        if lhsPrompt != rhsPrompt {
            return lhsPrompt > rhsPrompt
        }
        if lhs.ancestry.count != rhs.ancestry.count {
            return lhs.ancestry.count > rhs.ancestry.count
        }
        return lhs.shellPID < rhs.shellPID
    }

    private static func samePriority(_ lhs: SessionMatch, _ rhs: SessionMatch) -> Bool {
        lhs.metadata.effectiveFocus == rhs.metadata.effectiveFocus &&
            lhs.metadata.effectivePrompt == rhs.metadata.effectivePrompt &&
            lhs.metadata.focusDate == rhs.metadata.focusDate &&
            (lhs.metadata.promptDate ?? lhs.lastActivity) == (rhs.metadata.promptDate ?? rhs.lastActivity) &&
            lhs.ancestry.count == rhs.ancestry.count
    }

    private static func readLastActivity(for pid: pid_t, activityURL: URL) -> Date? {
        let fileURL = activityURL.appending(path: "\(pid)")
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let seconds = Double(value)
        else {
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
        return procs.filter { $0.kp_eproc.e_ppid == parentPID }.map(\.kp_proc.p_pid)
    }

    private static func visibleWindowOwnerPIDs() -> Set<pid_t> {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else {
            return []
        }
        var pids = Set<pid_t>()
        for entry in windowList {
            if let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
               let layer = entry[kCGWindowLayer as String] as? Int,
               layer == 0 {
                pids.insert(pid)
            }
        }
        return pids
    }

    private static func describe(_ pid: pid_t?) -> String {
        pid.map(String.init) ?? "unknown"
    }

    private static func describe(_ value: String?) -> String {
        value ?? "unknown"
    }

    private static func describe(_ value: Date?) -> String {
        guard let value else {
            return "unknown"
        }
        return RuntimeLogger.timestampString(for: value)
    }

    private static func describe(_ ancestry: [pid_t]) -> String {
        ancestry.map(String.init).joined(separator: "->")
    }

    private func writeToTTY(text: String, target: SessionTarget) -> OutputResult {
        let tty: String
        if let metadataTTY = target.metadata?.tty, !metadataTTY.isEmpty {
            tty = metadataTTY
        } else if let shellPID = target.shellPID, let resolved = Self.ttyPath(for: shellPID) {
            tty = resolved
        } else {
            log.error("writeToTTY failed: no tty for shellPID=\(Self.describe(target.shellPID))", category: .output)
            return .failure("Cannot find terminal device")
        }
        log.log("writeToTTY: tty=\(tty) textBytes=\(text.utf8.count) shellPID=\(Self.describe(target.shellPID))", category: .output)
        let fd = Darwin.open(tty, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            log.error("writeToTTY failed: could not open \(tty) errno=\(errno)", category: .output)
            return .failure("Cannot write to terminal device")
        }
        defer { Darwin.close(fd) }
        var writeOk = true
        text.withCString { ptr in
            let total = strlen(ptr)
            var offset = 0
            while offset < total {
                let n = Darwin.write(fd, ptr + offset, total - offset)
                if n < 0 {
                    if errno == EINTR {
                        continue
                    }
                    log.error("writeToTTY failed: write error on \(tty) errno=\(errno) wrote=\(offset)/\(total)", category: .output)
                    writeOk = false
                    return
                }
                offset += n
            }
        }
        if writeOk {
            log.log("writeToTTY: delivered bytes=\(text.utf8.count) tty=\(tty) shellPID=\(Self.describe(target.shellPID))", category: .output)
            return .success
        }
        return .failure("Failed to write to terminal device")
    }

    private func writeToPipe(action: String, text: String, target: SessionTarget) -> OutputResult {
        let message = "\(action)|\(text)\n"
        log.log(
            "writeToPipe: action=\(action) textBytes=\(text.utf8.count) payloadBytes=\(message.utf8.count)",
            category: .output
        )
        if !FileManager.default.fileExists(atPath: target.pipePath) {
            log.error(
                "writeToPipe failed: resolved pipe missing at \(target.pipePath) action=\(action) shellPID=\(Self.describe(target.shellPID)) frontmostApp=\(Self.describe(target.frontmostAppName)) frontPID=\(Self.describe(target.frontmostAppPID)) ancestry=\(Self.describe(target.ancestry))",
                category: .output
            )
            return .failure("Terminal session disappeared")
        }
        let fd = Darwin.open(target.pipePath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            log.error(
                "writeToPipe failed: could not open pipe at \(target.pipePath) action=\(action) shellPID=\(Self.describe(target.shellPID)) errno=\(errno)",
                category: .output
            )
            return .failure("Terminal session is busy")
        }
        defer { Darwin.close(fd) }
        var writeOk = true
        message.withCString { ptr in
            let total = strlen(ptr)
            var offset = 0
            while offset < total {
                let n = Darwin.write(fd, ptr + offset, total - offset)
                if n < 0 {
                    if errno == EINTR {
                        continue
                    }
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
            return .success
        }
        return .failure("Failed to write to terminal")
    }
}
