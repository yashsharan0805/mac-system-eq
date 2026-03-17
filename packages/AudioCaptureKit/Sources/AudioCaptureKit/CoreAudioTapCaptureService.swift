import AVFAudio
import CoreAudio
import DeviceKit
import DiagnosticsKit
import Foundation

public final class CoreAudioTapCaptureService: AudioCaptureService, @unchecked Sendable {
    public private(set) var capturedFormat: AVAudioFormat

    private var bufferHandler: CaptureBufferHandler?
    private let diagnosticsStore: DiagnosticsStore
    private let ioQueue = DispatchQueue(label: "com.macsystemeq.capture-io")
    private var muteMode: CaptureMuteMode = .passthrough

    private var tapID: AudioObjectID = .init(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = .init(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapASBD = AudioStreamBasicDescription()
    private var didLogFirstIOBufferLayout = false

    public init(diagnosticsStore: DiagnosticsStore = .shared) {
        self.diagnosticsStore = diagnosticsStore
        capturedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
    }

    deinit {
        stop()
        didLogFirstIOBufferLayout = false
    }

    public func requestAuthorization() async -> AudioAuthorizationStatus {
        // System-audio tap authorization is handled by macOS TCC at start time.
        // Avoid microphone permission APIs here so we do not trigger mic-recording prompts.
        .granted
    }

    public func setBufferHandler(_ handler: @escaping CaptureBufferHandler) {
        bufferHandler = handler
    }

    public func setMuteMode(_ mode: CaptureMuteMode) {
        muteMode = mode
    }

    public func start(systemCaptureTo outputDeviceID: AudioDeviceID) throws {
        guard #available(macOS 14.4, *) else {
            throw AudioCaptureError.unsupportedOS
        }

        stop()

        let excludedProcessObject = try translatePIDToProcessObject(getpid())
        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let outputDeviceUID = try readDeviceUID(outputDeviceID)
        let strategies: [TapCreationStrategy] = muteMode.isExclusive
            ? [.globalExcludingSelf, .deviceBoundExcludingSelf, .inclusiveProcesses]
            : [.deviceBoundExcludingSelf, .globalExcludingSelf]

        var status: OSStatus = -1
        var usedStrategy: TapCreationStrategy?
        for strategy in strategies {
            status = createTap(
                strategy: strategy,
                excludedProcessObject: excludedProcessObject,
                outputDeviceUID: outputDeviceUID,
                tapID: &createdTapID
            )
            if status == noErr {
                usedStrategy = strategy
                break
            }
        }

        guard status == noErr else {
            throw AudioCaptureError.createTapFailed(status)
        }
        tapID = createdTapID
        if let usedStrategy {
            let store = diagnosticsStore
            Task {
                await store.log(
                    .debug,
                    "Tap strategy selected: \(usedStrategy.rawValue)"
                )
            }
        }

        status = readTapFormat()
        guard status == noErr else {
            throw AudioCaptureError.tapFormatFailed(status)
        }

        let tapUID = try readTapUID()
        try createAggregateDevice(tapUID: tapUID, outputDeviceID: outputDeviceID)
        try setupIOProcAndStart()

        let store = diagnosticsStore
        let mode = muteMode.rawValue
        Task { await store.log(.info, "Started CoreAudio tap capture (mode=\(mode))") }
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
        didLogFirstIOBufferLayout = false
    }

    @available(macOS 14.4, *)
    private func createAggregateDevice(tapUID: String, outputDeviceID: AudioDeviceID) throws {
        let driftComp = true as CFBoolean
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: driftComp,
        ]
        let outputDeviceUID = try readDeviceUID(outputDeviceID)
        let uid = "com.macsystemeq.aggregate.\(UUID().uuidString)"
        let tapOnlyDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacSystemEQ Aggregate",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        var createdDevice = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(tapOnlyDescription as CFDictionary, &createdDevice)
        if status != noErr {
            let subDeviceEntry: [String: Any] = [
                kAudioSubDeviceUIDKey: outputDeviceUID,
                kAudioSubDeviceDriftCompensationKey: true,
            ]
            let fallbackDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacSystemEQ Aggregate",
                kAudioAggregateDeviceUIDKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [subDeviceEntry],
                kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
                kAudioAggregateDeviceTapListKey: [tapEntry],
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]
            status = AudioHardwareCreateAggregateDevice(fallbackDescription as CFDictionary, &createdDevice)
            guard status == noErr else {
                throw AudioCaptureError.createAggregateFailed(status)
            }
            let store = diagnosticsStore
            Task {
                await store.log(
                    .warning,
                    "Tap-only aggregate creation failed; using output-subdevice aggregate fallback."
                )
            }
        }

        aggregateDeviceID = createdDevice
        let store = diagnosticsStore
        Task {
            await store.log(
                .debug,
                "Created aggregate with output device UID \(outputDeviceUID) and tap UID \(tapUID)"
            )
        }
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

            let inputFrameCount = frameCount(from: inInputData)
            let outputFrameCount = frameCount(from: UnsafePointer(outOutputData))

            let sourceBufferList: UnsafePointer<AudioBufferList>
            let frameCount: UInt32
            if let inputFrameCount, inputFrameCount > 0 {
                sourceBufferList = inInputData
                frameCount = inputFrameCount
            } else if let outputFrameCount, outputFrameCount > 0 {
                sourceBufferList = UnsafePointer(outOutputData)
                frameCount = outputFrameCount
            } else {
                return
            }

