import CoreAudio
import DiagnosticsKit
import Foundation

public protocol DeviceManager {
    func outputDevices() throws -> [AudioDeviceDescriptor]
    func defaultOutputDeviceID() throws -> AudioDeviceID
    func observeOutputChanges(_ handler: @escaping @Sendable () -> Void) throws
}

public enum DeviceManagerError: Error, LocalizedError {
    case osStatus(OSStatus, String)
    case noDefaultOutput

    public var errorDescription: String? {
        switch self {
        case let .osStatus(status, operation):
            "\(operation) failed with OSStatus \(status)"
        case .noDefaultOutput:
            "No default output device found"
        }
    }
}

public final class CoreAudioDeviceManager: DeviceManager {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let listenerQueue = DispatchQueue(label: "com.macsystemeq.device-listener")

    public init() {}

    public func outputDevices() throws -> [AudioDeviceDescriptor] {
        let ids: [AudioDeviceID] = try readSystemArray(selector: kAudioHardwarePropertyDevices)
        let defaultID = try defaultOutputDeviceID()

        var devices: [AudioDeviceDescriptor] = []
        devices.reserveCapacity(ids.count)

        for id in ids {
            let channels = try outputChannelCount(deviceID: id)
            if channels <= 0 {
                continue
            }

            let uid = try readStringProperty(objectID: id, selector: kAudioDevicePropertyDeviceUID)
            let name = try readStringProperty(objectID: id, selector: kAudioObjectPropertyName)

            devices.append(
                AudioDeviceDescriptor(
                    id: id,
                    uid: uid,
                    name: name,
                    isDefaultOutput: id == defaultID
                )
            )
        }

        return devices.sorted { lhs, rhs in
            if lhs.isDefaultOutput != rhs.isDefaultOutput {
                return lhs.isDefaultOutput
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, "Reading default output device")
        }
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw DeviceManagerError.noDefaultOutput
        }

        return deviceID
    }

    public func observeOutputChanges(_ handler: @escaping @Sendable () -> Void) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, listenerQueue) { _, _ in
            handler()
        }

        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, "Registering output device listener")
        }
    }

    private func readSystemArray<T>(selector: AudioObjectPropertySelector) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, "Reading property data size: \(selector)")
        }

        let count = Int(size) / MemoryLayout<T>.size
        var raw = [UInt8](repeating: 0, count: Int(size))
        status = raw.withUnsafeMutableBytes { rawBuffer in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, rawBuffer.baseAddress!)
        }
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, "Reading property data: \(selector)")
        }

        return raw.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: T.self).prefix(count))
        }
    }

    private func outputChannelCount(deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, "Reading stream config size for device \(deviceID)")
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer)
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, "Reading stream config for device \(deviceID)")
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func readStringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfString)
        guard status == noErr else {
            throw DeviceManagerError.osStatus(status, "Reading string property \(selector)")
        }

        return (cfString?.takeRetainedValue() as String?) ?? "Unknown"
    }
}
