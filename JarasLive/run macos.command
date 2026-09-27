#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild -project 'Jaras Live.xcodeproj' -scheme 'Jaras Live macOS' \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/xcode -allowProvisioningUpdates build
SOURCE='build/xcode/Build/Products/Release/Jaras Live.app'
codesign --verify --deep --strict "$SOURCE"
# Encerramento normal para liberar o bundle antes da cópia.
python3 - "$HOME/Applications/Jaras Live.app/Contents/MacOS/Jaras Live" <<'PY'
import os,signal,subprocess,sys,time
for row in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
    fields=row.strip().split(None,1)
    if len(fields)==2 and fields[1]==sys.argv[1]: os.kill(int(fields[0]),signal.SIGTERM)
time.sleep(0.5)
PY
mkdir -p "$HOME/Applications"
ditto "$SOURCE" "$HOME/Applications/Jaras Live.app"
open "$HOME/Applications/Jaras Live.app"
