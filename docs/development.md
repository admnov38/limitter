# Development

[Back to the README](../README.md)

## Build and checks

```sh
swift test -c release
./scripts/build.sh
python3 scripts/test-connector.py dist/Limitter.app/Contents/MacOS/Limitter
codesign --verify --deep --strict dist/Limitter.app
```

The GitHub Actions workflow runs these checks on macOS. UI checks require an
interactive desktop and are run separately.

## Live diagnostics

These commands inspect your own local history or signed-in provider account.
They are optional diagnostics, not prerequisites for running the test suite.

```sh
dist/Limitter.app/Contents/MacOS/Limitter --diagnose
dist/Limitter.app/Contents/MacOS/Limitter --diagnose-claude
dist/Limitter.app/Contents/MacOS/Limitter --diagnose-claude-account
dist/Limitter.app/Contents/MacOS/Limitter --diagnose-pricing
dist/Limitter.app/Contents/MacOS/Limitter --diagnose-grok
```

`--diagnose` prints only aggregate counts and connection status. `--diagnose-claude` reports status-line quota availability; `--diagnose-claude-account` queries live account and model limits without scanning history. `--diagnose-pricing` emits aggregate 30-day per-model token counters and USD estimates as JSON, with no message contents. Connector tests use temporary directories and leave your real Claude settings untouched. `--diagnose-grok` checks live billing and Grok’s local history. `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and `GROK_HOME` are honored when provided to the process. `LIMITTER_DATA_DIR` overrides connector storage for testing.

## UI checks and previews

`--verify-ui` checks native settings-window launch, close, and reopen behavior; live appearance changes; the actual status-button readout; icon fallback; provider filtering; independent Codex/Claude/Grok and Activity/API Value timeframes; today-only Overview totals; line and histogram buckets on Overview and Activity; API Value model ordering; the daily note; current-session selection; API estimates; and the history needed for the full-width activity grid. It uses sample data and does not save preferences. It does not simulate physical mouse movement or menu selection.

```sh
dist/Limitter.app/Contents/MacOS/Limitter --verify-ui
mkdir -p artifacts
dist/Limitter.app/Contents/MacOS/Limitter --render-preview "$PWD/artifacts/settings.png" --preview-settings
dist/Limitter.app/Contents/MacOS/Limitter --render-preview "$PWD/artifacts/settings-light.png" --preview-settings --preview-light --section=menu-bar
dist/Limitter.app/Contents/MacOS/Limitter --render-preview "$PWD/artifacts/month.png" --preview-activity --preview-month
dist/Limitter.app/Contents/MacOS/Limitter --render-preview "$PWD/artifacts/dashboard.png" --preview-mixed
dist/Limitter.app/Contents/MacOS/Limitter --render-preview "$PWD/artifacts/api-value.png" --preview-costs
```

The package opens directly in Xcode via `Package.swift`. Core parsing and connections live in `Sources/LimitterCore`; the app and interface live in `Sources/Limitter`.

## Repository layout

```text
Sources/Limitter/          SwiftUI and AppKit application
Sources/LimitterCore/      Provider connections, history, quotas, and pricing
Tests/LimitterCoreTests/   Parsing, accounting, and regression tests
Resources/Info.plist      Bundle metadata and release version
scripts/                  App packaging, icon generation, connector checks
docs/                     User and developer documentation
```

## Release checks

Run the tests, connector checks, and release build above. Verify the bundle with
`codesign --verify --deep --strict dist/Limitter.app`. On an interactive Mac, run
`--verify-ui` and inspect the rendered previews. Automated sample-data checks do
not establish live provider compatibility; check each provider you intend to
claim as tested using your own signed-in CLI. Do not publish account diagnostics
or screenshots containing personal usage.

The build script compiles for the host architecture and signs the bundle ad hoc.
It does not produce a universal, Developer ID-signed, or notarized release. Keep
build outputs, connector backups, and local diagnostic artifacts out of Git.

To regenerate the README screenshots using sample data:

```sh
dist/Limitter.app/Contents/MacOS/Limitter --render-preview "$PWD/docs/images/overview.png" --preview-mixed
dist/Limitter.app/Contents/MacOS/Limitter --render-preview "$PWD/docs/images/activity.png" --preview-activity
```
