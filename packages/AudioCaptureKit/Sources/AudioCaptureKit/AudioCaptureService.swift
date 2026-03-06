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
            return false
        case .exclusiveMutedWhenTapped, .exclusiveMuted:
            return true
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
            return "System-wide capture requires macOS 14.4+"
        case .permissionDenied:
            return "Audio capture permission denied"
        case let .createTapFailed(status):
            return "Failed creating process tap: \(status)"
        case let .tapFormatFailed(status):
            return "Failed reading tap format: \(status)"
        case let .tapUIDReadFailed(status):
            return "Failed reading tap UID: \(status)"
        case let .outputDeviceUIDReadFailed(status):
            return "Failed reading output device UID: \(status)"
        case let .createAggregateFailed(status):
            return "Failed creating aggregate device: \(status)"
        case let .createIOProcFailed(status):
            return "Failed creating IOProc: \(status)"
        case let .startDeviceFailed(status):
            return "Failed starting capture device: \(status)"
        case let .translatePIDFailed(status):
            return "Failed translating PID to process object: \(status)"
        }
    }
}
