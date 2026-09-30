Download **Limitter-macOS-universal.zip**, unzip it, and move **Limitter.app** to **Applications**. Requires macOS 14 or later on Apple Silicon or Intel. Quit any older copy before opening the update.

Fixes missing Codex usage after updating the ChatGPT/Codex desktop app. Limitter now discovers the CLI in the new nested `codex-cli/CodexCLI.app` bundle even when launched from Finder with a minimal PATH. Legacy desktop bundles, the bundled CLI wrapper, and standalone CLI installations remain supported.

Adds `--diagnose-codex` to report the selected CLI, live quota windows, and Codex menu-bar readout without scanning local history. Regression tests cover system and user installations of both desktop apps, legacy and wrapper layouts, and an unusable nested CLI.

The app is ad-hoc signed and is **not Developer ID-signed or notarized**. macOS may block the first launch. If you trust this download, open System Settings → Privacy & Security → Open Anyway after attempting to launch it.

`SHA256SUMS.txt` contains the archive checksum. Check it in the download directory with `shasum -a 256 -c SHA256SUMS.txt`. The app bundle records its source commit in `LimitterSourceRevision` in `Contents/Info.plist`.

See [Apple’s instructions for opening an unnotarized app](https://support.apple.com/102445).
