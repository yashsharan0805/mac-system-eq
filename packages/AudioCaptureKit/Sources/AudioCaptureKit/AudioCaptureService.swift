import AVFAudio
import CoreAudio
import DeviceKit
import Foundation

public enum AudioAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

public enum CaptureMuteMode: String, Equatable, Sendable {
    case passthrough
    case exclusiveMutedWhenTapped
    case exclusiveMuted

    public var isExclusive: Bool {
        switch self {
        case .passthrough:
            false
        case .exclusiveMutedWhenTapped, .exclusiveMuted:
            true
        }
    }
}

public typealias CaptureBufferHandler = (
    _ buffer: UnsafePointer<AudioBufferList>,
    _ frameCount: UInt32,
    _ asbd: AudioStreamBasicDescription
) -> Void

public protocol AudioCaptureService {
    func requestAuthorization() async -> AudioAuthorizationStatus
    func setMuteMode(_ mode: CaptureMuteMode)
    func start(systemCaptureTo outputDeviceID: AudioDeviceID) throws
    func stop()
    func setBufferHandler(_ handler: @escaping CaptureBufferHandler)
    var capturedFormat: AVAudioFormat { get }
}

public enum AudioCaptureError: Error, LocalizedError {
    case unsupportedOS
    case permissionDenied
    case createTapFailed(OSStatus)
    case tapFormatFailed(OSStatus)
    case tapUIDReadFailed(OSStatus)
    case outputDeviceUIDReadFailed(OSStatus)
    case createAggregateFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case startDeviceFailed(OSStatus)
    case translatePIDFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            "System-wide capture requires macOS 14.4+"
        case .permissionDenied:
            "Audio capture permission denied"
        case let .createTapFailed(status):
            "Failed creating process tap: \(status)"
        case let .tapFormatFailed(status):
            "Failed reading tap format: \(status)"
        case let .tapUIDReadFailed(status):
            "Failed reading tap UID: \(status)"
        case let .outputDeviceUIDReadFailed(status):
            "Failed reading output device UID: \(status)"
        case let .createAggregateFailed(status):
            "Failed creating aggregate device: \(status)"
        case let .createIOProcFailed(status):
            "Failed creating IOProc: \(status)"
        case let .startDeviceFailed(status):
            "Failed starting capture device: \(status)"
        case let .translatePIDFailed(status):
            "Failed translating PID to process object: \(status)"
        }
    }
}
