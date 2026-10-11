#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-reaper-vst3.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
plugin="$build_dir/GainFixture.vst3"
mkdir -p "$plugin/Contents/MacOS"
cat > "$plugin/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.jaras.test.gain</string><key>CFBundleExecutable</key><string>GainFixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
clang++ -std=c++17 -fPIC -bundle -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation -o "$plugin/Contents/MacOS/GainFixture"
bash scripts/compile-vst3.sh "$build_dir"
python3 - "$build_dir/main.swift" <<'PY'
import pathlib,sys
catalog=pathlib.Path('Apple/Shared/PluginCatalog.swift').read_text()
model=pathlib.Path('Application/Project/NativeFXSettings.swift').read_text()
importer=pathlib.Path('Application/Project/ReaperProjectImporter.swift').read_text()
parts=['import Foundation\n', 'enum ProjectError: Error { case invalid(String) }\n']
parts.append(model[model.index('public struct ExternalPlugin:'):model.index('public struct NativeFXInstance:')])
parts.append(catalog[catalog.index('struct RecognizedPlugin:'):catalog.index('@MainActor final class PluginCatalog:')])
parts.append('enum ReaperProjectImporter {\n'+importer[importer.index('    public struct VST3Request:'):importer.index('    private struct ImportedFX {')]+'}\n')
parts.append(catalog[catalog.index('final class ReaperVST3ImportSession:'):catalog.index('struct ExternalPluginBrowser:')])
parts.append(pathlib.Path('Tests/Apple/VST3/ImportInspectionTests.swift').read_text())
pathlib.Path(sys.argv[1]).write_text('\n'.join(parts))
PY
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasVST3.h "$build_dir/main.swift" "$build_dir"/*.o -framework Accelerate -lc++ -o "$build_dir/test"
"$build_dir/test" "$plugin"
