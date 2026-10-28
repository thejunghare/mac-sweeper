import Foundation

/// The one-glance answer for every item in the Storage screen.
public enum DeleteFlag: String, Sendable, Codable, CaseIterable {
    /// Rebuilt automatically (caches, logs, build data) — delete freely.
    case safe
    /// Deletable, but it's your data or an app — look before you delete.
    case checkFirst
    /// Broom will not delete it (part of macOS, managed by its app, already in the Trash,
    /// or needs admin rights).
    case cannotDelete

    public var isDeletable: Bool { self != .cannotDelete }
}

/// Sections mirroring System Settings → General → Storage. "macOS" and
/// "Other Users & Shared" are deliberately absent: macOS manages those.
public enum StorageSection: String, CaseIterable, Identifiable, Sendable {
    case applications
    case developer
    case documents
    case mail
    case photos
    case trash
    case systemData

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .applications: return "Applications"
        case .developer: return "Developer"
        case .documents: return "Documents"
        case .mail: return "Mail"
        case .photos: return "Photos"
        case .trash: return "Trash"
        case .systemData: return "System Data"
        }
    }

    public var symbolName: String {
        switch self {
        case .applications: return "app.badge"
        case .developer: return "hammer"
        case .documents: return "doc"
        case .mail: return "envelope"
        case .photos: return "photo.on.rectangle"
        case .trash: return "trash"
        case .systemData: return "ellipsis.circle"
        }
    }
}

/// One item listed in a storage section.
public struct StorageEntry: Identifiable, Hashable, Sendable {
    public let path: URL
    /// Bytes on disk (recursive for folders and bundles).
    public let size: Int64
    public let isDirectory: Bool
    public let modificationDate: Date?
    public let flag: DeleteFlag
    /// A few words explaining the flag ("Part of macOS", "Rebuilt automatically", …).
    public let note: String
    /// The folder this entry must still be inside at delete time.
    public let root: URL
    public let section: StorageSection

    public var id: String { path.path }
    public var displayPath: String { homeRelativePath(path) }

    public init(
        path: URL,
        size: Int64,
        isDirectory: Bool,
        modificationDate: Date?,
        flag: DeleteFlag,
        note: String,
        root: URL,
        section: StorageSection
    ) {
        self.path = path.standardizedFileURL
        self.size = size
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.flag = flag
        self.note = note
        self.root = root.standardizedFileURL
        self.section = section
    }
}

public struct StorageSectionReport: Sendable, Identifiable {
    public let section: StorageSection
    /// Largest first, bounded by the analyzer's entry limit.
    public let entries: [StorageEntry]

    public init(section: StorageSection, entries: [StorageEntry]) {
        self.section = section
        self.entries = entries
    }

    public var id: StorageSection { section }
    public var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    public var safeEntries: [StorageEntry] { entries.filter { $0.flag == .safe } }
}

/// Capacity of the volume holding the home folder.
public struct DiskUsage: Sendable, Equatable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    public var usedBytes: Int64 { totalBytes - availableBytes }

    public static func current(for url: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskUsage? {
        let values = try? url.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        )
        guard let total = values?.volumeTotalCapacity,
              let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskUsage(totalBytes: Int64(total), availableBytes: available)
    }
}

/// Builds the Storage screen: what fills each section, and a `DeleteFlag` per item.
///
/// Read-only (metadata only, never file contents), never follows symlinks, cancellable.
/// Unlike the junk scanners, this lists the user's own files and apps too — deleting them
/// is a *user-chosen, per-item* action that `StorageDeleter` re-checks and sends to the
/// Trash, the same thing Finder's "Move to Trash" does.
public struct StorageAnalyzer: Sendable {
    public let rules: RulesEngine
    private let fileManager: FileManager
    private let applicationRoots: [URL]
    private let systemDataRoots: [URL]
    private let entryLimit: Int
    private let minimumListedSize: Int64
    /// Folders that hold everything else — never offered for deletion themselves.
    private let keptFolders: Set<String>

