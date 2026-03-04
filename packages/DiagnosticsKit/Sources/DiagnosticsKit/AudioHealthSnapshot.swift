import Foundation

public struct AudioHealthSnapshot: Codable, Equatable, Sendable {
    public var latencyMs: Double
    public var dropoutsLastMinute: Int
    public var cpuLoadPct: Double

    public init(latencyMs: Double, dropoutsLastMinute: Int, cpuLoadPct: Double) {
        self.latencyMs = latencyMs
        self.dropoutsLastMinute = dropoutsLastMinute
        self.cpuLoadPct = cpuLoadPct
    }

    public static let zero = AudioHealthSnapshot(latencyMs: 0, dropoutsLastMinute: 0, cpuLoadPct: 0)
}
