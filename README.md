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

## Permissions
- `System Audio Recording` is required because MacSystemEQ captures system output audio (apps like Spotify/YouTube) through Core Audio taps, processes it with EQ, and routes the processed signal to your output device.
- This is not microphone capture. The app does not request `Microphone` permission for normal system-wide EQ operation.

## Debug Run
```bash
./scripts/run-dev-debug.sh
```

Prints app diagnostics logs to terminal (`stderr`) while running the bundled app binary in foreground.

## App Icon
Generate/update the macOS icon assets (`.iconset` + `.icns`):
```bash
./scripts/generate-app-icon.sh
```

This produces:
- `apps/MacSystemEQApp/Assets/AppIcon.iconset`
- `apps/MacSystemEQApp/Config/AppIcon.icns`

## GitHub DMG Release
- Tag-based release: push a tag like `v0.2.0` to trigger `.github/workflows/release-dmg.yml`.
- Manual release: run **Release DMG** workflow from GitHub Actions (`workflow_dispatch`).
- Assets uploaded to the GitHub Release:
  - `MacSystemEQ-<version>.dmg`
  - `MacSystemEQ-<version>.dmg.sha256`

Example:
```bash
git tag v0.2.0
git push origin v0.2.0
```

For signed/notarized DMGs, configure secrets listed in `docs/release/notarization.md`.

## App Store Prep
- Readiness checklist: `docs/release/app-store-readiness.md`
- Reviewer notes template: `docs/release/app-store-review-notes.md`

## Notes
- In development, if system-tap APIs are unavailable/blocked on target machine, the app reports diagnostics and remains recoverable.
- Distribution is direct download + notarization (see `docs/release/notarization.md`).
- App Store publish readiness checklist: `docs/release/app-store-readiness.md`.
