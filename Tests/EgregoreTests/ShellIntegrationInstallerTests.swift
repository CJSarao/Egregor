import XCTest
@testable import Egregore

final class ShellIntegrationInstallerTests: XCTestCase {
    var tempDir: URL!
    var installer: ShellIntegrationInstaller!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "EgregoreTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        installer = ShellIntegrationInstaller(
            zshrcURL: tempDir.appending(path: ".zshrc"),
            registryURL: tempDir.appending(path: "egregore/sessions"),
            egregoreConfigURL: tempDir.appending(path: "egregore")
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSnippetContainsRequiredElements() {
        let s = ShellIntegrationInstaller.snippet
        XCTAssertTrue(s.contains("BEGIN Egregore integration"))
        XCTAssertTrue(s.contains("END Egregore integration"))
        XCTAssertTrue(s.contains("VOICE_PIPE"))
        XCTAssertTrue(s.contains("VOICE_REGISTRY"))
        XCTAssertTrue(s.contains("_egregore_inject"))
        XCTAssertTrue(s.contains("inject)"))
        XCTAssertTrue(s.contains("clear)"))
        XCTAssertTrue(s.contains("zle -F"))
    }

    func testIsInstalledReturnsFalseWhenNoZshrc() {
        XCTAssertFalse(installer.isInstalled)
    }

    func testInstallCreatesRegistryDirectory() throws {
        try installer.install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.registryURL.path))
    }

    func testInstallCreatesZshrcIfMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.zshrcURL.path))
        try installer.install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.zshrcURL.path))
    }

    func testInstallAppendsSnippetToExistingZshrc() throws {
        try "# existing content\n".write(to: installer.zshrcURL, atomically: true, encoding: .utf8)
        try installer.install()
        let content = try String(contentsOf: installer.zshrcURL, encoding: .utf8)
        XCTAssertTrue(content.contains("# existing content"))
        XCTAssertTrue(content.contains("BEGIN Egregore integration"))
        XCTAssertTrue(content.contains("_egregore_inject"))
    }

    func testInstallIsIdempotent() throws {
        try installer.install()
        try installer.install()
        let content = try String(contentsOf: installer.zshrcURL, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "BEGIN Egregore integration").count - 1, 1)
    }

    func testIsInstalledAfterInstall() throws {
        XCTAssertFalse(installer.isInstalled)
        try installer.install()
        XCTAssertTrue(installer.isInstalled)
    }

    func testUninstallRemovesManagedBlockPreservingOtherContent() throws {
        try "# existing content\n".write(to: installer.zshrcURL, atomically: true, encoding: .utf8)
        try installer.install()
        try installer.uninstall()
        let content = try String(contentsOf: installer.zshrcURL, encoding: .utf8)
        XCTAssertTrue(content.contains("# existing content"))
        XCTAssertFalse(content.contains("BEGIN Egregore integration"))
        XCTAssertFalse(content.contains("_egregore_inject"))
    }

    func testUninstallRemovesRegistryDirectory() throws {
        try installer.install()
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.egregoreConfigURL.path))
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.egregoreConfigURL.path))
    }

    func testUninstallIsIdempotentWhenNotInstalled() throws {
        XCTAssertNoThrow(try installer.uninstall())
    }

    func testIsInstalledFalseAfterUninstall() throws {
        try installer.install()
        try installer.uninstall()
        XCTAssertFalse(installer.isInstalled)
    }
}
