#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-midi-takes.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
for fixture in GainFixture AttackFixture; do
  plugin="$build_dir/$fixture.vst3"
  mkdir -p "$plugin/Contents/MacOS"
  cat > "$plugin/Contents/Info.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.catlive.test.$fixture</string><key>CFBundleExecutable</key><string>$fixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
  fixture_flags=(-DCATLIVE_TEST_FIXTURE)
  if [[ "$fixture" == AttackFixture ]]; then fixture_flags+=(-DCATLIVE_NOTE_ATTACK_COUNTER); fi
  clang++ -std=c++17 -fPIC -bundle "${fixture_flags[@]}" -ICore/ThirdParty/VST3 \
    Tests/Apple/VST3/GainFixture.cpp Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp \
    Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation \
    -o "$plugin/Contents/MacOS/$fixture"
done
JARAS_TEST_VST3="$build_dir/GainFixture.vst3" JARAS_TEST_MIDI_ATTACK_VST3="$build_dir/AttackFixture.vst3" \
  JARAS_AUDIO_TEST_SOURCE=Tests/Apple/MIDITakeInstrumentTests.swift bash scripts/test-audio.sh
JARAS_TEST_VST3="$build_dir/GainFixture.vst3" CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/MIDITakeExportTests.swift \
  bash scripts/test-offline-export.sh
