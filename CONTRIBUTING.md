# Contributing to MacSystemEQ

Thanks for contributing.

## Development Setup
1. Install Xcode 16.3+ and Swift 6.1+.
2. Clone the repo.
3. Run:
   ```bash
   swift build
   swift test
   ```
4. Run the app bundle:
   ```bash
   ./scripts/run-dev-app.sh
   ```

## Branches and Commits
- Use focused branches and keep PRs small.
- Write clear commit messages in imperative mood.
- Do not mix refactors with behavior changes unless required.

## Code Quality
- Ensure `swift build` and `swift test` pass locally.
- Follow existing project style (`.swiftformat`, `.swiftlint.yml`).
- Keep diagnostics actionable and avoid noisy logs in normal mode.

## Pull Requests
- Explain what changed and why.
- Include manual test steps for audio-path changes.
- Add/update docs when behavior or setup changes.
- Link related issues.

## Scope Notes
- This project targets macOS system-wide EQ behavior.
- Permission and routing behavior must remain explicit and user-recoverable.
