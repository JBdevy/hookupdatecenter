#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-clip-editor.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
plugin="$build_dir/GainFixture.vst3"
mkdir -p "$plugin/Contents/MacOS"
cat > "$plugin/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.jaras.test.gain</string><key>CFBundleExecutable</key><string>GainFixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
clang++ -std=c++17 -fPIC -bundle -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation -o "$plugin/Contents/MacOS/GainFixture"
bash scripts/compile-vst3.sh "$build_dir"
python3 - "$build_dir/Editor.swift" <<'PY'
import pathlib,sys
source=pathlib.Path('Apple/Shared/ExternalPluginEditor.swift').read_text()
pathlib.Path(sys.argv[1]).write_text(source[:source.index('\n#endif\n\n#if os(macOS)')]+'\n#endif\n')
PY
swiftc -swift-version 5 -parse-as-library -import-objc-header Apple/Bridge/JarasVST3.h Application/Project/NativeFXSettings.swift Tests/Apple/VST3/ClipEditorStateStubs.swift "$build_dir/Editor.swift" Tests/Apple/VST3/ClipEditorStateTests.swift "$build_dir"/*.o -framework Accelerate -lc++ -o "$build_dir/test"
"$build_dir/test" "$plugin"