    public init(
        rules: RulesEngine = RulesEngine(),
        fileManager: FileManager = .default,
        applicationRoots: [URL]? = nil,
        systemDataRoots: [URL]? = nil,
        entryLimit: Int = 200,
        minimumListedSize: Int64 = 1_000_000
    ) {
        let home = rules.homeDirectory
        let library = home.appendingPathComponent("Library")
        func lib(_ path: String) -> URL { library.appendingPathComponent(path) }

        let appRoots = applicationRoots ?? [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
        ]
        let dataRoots = systemDataRoots ?? [
            lib("Caches"),
            lib("Logs"),
            lib("Application Support"),
            lib("Containers"),
            lib("Group Containers"),
            lib("Saved Application State"),
            URL(fileURLWithPath: "/Library/Caches"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]

        var kept: [URL] = [home, library, home.appendingPathComponent("Downloads"),
                           home.appendingPathComponent(".Trash"), lib("Developer")]
        kept += rules.protectedHomeRoots.map { URL(fileURLWithPath: $0) }
        kept += JunkCategory.allCases.flatMap { rules.allowedRoots(for: $0) }
        kept += appRoots + dataRoots + Self.developerRoots(library: library)

        self.rules = rules
        self.fileManager = fileManager
        self.entryLimit = entryLimit
        self.minimumListedSize = minimumListedSize
        self.applicationRoots = appRoots
        self.systemDataRoots = dataRoots
        self.keptFolders = Set(kept.map { $0.standardizedFileURL.path })
    }

    private var home: URL { rules.homeDirectory }
    private func lib(_ path: String) -> URL {
        home.appendingPathComponent("Library").appendingPathComponent(path)
    }

    private static func developerRoots(library: URL) -> [URL] {
        [
            "Developer/Xcode/DerivedData",
            "Developer/Xcode/Archives",
            "Developer/Xcode/iOS DeviceSupport",
            "Developer/Xcode/watchOS DeviceSupport",
            "Developer/Xcode/tvOS DeviceSupport",
            "Developer/CoreSimulator/Caches",
        ].map { library.appendingPathComponent($0) }
    }

    // MARK: - Analysis

    /// Analyzes every section concurrently; `progress` fires as each one finishes.
    public func analyzeAll(
        progress: (@Sendable (StorageSectionReport) -> Void)? = nil
    ) async -> [StorageSectionReport] {
        let analyzer = self
        return await withTaskGroup(of: StorageSectionReport.self) { group in
            for section in StorageSection.allCases {
                group.addTask { analyzer.analyze(section) }
            }
            var reports: [StorageSectionReport] = []
            for await report in group {
                reports.append(report)
                progress?(report)
            }
            return StorageSection.allCases.compactMap { section in
                reports.first { $0.section == section }
            }
        }
    }

    /// Synchronous by nature (directory walks); call it off the main thread.
    public func analyze(_ section: StorageSection) -> StorageSectionReport {
        let entries: [StorageEntry]
        switch section {
        case .applications:
            entries = children(of: applicationRoots, section: section, minimumSize: 0)
        case .developer:
            entries = children(of: Self.developerRoots(library: home.appendingPathComponent("Library")),
                               section: section)
                + single(lib("Developer/CoreSimulator/Devices"), root: lib("Developer"), section: section)
        case .documents:
            entries = largestUserFiles()
        case .mail:
            entries = single(lib("Mail"), root: home.appendingPathComponent("Library"), section: section)
                + children(of: rules.allowedRoots(for: .mailDownloads), section: section)
        case .photos:
            entries = children(of: [home.appendingPathComponent("Pictures")], section: section, minimumSize: 0)
                .filter { $0.path.pathExtension == "photoslibrary" }
        case .trash:
            entries = children(of: [home.appendingPathComponent(".Trash")], section: section, minimumSize: 0)
        case .systemData:
            entries = children(of: systemDataRoots, section: section)
        }
        let sorted = entries.sorted { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }
        return StorageSectionReport(section: section, entries: Array(sorted.prefix(entryLimit)))
    }

    /// Direct children of each root, each sized recursively. Hidden entries and symlinks
    /// are skipped.
    private func children(of roots: [URL], section: StorageSection, minimumSize: Int64? = nil) -> [StorageEntry] {
        let minimum = minimumSize ?? minimumListedSize
        var entries: [StorageEntry] = []
        for root in roots {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                if Task.isCancelled { return entries }
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true { continue }
                let size = ScanSupport.size(of: url, fileManager: fileManager)
                guard size >= minimum else { continue }
                entries.append(makeEntry(url, size: size, isDirectory: values?.isDirectory == true,
                                         root: root, section: section))
            }
        }
        return entries
    }

