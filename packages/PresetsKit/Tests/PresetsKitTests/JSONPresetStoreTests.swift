@testable import AudioPipelineKit
import Foundation
@testable import PresetsKit
import Testing

struct JSONPresetStoreTests {
    @Test("roundtrip save and load")
    func roundtrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacSystemEQTests-\(UUID().uuidString)", isDirectory: true)

        let store = try JSONPresetStore(baseDirectory: dir)
        let preset = EQPreset(
            name: "Test",
            preampDB: 1,
            bands: [EQBandConfig(frequencyHz: 100, gainDB: 1, q: 1, isBypassed: false)]
        )

        try store.save(preset)
        let all = try store.loadAll()

        #expect(all.contains(where: { $0.name == "Test" }))
    }
}
