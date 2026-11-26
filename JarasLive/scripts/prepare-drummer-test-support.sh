#!/bin/bash
set -euo pipefail
build_dir="$1"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasDrummerPad.mm -o "$build_dir/drummer-pad.o"
# These two helpers live beside their UI, but the engine uses them without a window.
{
    echo 'import AVFoundation'
    sed -n '/^enum PadAudioBuffer {/,/^}/p' Apple/Shared/VinhetasPanel.swift
    sed -n '/^@MainActor enum DrummerMIDILearn {/,/^}/p' Apple/Shared/DrummerPadEditor.swift
} > "$build_dir/DrummerPadSupport.swift"
