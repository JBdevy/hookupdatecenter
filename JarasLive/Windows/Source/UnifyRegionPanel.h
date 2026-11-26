#pragma once
#include "Localization.h"
namespace catlive {
// Matches the region-header popover in Apple/Shared/RegionEditor.swift.
class UnifyRegionPanel final : public Component {
  public:
    explicit UnifyRegionPanel(std::function<bool(String)> create) : create(std::move(create)) {
        setName(localization::translate(String::fromUTF8("Unificar regiões")));
        setWantsKeyboardFocus(true);
        addAndMakeVisible(name); addAndMakeVisible(cancel); addAndMakeVisible(unify);
        name.setName(localization::translate("Nome"));
        name.setTextToShowWhenEmpty(localization::translate("Nome"), theme::secondary);
        name.setFont(theme::font(13)); name.setSelectAllWhenFocused(true);
        name.onReturnKey = [this] { commit(); };
        name.onEscapeKey = [this] { dismiss(); };
        name.onTextChange = [this] { invalid = false; repaint(); };
        cancel.setButtonText(localization::translate("Cancelar"));
        unify.setButtonText(localization::translate("Unificar"));
        cancel.onClick = [this] { dismiss(); }; unify.onClick = [this] { commit(); };
        setSize(300, 146);
    }
    void parentHierarchyChanged() override {
        if (getParentComponent()) MessageManager::callAsync([safe=SafePointer<UnifyRegionPanel>(this)] {
            if (safe && safe->isShowing()) safe->name.grabKeyboardFocus();
        });
    }
    void resized() override {
        name.setBounds(18, 49, getWidth()-36, 26);
        cancel.setBounds(18, 102, 84, 26); unify.setBounds(getWidth()-102, 102, 84, 26);
    }
    void paint(Graphics &g) override {
        g.setColour(Colours::white); g.setFont(theme::font(14, true));
        g.drawText(localization::translate(String::fromUTF8("Unificar regiões")), 18, 16, getWidth()-36, 20, Justification::centredLeft);
        if (invalid) {
            g.setColour(Colour(0xffff5353)); g.drawRoundedRectangle(name.getBounds().toFloat(), 5, 1);
            g.setFont(theme::font(11));
            g.drawText(localization::translate("Escolha um nome"), 18, 77, getWidth()-36, 18, Justification::centredLeft);
        }
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::escapeKey) { dismiss(); return true; }
        if (key == KeyPress::returnKey) { commit(); return true; }
        return false;
    }
  private:
    TextEditor name;
    TextButton cancel, unify;
    std::function<bool(String)> create;
    bool invalid = false;
    void dismiss() { if (auto *popover = findParentComponentOfClass<CallOutBox>()) popover->dismiss(); }
    void commit() {
        const auto value = name.getText().trim();
        if (value.isEmpty()) { invalid = true; name.grabKeyboardFocus(); repaint(); return; }
        if (create(value)) dismiss();
    }
};
}
