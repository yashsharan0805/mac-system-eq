import AVFAudio
import AudioToolbox
import DiagnosticsKit
import DeviceKit
import Foundation

public final class AVAudioEQPipelineService: AudioPipelineService, @unchecked Sendable {
    private let diagnosticsStore: DiagnosticsStore
    private let eqNode: AVAudioUnitEQ
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: StereoFloatRingBuffer?
    private var currentPreset: EQPreset?
    private var selectedOutputDeviceID: AudioDeviceID?
    private var processingFormat: AVAudioFormat

    private let stateLock = NSLock()
    private var droppedFramesInWindow = 0
    private var processedFramesInWindow = 0
    private var windowStart = Date()
    private var ingestedBlocks = 0
    private var unsupportedBlocks = 0
    private var lastInputRMS: Float = 0
    private var renderedBlocks = 0
    private var renderedFrames = 0
    private var lastOutputRMS: Float = 0
    private var hasLoggedInputFormat = false
    private var hasLoggedUnsupportedFormat = false
    private var hasLoggedRenderFormat = false

    public init(diagnosticsStore: DiagnosticsStore = .shared) {
        self.diagnosticsStore = diagnosticsStore
        self.eqNode = AVAudioUnitEQ(numberOfBands: 10)
        self.processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!

        configureBandDefaults()
    }

    public func startIfNeeded(format: AVAudioFormat? = nil) throws {
        if let format {
            processingFormat = format.standardizedStereoFloatFormat()
        }

        if engine.isRunning {
            return
        }

        if sourceNode == nil {
            ringBuffer = StereoFloatRingBuffer(capacityFrames: Int(processingFormat.sampleRate) * 4)
            sourceNode = AVAudioSourceNode(format: processingFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                guard let self else {
                    return noErr
                }
                self.render(into: audioBufferList, frameCount: Int(frameCount))
                return noErr
            }

            guard let sourceNode else {
                throw AudioPipelineError.engineStartFailed("Source node not initialized")
            }

            engine.attach(sourceNode)
            engine.attach(eqNode)

            engine.connect(sourceNode, to: eqNode, format: processingFormat)
            engine.connect(eqNode, to: engine.mainMixerNode, format: processingFormat)
        }

        do {
            try engine.start()
            let store = diagnosticsStore
            Task { await store.log(.info, "Audio pipeline started") }
        } catch {
            throw AudioPipelineError.engineStartFailed(error.localizedDescription)
        }
    }

    public func stop() {
        if engine.isRunning {
            engine.stop()
            let store = diagnosticsStore
            Task { await store.log(.info, "Audio pipeline stopped") }
        }
    }

    public func configure(with preset: EQPreset) throws {
        let normalized = Self.normalized(preset)
        guard normalized.bands.count == eqNode.bands.count else {
            throw AudioPipelineError.invalidBandCount(expected: eqNode.bands.count, actual: normalized.bands.count)
        }

        let changed = Self.changedBandIndexes(old: currentPreset, new: normalized)
        for index in changed {
            let band = normalized.bands[index]
            let target = eqNode.bands[index]
            target.filterType = .parametric
            target.frequency = band.frequencyHz
            target.gain = band.gainDB
            target.bandwidth = band.q
            target.bypass = band.isBypassed
        }

        engine.mainMixerNode.outputVolume = Self.clamp(normalized.preampDB, min: -12, max: 12).dbToLinearGain()
        currentPreset = normalized

        let store = diagnosticsStore
        Task { await store.log(.info, "Applied preset: \(normalized.name)") }
    }

    public func setEnabled(_ enabled: Bool) {
        eqNode.bypass = !enabled
    }

    public func setOutputDevice(_ id: AudioDeviceID) throws {
        selectedOutputDeviceID = id
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw AudioPipelineError.outputAudioUnitUnavailable
        }

