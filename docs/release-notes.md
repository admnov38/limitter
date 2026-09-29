Download **Limitter-macOS-universal.zip**, unzip it, and move **Limitter.app** to **Applications**. Requires macOS 14 or later on Apple Silicon or Intel. Quit any older copy before opening the update.

Newly used models now trigger an automatic pricing refresh even when the daily cache is still fresh. Missing prices and failed sources retry every 15 minutes, with a one-minute minimum between automatic requests. Published prices are applied to existing history without an app update. This resolves Claude Sonnet 5.5 remaining unpriced until the old daily cache expired.

Previously downloaded rates survive incomplete source responses. Dashboard refresh also refreshes prices, provider-prefixed model IDs are recognized, and linked model names in Anthropic’s pricing table are supported. Models with no published matching price remain explicitly unpriced.

The app is ad-hoc signed and is **not Developer ID-signed or notarized**. macOS may block the first launch. If you trust this download, open System Settings → Privacy & Security → Open Anyway after attempting to launch it.

`SHA256SUMS.txt` contains the archive checksum. Check it in the download directory with `shasum -a 256 -c SHA256SUMS.txt`. The app bundle records its source commit in `LimitterSourceRevision` in `Contents/Info.plist`.

See [Apple’s instructions for opening an unnotarized app](https://support.apple.com/102445).
