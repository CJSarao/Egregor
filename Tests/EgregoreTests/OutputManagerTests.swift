import XCTest
import Darwin
@testable import Egregore

final class OutputManagerTests: XCTestCase {
    private var logDir: URL!
    private var logFile: URL!

    // Opens the FIFO with O_RDWR so both ends are held — no blocking on open,
    // and a non-blocking writer (ShellOutputManager) can connect immediately.
    private func makePipe() -> (path: String, fd: Int32) {
        let path = "/tmp/egregore-test-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).pipe"
        Darwin.mkfifo(path, 0o600)
        let fd = Darwin.open(path, O_RDWR)
        precondition(fd >= 0, "Failed to open test FIFO at \(path)")
        return (path, fd)
    }

    private func readAll(fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buffer, 4095)
        return n > 0 ? String(bytes: Array(buffer.prefix(n)), encoding: .utf8) ?? "" : ""
    }

    private func readLog() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    override func setUp() {
        super.setUp()
        logDir = FileManager.default.temporaryDirectory
            .appending(path: "egregore-output-logs-\(UUID().uuidString)")
        logFile = logDir.appending(path: "egregore.log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logDir)
        super.tearDown()
    }

    func testAppendWritesInjectMessage() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd); Darwin.unlink(path) }

        let manager = ShellOutputManager(sessionResolver: { path })
        manager.append("hello world")

        XCTAssertEqual(readAll(fd: fd), "inject|hello world\n")
    }

    func testMultipleAppendsWriteSequentialInjectMessages() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd); Darwin.unlink(path) }

        let manager = ShellOutputManager(sessionResolver: { path })
        manager.append("foo")
        manager.append("bar")

        let raw = readAll(fd: fd)
        let messages = raw.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { $0 + "\n" }
        XCTAssertEqual(messages, ["inject|foo\n", "inject|bar\n"])
    }

    func testClearWritesClearMessage() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd); Darwin.unlink(path) }

        let manager = ShellOutputManager(sessionResolver: { path })
        manager.clear()

        XCTAssertEqual(readAll(fd: fd), "clear|\n")
    }

    func testAppendThenClearWritesBothMessages() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd); Darwin.unlink(path) }

        let manager = ShellOutputManager(sessionResolver: { path })
        manager.append("some text")
        manager.clear()

        let raw = readAll(fd: fd)
        let messages = raw.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { $0 + "\n" }
        XCTAssertEqual(messages, ["inject|some text\n", "clear|\n"])
    }

    func testMultipleAppendsFollowedByClearResultsInClearMessage() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd); Darwin.unlink(path) }

        let manager = ShellOutputManager(sessionResolver: { path })
        manager.append("alpha")
        manager.append("beta")
        manager.append("gamma")
        manager.clear()

        let raw = readAll(fd: fd)
        let messages = raw.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { $0 + "\n" }
        XCTAssertEqual(messages.last, "clear|\n")
        XCTAssertEqual(messages.count, 4)
    }

    func testAppendWithUnicodeText() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd); Darwin.unlink(path) }

        let manager = ShellOutputManager(sessionResolver: { path })
        manager.append("git log --oneline 🎉")

        XCTAssertEqual(readAll(fd: fd), "inject|git log --oneline 🎉\n")
    }

    func testAppendWithEmptyStringWritesEmptyInjectMessage() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd); Darwin.unlink(path) }

        let manager = ShellOutputManager(sessionResolver: { path })
        manager.append("")

        XCTAssertEqual(readAll(fd: fd), "inject|\n")
    }

    func testMissingSessionIsNoop() {
        let logger = RuntimeLogger(fileURL: logFile)
        let manager = ShellOutputManager(sessionResolver: { nil }, logger: logger)
        manager.append("hello")
        manager.clear()
        // No crash — silent no-op when no session is found
        let contents = readLog()
        XCTAssertTrue(contents.contains("writeToPipe failed: no registered shell session found"))
    }

    func testSendDoesNotCrash() {
        // CGEvent posting may silently fail without Accessibility permissions in CI.
        let manager = ShellOutputManager(sessionResolver: { nil })
        manager.send()
    }

    func testMissingPipePathLogsDistinctError() {
        let missingPath = "/tmp/egregore-test-missing-\(UUID().uuidString).pipe"
        let logger = RuntimeLogger(fileURL: logFile)
        let manager = ShellOutputManager(sessionResolver: { missingPath }, logger: logger)

        manager.append("hello")

        let contents = readLog()
        XCTAssertTrue(contents.contains("resolved pipe missing at \(missingPath)"))
        XCTAssertTrue(contents.contains("action=inject"))
    }

    func testAppendLogDoesNotContainRawText() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd); Darwin.unlink(path) }

        let logger = RuntimeLogger(fileURL: logFile)
        let manager = ShellOutputManager(sessionResolver: { path }, logger: logger)

        manager.append("secret-token")

        let contents = readLog()
        XCTAssertTrue(contents.contains("textBytes=12"))
        XCTAssertFalse(contents.contains("secret-token"))
    }
}
