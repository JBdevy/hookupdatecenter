#pragma once
#include "Common.h"

namespace catlive {
class InlineMixerTrackName final : public TextEditor {
  public:
    InlineMixerTrackName() {
        setComponentID("mixerTrackNameEditor");
        setTitle("Track name");
        setFont(theme::semiboldFont(11));
        setIndents(3, 0);
        setSelectAllWhenFocused(true);
        setColour(TextEditor::backgroundColourId, Colour(0xff1a1a1a));
        setColour(TextEditor::textColourId, Colours::white);
        setColour(TextEditor::outlineColourId, theme::line);
        setColour(TextEditor::focusedOutlineColourId, theme::line);
        onReturnKey = [this] { finish(true); };
        onEscapeKey = [this] { finish(false); };
        onFocusLost = [this] { finish(true); };
    }
    ~InlineMixerTrackName() override { Desktop::getInstance().removeGlobalMouseListener(&outsideClick); }

    void open(juce::Rectangle<int> bounds, const String &name, std::function<void(String)> renamed) {
        if (isVisible()) return;
        setText(name, false);
        editWidth = std::max(84, roundToInt(GlyphArrangement::getStringWidth(theme::semiboldFont(11), name)) + 36);
        layoutIn(bounds);
        commit = std::move(renamed);
        setVisible(true);
        toFront(true);
        grabKeyboardFocus();
        selectAll();
        Desktop::getInstance().addGlobalMouseListener(&outsideClick);
    }

    void finishIfOutside(Component *target) {
        if (!target || (target != this && !isParentOf(target))) finish(true);
    }
    void layoutIn(juce::Rectangle<int> bounds) {
        if (editWidth > 0) bounds.setWidth(std::min(editWidth, bounds.getWidth()));
        setBounds(bounds);
    }
    void confirm() { finish(true); }
    std::function<void(int)> navigate;
    bool keyPressed(const KeyPress &key) override {
        if (navigate && !key.getModifiers().isAnyModifierKeyDown() &&
            (key.getKeyCode() == KeyPress::upKey || key.getKeyCode() == KeyPress::downKey)) {
            navigate(key.getKeyCode() == KeyPress::downKey ? 1 : -1);
            return true;
        }
        return TextEditor::keyPressed(key);
    }

  private:
    struct OutsideClick final : MouseListener {
        explicit OutsideClick(InlineMixerTrackName &owner) : editor(owner) {}
        void mouseDown(const MouseEvent &event) override { editor.finishIfOutside(event.eventComponent); }
        InlineMixerTrackName &editor;
    } outsideClick{*this};
    std::function<void(String)> commit;
    int editWidth = 0;

    void finish(bool save) {
        if (!isVisible() || !commit) return;
        Desktop::getInstance().removeGlobalMouseListener(&outsideClick);
        auto renamed = std::move(commit);
        const auto name = getText().trim();
        editWidth = 0;
        setVisible(false);
        if (save && name.isNotEmpty())
            MessageManager::callAsync([renamed = std::move(renamed), name] { renamed(name); });
    }
};

inline bool canRenameMixerTrack(const jaras::Track &track) {
    return jaras::fixedTrackName(track.role).empty() && track.role.id != "vinhetas";
}
}