        var mutableID = id
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioPipelineError.unsupportedOutputDeviceChange(status)
        }

        let store = diagnosticsStore
        Task { await store.log(.info, "Switched output device: \(id)") }
    }

    public func ingest(buffer: UnsafePointer<AudioBufferList>, frameCount: UInt32, asbd: AudioStreamBasicDescription) {
        guard let ringBuffer else {
            return
        }

        if !hasLoggedInputFormat {
            hasLoggedInputFormat = true
            let store = diagnosticsStore
            let descriptor = Self.describe(asbd: asbd)
            Task { await store.log(.info, "Pipeline input format: \(descriptor)") }
        }

        let frames = Int(frameCount)
        if frames == 0 {
            return
        }

        let data = PCMFrameReader.readStereoFloat(buffer: buffer, frameCount: frames, asbd: asbd)
        guard let data else {
            stateLock.lock()
            unsupportedBlocks += 1
            stateLock.unlock()
            let store = diagnosticsStore
            if !hasLoggedUnsupportedFormat {
                hasLoggedUnsupportedFormat = true
                let descriptor = Self.describe(asbd: asbd)
                Task { await store.log(.warning, "Unsupported input format encountered: \(descriptor)") }
            }
            return
        }

        let dropped = ringBuffer.push(left: data.left, right: data.right)
        let rms = Self.rms(left: data.left, right: data.right)
        stateLock.lock()
        ingestedBlocks += 1
        droppedFramesInWindow += dropped
        processedFramesInWindow += frames
        lastInputRMS = rms
        updateHealthSnapshotIfNeeded()
        stateLock.unlock()
    }

    public func currentHealthSnapshot() -> AudioHealthSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        let latencyFrames = ringBuffer?.count ?? 0
        let latencyMs = Double(latencyFrames) / processingFormat.sampleRate * 1_000
        let cpuLoadApprox = min(100.0, Double(processedFramesInWindow) / max(1, processingFormat.sampleRate * 0.01))
        return AudioHealthSnapshot(latencyMs: latencyMs, dropoutsLastMinute: droppedFramesInWindow, cpuLoadPct: cpuLoadApprox)
    }

    public func runtimeStats() -> PipelineRuntimeStats {
        stateLock.lock()
        defer { stateLock.unlock() }
        return PipelineRuntimeStats(
            ingestedBlocks: ingestedBlocks,
            unsupportedBlocks: unsupportedBlocks,
            lastInputRMS: lastInputRMS,
            renderedBlocks: renderedBlocks,
            renderedFrames: renderedFrames,
            lastOutputRMS: lastOutputRMS,
            ringBufferFrames: ringBuffer?.count ?? 0
        )
    }

    public static func normalized(_ preset: EQPreset) -> EQPreset {
        let normalizedBands = preset.bands.map {
            EQBandConfig(
                frequencyHz: clamp($0.frequencyHz, min: 20, max: 20_000),
                gainDB: clamp($0.gainDB, min: -24, max: 24),
                q: clamp($0.q, min: 0.1, max: 18),
                isBypassed: $0.isBypassed
            )
        }

        return EQPreset(
            id: preset.id,
            name: preset.name,
            preampDB: clamp(preset.preampDB, min: -12, max: 12),
            bands: normalizedBands
        )
    }

    public static func changedBandIndexes(old: EQPreset?, new: EQPreset) -> [Int] {
        guard let old else {
            return Array(new.bands.indices)
        }

        return new.bands.indices.filter { index in
            old.bands.indices.contains(index) ? old.bands[index] != new.bands[index] : true
        }
    }

    private func render(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard let ringBuffer else {
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard frameCount > 0, !buffers.isEmpty else {
            return
        }

        if !hasLoggedRenderFormat {
            hasLoggedRenderFormat = true
            let summary = Self.describe(bufferList: audioBufferList)
            let store = diagnosticsStore
            Task { await store.log(.debug, "Pipeline render buffer layout: \(summary), frames=\(frameCount)") }
        }

        if buffers.count >= 2,
           let leftBase = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           let rightBase = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            let written = ringBuffer.pop(
                left: UnsafeMutableBufferPointer(start: leftBase, count: frameCount),
                right: UnsafeMutableBufferPointer(start: rightBase, count: frameCount)
            )

            if written < frameCount {
                let remaining = frameCount - written
                leftBase.advanced(by: written).update(repeating: 0, count: remaining)
                rightBase.advanced(by: written).update(repeating: 0, count: remaining)
            }
            updateRenderStats(left: leftBase, right: rightBase, frameCount: frameCount)
            return
        }

        guard buffers.count == 1,
              let interleavedBase = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            return
        }

        let channelCount = max(1, Int(buffers[0].mNumberChannels))
        var left = Array(repeating: Float.zero, count: frameCount)
        var right = Array(repeating: Float.zero, count: frameCount)
        let written = left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                ringBuffer.pop(left: leftBuffer, right: rightBuffer)
            }
        }

        for frame in 0 ..< frameCount {
            let base = frame * channelCount
            if frame < written {
                if channelCount == 1 {
                    interleavedBase[base] = 0.5 * (left[frame] + right[frame])
                } else {
                    interleavedBase[base] = left[frame]
                    interleavedBase[base + 1] = right[frame]
                    if channelCount > 2 {
                        for channel in 2 ..< channelCount {
                            interleavedBase[base + channel] = 0
                        }
                    }
                }
            } else {
                for channel in 0 ..< channelCount {
                    interleavedBase[base + channel] = 0
                }
            }
        }
        updateRenderStats(left: left, right: right, frameCount: frameCount)
    }

    private func updateHealthSnapshotIfNeeded() {
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= 1 else {
            return
        }

        let latencyFrames = ringBuffer?.count ?? 0
        let latencyMs = Double(latencyFrames) / processingFormat.sampleRate * 1_000
        let cpuLoadApprox = min(100.0, Double(processedFramesInWindow) / max(1, processingFormat.sampleRate * elapsed) * 100)
        let snapshot = AudioHealthSnapshot(latencyMs: latencyMs, dropoutsLastMinute: droppedFramesInWindow, cpuLoadPct: cpuLoadApprox)

        let store = diagnosticsStore
        Task { await store.setHealth(snapshot) }

        processedFramesInWindow = 0
        droppedFramesInWindow = 0
        windowStart = Date()
    }

    private func configureBandDefaults() {
        let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
        for (index, band) in eqNode.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = frequencies[index]
            band.gain = 0
            band.bandwidth = 1
            band.bypass = false
        }
    }

    private static func clamp(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    private static func describe(asbd: AudioStreamBasicDescription) -> String {
        "sr=\(asbd.mSampleRate), formatID=\(asbd.mFormatID), flags=0x\(String(asbd.mFormatFlags, radix: 16)), channels=\(asbd.mChannelsPerFrame), bits=\(asbd.mBitsPerChannel), bpf=\(asbd.mBytesPerFrame)"
    }

    private static func rms(left: [Float], right: [Float]) -> Float {
        let count = min(left.count, right.count)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for index in 0 ..< count {
            let l = left[index]
            let r = right[index]
            sum += 0.5 * (l * l + r * r)
        }

        return sqrtf(sum / Float(count))
    }

    private func updateRenderStats(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int) {
        let outputRMS = Self.rms(left: left, right: right, count: frameCount)
        stateLock.lock()
        renderedBlocks += 1
        renderedFrames += frameCount
        lastOutputRMS = outputRMS
        stateLock.unlock()
    }

    private func updateRenderStats(left: [Float], right: [Float], frameCount: Int) {
        let outputRMS = Self.rms(left: left, right: right)
        stateLock.lock()
        renderedBlocks += 1
        renderedFrames += frameCount
        lastOutputRMS = outputRMS
        stateLock.unlock()
    }

    private static func describe(bufferList: UnsafeMutablePointer<AudioBufferList>) -> String {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let descriptions = buffers.enumerated().map { index, buffer in
            let hasData = buffer.mData != nil ? "1" : "0"
            return "#\(index){bytes=\(buffer.mDataByteSize),channels=\(buffer.mNumberChannels),data=\(hasData)}"
        }
        return "count=\(buffers.count) [\(descriptions.joined(separator: ", "))]"
    }

    private static func rms(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0 ..< count {
            let l = left[index]
            let r = right[index]
            sum += 0.5 * (l * l + r * r)
        }
        return sqrtf(sum / Float(count))
    }
}

