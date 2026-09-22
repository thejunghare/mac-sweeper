import Foundation
import os

/// Thin `os_log`/`Logger` wrapper so Core never sprinkles logging calls directly and the
/// privacy annotations stay consistent (§5: no path/filename telemetry — these logs are
/// local-only, private by default).
public struct CoreLogging: Sendable {
    public static let shared = CoreLogging()

    private let logger: Logger

    public init(subsystem: String = "app.broom.core", category: String = "cleaner") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .private)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
    }
}
