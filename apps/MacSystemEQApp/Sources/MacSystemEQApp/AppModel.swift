import AppKit
import AudioCaptureKit
import AudioPipelineKit
import DeviceKit
import DiagnosticsKit
import Foundation
import PresetsKit

@MainActor
final class AppModel: ObservableObject {
    @Published var authorizationStatus: AudioAuthorizationStatus = .notDetermined
    @Published var isEnabled = false
    @Published var outputDevices: [AudioDeviceDescriptor] = []
    @Published var selectedOutputDeviceID: AudioDeviceID?
    @Published var presets: [EQPreset] = []
    @Published var selectedPresetID: UUID?
    @Published var editablePreset: EQPreset = DefaultPresets.factory()[0]
    @Published var lastError: String?
    @Published var healthSnapshot: AudioHealthSnapshot = .zero
    @Published var pipelineStats: PipelineRuntimeStats = .zero
    @Published var recentLogs: [LogEntry] = []
    @Published var launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
    @Published var exclusiveModeRequested = false
    @Published var activeMuteMode: CaptureMuteMode = .passthrough
    @Published var visualizerEnabled = false
    @Published var visualizerSamples: [Float] = Array(repeating: 0, count: 48)

    private let captureService: CoreAudioTapCaptureService
    private let pipelineService: AVAudioEQPipelineService
    private let deviceManager: CoreAudioDeviceManager
    private let diagnosticsStore: DiagnosticsStore
    private let featureFlags: FeatureFlags
    private let presetStore: JSONPresetStore?

    private var pollingTask: Task<Void, Never>?
    private var exclusiveActivatedAt: Date?
    private var lastExclusiveNonSilentAt: Date?
    private var isExclusiveRecoveryInProgress = false
    private let exclusiveSignalThreshold: Float = 0.0001
    private let exclusiveSilenceTimeout: TimeInterval = 3
    private var lastPipelineStatsLogAt: Date?
    private var didLogSilentCaptureWarning = false
    private var didLogSilentRenderWarning = false
    private var didSurfacePermissionHint = false
    private let visualizerSampleCount = 48

    init() {
        diagnosticsStore = .shared
        captureService = CoreAudioTapCaptureService(diagnosticsStore: diagnosticsStore)
        pipelineService = AVAudioEQPipelineService(diagnosticsStore: diagnosticsStore)
        deviceManager = CoreAudioDeviceManager()
        featureFlags = FeatureFlags.fromEnvironment()
        presetStore = try? JSONPresetStore(diagnosticsStore: diagnosticsStore)

        captureService.setBufferHandler { [weak pipelineService] buffer, frameCount, asbd in
            pipelineService?.ingest(buffer: buffer, frameCount: frameCount, asbd: asbd)
        }

        Task {
            await diagnosticsStore.log(.info, "MacSystemEQ app model initialized")
            if featureFlags.enableVerboseLogging {
                await diagnosticsStore.log(.debug, "Verbose logging enabled")
            }
        }

        Task {
            await bootstrap()
        }
    }

    func bootstrap() async {
        authorizationStatus = await captureService.requestAuthorization()
        reloadDevices()
        loadPresets()

        do {
            try deviceManager.observeOutputChanges { [weak self] in
                Task { @MainActor in
                    self?.reloadDevices()
                }
            }
        } catch {
            setError(error)
        }

        startPollingDiagnostics()
    }

    func requestAuthorization() async {
        authorizationStatus = await captureService.requestAuthorization()
    }

    func toggleEnabled() async {
        if isEnabled {
            stopSystemEQ()
            return
        }

        await startSystemEQ()
    }

    func applySelectedPreset() {
        guard let preset = presets.first(where: { $0.id == selectedPresetID }) else {
            return
        }

        editablePreset = preset
        do {
            try pipelineService.configure(with: editablePreset)
        } catch {
            setError(error)
        }
    }

    func setPreamp(_ value: Float) {
        editablePreset.preampDB = value
        applyEditablePreset()
    }

