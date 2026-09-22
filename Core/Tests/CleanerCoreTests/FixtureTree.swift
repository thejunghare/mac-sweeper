import Foundation
import XCTest

/// Builds synthetic junk fixture trees in a temp directory. Tests NEVER touch the real
/// home directory (§9).
final class FixtureTree {
    let root: URL
    let fileManager = FileManager.default

    init(name: String = "fixture") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("broom-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: root)
    }

    // MARK: Path helpers

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    // MARK: Creation

    @discardableResult
    func createFile(_ relativePath: String, bytes: Int = 1024, modificationDate: Date? = nil) throws -> URL {
        let url = self.url(relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(repeating: UInt8.random(in: 0...255), count: bytes)
        try data.write(to: url)
        if let modificationDate {
            try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    func createDirectory(_ relativePath: String, modificationDate: Date? = nil) throws -> URL {
        let url = self.url(relativePath)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        if let modificationDate {
            try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    func createSymbolicLink(_ relativePath: String, to target: URL) throws -> URL {
        let url = self.url(relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    /// A fixture shaped like the real home directory for scanner tests.
    static func makeHomeLayout() throws -> FixtureTree {
        let tree = try FixtureTree(name: "home")
        try tree.createDirectory("Library/Caches/com.example.junkcache")
        try tree.createFile("Library/Caches/com.example.junkcache/blob.bin", bytes: 4096)
        try tree.createDirectory("Library/Caches/Homebrew/Downloads")
        try tree.createFile("Library/Caches/Homebrew/Downloads/pkg.tar", bytes: 2048)
        try tree.createDirectory("Library/Caches/com.apple.Safari/WebKitCache")
        try tree.createFile("Library/Caches/com.apple.Safari/WebKitCache/page.bin", bytes: 1024)
        try tree.createDirectory("Library/Logs/com.example.app")
        try tree.createFile("Library/Logs/com.example.app/app.log", bytes: 512)
        try tree.createDirectory(".Trash")
        try tree.createFile(".Trash/old-document.pdf", bytes: 8192)
        try tree.createFile("Downloads/big-file.zip", bytes: 64 * 1024)
        return tree
    }
}

/// XCTestCase with a convenient temp-dir helper.
extension XCTestCase {
    func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("broom-xctest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

/// Thread-safe synchronous progress recorder for asserting `@Sendable` progress callbacks.
final class ProgressRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
