#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Releases a new version of Humidor on GitHub: sets the version, commits and
# tags it, builds the application and publishes it with the changes since the
# previous release.
#
# Usage: Scripts/release.sh <version>, e.g. Scripts/release.sh 1.1.0
#
# Requires a clean working tree on the main branch, and the GitHub CLI (gh).

set -eu

version="${1:-}"
package_path="$(cd "$(dirname "$0")/.." && pwd)"
application_file="$package_path/Sources/HumidorCore/Application.swift"

if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Usage: $0 <version>, e.g. $0 1.1.0" >&2
    exit 1
fi

cd "$package_path"

if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree has uncommitted changes" >&2
    exit 1
fi

if [ "$(git branch --show-current)" != "main" ]; then
    echo "Releases are made from the main branch" >&2
    exit 1
fi

if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    echo "Version $version was already released" >&2
    exit 1
fi

previous_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"

# Version
sed -i '' "s/static let version = \"[^\"]*\"/static let version = \"$version\"/" "$application_file"
git commit -q -m "Release $version" -- "$application_file"
git tag "v$version"

# Application, built outside the project folder: iCloud Drive adds extended
# attributes to files, which make the signature invalid
build_folder="$(mktemp -d)"
Scripts/build-app.sh release "$build_folder"
ditto -c -k --keepParent "$build_folder/Humidor.app" "$build_folder/Humidor.zip"

# Release notes: the changes since the previous release, and how to install
notes="$build_folder/notes.md"
{
    echo "## Changes"
    echo
    if [ -n "$previous_tag" ]; then
        git log --no-merges --format='- %s' "$previous_tag..v$version~1"
    fi
    echo
    echo "## Installation"
    echo
    echo "Requires macOS 15 or later on a Mac with Apple silicon. Unzip \`Humidor.zip\` and move \`Humidor.app\` to the Applications folder."
    echo
    echo "The application is not notarized yet. Control-click it in Finder, choose Open and confirm, or run:"
    echo
    echo '```sh'
    echo 'xattr -dr com.apple.quarantine /Applications/Humidor.app'
    echo '```'
} > "$notes"

git push -q origin main "v$version"
gh release create "v$version" "$build_folder/Humidor.zip" --title "Humidor $version" --notes-file "$notes"

rm -rf "$build_folder"
echo "Released Humidor $version"
