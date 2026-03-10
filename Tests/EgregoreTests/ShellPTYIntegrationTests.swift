import XCTest
import Darwin
@testable import Egregore

final class ShellPTYIntegrationTests: XCTestCase {
    func testInteractiveZshInjectPopulatesNormalPromptBuffer() throws {
        let harness = try InteractiveZshHarness()
        defer { harness.shutdown() }

        try harness.sendPipeMessage("inject|echo PROMPT_BUFFER_OK\n")
        XCTAssertTrue(try harness.waitForDebugLog(containing: "inject applied after_len=21 after_buffer<<<echo PROMPT_BUFFER_OK>>>").contains("after_cursor=21"))
        try harness.pressReturn()

        XCTAssertTrue(try harness.waitForOutput(containing: "PROMPT_BUFFER_OK").contains("PROMPT_BUFFER_OK"))
    }

    func testInteractiveZshInjectPopulatesInteractiveEditorBuffer() throws {
        let harness = try InteractiveZshHarness()
        defer { harness.shutdown() }

        try harness.startEditor(variableName: "egregore_value")
        try harness.sendPipeMessage("inject|hello world\n")
        try harness.pressReturn()

        XCTAssertTrue(try harness.waitForOutput(containing: "RESULT<<<hello world>>>").contains("RESULT<<<hello world>>>"))
        XCTAssertTrue(try harness.waitForDebugLog(containing: "inject applied after_len=11 after_buffer<<<hello world>>>").contains("after_cursor=11"))
    }
}

private final class InteractiveZshHarness {
    private let homeURL: URL
    private let registryURL: URL
    private let debugLogURL: URL
    private let promptMarker = "EGREGORE_PROMPT> "
    private let childPID: pid_t
    private let masterFD: Int32
    private var transcript = ""
    private var didShutdown = false

    init() throws {
        let fm = FileManager.default
        homeURL = fm.temporaryDirectory.appending(path: "egregore-shell-pty-\(UUID().uuidString)", directoryHint: .isDirectory)
        registryURL = homeURL.appending(path: ".config/egregore/sessions", directoryHint: .isDirectory)
        debugLogURL = homeURL.appending(path: ".local/share/egregore/logs/shell-integration.log")

        try fm.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try Self.writeZshrc(homeURL: homeURL, debugLogURL: debugLogURL)

        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, nil)
        guard pid >= 0 else {
            throw HarnessError.launchFailed("forkpty failed with errno \(errno)")
        }
        if pid == 0 {
            setenv("HOME", homeURL.path(percentEncoded: false), 1)
            setenv("ZDOTDIR", homeURL.path(percentEncoded: false), 1)
            setenv("TERM", "xterm-256color", 1)
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup("zsh"), strdup("-i"), nil]
            execv("/bin/zsh", &argv)
            _exit(127)
        }

        childPID = pid
        masterFD = master

        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        _ = try waitForOutput(containing: promptMarker)
        _ = try waitForSessionPipePath()
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true

        _ = Darwin.write(masterFD, "exit\n", 5)
        usleep(100_000)
        Darwin.kill(childPID, SIGKILL)

        var status: Int32 = 0
        _ = waitpid(childPID, &status, 0)
        Darwin.close(masterFD)
        try? FileManager.default.removeItem(at: homeURL)
    }

    func sendPipeMessage(_ message: String) throws {
        let pipePath = try waitForSessionPipePath()
        let fd = Darwin.open(pipePath, O_WRONLY)
        guard fd >= 0 else {
            throw HarnessError.pipeWriteFailed("open failed for \(pipePath) with errno \(errno)")
        }
        defer { Darwin.close(fd) }

        let writeResult = message.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }
        guard writeResult == message.utf8.count else {
            throw HarnessError.pipeWriteFailed("write failed for \(pipePath); wrote \(writeResult) of \(message.utf8.count)")
        }
    }

    func startEditor(variableName: String) throws {
        transcript = ""
        _ = readAvailableOutput()
        try sendCommand("\(variableName)=''; vared -p 'EDIT> ' \(variableName); print -r -- \"RESULT<<<$\(variableName)>>>\"")
        _ = try waitForOutput(containing: "EDIT> ")
    }

    func pressReturn() throws {
        try sendInput("\n")
    }

    func waitForOutput(containing needle: String, timeout: TimeInterval = 3.0) throws -> String {
        try waitFor(timeout: timeout) {
            transcript += readAvailableOutput()
            return transcript.contains(needle) ? transcript : nil
        }
    }

    private func sendInput(_ input: String) throws {
        let wrote = input.withCString { ptr in
            Darwin.write(masterFD, ptr, strlen(ptr))
        }
        guard wrote == input.utf8.count else {
            throw HarnessError.pipeWriteFailed("pty write failed; wrote \(wrote) of \(input.utf8.count)")
        }
    }

    private func sendCommand(_ command: String) throws {
        try sendInput("\u{1B}[200~\(command)\u{1B}[201~")
        try sendInput("\n")
    }

    func waitForDebugLog(containing needle: String, timeout: TimeInterval = 3.0) throws -> String {
        try waitFor(timeout: timeout) {
            guard let contents = try? String(contentsOf: debugLogURL, encoding: .utf8) else { return nil }
            return contents.contains(needle) ? contents : nil
        }
    }

    private static func writeZshrc(homeURL: URL, debugLogURL: URL) throws {
        let rc = """
        export PROMPT='EGREGORE_PROMPT> '
        export EGREGORE_SHELL_DEBUG=1
        export EGREGORE_SHELL_DEBUG_LOG='\(debugLogURL.path(percentEncoded: false))'
        \(ShellIntegrationInstaller.snippet)
        """
        try rc.write(to: homeURL.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
    }

    private func waitForSessionPipePath(timeout: TimeInterval = 3.0) throws -> String {
        let sessionFile = registryURL.appending(path: "\(childPID)")
        return try waitFor(timeout: timeout) {
            guard let path = try? String(contentsOf: sessionFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty else {
                return nil
            }
            return path
        }
    }

    private func readAvailableOutput() -> String {
        var chunks = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                chunks += String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return chunks
    }

    private func waitFor<T>(timeout: TimeInterval, condition: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = condition() { return value }
            usleep(20_000)
        }
        let debugLog = (try? String(contentsOf: debugLogURL, encoding: .utf8)) ?? "<missing>"
        throw HarnessError.timeout("timed out after \(timeout)s transcript=\(transcript.debugDescription) debugLog=\(debugLog.debugDescription)")
    }

    private enum HarnessError: Error {
        case launchFailed(String)
        case pipeWriteFailed(String)
        case timeout(String)
    }
}
