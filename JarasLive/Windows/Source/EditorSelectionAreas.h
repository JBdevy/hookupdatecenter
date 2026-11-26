#pragma once
#include <juce_gui_basics/juce_gui_basics.h>
#include <functional>
#include <vector>

namespace catlive {
inline bool isSelectAllShortcut(const juce::KeyPress &key) {
    const auto mods = key.getModifiers();
    const auto code = key.getKeyCode();
    return mods.isCtrlDown() && !mods.isAltDown() && !mods.isShiftDown() &&
           (code == 'A' || code == 'a' || code == 1);
}
inline bool selectionTextEditorFocused() {
    for (auto *at = juce::Component::getCurrentlyFocusedComponent(); at; at = at->getParentComponent())
        if (dynamic_cast<juce::TextEditor *>(at)) return true;
    return false;
}

// Registers the real editor areas. Pointer activation includes right-clicks;
// keyboard focus changes also choose an area. Toolbar focus keeps the last area.
class EditorSelectionAreas final : private juce::MouseListener, private juce::FocusChangeListener {
  public:
    EditorSelectionAreas() { juce::Desktop::getInstance().addFocusChangeListener(this); }
    ~EditorSelectionAreas() {
        juce::Desktop::getInstance().removeFocusChangeListener(this);
        for (auto &area : areas) if (area.component) area.component->removeMouseListener(this);
    }
    void add(juce::Component &component, juce::String name, std::function<bool()> select) {
        for (auto &area : areas) if (area.component.getComponent() == &component) {
            area.name = std::move(name); area.select = std::move(select); return;
        }
        areas.push_back({&component, std::move(name), std::move(select)});
        component.addMouseListener(this, true);
    }
    void activate(juce::Component &component) { choose(&component); }
    juce::String activeScope() const {
        for (const auto &area : areas) if (area.component && area.component.getComponent() == active.getComponent()) return area.name;
        return {};
    }
    bool selectAll(const juce::KeyPress &key) {
        if (!isSelectAllShortcut(key) || selectionTextEditorFocused() ||
            juce::Component::getCurrentlyModalComponent()) return false;
        for (const auto &area : areas)
            if (area.component && area.component.getComponent() == active.getComponent() && area.component->isShowing() && area.select) {
                area.select();
                return true; // Empty area still owns Ctrl+A; never spill into another scope.
            }
        return false;
    }
  private:
    struct Area { juce::Component::SafePointer<juce::Component> component; juce::String name; std::function<bool()> select; };
    std::vector<Area> areas;
    juce::Component::SafePointer<juce::Component> active;
    void choose(juce::Component *component) {
        for (auto *at = component; at; at = at->getParentComponent())
            for (const auto &area : areas) if (area.component.getComponent() == at) {
                active = at; return;
            }
    }
    void mouseDown(const juce::MouseEvent &event) override { choose(event.originalComponent); }
    void globalFocusChanged(juce::Component *component) override { choose(component); }
};
} // namespace catlive
