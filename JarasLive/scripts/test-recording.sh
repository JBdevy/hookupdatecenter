#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-recording.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
for source in Core/ThirdParty/Lame/*.c; do
 clang -O2 -DHAVE_CONFIG_H -ICore/ThirdParty/Lame -c "$source" -o "$build_dir/$(basename "$source" .c).o"
done
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasRecording.mm -o "$build_dir/recording.o"
python3 - "$build_dir/Writer.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackRecording.swift').read_text()
source = source[:source.index('@MainActor final class TrackRecording')]
source = source.replace('private struct', 'struct').replace('private final class CaptureWriter','final class CaptureWriter')
Path(sys.argv[1]).write_text(source)
PY
cp Tests/Apple/RecordingTests.swift "$build_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasRecording.h Application/Project/{ProjectModels,MIDIItem,ProjectDocumentCodec,ProjectDocumentAppearance,MultiLoop,AudioFileRead,TimelineTempo,OutputPatch,TrackRouting,ClipRepetition,NativeFXSettings,RecordingOverview,StemProjectImporter,MediaFileNames,HookImportRules}.swift "$build_dir/Writer.swift" "$build_dir/main.swift" "$build_dir"/*.o -lc++ -o "$build_dir/test"
"$build_dir/test"
