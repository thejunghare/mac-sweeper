import CryptoKit
import Foundation

/// Hash-based duplicate finder (§4). Never auto-selected: the user picks extra copies,
/// and `SafeDeleter` always keeps at least one verified copy of every group.
///
/// Privacy (§5.5): SHA-256 hashes are computed locally and never transmitted; file
/// *contents* are never returned by the scanner, only paths/sizes.
///
/// Strategy: bucket by size → hash candidates (full-content SHA-256) → emit items for
/// every file that belongs to a group of 2+ identical files. Bounded by
/// `duplicateMaxFilesConsidered` to keep scans predictable.
public struct DuplicatesScanner: Scanner {
    public let name = "duplicates"
    public let supportedCategories: Set<JunkCategory> = [.duplicates]

    public let maxFilesConsidered: Int

    public init(maxFilesConsidered: Int = 20_000) {
        self.maxFilesConsidered = maxFilesConsidered
    }

    public func scan(_ context: ScanContext) async -> ScannerResult {
        collectCandidates(context)
    }

    private func collectCandidates(_ context: ScanContext) -> ScannerResult {
        let config = context.configuration
        var result = ScannerResult()

        // 1. Collect candidate files (regular files, >= minimum size).
        var candidates: [URL] = []
        for relativeRoot in config.duplicateRoots {
            if Task.isCancelled || candidates.count >= maxFilesConsidered { break }
            let root = context.homeDirectory.appendingPathComponent(relativeRoot)
            guard context.fileManager.fileExists(atPath: root.path) else { continue }

            guard let enumerator = context.fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if Task.isCancelled || candidates.count >= maxFilesConsidered { break }
                if config.isExcluded(path: url.path) { enumerator.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
                let size = Int64(values?.fileSize ?? 0)
                if size >= config.duplicateMinimumSize {
                    candidates.append(url)
                }
            }
        }

        // 2. Bucket by size.
        var bySize: [Int64: [URL]] = [:]
        for url in candidates {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            bySize[Int64(size), default: []].append(url)
        }
        let sizeGroups = bySize.values.filter { $0.count > 1 }

        // 3. Hash groups with >= 2 files of the same size.
        var byHash: [String: [URL]] = [:]
        for group in sizeGroups {
            if Task.isCancelled { break }
            for url in group {
                if let hash = Self.sha256(of: url) {
                    byHash[hash, default: []].append(url)
                }
            }
        }

        // 4. Emit informational items for confirmed duplicate groups.
        for (hash, urls) in byHash where urls.count > 1 {
            let count = urls.count
            let shortHash = String(hash.prefix(12))
            for url in urls {
                guard let size = ScanSupport.fileSize(at: url) else { continue }
                result.items.append(
                    JunkItem(
                        path: url,
                        size: size,
                        category: .duplicates,
                        riskLevel: .medium,
                        modificationDate: ScanSupport.modificationDate(of: url),
                        root: context.homeDirectory,
                        detail: "\(count) identical copies · \(shortHash)",
                        groupID: hash
                    )
                )
            }
        }
        result.items.sort { $0.size > $1.size }
        return result
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else {
                    break
                }
                chunk = data
            } catch {
                return nil
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
