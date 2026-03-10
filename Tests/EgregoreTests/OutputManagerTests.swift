import XCTest
import Darwin
@testable import Egregore

final class OutputManagerTests: XCTestCase {
    private var logDir: URL!
    private var logFile: URL!
    private var registryURL: URL!
    private var activityURL: URL!

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
        registryURL = logDir.appending(path: "sessions", directoryHint: .isDirectory)
        activityURL = logDir.appending(path: "activity", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: registryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: activityURL, withIntermediateDirectories: true)
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

    func testResolveSessionPrefersMostRecentlyActiveShell() throws {
        let (olderPath, olderFD) = makePipe()
        let (newerPath, newerFD) = makePipe()
        defer {
            Darwin.close(olderFD)
            Darwin.close(newerFD)
            Darwin.unlink(olderPath)
            Darwin.unlink(newerPath)
        }

        try olderPath.write(to: registryURL.appending(path: "201"), atomically: true, encoding: .utf8)
        try newerPath.write(to: registryURL.appending(path: "202"), atomically: true, encoding: .utf8)
        try "10.0".write(to: activityURL.appending(path: "201"), atomically: true, encoding: .utf8)
        try "20.0".write(to: activityURL.appending(path: "202"), atomically: true, encoding: .utf8)

        let logger = RuntimeLogger(fileURL: logFile)
        let manager = ShellOutputManager(
            registryURL: registryURL,
            activityURL: activityURL,
            frontmostApplicationProvider: { .init(pid: 100, name: "Ghostty") },
            childPIDProvider: { pid in
                switch pid {
                case 100: return [200, 300]
                case 200: return [201]
                case 300: return [202]
                default: return []
                }
            },
            logger: logger
        )

        manager.append("focused shell")

        XCTAssertEqual(readAll(fd: newerFD), "inject|focused shell\n")
        XCTAssertEqual(readAll(fd: olderFD), "")

        let contents = readLog()
        XCTAssertTrue(contents.contains("session resolve: candidates"))
        XCTAssertTrue(contents.contains("shell PID 202"))
    }
}