private extension AVAudioFormat {
    func standardizedStereoFloatFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
    }
}

private extension Float {
    func dbToLinearGain() -> Float {
        powf(10, self / 20)
    }
}

private final class StereoFloatRingBuffer {
    private var left: [Float]
    private var right: [Float]
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private var _count = 0
    private let lock = NSLock()

    init(capacityFrames: Int) {
        capacity = max(1_024, capacityFrames)
        left = Array(repeating: 0, count: capacity)
        right = Array(repeating: 0, count: capacity)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func push(left: [Float], right: [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let frames = min(left.count, right.count)
        var dropped = 0

        for index in 0 ..< frames {
            if _count == capacity {
                readIndex = (readIndex + 1) % capacity
                _count -= 1
                dropped += 1
            }

            self.left[writeIndex] = left[index]
            self.right[writeIndex] = right[index]
            writeIndex = (writeIndex + 1) % capacity
            _count += 1
        }

        return dropped
    }

    func pop(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let framesToRead = min(left.count, right.count, _count)
        if framesToRead == 0 {
            return 0
        }

        for index in 0 ..< framesToRead {
            left[index] = self.left[readIndex]
            right[index] = self.right[readIndex]
            readIndex = (readIndex + 1) % capacity
        }

        _count -= framesToRead
        return framesToRead
    }
}

private struct PCMFrameReader {
    static func readStereoFloat(
        buffer: UnsafePointer<AudioBufferList>,
        frameCount: Int,
        asbd: AudioStreamBasicDescription
    ) -> (left: [Float], right: [Float])? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer))
        guard frameCount > 0 else {
            return ([], [])
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bytesPerSample = max(1, Int(asbd.mBitsPerChannel / 8))

        if isFloat, bytesPerSample == MemoryLayout<Float>.size {
            if list.count >= 2,
               let leftPtr = list[0].mData?.assumingMemoryBound(to: Float.self),
               let rightPtr = list[1].mData?.assumingMemoryBound(to: Float.self) {
                return (
                    Array(UnsafeBufferPointer(start: leftPtr, count: frameCount)),
                    Array(UnsafeBufferPointer(start: rightPtr, count: frameCount))
                )
            }

            if list.count == 1,
               let interleaved = list[0].mData?.assumingMemoryBound(to: Float.self) {
                var left = Array(repeating: Float.zero, count: frameCount)
                var right = Array(repeating: Float.zero, count: frameCount)
                let channels = max(1, Int(asbd.mChannelsPerFrame))
                for frame in 0 ..< frameCount {
                    left[frame] = interleaved[frame * channels]
                    right[frame] = channels > 1 ? interleaved[frame * channels + 1] : left[frame]
                }
                return (left, right)
            }
        }

        if isSignedInt, bytesPerSample == MemoryLayout<Int16>.size, list.count >= 1,
           let interleaved = list[0].mData?.assumingMemoryBound(to: Int16.self) {
            var left = Array(repeating: Float.zero, count: frameCount)
            var right = Array(repeating: Float.zero, count: frameCount)
            let channels = max(1, Int(asbd.mChannelsPerFrame))

            for frame in 0 ..< frameCount {
                left[frame] = Float(interleaved[frame * channels]) / Float(Int16.max)
                right[frame] = channels > 1 ? Float(interleaved[frame * channels + 1]) / Float(Int16.max) : left[frame]
            }
            return (left, right)
        }

        if isSignedInt, bytesPerSample == MemoryLayout<Int32>.size, list.count >= 1,
           let interleaved = list[0].mData?.assumingMemoryBound(to: Int32.self) {
            var left = Array(repeating: Float.zero, count: frameCount)
            var right = Array(repeating: Float.zero, count: frameCount)
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let scale = Float(Int32.max)

            for frame in 0 ..< frameCount {
                left[frame] = Float(interleaved[frame * channels]) / scale
                right[frame] = channels > 1 ? Float(interleaved[frame * channels + 1]) / scale : left[frame]
            }
            return (left, right)
        }

        if isFloat, bytesPerSample == MemoryLayout<Double>.size {
            if list.count >= 2,
               let leftPtr = list[0].mData?.assumingMemoryBound(to: Double.self),
               let rightPtr = list[1].mData?.assumingMemoryBound(to: Double.self) {
                var left = Array(repeating: Float.zero, count: frameCount)
                var right = Array(repeating: Float.zero, count: frameCount)
                for frame in 0 ..< frameCount {
                    left[frame] = Float(leftPtr[frame])
                    right[frame] = Float(rightPtr[frame])
                }
                return (left, right)
            }

            if list.count == 1,
               let interleaved = list[0].mData?.assumingMemoryBound(to: Double.self) {
                var left = Array(repeating: Float.zero, count: frameCount)
                var right = Array(repeating: Float.zero, count: frameCount)
                let channels = max(1, Int(asbd.mChannelsPerFrame))
                for frame in 0 ..< frameCount {
                    left[frame] = Float(interleaved[frame * channels])
                    right[frame] = channels > 1 ? Float(interleaved[frame * channels + 1]) : left[frame]
                }
                return (left, right)
            }
        }

        return nil
    }
}
