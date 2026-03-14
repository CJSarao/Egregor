import XCTest
@testable import Egregore

final class RuntimeLoggerTests: XCTestCase {
    // MARK: Internal

    override func setUp() {
        logDir = FileManager.default.temporaryDirectory
            .appending(path: "egregore-test-logs-\(UUID().uuidString)")
        logFile = logDir.appending(path: "egregore.log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logDir)
    }

    func testLogWritesTimestampedEntry() throws {
        let logger = RuntimeLogger(fileURL: logFile)
        logger.log("hello world", category: .general)
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("[general] hello world"))
        XCTAssertTrue(contents.contains("[20"))
    }

    func testErrorWritesErrorPrefix() throws {
        let logger = RuntimeLogger(fileURL: logFile)
        logger.error("pipe failed", category: .output)
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("[ERROR:output] pipe failed"))
    }

    func testMultipleEntriesAppend() throws {
        let logger = RuntimeLogger(fileURL: logFile)
        logger.log("first", category: .session)
        logger.log("second", category: .hotkey)
        logger.error("third", category: .transcriber)
        let lines = try String(contentsOf: logFile, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("[session] first"))
        XCTAssertTrue(lines[1].contains("[hotkey] second"))
        XCTAssertTrue(lines[2].contains("[ERROR:transcriber] third"))
    }

    func testLogDirectoryURLIsUnderLocalShare() {
        let path = RuntimeLogger.logDirectoryURL.path(percentEncoded: false)
        XCTAssertTrue(path.hasSuffix(".local/share/egregore/logs/"))
    }

    // MARK: Private

    private var logDir: URL!
    private var logFile: URL!
}
