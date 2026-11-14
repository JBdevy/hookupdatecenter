#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CATLIVE_JUCE_SOURCE:?Set CATLIVE_JUCE_SOURCE to the existing JUCE checkout}"
resize_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-divider-resize.XXXXXX")"
trap 'rm -rf "$resize_test_dir"' EXIT
python3 - "$resize_test_dir" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1]); source=Path('Windows/Source/DragDivider.h').read_text()
source=source[source.index('class DragDivider final'):source.index('class SongDisplayLabel final')]
source=source.replace('private Timer','public Timer').replace('  private:','  public:')
(out/'main.cpp').write_text('#include <juce_gui_basics/juce_gui_basics.h>\n#include <optional>\nnamespace catlive { using namespace juce; namespace theme { const auto green=Colours::green,secondary=Colours::grey; }\n'+source+'}\n'+Path('Tests/Core/WindowsDividerResizeTests.cpp').read_text())
(out/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.22)
project(CatLiveDividerResize LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
add_subdirectory("$ENV{CATLIVE_JUCE_SOURCE}" juce)
juce_add_console_app(DividerResize)
target_sources(DividerResize PRIVATE main.cpp)
target_compile_definitions(DividerResize PRIVATE JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0)
target_link_libraries(DividerResize PRIVATE juce::juce_gui_basics)
''')
PY
if command -v cmake >/dev/null 2>&1; then
    cmake -S "$resize_test_dir" -B "$resize_test_dir/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$resize_test_dir/build" --parallel 2
    "$resize_test_dir/build/DividerResize_artefacts/Release/DividerResize"
elif [[ "$(uname -s)" == Darwin ]]; then
    modules="$CATLIVE_JUCE_SOURCE/modules"
    options=(-DJUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 -DJUCE_STANDALONE_APPLICATION=1
        -DJUCE_WEB_BROWSER=0 -DJUCE_USE_CURL=0 -DNDEBUG=1 -I "$modules")
    clang "${options[@]}" -c "$modules/juce_graphics/juce_graphics_Sheenbidi.c" -o "$resize_test_dir/bidi.o"
    clang++ -std=c++17 -O0 "${options[@]}" "$resize_test_dir/main.cpp" \
        "$modules/juce_core/juce_core.mm" "$modules/juce_core/juce_core_CompilationTime.cpp" \
        "$modules/juce_events/juce_events.mm" "$modules/juce_data_structures/juce_data_structures.mm" \
        "$modules/juce_graphics/juce_graphics.mm" "$modules/juce_graphics/juce_graphics_Harfbuzz.cpp" \
        "$modules/juce_gui_basics/juce_gui_basics.mm" "$modules/juce_gui_basics/juce_gui_basics_"{2,3,4,5}.cpp \
        "$resize_test_dir/bidi.o" -framework Cocoa -framework QuartzCore -framework IOKit -framework Security \
        -weak_framework Metal -weak_framework MetalKit -o "$resize_test_dir/test"
    "$resize_test_dir/test"
else
    echo 'CMake is required for this platform.' >&2; exit 1
fi
