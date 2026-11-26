#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
update_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-windows-update.XXXXXX")"
trap 'rm -rf "$update_test_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
    Tests/Core/WindowsDesktopUpdateTests.cpp -o "$update_test_dir/test"
"$update_test_dir/test"
if [[ -n "${CATLIVE_JUCE_SOURCE:-}" ]]; then
    if [[ "$(uname -s)" != Darwin ]]; then
        echo "The optional JUCE JSON fixture currently uses the macOS JUCE core build." >&2
        exit 2
    fi
    "${CXX:-clang++}" -x objective-c++ -std=c++17 -O0 -DDEBUG=1 \
        -DJUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 -DJUCE_STANDALONE_APPLICATION=1 \
        '-DJUCE_APPLICATION_VERSION_STRING="1.35.0"' -I "$CATLIVE_JUCE_SOURCE/modules" \
        Tests/Core/WindowsDesktopUpdateJSONTests.cpp \
        "$CATLIVE_JUCE_SOURCE/modules/juce_core/juce_core.mm" \
        "$CATLIVE_JUCE_SOURCE/modules/juce_core/juce_core_CompilationTime.cpp" \
        -framework Cocoa -framework IOKit -framework Security -o "$update_test_dir/json-test"
    "$update_test_dir/json-test"
fi
