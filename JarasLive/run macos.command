#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 scripts/prepare-catstem.py
xcodebuild -project 'CatLive.xcodeproj' -scheme 'CatLive macOS' \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/xcode -allowProvisioningUpdates build
python3 scripts/install-macos.py 'build/xcode/Build/Products/Release/CatLive.app'
