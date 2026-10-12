#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
    echo "Usage: scripts/build-app.sh [release|debug]" >&2
    exit 2
fi
build_args=(--configuration "$configuration" --scratch-path "${TR7_BUILD_PATH:-.build}")
if [[ -n "${TR7_CACHE_PATH:-}" ]]; then build_args+=(--cache-path "$TR7_CACHE_PATH"); fi
if [[ -n "${TR7_MODULE_CACHE:-}" ]]; then build_args+=(-Xswiftc -module-cache-path -Xswiftc "$TR7_MODULE_CACHE"); fi
if [[ "${TR7_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then build_args+=(--disable-sandbox); fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app="dist/TR7Mac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
cp "$binary_dir/TR7Mac" "$app/Contents/MacOS/TR7Mac"
cp "$binary_dir/tr7" dist/tr7
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp Packaging/TR7Mac.icns "$app/Contents/Resources/TR7Mac.icns"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Packaging/Info.plist)"
codesign --force --sign - -r="designated => identifier \"$bundle_id\"" "$app"
codesign --verify --strict "$app"
echo "Built $PWD/$app"
