#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
build_args=(-c "$configuration")
if [[ "${2:-}" == "--universal" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
elif [[ -n "${2:-}" ]]; then
    printf 'Usage: %s [release|debug] [--universal]\n' "$0" >&2
    exit 1
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
bundle="$PWD/dist/Limitter.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/Limitter" "$bundle/Contents/MacOS/Limitter.next"
mv -f "$bundle/Contents/MacOS/Limitter.next" "$bundle/Contents/MacOS/Limitter"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
swift scripts/make-icon.swift "$bundle/Contents/Resources"
codesign --force --deep --sign - "$bundle"
printf 'Built %s\n' "$bundle"
