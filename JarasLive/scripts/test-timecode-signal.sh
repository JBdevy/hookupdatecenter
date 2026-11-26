#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-timecode-signal.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasTimecode.mm -o "$test_dir/timecode.o"
cp Tests/Apple/TimecodeSignalTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasTimecode.h "$test_dir/main.swift" "$test_dir/timecode.o" -lc++ -o "$test_dir/test"
# Hosted runners can start without the per-user CoreMIDI LaunchAgent loaded.
# Start Apple's service before exercising real endpoint traffic; do not skip the
# MIDI assertions when the runner has no physical MIDI equipment attached.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    midi_domain="gui/$(id -u)"
    if ! launchctl print "$midi_domain" >/dev/null 2>&1; then
        midi_domain="user/$(id -u)"
    fi
    if ! launchctl print "$midi_domain/com.apple.midiserver" >/dev/null 2>&1; then
        launchctl bootstrap "$midi_domain" /System/Library/LaunchAgents/com.apple.midiserver.plist
    fi
    launchctl kickstart "$midi_domain/com.apple.midiserver"
fi
"$test_dir/test"
