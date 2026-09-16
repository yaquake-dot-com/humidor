#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Humidor.app from the Humidor executable.
#
# Usage: Scripts/build-app.sh [debug|release] [output folder]
#
# The build folder defaults to /tmp/humidor-build (building inside an
# iCloud-synced folder breaks code signing); set BUILD_PATH to change it.

set -eu

configuration="${1:-release}"
package_path="$(cd "$(dirname "$0")/.." && pwd)"
output_path="${2:-$package_path/dist}"
build_path="${BUILD_PATH:-/tmp/humidor-build}"

version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$package_path/Sources/HumidorCore/Application.swift")"
app_path="$output_path/Humidor.app"

swift build --package-path "$package_path" --scratch-path "$build_path" \
    --configuration "$configuration" --product Humidor

bin_path="$(swift build --package-path "$package_path" --scratch-path "$build_path" \
    --configuration "$configuration" --show-bin-path)"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

cp "$bin_path/Humidor" "$app_path/Contents/MacOS/Humidor"

# SwiftPM links without reading the SDK version, which records the deployment
# target as the SDK version. macOS then shows the legacy appearance instead of
# the current design, so record the SDK the executable was built with.
executable="$app_path/Contents/MacOS/Humidor"
deployment_target="$(otool -l "$executable" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
vtool -set-build-version macos "$deployment_target" "$(xcrun --show-sdk-version)" -replace \
    -output "$executable.tmp" "$executable" 2>/dev/null
mv "$executable.tmp" "$executable"
cp -R "$bin_path/Humidor_HumidorCore.bundle" "$app_path/Contents/Resources/"
# Translations of the application target are looked up in the main bundle
cp -R "$bin_path/Humidor_Humidor.bundle/Contents/Resources/"*.lproj "$app_path/Contents/Resources/"
cp "$package_path/Packaging/AppIcon.icns" "$app_path/Contents/Resources/"
sed "s/@VERSION@/$version/g" "$package_path/Packaging/Info.plist" > "$app_path/Contents/Info.plist"
printf "APPL????" > "$app_path/Contents/PkgInfo"

# Ad-hoc signature, required to run on Apple silicon
codesign --force --sign - --timestamp=none "$app_path"

echo "Built $app_path"
