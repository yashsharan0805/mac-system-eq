import AppKit
import AudioPipelineKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacSystemEQ")
                .font(.headline)

            if model.authorizationStatus != .granted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio permission required for system capture.")
                        .font(.caption)
                    Button("Grant Permission") {
                        Task { await model.requestAuthorization() }
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { model.isEnabled },
                set: { _ in Task { await model.toggleEnabled() } }
            )) {
                Text("Enable System EQ")
            }

            Picker("Output Device", selection: Binding(
                get: { model.selectedOutputDeviceID ?? 0 },
                set: { model.selectOutputDevice($0) }
            )) {
                ForEach(model.outputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .disabled(model.outputDevices.isEmpty)

            Picker("Preset", selection: Binding(
                get: { model.selectedPresetID ?? UUID() },
                set: {
                    model.selectedPresetID = $0
                    model.applySelectedPreset()
                }
            )) {
                ForEach(model.presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .disabled(model.presets.isEmpty)

            Toggle("Music Visualizer", isOn: Binding(
                get: { model.visualizerEnabled },
                set: { model.visualizerEnabled = $0 }
            ))

            if model.visualizerEnabled {
                MusicVisualizerView(samples: model.visualizerSamples, isEnabled: model.visualizerEnabled)
                    .frame(height: 56)
            }

            Divider()

            HStack {
                Button("Settings...") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
