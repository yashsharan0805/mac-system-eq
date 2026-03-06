# App Store Review Notes Template (MacSystemEQ)

Use this text in App Store Connect -> App Review Information -> Notes.

## Why System Audio Recording Permission Is Requested
MacSystemEQ is a system-wide equalizer.  
To apply EQ to audio from other apps (for example music and browser playback), it must capture system output audio using Core Audio process taps and route the processed signal to the selected output device.

The app requests `System Audio Recording` permission for this purpose only.  
It does not require microphone permission for normal operation.

## How To Verify Core Functionality
1. Launch MacSystemEQ.
2. Grant `System Audio Recording` permission when prompted.
3. In the menu bar popover, enable `Enable System EQ`.
4. Start audio playback in another app (for example Safari or Music).
5. Switch presets between `Flat` and `Bass Boost`.
6. Confirm audible change in tonal balance while playback continues.

## Feature Notes
- App is a menu bar utility with a settings window.
- It includes output-device selection, preset management, per-app presets, and diagnostics logs export.
- If exclusive route is unavailable and strict single-path mode is enabled, EQ turns off instead of mixing dry+wet paths.
