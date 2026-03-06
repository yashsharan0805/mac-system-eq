# MacSystemEQ

System-wide macOS equalizer MVP for macOS 14.4+.

## Scope
- System-wide audio capture using Core Audio process taps.
- 10-band parametric equalizer pipeline.
- Presets, diagnostics, output device selection baseline.
- Menu bar app and settings UI.
- Direct download distribution path with notarization docs.

## Repository Layout
- `apps/MacSystemEQApp`: SwiftUI menu bar app.
- `packages/AudioCaptureKit`: Core Audio tap session, aggregate device lifecycle.
- `packages/AudioPipelineKit`: AVAudioEngine + EQ graph + buffering.
- `packages/PresetsKit`: preset model/store and import/export.
- `packages/DeviceKit`: output device listing/default resolution.
- `packages/DiagnosticsKit`: logging and runtime health snapshots.

## Requirements
- macOS 14.4+
- Xcode 16.3+
- Swift 6.1+

## Quick Start
```bash
swift build
swift test
./scripts/run-dev-app.sh
```

Run as an `.app` bundle for correct macOS TCC identity (System Audio Recording permission).

## Debug Run
```bash
./scripts/run-dev-debug.sh
```

Prints app diagnostics logs to terminal (`stderr`) while running the bundled app binary in foreground.

## Notes
- In development, if system-tap APIs are unavailable/blocked on target machine, the app reports diagnostics and remains recoverable.
- Distribution is direct download + notarization (see `docs/release/notarization.md`).