    func setBandGain(index: Int, gainDB: Float) {
        guard editablePreset.bands.indices.contains(index) else {
            return
        }

        editablePreset.bands[index].gainDB = gainDB
        applyEditablePreset()
    }

    func selectOutputDevice(_ id: AudioDeviceID) {
        selectedOutputDeviceID = id
        if isEnabled {
            do {
                try pipelineService.setOutputDevice(id)
            } catch {
                setError(error)
            }
        }
    }

    func saveEditablePreset() {
        guard let store = presetStore else {
            return
        }

        do {
            let normalized = AVAudioEQPipelineService.normalized(editablePreset)
            let named = EQPreset(
                id: normalized.id,
                name: sanitizedPresetName(normalized.name),
                preampDB: normalized.preampDB,
                bands: normalized.bands
            )
            editablePreset = named

            if let idx = presets.firstIndex(where: { $0.id == named.id }) {
                presets[idx] = named
            } else {
                presets.append(named)
            }

            selectedPresetID = named.id
            try store.save(named)
        } catch {
            setError(error)
        }
    }

    func createCustomPreset() {
        let base = AVAudioEQPipelineService.normalized(editablePreset)
        let custom = EQPreset(
            name: nextCustomPresetName(),
            preampDB: base.preampDB,
            bands: base.bands
        )

        editablePreset = custom
        presets.append(custom)
        selectedPresetID = custom.id
        applyEditablePreset()
        saveEditablePreset()
    }

    func deleteSelectedPreset() {
        guard let id = selectedPresetID else {
            return
        }

        guard presets.count > 1 else {
            lastError = "Keep at least one preset."
            return
        }

        do {
            if let store = presetStore {
                try store.delete(id: id)
            }

            presets.removeAll { $0.id == id }
            if let fallback = presets.first {
                selectedPresetID = fallback.id
                editablePreset = fallback
                applyEditablePreset()
            }
        } catch {
            setError(error)
        }
    }

    func setPresetName(_ name: String) {
        let sanitized = sanitizedPresetName(name)
        editablePreset.name = sanitized
        if let id = selectedPresetID,
           let idx = presets.firstIndex(where: { $0.id == id }) {
            presets[idx].name = sanitized
        }
    }

    func importPreset() {
        guard let store = presetStore else {
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let preset = try store.importPreset(from: url)
            if let existing = presets.firstIndex(where: { $0.id == preset.id }) {
                presets[existing] = preset
            } else {
                presets.append(preset)
            }
            selectedPresetID = preset.id
            editablePreset = preset
            applyEditablePreset()
        } catch {
            setError(error)
        }
    }

