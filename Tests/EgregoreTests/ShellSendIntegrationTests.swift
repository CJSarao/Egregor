import Darwin
import Foundation
import XCTest
@testable import Egregore

final class ShellSendIntegrationTests: XCTestCase {
    // MARK: Internal

    override func tearDown() {
        if let process, process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        outputPipe = nil
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        super.tearDown()
    }

    func testSendSubmitsInjectedBufferInInteractiveZsh() throws {
        try launchInteractiveShell()
        let pipePath = try waitForPipePath()

        let manager = ShellOutputManager { pipePath }
        XCTAssertEqual(manager.append("echo EGREGORE_SEND_OK"), .success)
        XCTAssertEqual(manager.send(), .success)

        let output = try waitForOutput(containing: "EGREGORE_SEND_OK")
        XCTAssertTrue(output.contains("echo EGREGORE_SEND_OK"))
        XCTAssertTrue(output.contains("EGREGORE_SEND_OK"))
    }

    // MARK: Private

    private struct SessionFile: Decodable {
        let pipePath: String
    }

    private var tempHome: URL!
    private var process: Process?
    private var outputPipe: Pipe?

    private func launchInteractiveShell() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appending(path: "egregore-shell-send-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        let zshrc = tempHome.appending(path: ".zshrc")
        let zshrcContents = [
            "PROMPT='PROMPT> '",
            "unsetopt BEEP",
            ShellIntegrationInstaller.snippet,
        ].joined(separator: "\n\n") + "\n"
        try zshrcContents.write(to: zshrc, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        proc.arguments = ["-q", "/dev/null", "/bin/zsh", "-i"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempHome.path
        environment["ZDOTDIR"] = tempHome.path
        environment["TERM"] = "xterm-256color"
        proc.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        self.outputPipe = outputPipe
        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(outputFD, F_GETFL)
        _ = fcntl(outputFD, F_SETFL, flags | O_NONBLOCK)
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = outputPipe

        try proc.run()
        process = proc
    }

    private func waitForPipePath(timeout: TimeInterval = 5) throws -> String {
        let sessionsURL = tempHome.appending(path: ".config/egregore/sessions", directoryHint: .isDirectory)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let files = try? FileManager.default.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil),
               let sessionFileURL = files.first,
               let raw = try? String(contentsOf: sessionFileURL, encoding: .utf8),
               let data = raw.data(using: .utf8),
               let session = try? JSONDecoder().decode(SessionFile.self, from: data),
               !session.pipePath.isEmpty {
                return session.pipePath
            }
            usleep(50000)
        }

        XCTFail("Timed out waiting for shell session registration")
        return ""
    }

    private func waitForOutput(containing needle: String, timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var output = ""

        while Date() < deadline {
            output += readAvailableOutput()
            if output.contains(needle) {
                return output
            }
            usleep(50000)
        }

        XCTFail("Timed out waiting for output containing '\(needle)'. Output so far: \(output)")
        return output
    }

    private func readAvailableOutput() -> String {
        guard let outputPipe else {
            return ""
        }
        let fd = outputPipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        var output = ""

        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                output += String(decoding: buffer.prefix(count), as: UTF8.self)
                continue
            }
            if count < 0, errno == EWOULDBLOCK || errno == EAGAIN {
                break
            }
            break
        }

        return output
    }
}
