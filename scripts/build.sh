#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/dist/Limitter.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/Limitter" "$bundle/Contents/MacOS/Limitter.next"
mv -f "$bundle/Contents/MacOS/Limitter.next" "$bundle/Contents/MacOS/Limitter"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
swift scripts/make-icon.swift "$bundle/Contents/Resources"
codesign --force --deep --sign - "$bundle"
printf 'Built %s\n' "$bundle"
