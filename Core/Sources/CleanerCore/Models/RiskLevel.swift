import Foundation

/// Risk classification for a deletable item. Drives the confirmation tier in the UI (§5.2)
/// and is enforced by `DeletionPolicy` in the deletion engine.
public enum RiskLevel: Int, Comparable, Sendable, Codable, CaseIterable {
    /// Regenerated automatically by the owning app (caches, logs, Trash).
    case low = 0
    /// Recoverable but may cost the user something (Xcode archives, Mail downloads, system logs).
    case medium = 1
    /// Uniquely valuable data (iOS device backups). Requires explicit type-to-confirm.
    case high = 2

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .low: return "Low risk"
        case .medium: return "Medium risk"
        case .high: return "High risk"
        }
    }
}
