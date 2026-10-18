#pragma once
#include "EditorShortcuts.h"

namespace catlive {
// A floating FX window is a separate keyboard root. Listen at its focused
// control so Space does not toggle a button instead of controlling transport.
class FloatingShortcuts final : private FocusChangeListener, public KeyListener {
    Component::SafePointer<Component> root, focused;
    std::function<bool(const KeyPress &)> dispatch;
    std::function<void(bool)> state;
    void globalFocusChanged(Component *next) override {
        if (focused) focused->removeKeyListener(this);
        focused = nullptr;
        if (root && next && (next == root || root->isParentOf(next))) {
            focused = next;
            next->addKeyListener(this);
        }
        if (state) state(false);
    }
public:
    FloatingShortcuts(Component &window, std::function<bool(const KeyPress &)> key,
                      std::function<void(bool)> keyState)
        : root(&window), dispatch(std::move(key)), state(std::move(keyState)) {
        Desktop::getInstance().addFocusChangeListener(this);
        globalFocusChanged(Component::getCurrentlyFocusedComponent());
    }
    ~FloatingShortcuts() override {
        Desktop::getInstance().removeFocusChangeListener(this);
        if (focused) focused->removeKeyListener(this);
    }
    static bool allows(const KeyPress &key) {
        if (Component::getCurrentlyModalComponent()) return false;
        for (auto *focus = Component::getCurrentlyFocusedComponent(); focus; focus = focus->getParentComponent())
            if (dynamic_cast<TextEditor *>(focus)) return false;
        const auto code = key.getKeyCode();
        if (code == KeyPress::deleteKey || code == KeyPress::backspaceKey || code == KeyPress::tabKey ||
            code == KeyPress::returnKey || code == KeyPress::escapeKey || code == KeyPress::upKey ||
            code == KeyPress::downKey || code == KeyPress::leftKey || code == KeyPress::rightKey ||
            code == KeyPress::homeKey || code == KeyPress::endKey || code == KeyPress::pageUpKey ||
            code == KeyPress::pageDownKey || (code == KeyPress::F4Key && key.getModifiers().isAltDown())) return false;
        auto letter = code;
        if (key.getModifiers().isCtrlDown() && letter >= 1 && letter <= 26) letter += 'A' - 1;
        if (letter >= 'a' && letter <= 'z') letter -= 'a' - 'A';
        // Clipboard and select-all belong to the active editor/list.
        if (key.getModifiers().isCtrlDown() && String("ACVX").containsChar((juce_wchar)letter)) return false;
        return true;
    }
    bool keyPressed(const KeyPress &key, Component *) override {
        return allows(key) && dispatch && dispatch(key);
    }
    bool keyStateChanged(bool down, Component *) override {
        if (state) state(down);
        return false;
    }
};
}
