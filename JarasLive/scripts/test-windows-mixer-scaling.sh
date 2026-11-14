#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CATLIVE_JUCE_SOURCE:?Set CATLIVE_JUCE_SOURCE to the existing JUCE checkout}"
scaling_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-scaling.XXXXXX")"
trap 'rm -rf "$scaling_test_dir"' EXIT
python3 - "$scaling_test_dir" <<'PY'
from pathlib import Path
import sys
def method(source, signature):
    start=source.index(signature);begin=source.index('{',start);depth=1;end=begin+1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]
source=Path('Windows/Source/MixerPanel.h').read_text()
methods='\n'.join(method(source, s) for s in ['    void resized() override {','    void revealTrack(', '    void refresh() {','    void refreshVisible() {','    void syncScroll() {'])
special=Path('Windows/Source/SpecialTrackControls.h').read_text()
special=special[special.index('class SpecialTrackControls'):special.rindex('\n}')]
# Expose only the inherited Timer inspection API to this fixture.
special=special.replace('private Timer','public Timer')
visibility=method(Path('Windows/Source/MeterDisplay.h').read_text(),'inline bool visibleInViewport(')
test=Path('Tests/Core/WindowsMixerScalingTests.cpp').read_text().replace('// INSERT_MIXER_METHODS',methods).replace('// INSERT_SPECIAL_CONTROLS',special).replace('// INSERT_VIEWPORT_VISIBILITY',visibility)
(Path(sys.argv[1])/'main.cpp').write_text(test)
PY
modules="$CATLIVE_JUCE_SOURCE/modules"
options=(-DJUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 -DJUCE_STANDALONE_APPLICATION=1
    -DJUCE_WEB_BROWSER=0 -DJUCE_USE_CURL=0 -DNDEBUG=1 -I "$modules")
clang "${options[@]}" -c "$modules/juce_graphics/juce_graphics_Sheenbidi.c" -o "$scaling_test_dir/bidi.o"
clang++ -std=c++17 -O0 "${options[@]}" "$scaling_test_dir/main.cpp" \
    "$modules/juce_core/juce_core.mm" "$modules/juce_core/juce_core_CompilationTime.cpp" \
    "$modules/juce_events/juce_events.mm" "$modules/juce_data_structures/juce_data_structures.mm" \
    "$modules/juce_graphics/juce_graphics.mm" "$modules/juce_graphics/juce_graphics_Harfbuzz.cpp" \
    "$modules/juce_gui_basics/juce_gui_basics.mm" "$modules/juce_gui_basics/juce_gui_basics_"{2,3,4,5}.cpp \
    "$scaling_test_dir/bidi.o" -framework Cocoa -framework QuartzCore -framework IOKit -framework Security \
    -weak_framework Metal -weak_framework MetalKit -o "$scaling_test_dir/test"
"$scaling_test_dir/test"
