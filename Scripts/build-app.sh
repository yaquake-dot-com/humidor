#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Nicotine+.app from the NicotinePlus executable.
#
# Usage: Scripts/build-app.sh [debug|release] [output folder]
#
# The build folder defaults to /tmp/nicotine-swift-build (building inside an
# iCloud-synced folder breaks code signing); set BUILD_PATH to change it.

set -eu

configuration="${1:-release}"
package_path="$(cd "$(dirname "$0")/.." && pwd)"
output_path="${2:-$package_path/dist}"
build_path="${BUILD_PATH:-/tmp/nicotine-swift-build}"

version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$package_path/Sources/NicotineCore/Application.swift")"
app_path="$output_path/Nicotine+.app"

swift build --package-path "$package_path" --scratch-path "$build_path" \
    --configuration "$configuration" --product NicotinePlus

bin_path="$(swift build --package-path "$package_path" --scratch-path "$build_path" \
    --configuration "$configuration" --show-bin-path)"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

cp "$bin_path/NicotinePlus" "$app_path/Contents/MacOS/Nicotine+"
cp -R "$bin_path/NicotinePlus_NicotineCore.bundle" "$app_path/Contents/Resources/"
cp "$package_path/Packaging/AppIcon.icns" "$app_path/Contents/Resources/"
sed "s/@VERSION@/$version/g" "$package_path/Packaging/Info.plist" > "$app_path/Contents/Info.plist"
printf "APPL????" > "$app_path/Contents/PkgInfo"

# Ad-hoc signature, required to run on Apple silicon
codesign --force --sign - --timestamp=none "$app_path"

echo "Built $app_path"
