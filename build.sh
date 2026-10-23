#!/bin/zsh
# Builds "Live Photo Repair.app" into ./build using the Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary so the release runs on Apple silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64

APP="build/Live Photo Repair.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/LivePhotoRepair" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Finder metadata on copied files makes codesign fail.
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Built $APP"