    func exportPreset() {
        guard let store = presetStore,
              let preset = presets.first(where: { $0.id == selectedPresetID }) else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name.replacingOccurrences(of: " ", with: "-"))" + ".json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try store.export(preset, to: url)
        } catch {
            setError(error)
        }
    }

    func exportLogs() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "mac-system-eq-logs.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                try await diagnosticsStore.exportLogs(to: url)
            } catch {
                await MainActor.run {
                    self.setError(error)
                }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLoginEnabled = enabled
        } catch {
            setError(error)
        }
    }

    func setExclusiveMode(_ enabled: Bool) {
        exclusiveModeRequested = enabled
        let requestedExclusive = enabled

        guard isEnabled else {
            return
        }

        guard let outputDeviceID = selectedOutputDeviceID ?? outputDevices.first?.id else {
            lastError = "No output device available."
            return
        }

        do {
            captureService.stop()
            try startCaptureWithFallback(outputDeviceID: outputDeviceID)
            if activeMuteMode.isExclusive || !requestedExclusive {
                lastError = nil
            }
        } catch {
            setError(error)
            stopSystemEQ()
        }
    }

    private func startSystemEQ() async {
        guard authorizationStatus == .granted else {
            lastError = "Grant audio permission before starting system EQ."
            return
        }
        let requestedExclusive = exclusiveModeRequested

        guard let outputDeviceID = selectedOutputDeviceID ?? outputDevices.first?.id else {
            lastError = "No output device available."
            return
        }

        do {
            try pipelineService.startIfNeeded(format: captureService.capturedFormat)
            try pipelineService.setOutputDevice(outputDeviceID)
            try pipelineService.configure(with: editablePreset)
            pipelineService.setEnabled(true)
            try startCaptureWithFallback(outputDeviceID: outputDeviceID)
            isEnabled = true
            if activeMuteMode.isExclusive || !requestedExclusive {
                lastError = nil
            }
        } catch {
            setError(error)
            stopSystemEQ()
        }
    }

    private func stopSystemEQ() {
        captureService.stop()
        pipelineService.setEnabled(false)
        pipelineService.stop()
        activeMuteMode = .passthrough
        exclusiveActivatedAt = nil
        lastExclusiveNonSilentAt = nil
        isExclusiveRecoveryInProgress = false
        lastPipelineStatsLogAt = nil
        didLogSilentCaptureWarning = false
        didLogSilentRenderWarning = false
        didSurfacePermissionHint = false
        isEnabled = false
    }

    private func reloadDevices() {
        do {
            outputDevices = try deviceManager.outputDevices()
            if selectedOutputDeviceID == nil {
                selectedOutputDeviceID = outputDevices.first?.id
            } else if !outputDevices.contains(where: { $0.id == selectedOutputDeviceID }) {
                selectedOutputDeviceID = outputDevices.first?.id
            }
        } catch {
            setError(error)
        }
    }

    private func loadPresets() {
        do {
            if let store = presetStore {
                presets = try store.loadAll()
            } else {
                presets = DefaultPresets.factory()
            }

            if presets.isEmpty {
                presets = DefaultPresets.factory()
            }

            if let first = presets.first {
                selectedPresetID = selectedPresetID ?? first.id
                editablePreset = presets.first(where: { $0.id == selectedPresetID }) ?? first
            }
        } catch {
            setError(error)
            presets = DefaultPresets.factory()
            editablePreset = presets[0]
            selectedPresetID = presets[0].id
        }
    }

    private func applyEditablePreset() {
        do {
            try pipelineService.configure(with: editablePreset)
            if let idx = presets.firstIndex(where: { $0.id == editablePreset.id }) {
                presets[idx] = editablePreset
            }
        } catch {
            setError(error)
        }
    }

    private func nextCustomPresetName() -> String {
        let prefix = "Custom"
        let usedIndexes = Set(
            presets.compactMap { preset -> Int? in
                let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name == prefix || name.hasPrefix(prefix + " ") else {
                    return nil
                }
                if name == prefix {
                    return 1
                }
                let suffix = name.replacingOccurrences(of: prefix + " ", with: "")
                return Int(suffix)
            }
        )

        var candidate = 1
        while usedIndexes.contains(candidate) {
            candidate += 1
        }
        return "\(prefix) \(candidate)"
    }

    private func sanitizedPresetName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Preset" : trimmed
    }

    private func setError(_ error: Error) {
        lastError = error.localizedDescription
        Task {
            await diagnosticsStore.log(.error, error.localizedDescription)
        }
    }

    private func startCaptureWithFallback(outputDeviceID: AudioDeviceID) throws {
        guard exclusiveModeRequested else {
            try startCapture(mode: .passthrough, outputDeviceID: outputDeviceID)
            return
        }

        do {
            try startCapture(mode: .exclusiveMutedWhenTapped, outputDeviceID: outputDeviceID)
            return
        } catch {
            let store = diagnosticsStore
            Task {
                await store.log(
                    .warning,
                    "Exclusive startup (mutedWhenTapped) failed (\(error.localizedDescription)); retrying forced mute."
                )
            }
        }

        do {
            try startCapture(mode: .exclusiveMuted, outputDeviceID: outputDeviceID)
            let store = diagnosticsStore
            Task {
                await store.log(
                    .warning,
                    "Exclusive startup succeeded using forced mute strategy."
                )
            }
        } catch {
            let store = diagnosticsStore
            Task {
                await store.log(
                    .warning,
                    "Exclusive startup (forced mute) failed (\(error.localizedDescription)); falling back to passthrough."
                )
            }

            try fallbackToPassthrough(
                outputDeviceID: outputDeviceID,
                userMessage: "Exclusive mode unavailable on this route. Using blended mode.",
                logMessage: "Exclusive mode startup failed in all strategies; switched to passthrough mode."
            )
        }
    }

    private func configureExclusiveSignalTracking(for mode: CaptureMuteMode) {
        guard mode.isExclusive else {
            exclusiveActivatedAt = nil
            lastExclusiveNonSilentAt = nil
            return
        }

        exclusiveActivatedAt = Date()
        lastExclusiveNonSilentAt = pipelineStats.lastInputRMS > exclusiveSignalThreshold ? Date() : nil
    }

    private func evaluateExclusiveSignalHealth(stats: PipelineRuntimeStats) {
        guard isEnabled, activeMuteMode.isExclusive else {
            return
        }

        let hasNonSilentSignal = stats.lastInputRMS > exclusiveSignalThreshold
        if hasNonSilentSignal {
            lastExclusiveNonSilentAt = Date()
        }

        guard !isExclusiveRecoveryInProgress,
              let activatedAt = exclusiveActivatedAt else {
            return
        }

        let now = Date()
        let startupWindowElapsed = now.timeIntervalSince(activatedAt) >= exclusiveSilenceTimeout
        let staleSince = lastExclusiveNonSilentAt ?? activatedAt
        let signalStale = now.timeIntervalSince(staleSince) >= exclusiveSilenceTimeout
        guard startupWindowElapsed, signalStale else {
            return
        }

        guard let outputDeviceID = selectedOutputDeviceID ?? outputDevices.first?.id else {
            return
        }

        isExclusiveRecoveryInProgress = true
        defer { isExclusiveRecoveryInProgress = false }
        do {
            switch activeMuteMode {
            case .exclusiveMutedWhenTapped:
                do {
                    captureService.stop()
                    try startCapture(mode: .exclusiveMuted, outputDeviceID: outputDeviceID)
                    let store = diagnosticsStore
                    Task {
                        await store.log(
                            .warning,
                            "Exclusive mode (mutedWhenTapped) had no incoming signal for >3s; retrying in forced mute mode."
                        )
                    }
                } catch {
                    try fallbackToPassthrough(
                        outputDeviceID: outputDeviceID,
                        userMessage: "Exclusive mode produced silence on this route. Fell back to blended mode.",
                        logMessage: "Exclusive retry in forced mute mode failed (\(error.localizedDescription)); switched to passthrough mode."
                    )
                }
            case .exclusiveMuted:
                try fallbackToPassthrough(
                    outputDeviceID: outputDeviceID,
                    userMessage: "Exclusive mode produced silence on this route. Fell back to blended mode.",
                    logMessage: "Exclusive mode (forced mute) had no incoming signal for >3s; switched to passthrough mode."
                )
            case .passthrough:
                return
            }
        } catch {
            setError(error)
            stopSystemEQ()
        }
    }

    private func startCapture(mode: CaptureMuteMode, outputDeviceID: AudioDeviceID) throws {
        captureService.setMuteMode(mode)
        try captureService.start(systemCaptureTo: outputDeviceID)
        activeMuteMode = mode
        configureExclusiveSignalTracking(for: mode)
    }

    private func fallbackToPassthrough(
        outputDeviceID: AudioDeviceID,
        userMessage: String,
        logMessage: String
    ) throws {
        captureService.stop()
        try startCapture(mode: .passthrough, outputDeviceID: outputDeviceID)
        exclusiveModeRequested = false
        lastError = userMessage
        let store = diagnosticsStore
        Task {
            await store.log(.warning, logMessage)
        }
    }

    private func startPollingDiagnostics() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                let health = pipelineService.currentHealthSnapshot()
                let stats = pipelineService.runtimeStats()
                let logs = await diagnosticsStore.recentLogs(limit: 200)
                await MainActor.run {
                    healthSnapshot = health
                    pipelineStats = stats
                    recentLogs = logs
                    evaluateExclusiveSignalHealth(stats: stats)
                    updateVisualizerSamples(stats: stats)
                    logPipelineStatsIfNeeded(stats: stats)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func updateVisualizerSamples(stats: PipelineRuntimeStats) {
        let rms = max(stats.lastInputRMS, stats.lastOutputRMS)
        let level: Float
        if visualizerEnabled {
            level = visualizerLevel(for: rms)
        } else {
            let tail = visualizerSamples.last ?? 0
            level = max(0, tail - 0.04)
        }

        visualizerSamples.append(level)
        if visualizerSamples.count > visualizerSampleCount {
            visualizerSamples.removeFirst(visualizerSamples.count - visualizerSampleCount)
        }
    }

    private func visualizerLevel(for rms: Float) -> Float {
        let safe = max(0.000_001, rms)
        let db = 20 * log10f(safe)
        let normalized = (db + 60) / 60
        return max(0, min(1, normalized))
    }

    private func logPipelineStatsIfNeeded(stats: PipelineRuntimeStats) {
        guard isEnabled else {
            return
        }

        let now = Date()
        if let last = lastPipelineStatsLogAt,
           now.timeIntervalSince(last) < 3 {
            return
        }
        lastPipelineStatsLogAt = now

        let inRMS = stats.lastInputRMS
        let outRMS = stats.lastOutputRMS
        let message = String(
            format: "Pipeline stats: inBlocks=%d unsupported=%d inRMS=%.5f renderBlocks=%d renderFrames=%d outRMS=%.5f ringFrames=%d mode=%@",
            stats.ingestedBlocks,
            stats.unsupportedBlocks,
            inRMS,
            stats.renderedBlocks,
            stats.renderedFrames,
            outRMS,
            stats.ringBufferFrames,
            activeMuteMode.rawValue
        )
        let store = diagnosticsStore
        Task {
            await store.log(.debug, message)
        }

        if !didLogSilentCaptureWarning,
           stats.ingestedBlocks > 50,
           inRMS < 0.00005 {
            didLogSilentCaptureWarning = true
            Task {
                await store.log(
                    .warning,
                    "Capture appears silent: ingested blocks are arriving but input RMS remains near zero."
                )
            }
            surfacePotentialPermissionOrRoutingIssueIfNeeded(stats: stats)
        } else if inRMS >= 0.00005 {
            didLogSilentCaptureWarning = false
            didSurfacePermissionHint = false
        }

        if !didLogSilentRenderWarning,
           stats.renderedBlocks > 50,
           inRMS >= 0.0002,
           outRMS < 0.00005 {
            didLogSilentRenderWarning = true
            Task {
                await store.log(
                    .warning,
                    "Render appears silent despite non-silent input RMS."
                )
            }
        } else if outRMS >= 0.00005 {
            didLogSilentRenderWarning = false
        }
    }

    private func surfacePotentialPermissionOrRoutingIssueIfNeeded(stats: PipelineRuntimeStats) {
        guard !didSurfacePermissionHint,
              stats.ingestedBlocks > 200 else {
            return
        }

        didSurfacePermissionHint = true
        lastError = "System audio capture appears silent. In macOS Settings > Privacy & Security > Screen & System Audio Recording, enable access for MacSystemEQ, then restart the app."
        let store = diagnosticsStore
        Task {
            await store.log(
                .warning,
                "Likely missing System Audio Recording permission or blocked route: stream callbacks are active but captured RMS stayed at 0."
            )
        }
    }
}
