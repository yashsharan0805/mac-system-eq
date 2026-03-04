# ADR-001: System Audio Strategy

## Status
Accepted

## Date
2026-03-04

## Context
The product requires system-wide EQ on macOS. Capturing only app-local playback is out of scope for MVP.

## Decision
Use Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`) and a private aggregate device created at runtime. Feed tap audio into an AVAudioEngine-based EQ pipeline and play processed output through the selected output device.

## Rationale
- Uses Apple-supported modern APIs on macOS 14.4+.
- Avoids mandatory installation of a third-party virtual audio driver for MVP.
- Keeps architecture compatible with a phase-2 fallback (virtual device path) if hardware/API edge cases block specific machines.

## Consequences
- Requires tighter runtime diagnostics and fallback handling.
- macOS version floor is 14.4+.
- Packaging focuses on direct download + notarization rather than App Store constraints.
