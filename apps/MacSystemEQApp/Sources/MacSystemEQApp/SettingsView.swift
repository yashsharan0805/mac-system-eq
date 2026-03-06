import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MacSystemEQ Settings")
                .font(.title2)

            GroupBox("Playback") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))

                    Toggle("Exclusive mode (mute original audio)", isOn: Binding(
                        get: { model.exclusiveModeRequested },
                        set: { model.setExclusiveMode($0) }
                    ))

                    Text("Active output mode: \(activeModeDescription)")
                        .font(.caption)
                        .foregroundStyle(activeModeColor)

                    if !model.exclusiveModeRequested, model.activeMuteMode == .passthrough {
                        Text("Tip: blended mode is safer; use exclusive mode only when signal is stable on your route.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Preamp")
                        Slider(
                            value: Binding(
                                get: { Double(model.editablePreset.preampDB) },
                                set: { model.setPreamp(Float($0)) }
                            ),
                            in: -12 ... 12,
                            step: 0.5
                        )
                        Text(String(format: "%+.1f dB", model.editablePreset.preampDB))
                            .monospacedDigit()
                            .frame(width: 75, alignment: .trailing)
                    }
                }
            }

            GroupBox("Presets") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Preset", selection: Binding(
                        get: { model.selectedPresetID ?? model.presets.first?.id ?? UUID() },
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

                    HStack(spacing: 8) {
                        TextField("Preset name", text: Binding(
                            get: { model.editablePreset.name },
                            set: { model.setPresetName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button("New") {
                            model.createCustomPreset()
                        }

                        Button("Delete") {
                            model.deleteSelectedPreset()
                        }
                        .disabled(model.selectedPresetID == nil || model.presets.count <= 1)

                        Button("Save") {
                            model.saveEditablePreset()
                        }
                    }

                    HStack {
                        Button("Import Preset") {
                            model.importPreset()
                        }
                        Button("Export Preset") {
                            model.exportPreset()
                        }
                    }
                }
            }

            GroupBox("10-Band EQ") {
                VStack(spacing: 8) {
                    ForEach(Array(model.editablePreset.bands.enumerated()), id: \.offset) { index, band in
                        HStack {
                            Text("\(Int(band.frequencyHz)) Hz")
                                .frame(width: 70, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(model.editablePreset.bands[index].gainDB) },
                                    set: { model.setBandGain(index: index, gainDB: Float($0)) }
                                ),
                                in: -24 ... 24,
                                step: 0.5
                            )
                            Text(String(format: "%+.1f dB", model.editablePreset.bands[index].gainDB))
                                .monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                }
            }

            GroupBox("Music Visualizer") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable visualizer", isOn: Binding(
                        get: { model.visualizerEnabled },
                        set: { model.visualizerEnabled = $0 }
                    ))

                    MusicVisualizerView(
                        samples: model.visualizerSamples,
                        isEnabled: model.visualizerEnabled
                    )
                    .frame(height: 110)

                    Text("Uses pipeline RMS levels for a lightweight live visualization.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latency: \(model.healthSnapshot.latencyMs, specifier: "%.2f") ms")
                    Text("Dropouts/min: \(model.healthSnapshot.dropoutsLastMinute)")
                    Text("CPU load (approx): \(model.healthSnapshot.cpuLoadPct, specifier: "%.1f")%")
                    Text("Input blocks seen: \(model.pipelineStats.ingestedBlocks)")
                    Text("Unsupported blocks: \(model.pipelineStats.unsupportedBlocks)")
                    Text("Last input RMS: \(model.pipelineStats.lastInputRMS, specifier: "%.4f")")
                    Text("Rendered blocks: \(model.pipelineStats.renderedBlocks)")
                    Text("Rendered frames: \(model.pipelineStats.renderedFrames)")
                    Text("Last output RMS: \(model.pipelineStats.lastOutputRMS, specifier: "%.4f")")
                    Text("Ring buffer frames: \(model.pipelineStats.ringBufferFrames)")

                    Button("Export Logs") {
                        model.exportLogs()
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.recentLogs.suffix(30)) { log in
                                Text("[\(log.level.rawValue.uppercased())] \(log.message)")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 160)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 720)
    }

    private var activeModeDescription: String {
        switch model.activeMuteMode {
        case .passthrough:
            return "Blended (dry + wet)"
        case .exclusiveMutedWhenTapped:
            return "Exclusive (wet-only, muted-when-tapped)"
        case .exclusiveMuted:
            return "Exclusive (wet-only, forced-muted)"
        }
    }

    private var activeModeColor: Color {
        model.activeMuteMode.isExclusive ? .green : .secondary
    }
}
