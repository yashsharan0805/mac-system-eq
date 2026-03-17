import AVFAudio
import DeviceKit
import Foundation

public struct EQBandConfig: Codable, Equatable, Sendable {
    public var frequencyHz: Float
    public var gainDB: Float
    public var q: Float
    public var isBypassed: Bool

    public init(frequencyHz: Float, gainDB: Float, q: Float, isBypassed: Bool) {
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
        self.isBypassed = isBypassed
    }
}

public struct EQPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var preampDB: Float
    public var bands: [EQBandConfig]

    public init(id: UUID = UUID(), name: String, preampDB: Float, bands: [EQBandConfig]) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
    }
}

public protocol AudioPipelineService {
    func configure(with preset: EQPreset) throws
    func setEnabled(_ enabled: Bool)
    func setOutputDevice(_ id: AudioDeviceID) throws
}

public struct PipelineRuntimeStats: Equatable, Sendable {
    public let ingestedBlocks: Int
    public let unsupportedBlocks: Int
    public let lastInputRMS: Float
    public let renderedBlocks: Int
    public let renderedFrames: Int
    public let lastOutputRMS: Float
    public let ringBufferFrames: Int

    public init(
        ingestedBlocks: Int,
        unsupportedBlocks: Int,
        lastInputRMS: Float,
        renderedBlocks: Int,
        renderedFrames: Int,
        lastOutputRMS: Float,
        ringBufferFrames: Int
    ) {
        self.ingestedBlocks = ingestedBlocks
        self.unsupportedBlocks = unsupportedBlocks
        self.lastInputRMS = lastInputRMS
        self.renderedBlocks = renderedBlocks
        self.renderedFrames = renderedFrames
        self.lastOutputRMS = lastOutputRMS
        self.ringBufferFrames = ringBufferFrames
    }

    public static let zero = PipelineRuntimeStats(
        ingestedBlocks: 0,
        unsupportedBlocks: 0,
        lastInputRMS: 0,
        renderedBlocks: 0,
        renderedFrames: 0,
        lastOutputRMS: 0,
        ringBufferFrames: 0
    )
}

public enum AudioPipelineError: Error, LocalizedError {
    case invalidBandCount(expected: Int, actual: Int)
    case engineStartFailed(String)
    case unsupportedOutputDeviceChange(OSStatus)
    case outputAudioUnitUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidBandCount(expected, actual):
            "Invalid band count. Expected \(expected), got \(actual)."
        case let .engineStartFailed(reason):
            "Failed to start audio engine: \(reason)"
        case let .unsupportedOutputDeviceChange(status):
            "Changing output device failed with OSStatus \(status)"
        case .outputAudioUnitUnavailable:
            "Audio output unit is unavailable"
        }
    }
}
