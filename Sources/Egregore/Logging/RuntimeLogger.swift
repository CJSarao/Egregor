import Foundation
import os

final class RuntimeLogger: Sendable {
    // MARK: Lifecycle

    init() {
        let dir = Self.logDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = Self.logFileURL
        if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        }
        fileHandle = NIOLockedValueBox(try? FileHandle(forWritingTo: fileURL))
        _ = fileHandle.withLockedValue { $0?.seekToEndOfFile() }
    }

    init(fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        }
        fileHandle = NIOLockedValueBox(try? FileHandle(forWritingTo: fileURL))
        _ = fileHandle.withLockedValue { $0?.seekToEndOfFile() }
    }

    // MARK: Internal

    enum Category: String {
        case general
        case hotkey
        case audio
        case transcriber
        case resolver
        case output
        case session
    }

    static let shared = RuntimeLogger()

    static let logDirectoryURL = URL.homeDirectory
        .appending(path: ".local/share/egregore/logs", directoryHint: .isDirectory)

    static var logFileURL: URL {
        logDirectoryURL.appending(path: "egregore.log")
    }

    static func timestampString(for date: Date) -> String {
        formatter.string(from: date)
    }

    func log(_ message: String, category: Category = .general) {
        let timestamp = Self.formatter.string(from: Date())
        let line = "[\(timestamp)] [\(category.rawValue)] \(message)\n"
        osLog.log("[\(category.rawValue)] \(message)")
        fileHandle.withLockedValue { handle in
            if let data = line.data(using: .utf8) {
                handle?.write(data)
            }
        }
    }

    func error(_ message: String, category: Category = .general) {
        let timestamp = Self.formatter.string(from: Date())
        let line = "[\(timestamp)] [ERROR:\(category.rawValue)] \(message)\n"
        osLog.error("[\(category.rawValue)] \(message)")
        fileHandle.withLockedValue { handle in
            if let data = line.data(using: .utf8) {
                handle?.write(data)
            }
        }
    }

    // MARK: Private

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let fileHandle: NIOLockedValueBox<FileHandle?>
    private let osLog = Logger(subsystem: "com.egregore.app", category: "runtime")
}

/// Minimal lock box — avoids importing NIO just for thread-safe mutable state.
final class NIOLockedValueBox<Value>: @unchecked Sendable {
    // MARK: Lifecycle

    init(_ value: Value) {
        self.value = value
    }

    // MARK: Internal

    func withLockedValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    // MARK: Private

    private var value: Value
    private let lock = NSLock()
}
