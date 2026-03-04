import AudioPipelineKit
import DiagnosticsKit
import Foundation

public protocol PresetStore {
    func loadAll() throws -> [EQPreset]
    func save(_ preset: EQPreset) throws
    func delete(id: UUID) throws
}

public enum PresetStoreError: Error, LocalizedError {
    case appSupportPathUnavailable
    case io(Error)
    case presetNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .appSupportPathUnavailable:
            return "Application Support directory not available"
        case let .io(error):
            return "I/O error: \(error.localizedDescription)"
        case let .presetNotFound(id):
            return "Preset not found: \(id)"
        }
    }
}

public final class JSONPresetStore: PresetStore {
    private let diagnosticsStore: DiagnosticsStore
    private let baseDirectory: URL
    private let presetsFileURL: URL

    public init(
        diagnosticsStore: DiagnosticsStore = .shared,
        baseDirectory: URL? = nil
    ) throws {
        self.diagnosticsStore = diagnosticsStore

        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw PresetStoreError.appSupportPathUnavailable
            }
            self.baseDirectory = appSupport.appendingPathComponent("MacSystemEQ", isDirectory: true)
        }

        presetsFileURL = self.baseDirectory.appendingPathComponent("presets.json")
        try ensureStorageExists()
    }

    public func loadAll() throws -> [EQPreset] {
        if !FileManager.default.fileExists(atPath: presetsFileURL.path) {
            let defaults = DefaultPresets.factory()
            try persist(defaults)
            return defaults
        }

        do {
            let data = try Data(contentsOf: presetsFileURL)
            let decoder = JSONDecoder()
            return try decoder.decode([EQPreset].self, from: data)
        } catch {
            throw PresetStoreError.io(error)
        }
    }

    public func save(_ preset: EQPreset) throws {
        var presets = try loadAll()
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        try persist(presets)
    }

    public func delete(id: UUID) throws {
        var presets = try loadAll()
        guard presets.contains(where: { $0.id == id }) else {
            throw PresetStoreError.presetNotFound(id)
        }

        presets.removeAll { $0.id == id }
        try persist(presets)
    }

    public func export(_ preset: EQPreset, to destination: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preset)
            try data.write(to: destination)
            let store = diagnosticsStore
            Task { await store.log(.info, "Exported preset \(preset.name) to \(destination.path)") }
        } catch {
            throw PresetStoreError.io(error)
        }
    }

    public func importPreset(from source: URL) throws -> EQPreset {
        do {
            let data = try Data(contentsOf: source)
            let decoder = JSONDecoder()
            var preset = try decoder.decode(EQPreset.self, from: data)
            preset = EQPreset(
                id: UUID(),
                name: preset.name,
                preampDB: preset.preampDB,
                bands: preset.bands
            )
            try save(preset)
            let store = diagnosticsStore
            Task { await store.log(.info, "Imported preset from \(source.path)") }
            return preset
        } catch {
            throw PresetStoreError.io(error)
        }
    }

    private func ensureStorageExists() throws {
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            throw PresetStoreError.io(error)
        }
    }

    private func persist(_ presets: [EQPreset]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(presets)
            try data.write(to: presetsFileURL)
            let store = diagnosticsStore
            Task { await store.log(.debug, "Persisted \(presets.count) presets") }
        } catch {
            throw PresetStoreError.io(error)
        }
    }
}

public enum DefaultPresets {
    public static func factory() -> [EQPreset] {
        let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

        func makeBand(_ frequency: Float, gain: Float = 0) -> EQBandConfig {
            EQBandConfig(frequencyHz: frequency, gainDB: gain, q: 1, isBypassed: false)
        }

        let flat = EQPreset(name: "Flat", preampDB: 0, bands: frequencies.map { makeBand($0) })
        let bassBoost = EQPreset(
            name: "Bass Boost",
            preampDB: -1,
            bands: frequencies.enumerated().map { index, frequency in
                switch index {
                case 0: makeBand(frequency, gain: 5)
                case 1: makeBand(frequency, gain: 4)
                case 2: makeBand(frequency, gain: 3)
                default: makeBand(frequency, gain: 0)
                }
            }
        )
        let vocal = EQPreset(
            name: "Vocal",
            preampDB: 0,
            bands: frequencies.enumerated().map { index, frequency in
                switch index {
                case 3: makeBand(frequency, gain: -1)
                case 4: makeBand(frequency, gain: 2)
                case 5: makeBand(frequency, gain: 3)
                case 6: makeBand(frequency, gain: 2)
                default: makeBand(frequency, gain: 0)
                }
            }
        )
        let trebleBoost = EQPreset(
            name: "Treble Boost",
            preampDB: -1,
            bands: frequencies.enumerated().map { index, frequency in
                switch index {
                case 7: makeBand(frequency, gain: 2)
                case 8: makeBand(frequency, gain: 4)
                case 9: makeBand(frequency, gain: 5)
                default: makeBand(frequency, gain: 0)
                }
            }
        )

        return [flat, bassBoost, vocal, trebleBoost]
    }
}