    private func single(_ url: URL, root: URL, section: StorageSection) -> [StorageEntry] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let size = ScanSupport.size(of: url, fileManager: fileManager)
        return [makeEntry(url, size: size, isDirectory: true, root: root, section: section)]
    }

    /// Largest regular files in the home folder outside `~/Library`, the Trash and app
    /// bundles — the "Documents" view of System Settings.
    private func largestUserFiles() -> [StorageEntry] {
        let skipped: Set<String> = [
            home.appendingPathComponent("Library").path,
            home.appendingPathComponent(".Trash").path,
            home.appendingPathComponent("Applications").path,
        ]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
                                      .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: home,
            includingPropertiesForKeys: keys,
            options: [], // no .followsSymlinks
            errorHandler: { _, _ in true }
        ) else { return [] }

        var found: [(url: URL, size: Int64)] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            if skipped.contains(url.standardizedFileURL.path) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isPackage == true {
                // Bundles (apps, Photos libraries, …) belong to their own sections.
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            guard size >= minimumListedSize else { continue }
            found.append((url, size))
            if found.count > entryLimit * 4 {
                found = Array(found.sorted { $0.size > $1.size }.prefix(entryLimit))
            }
        }
        return found.map { makeEntry($0.url, size: $0.size, isDirectory: false, root: home, section: .documents) }
    }

    private func makeEntry(
        _ url: URL,
        size: Int64,
        isDirectory: Bool,
        root: URL,
        section: StorageSection
    ) -> StorageEntry {
        let verdict = flag(for: url)
        return StorageEntry(
            path: url,
            size: size,
            isDirectory: isDirectory,
            modificationDate: ScanSupport.modificationDate(of: url),
            flag: verdict.flag,
            note: verdict.note,
            root: root,
            section: section
        )
    }

    // MARK: - Flag

    /// Decides the flag from the path and the file's on-disk permissions. Also re-run by
    /// `StorageDeleter` immediately before every delete.
    public func flag(for url: URL) -> (flag: DeleteFlag, note: String) {
        let path = url.standardizedFileURL.path
        func isInside(_ folder: URL) -> Bool {
            let folderPath = folder.standardizedFileURL.path
            return path == folderPath || path.hasPrefix(folderPath + "/")
        }

        // 1. macOS itself. The scanner denylist also blocks /Applications; here the user
        //    picks apps one by one, so only true system locations are refused.
        for denied in rules.hardDenylist where denied != "/Applications" {
            if path == denied || path.hasPrefix(denied + "/") { return (.cannotDelete, "Part of macOS") }
        }
        if isSystemProtected(path) { return (.cannotDelete, "Part of macOS") }

        // 2. Folders that hold everything else.
        if keptFolders.contains(path) { return (.cannotDelete, "Folder macOS needs") }

        // 3. Already deleted.
        if isInside(home.appendingPathComponent(".Trash")) {
            return (.cannotDelete, "Already in Trash — empty it in Finder")
        }

        // 4. Data owned by an app that must manage it itself.
        if url.pathExtension == "photoslibrary" || path.contains(".photoslibrary/") {
            return (.cannotDelete, "Manage in Photos")
        }
        if isInside(lib("Mail")) { return (.cannotDelete, "Manage in Mail") }
        if isInside(lib("Developer/CoreSimulator/Devices")) {
            return (.cannotDelete, "Manage in Xcode → Devices")
        }
        let junk = rules.junkLocation(for: path)
        if junk == nil && (isInside(lib("Containers")) || isInside(lib("Group Containers"))) {
            return (.cannotDelete, "App data protected by macOS")
        }

        // 5. What the filesystem allows. Moving a folder also needs write access to it.
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard fileManager.isDeletableFile(atPath: path),
              !isDirectory || fileManager.isWritableFile(atPath: path) else {
            return (.cannotDelete, "Needs admin — delete in Finder")
        }

        // 6. Known junk locations.
        if let junk {
            if junk.category.riskLevel == .low {
                return (.safe, "\(junk.category.displayName) — rebuilt automatically")
            }
            return (.checkFirst, junk.category.displayName)
        }
        if isInside(lib("Saved Application State")) { return (.safe, "Window state — rebuilt automatically") }

        // 7. Everything else is the user's own data or an app.
        if url.pathExtension == "app" { return (.checkFirst, "Removes the app") }
        if isInside(lib("Application Support")) { return (.checkFirst, "App data — only for apps you removed") }
        return (.checkFirst, "Your file")
    }

    /// SIP-protected items carry the `SF_RESTRICTED` file flag.
    private func isSystemProtected(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let restricted: UInt32 = 0x0008_0000 // SF_RESTRICTED in <sys/stat.h>
        return info.st_flags & restricted != 0
    }
}
