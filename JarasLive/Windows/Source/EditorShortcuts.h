#pragma once
#include <juce_gui_basics/juce_gui_basics.h>
namespace catlive {
// Some Windows keyboard layouts deliver Ctrl+letters as WM_CHAR control codes.
// JUCE's editor mapper expects the corresponding letter; retry only editing keys
// after the focused editor declined the original event.
inline bool retryEditorShortcut(const juce::KeyPress &key) {
    auto *editor =
        dynamic_cast<juce::TextEditor *>(juce::Component::getCurrentlyFocusedComponent());
    if (!editor || !key.getModifiers().isCtrlDown() || key.getModifiers().isAltDown())
        return false;
    const int code = key.getKeyCode();
    if (code != 1 && code != 3 && code != 22 && code != 24 && code != 25 && code != 26)
        return false;
    return editor->keyPressed(juce::KeyPress('A' + code - 1, key.getModifiers(), 0));
}
} // namespace catlive
