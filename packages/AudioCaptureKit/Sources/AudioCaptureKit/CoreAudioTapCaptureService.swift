import AVFAudio
import AVFoundation
import CoreAudio
import DiagnosticsKit
import DeviceKit
import Foundation

public final class CoreAudioTapCaptureService: AudioCaptureService, @unchecked Sendable {
    public private(set) var capturedFormat: AVAudioFormat

    private var bufferHandler: CaptureBufferHandler?
    private let diagnosticsStore: DiagnosticsStore
    private let ioQueue = DispatchQueue(label: "com.macsystemeq.capture-io")

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapASBD = AudioStreamBasicDescription()

    public init(diagnosticsStore: DiagnosticsStore = .shared) {
        self.diagnosticsStore = diagnosticsStore
        capturedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
    }

    deinit {
        stop()
    }

    public func requestAuthorization() async -> AudioAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    public func setBufferHandler(_ handler: @escaping CaptureBufferHandler) {
        bufferHandler = handler
    }

    public func start(systemCaptureTo outputDeviceID: AudioDeviceID) throws {
        guard #available(macOS 14.4, *) else {
            throw AudioCaptureError.unsupportedOS
        }

        stop()

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard auth == .authorized else {
            throw AudioCaptureError.permissionDenied
        }

        let excludedProcessObject = try translatePIDToProcessObject(getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [excludedProcessObject])
        description.name = "MacSystemEQ Global Tap"
        description.isPrivate = true

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &createdTapID)
        guard status == noErr else {
            throw AudioCaptureError.createTapFailed(status)
        }
        tapID = createdTapID

        status = readTapFormat()
        guard status == noErr else {
            throw AudioCaptureError.tapFormatFailed(status)
        }

        let tapUID = try readTapUID()
        try createAggregateDevice(tapUID: tapUID, outputDeviceID: outputDeviceID)
        try setupIOProcAndStart()

        let store = diagnosticsStore
        Task { await store.log(.info, "Started CoreAudio tap capture") }
    }

    public func stop() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    @available(macOS 14.4, *)
    private func createAggregateDevice(tapUID: String, outputDeviceID: AudioDeviceID) throws {
        let driftComp = true as CFBoolean
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: driftComp
        ]

        let uid = "com.macsystemeq.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacSystemEQ Aggregate",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var createdDevice = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdDevice)
        guard status == noErr else {
            throw AudioCaptureError.createAggregateFailed(status)
        }

        aggregateDeviceID = createdDevice

        // We keep outputDeviceID for future explicit routing support in tap aggregate composition.
        _ = outputDeviceID
    }

    private func setupIOProcAndStart() throws {
        var procID: AudioDeviceIOProcID?
        let statusCreate = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            ioQueue
        ) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else {
                return
            }

            guard let frameCount = self.frameCount(from: inInputData), frameCount > 0 else {
                return
            }

            copyAudioBufferList(input: inInputData, output: outOutputData)

            bufferHandler?(inInputData, frameCount, tapASBD)
        }

        guard statusCreate == noErr, let procID else {
            throw AudioCaptureError.createIOProcFailed(statusCreate)
        }

        ioProcID = procID

        let statusStart = AudioDeviceStart(aggregateDeviceID, procID)
        guard statusStart == noErr else {
            throw AudioCaptureError.startDeviceFailed(statusStart)
        }
    }

    private func frameCount(from input: UnsafePointer<AudioBufferList>) -> UInt32? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first else {
            return nil
        }

        let bytesPerFrame = max(1, Int(tapASBD.mBytesPerFrame))
        return UInt32(first.mDataByteSize) / UInt32(bytesPerFrame)
    }

    private func readTapFormat() -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &tapASBD)

        if status == noErr,
           let format = AVAudioFormat(streamDescription: &tapASBD) {
            capturedFormat = format
        }

        return status
    }

    private func readTapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value)

        guard status == noErr, let value else {
            throw AudioCaptureError.tapUIDReadFailed(status)
        }

        return value.takeRetainedValue() as String
    }

    private func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var translated = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePID = pid

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &mutablePID,
            &size,
            &translated
        )

        guard status == noErr, translated != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioCaptureError.translatePIDFailed(status)
        }

        return translated
    }
}

private func copyAudioBufferList(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
    let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputList = UnsafeMutableAudioBufferListPointer(output)
    let count = min(inputList.count, outputList.count)

    for index in 0 ..< count {
        guard let inData = inputList[index].mData,
              let outData = outputList[index].mData else {
            continue
        }

        let bytes = min(Int(inputList[index].mDataByteSize), Int(outputList[index].mDataByteSize))
        memcpy(outData, inData, bytes)
        outputList[index].mDataByteSize = UInt32(bytes)
    }
}
