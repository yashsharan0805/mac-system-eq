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
    @Published var recentLogs: [LogEntry] = []
    @Published var launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()

    private let captureService: CoreAudioTapCaptureService
    private let pipelineService: AVAudioEQPipelineService
    private let deviceManager: CoreAudioDeviceManager
    private let diagnosticsStore: DiagnosticsStore
    private let featureFlags: FeatureFlags
    private let presetStore: JSONPresetStore?

    private var pollingTask: Task<Void, Never>?

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
            editablePreset = normalized

            if let idx = presets.firstIndex(where: { $0.id == normalized.id }) {
                presets[idx] = normalized
            } else {
                presets.append(normalized)
            }

            selectedPresetID = normalized.id
            try store.save(normalized)
        } catch {
            setError(error)
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
            presets.append(preset)
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

    private func startSystemEQ() async {
        guard authorizationStatus == .granted else {
            lastError = "Grant audio permission before starting system EQ."
            return
        }

        guard let outputDeviceID = selectedOutputDeviceID ?? outputDevices.first?.id else {
            lastError = "No output device available."
            return
        }

        do {
            try pipelineService.startIfNeeded(format: captureService.capturedFormat)
            try pipelineService.setOutputDevice(outputDeviceID)
            try pipelineService.configure(with: editablePreset)
            pipelineService.setEnabled(true)
            try captureService.start(systemCaptureTo: outputDeviceID)
            isEnabled = true
        } catch {
            setError(error)
            stopSystemEQ()
        }
    }

    private func stopSystemEQ() {
        captureService.stop()
        pipelineService.setEnabled(false)
        pipelineService.stop()
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

    private func setError(_ error: Error) {
        lastError = error.localizedDescription
        Task {
            await diagnosticsStore.log(.error, error.localizedDescription)
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
                let logs = await diagnosticsStore.recentLogs(limit: 200)
                await MainActor.run {
                    healthSnapshot = health
                    recentLogs = logs
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
