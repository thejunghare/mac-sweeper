import Foundation

// FileManager is documented thread-safe for the operations Core performs (metadata reads,
// enumeration, trash). The SDK does not mark it Sendable, so we opt in explicitly to keep
// ScanContext/SafeDeleter Sendable across structured-concurrency boundaries.
extension FileManager: @unchecked @retroactive Sendable {}
