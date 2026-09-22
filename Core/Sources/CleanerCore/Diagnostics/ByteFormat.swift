import Foundation

/// Byte-count formatting for UI and logs.
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func string(_ bytes: Int) -> String {
        string(Int64(bytes))
    }
}