            if !didLogFirstIOBufferLayout {
                didLogFirstIOBufferLayout = true
                let store = diagnosticsStore
                let inputSummary = describe(bufferList: inInputData)
                let outputSummary = describe(bufferList: UnsafePointer(outOutputData))
                let selected = sourceBufferList == inInputData ? "input" : "output"
                Task {
                    await store.log(
                        .debug,
                        "IOProc first buffers: in=\(inputSummary), out=\(outputSummary), selected=\(selected), frames=\(frameCount)"
                    )
                }
            }

            bufferHandler?(sourceBufferList, frameCount, tapASBD)
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
        guard !buffers.isEmpty else {
            return nil
        }

        let isNonInterleaved = (tapASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = max(1, Int(tapASBD.mChannelsPerFrame))
        let bytesPerFrame = max(1, Int(tapASBD.mBytesPerFrame))
        let perBufferBytesPerFrame = isNonInterleaved ? max(1, bytesPerFrame / channels) : bytesPerFrame

        let maxByteSize = buffers.reduce(0) { partial, buffer in
            max(partial, Int(buffer.mDataByteSize))
        }
        guard maxByteSize > 0 else {
            return nil
        }

        return UInt32(maxByteSize / perBufferBytesPerFrame)
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
           let format = AVAudioFormat(streamDescription: &tapASBD)
        {
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

    private func readDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else {
            throw AudioCaptureError.outputDeviceUIDReadFailed(status)
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

    private func readActiveOutputProcessObjects(excluding excludedProcessObject: AudioObjectID) -> [AudioObjectID] {
        let processObjects = (try? readProcessObjectList()) ?? []
        guard !processObjects.isEmpty else {
            return []
        }

        let runningOutput = processObjects.filter { processObject in
            processObject != excludedProcessObject && isProcessRunningOutput(processObject)
        }
        if !runningOutput.isEmpty {
            return runningOutput
        }

        // Fallback: include all known process objects except this app.
        return processObjects.filter { $0 != excludedProcessObject }
    }

    @available(macOS 14.4, *)
    private func createTap(
        strategy: TapCreationStrategy,
        excludedProcessObject: AudioObjectID,
        outputDeviceUID: String,
        tapID: inout AudioObjectID
    ) -> OSStatus {
        switch strategy {
        case .globalExcludingSelf:
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [excludedProcessObject])
            description.name = "MacSystemEQ Global Tap"
            description.isPrivate = true
            description.muteBehavior = muteBehavior(for: muteMode)
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            if status != noErr {
                let store = diagnosticsStore
                Task {
                    await store.log(.warning, "Global tap creation failed (\(status)).")
                }
            }
            return status

        case .deviceBoundExcludingSelf:
            let description = CATapDescription(
                excludingProcesses: [excludedProcessObject],
                deviceUID: outputDeviceUID,
                stream: 0
            )
            description.name = "MacSystemEQ Device Tap"
            description.isPrivate = true
            description.muteBehavior = muteBehavior(for: muteMode)
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            if status != noErr {
                let store = diagnosticsStore
                Task {
                    await store.log(.warning, "Device-bound tap creation failed (\(status)).")
                }
            }
            return status

        case .inclusiveProcesses:
            let includedProcesses = readActiveOutputProcessObjects(excluding: excludedProcessObject)
            guard !includedProcesses.isEmpty else {
                let store = diagnosticsStore
                Task {
                    await store.log(
                        .warning,
                        "Inclusive tap skipped because no candidate processes were found."
                    )
                }
                return -1
            }

            let description = CATapDescription(stereoMixdownOfProcesses: includedProcesses)
            description.name = "MacSystemEQ Inclusive Tap"
            description.isPrivate = true
            description.muteBehavior = muteBehavior(for: muteMode)
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            let store = diagnosticsStore
            if status == noErr {
                let processCount = includedProcesses.count
                Task {
                    await store.log(
                        .debug,
                        "Created inclusive tap with \(processCount) candidate processes."
                    )
                }
            } else {
                Task {
                    await store.log(.warning, "Inclusive tap creation failed (\(status)).")
                }
            }
            return status
        }
    }

    private func readProcessObjectList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr, size > 0 else {
            throw AudioCaptureError.createTapFailed(status)
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processObjects = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        status = processObjects.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return OSStatus(-1)
            }
            var mutableSize = size
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &mutableSize,
                baseAddress
            )
        }
        guard status == noErr else {
            throw AudioCaptureError.createTapFailed(status)
        }

        return processObjects.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func isProcessRunningOutput(_ processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &size,
            &value
        )

        // Treat unknown status as "running" to avoid filtering out valid process objects.
        if status != noErr {
            return true
        }
        return value != 0
    }

    private func muteBehavior(for mode: CaptureMuteMode) -> CATapMuteBehavior {
        switch mode {
        case .passthrough:
            .unmuted
        case .exclusiveMutedWhenTapped:
            .mutedWhenTapped
        case .exclusiveMuted:
            .muted
        }
    }

    private func describe(bufferList: UnsafePointer<AudioBufferList>) -> String {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let descriptions = buffers.enumerated().map { index, buffer in
            let hasData = buffer.mData != nil ? "1" : "0"
            return "#\(index){bytes=\(buffer.mDataByteSize),channels=\(buffer.mNumberChannels),data=\(hasData)}"
        }
        return "count=\(buffers.count) [\(descriptions.joined(separator: ", "))]"
    }
}

private enum TapCreationStrategy: String {
    case globalExcludingSelf = "global-excluding-self"
    case deviceBoundExcludingSelf = "device-bound-excluding-self"
    case inclusiveProcesses = "inclusive-process-list"
}
