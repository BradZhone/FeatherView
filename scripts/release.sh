#!/bin/bash
# Builds a universal (arm64 + x86_64) FeatherView.app, runs the tests, and writes
# dist/FeatherView-<version>-macos-universal.zip plus its SHA-256.
# The app is ad-hoc signed, not notarized: see README "Installation" for the Gatekeeper step.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=FeatherView
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP="dist/$NAME-$VERSION-macos-universal.zip"

make test
rm -rf build/$NAME.app
make ARCH="-arch arm64 -arch x86_64"
lipo -info "build/$NAME.app/Contents/MacOS/$NAME"
codesign --verify --deep "build/$NAME.app"

mkdir -p dist
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "build/$NAME.app" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "$ZIP"
cat "$ZIP.sha256"
