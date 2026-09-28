#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ -n "${1:-}" && "$1" != "v$version" ]]; then
    printf 'Release tag %s does not match bundle version v%s\n' "$1" "$version" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    printf 'Commit or stash local changes before packaging a release.\n' >&2
    exit 1
fi
./scripts/build.sh release --universal
bundle="$PWD/dist/Limitter.app"
revision=$(git rev-parse HEAD)
/usr/libexec/PlistBuddy -c "Add :LimitterSourceRevision string $revision" "$bundle/Contents/Info.plist"
codesign --force --deep --sign - "$bundle"
lipo "$bundle/Contents/MacOS/Limitter" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$bundle"
archive="$PWD/dist/Limitter-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$archive"
verification_dir=$(mktemp -d)
trap 'rm -rf "$verification_dir"' EXIT
ditto -x -k "$archive" "$verification_dir"
codesign --verify --deep --strict "$verification_dir/Limitter.app"
lipo "$verification_dir/Limitter.app/Contents/MacOS/Limitter" -verify_arch arm64 x86_64
(
    cd dist
    shasum -a 256 Limitter-macOS-universal.zip > SHA256SUMS.txt
)
printf 'Packaged Limitter %s from %s: %s\n' "$version" "$revision" "$archive"
