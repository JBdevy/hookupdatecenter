#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-click-audio.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasTimecode.mm -o "$test_dir/timecode.o"
cp Tests/Apple/ClickTrackAudioTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasTimecode.h \
 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift \
 Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift \
 Apple/Shared/ClickAudioSample.swift "$test_dir/main.swift" "$test_dir/timecode.o" -lc++ -o "$test_dir/test"
"$test_dir/test" "$PWD/Apple/Resources/Click.mp3"
