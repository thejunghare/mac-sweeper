import Foundation

/// Output of a complete read-only scan.
public struct ScanReport: Sendable {
    public let items: [JunkItem]
    public let issues: [ScanIssue]
    public let startedAt: Date
    public let finishedAt: Date

    public init(items: [JunkItem], issues: [ScanIssue], startedAt: Date, finishedAt: Date) {
        self.items = items
        self.issues = issues
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Total reclaimable bytes across deletable items only.
    public var totalDeletableSize: Int64 {
        items.filter { $0.category.isDeletable }.reduce(0) { $0 + $1.size }
    }

    public var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    public func items(in category: JunkCategory) -> [JunkItem] {
        items.filter { $0.category == category }
    }

    public func size(in category: JunkCategory) -> Int64 {
        items(in: category).reduce(0) { $0 + $1.size }
    }

    /// Categories present in this report, ordered by the canonical category order.
    public var categories: [JunkCategory] {
        JunkCategory.allCases.filter { category in
            items.contains { $0.category == category }
        }
    }
}
