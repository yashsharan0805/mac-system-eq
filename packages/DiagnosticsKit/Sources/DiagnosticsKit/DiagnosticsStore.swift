import Foundation

public enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct LogEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let level: LogLevel
    public let message: String
    public let timestamp: Date

    public init(level: LogLevel, message: String, timestamp: Date = Date()) {
        id = UUID()
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }
}

public struct FeatureFlags: Sendable {
    public let enableExperimentalCaptureFallback: Bool
    public let enableVerboseLogging: Bool

    public init(
        enableExperimentalCaptureFallback: Bool = false,
        enableVerboseLogging: Bool = false
    ) {
        self.enableExperimentalCaptureFallback = enableExperimentalCaptureFallback
        self.enableVerboseLogging = enableVerboseLogging
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> FeatureFlags {
        FeatureFlags(
            enableExperimentalCaptureFallback: env["EQ_ENABLE_EXPERIMENTAL_CAPTURE_FALLBACK"] == "1",
            enableVerboseLogging: env["EQ_ENABLE_VERBOSE_LOGGING"] == "1"
        )
    }
}

public actor DiagnosticsStore {
    public static let shared = DiagnosticsStore()

    private var logs: [LogEntry] = []
    private var health: AudioHealthSnapshot = .zero
    private let maxLogs = 1_000

    public init() {}

    public func log(_ level: LogLevel, _ message: String) {
        logs.append(LogEntry(level: level, message: message))
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }

    public func setHealth(_ snapshot: AudioHealthSnapshot) {
        health = snapshot
    }

    public func latestHealth() -> AudioHealthSnapshot {
        health
    }

    public func recentLogs(limit: Int = 200) -> [LogEntry] {
        Array(logs.suffix(max(1, limit)))
    }

    public func exportLogs(to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(logs)
        try data.write(to: fileURL)
    }
}
