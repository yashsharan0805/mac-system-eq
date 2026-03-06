# App Store Readiness Checklist (macOS)

Last updated: 2026-03-06

Scope: publish `MacSystemEQ` to the Mac App Store.

Status legend:
- `DONE`: implemented in repo or already complete
- `TODO`: required and not complete yet
- `VERIFY`: needs validation/testing before submission
- `MANUAL`: done in App Store Connect / Apple Developer portal

## 1) Account + App Store Connect
| Item | Status | Evidence / Action |
|---|---|---|
| Apple Developer Program active | MANUAL | Confirm membership + team role with submission permissions. |
| App record created in App Store Connect | MANUAL | Bundle ID must be `com.yashsharan.macsystemeq`. |
| Agreements, tax, banking completed | MANUAL | Required for distribution and paid apps. |
| App category, age rating, availability, pricing configured | MANUAL | Complete in App Store Connect before submission. |

## 2) Technical Compliance
| Item | Status | Evidence / Action |
|---|---|---|
| App Sandbox enabled | TODO | `apps/MacSystemEQApp/Config/MacSystemEQ.entitlements` currently has `com.apple.security.app-sandbox = false`. |
| System-audio capture works with sandbox enabled | VERIFY | High-risk item for this app architecture; validate on clean macOS test machine. |
| Build uses currently accepted Xcode/SDK | VERIFY | Check Apple “Upcoming Requirements” before archive/upload. |
| App Store signing (Apple Distribution + profile) | MANUAL | Configure signing for App Store distribution path. |

## 3) Privacy + Permissions
| Item | Status | Evidence / Action |
|---|---|---|
| System Audio Recording usage string present | DONE | `NSAudioCaptureUsageDescription` exists in `apps/MacSystemEQApp/Config/Info.plist`. |
| Microphone usage prompt not requested by app | DONE | No `NSMicrophoneUsageDescription`; mic auth API path removed. |
| App Privacy questionnaire completed | MANUAL | Fill App Privacy in App Store Connect. |
| Privacy Policy URL added | MANUAL | Required in App Store Connect. |
| Export compliance answered | MANUAL | Complete encryption/export section in App Store Connect. |

## 4) Store Listing Metadata
| Item | Status | Evidence / Action |
|---|---|---|
| Name, subtitle, description, keywords | MANUAL | Complete in App Store Connect. |
| Support URL | MANUAL | Required field in App Store Connect. |
| macOS screenshots uploaded (spec-compliant) | MANUAL | Provide required screenshot set for macOS display sizes. |
| “What’s New” text for this version | MANUAL | Add before submit. |

## 5) Review Package
| Item | Status | Evidence / Action |
|---|---|---|
| Reviewer notes for System Audio Recording permission | TODO | Explain why capture is required for system-wide EQ behavior. |
| Repro steps for reviewer | TODO | Add concise steps: grant permission, enable EQ, switch presets, verify effect. |
| Test account details (if login ever added) | MANUAL | Not needed currently unless auth is introduced. |

## 6) Pre-submit Validation
| Item | Status | Evidence / Action |
|---|---|---|
| Clean install test on fresh macOS user | TODO | Validate first-run permission flow and recovery paths. |
| Regression tests pass (unit + integration) | VERIFY | Run full test suite before final archive. |
| Crash/log export behavior validated | VERIFY | Confirm diagnostics remain functional in release build. |

## Immediate Next Steps
1. Enable App Sandbox and test whether current Core Audio tap approach still functions.
2. If sandbox breaks system-wide capture, decide on App Store path vs direct-download-only strategy.
3. Prepare App Store Connect metadata (privacy policy URL, support URL, screenshots, what’s new).
4. Run a final submission dry run with an App Store-signed archive.
