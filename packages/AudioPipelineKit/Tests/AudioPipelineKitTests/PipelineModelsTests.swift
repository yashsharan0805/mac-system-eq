@testable import AudioPipelineKit
import Foundation
import Testing

struct PipelineModelsTests {
    @Test("clamps out-of-range values")
    func clampingWorks() {
        let preset = EQPreset(
            name: "Bad preset",
            preampDB: 22,
            bands: [
                EQBandConfig(frequencyHz: 10, gainDB: 90, q: 0.01, isBypassed: false),
                EQBandConfig(frequencyHz: 50000, gainDB: -99, q: 50, isBypassed: false),
            ]
        )

        let normalized = AVAudioEQPipelineService.normalized(preset)

        #expect(normalized.preampDB == 12)
        #expect(normalized.bands[0].frequencyHz == 20)
        #expect(normalized.bands[0].gainDB == 24)
        #expect(normalized.bands[0].q == 0.1)
        #expect(normalized.bands[1].frequencyHz == 20000)
        #expect(normalized.bands[1].gainDB == -24)
        #expect(normalized.bands[1].q == 18)
    }

    @Test("detects changed band indexes")
    func changedIndexesWork() {
        let old = EQPreset(
            id: UUID(),
            name: "old",
            preampDB: 0,
            bands: [
                EQBandConfig(frequencyHz: 100, gainDB: 0, q: 1, isBypassed: false),
                EQBandConfig(frequencyHz: 1000, gainDB: 0, q: 1, isBypassed: false),
            ]
        )

        let newPreset = EQPreset(
            id: old.id,
            name: "new",
            preampDB: 0,
            bands: [
                EQBandConfig(frequencyHz: 100, gainDB: 0, q: 1, isBypassed: false),
                EQBandConfig(frequencyHz: 1000, gainDB: 3, q: 1, isBypassed: false),
            ]
        )

        let changed = AVAudioEQPipelineService.changedBandIndexes(old: old, new: newPreset)
        #expect(changed == [1])
    }
}
