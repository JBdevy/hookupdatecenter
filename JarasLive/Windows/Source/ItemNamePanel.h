#pragma once
#include "Localization.h"
#include "Common.h"
namespace catlive {
class ItemNamePanel final : public Component {
    TextEditor name;
    TextButton cancel{localization::translate("Cancelar")}, save{localization::translate("Salvar")};
    std::function<void(String)> commit;
    std::function<void()> close;
    void confirm() { const auto value=name.getText().trim(); if(value.isNotEmpty())commit(value); }
public:
    ItemNamePanel(String value, std::function<void(String)> apply, std::function<void()> dismiss)
        : commit(std::move(apply)), close(std::move(dismiss)) {
        for(Component *c:std::initializer_list<Component*>{&name,&cancel,&save})addAndMakeVisible(c);
        name.setText(value);name.selectAll();name.setComponentID("itemName");
        name.onReturnKey=[this]{confirm();};name.onEscapeKey=close;
        name.onTextChange=[this]{save.setEnabled(name.getText().trim().isNotEmpty());};
        cancel.onClick=close;save.onClick=[this]{confirm();};
        save.setColour(TextButton::buttonColourId,Colour(0xff63b641));
    }
    void parentHierarchyChanged() override { if(isShowing())name.grabKeyboardFocus(); }
    void resized() override {
        auto r=getLocalBounds().reduced(16);name.setBounds(r.removeFromTop(32));
        auto buttons=r.removeFromBottom(32);cancel.setBounds(buttons.removeFromLeft(100));save.setBounds(buttons.removeFromRight(100));
    }
};
}
