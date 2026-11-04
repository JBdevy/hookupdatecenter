#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIRECTORY="${1:-$PWD/build}"
VERSION="${VERSION:-1.00}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]{2}$ ]] || { echo 'Use uma versão X.XX.'; exit 1; }
mkdir -p "$BUILD_DIRECTORY"
BUILD_DIRECTORY="$(cd "$BUILD_DIRECTORY" && pwd)"
APP="$BUILD_DIRECTORY/Kontakt Add Libray.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in arm64 x86_64; do
    mkdir -p "$BUILD_DIRECTORY/$architecture"
    xcrun swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK" -target "$architecture-apple-macos12.0" \
        Sources/KontaktLibraryCore/*.swift Sources/KontaktAddLibray/*.swift -o "$BUILD_DIRECTORY/$architecture/KontaktAddLibray"
    xcrun swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK" -target "$architecture-apple-macos12.0" \
        Sources/KontaktLibraryCore/*.swift Sources/KontaktLibraryInstaller/*.swift -o "$BUILD_DIRECTORY/$architecture/KontaktLibraryInstaller"
done
for binary in KontaktAddLibray KontaktLibraryInstaller; do
    lipo -create "$BUILD_DIRECTORY/arm64/$binary" "$BUILD_DIRECTORY/x86_64/$binary" -output "$APP/Contents/MacOS/$binary"
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-100}" "$APP/Contents/Info.plist"
swift scripts/icon.swift "$BUILD_DIRECTORY/AppIcon.iconset"
iconutil -c icns "$BUILD_DIRECTORY/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/MacOS/KontaktLibraryInstaller"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
