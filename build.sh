#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release "$@"
bin_dir="$(swift build -c release "$@" --show-bin-path)"
staging=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Stillframe.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_dir/Stillframe" "$contents/MacOS/"
cp LICENSE Sources/Stillframe/Resources/Welcome.jpg "$contents/Resources/"
cp Packaging/Info.plist "$contents/Info.plist"

# Give changed artwork a new resource name in the system icon cache.
icon="Stillframe-$(shasum -a 256 Packaging/Stillframe.icns | cut -c1-12).icns"
cp Packaging/Stillframe.icns "$contents/Resources/$icon"
plutil -replace CFBundleIconFile -string "$icon" "$contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
swift Packaging/InstallBuild.swift "$app" "$PWD/Stillframe.app"
