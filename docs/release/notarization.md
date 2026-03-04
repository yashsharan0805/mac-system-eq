# Notarization and Distribution

## Target
Direct download (zip or DMG) with Developer ID signing and Apple notarization.

## Prerequisites
- Apple Developer Team with Developer ID certificates.
- `xcrun notarytool` credentials configured.
- Hardened runtime enabled for release app bundle.

## Steps
1. Archive and sign app bundle with Developer ID Application certificate.
2. Package artifact (`.zip` or `.dmg`).
3. Submit to notarization:
   ```bash
   xcrun notarytool submit <artifact> --keychain-profile <profile> --wait
   ```
4. Staple ticket:
   ```bash
   xcrun stapler staple <path-to-app-or-dmg>
   ```
5. Verify gatekeeper acceptance:
   ```bash
   spctl --assess --verbose=4 <path-to-app>
   ```

## Hardened Runtime Notes
- Keep only required exceptions.
- Re-validate entitlement set before every release.
