@testable import DiagnosticsKit
import Foundation
import Testing

struct DiagnosticsStoreTests {
    @Test("stores and returns health snapshots")
    func storesHealth() async {
        let store = DiagnosticsStore()
        let snapshot = AudioHealthSnapshot(latencyMs: 8.2, dropoutsLastMinute: 1, cpuLoadPct: 14.3)
        await store.setHealth(snapshot)
        let returned = await store.latestHealth()
        #expect(returned == snapshot)
    }

    @Test("stores logs")
    func storesLogs() async {
        let store = DiagnosticsStore()
        await store.log(.info, "hello")
        let logs = await store.recentLogs(limit: 10)
        #expect(logs.count == 1)
        #expect(logs[0].message == "hello")
    }
}
