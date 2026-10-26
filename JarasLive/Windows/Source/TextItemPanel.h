#pragma once
#include "Localization.h"
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class TextItemPanel final : public Component {
  public:
    TextItemPanel(String initial, std::function<void(String)> save) : commit(std::move(save)) {
        addAndMakeVisible(editor);
        editor.setMultiLine(true, true);
        editor.setReturnKeyStartsNewLine(true);
        editor.setScrollbarsShown(true);
        editor.setFont(theme::font(14));
        editor.setIndents(10, 10);
        editor.setText(initial, false);
        editor.setCaretPosition(initial.length());
        editor.apply = [this] { apply(); };
        editor.onEscapeKey = [this] { ModalSheet::dismiss(*this); };
        editor.onTextChange = [this] { repaint(); };
        addAndMakeVisible(cancel);
        addAndMakeVisible(confirm);
        cancel.onClick = [this] { ModalSheet::dismiss(*this); };
        confirm.onClick = [this] { apply(); };
        cancel.setWantsKeyboardFocus(false);
        confirm.setWantsKeyboardFocus(false);
        confirm.setColour(TextButton::buttonColourId, Colour(0xff4d825c));
        MessageManager::callAsync([safe = SafePointer<TextItemPanel>(this)] {
            if (safe && safe->isShowing())
                safe->editor.grabKeyboardFocus();
        });
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(theme::secondary);
        g.setFont(theme::font(11));
        g.drawText(String(editor.getText().length()) + " caracteres", 18, 206, getWidth() - 36, 18,
                   Justification::centredRight);
        g.drawText("Ctrl+Enter para aplicar; Enter para uma nova linha.", 18, 232, getWidth() - 36,
                   20, Justification::centredLeft);
    }
    void resized() override {
        editor.setBounds(18, 12, getWidth() - 36, 180);
        cancel.setBounds(18, getHeight() - 44, 82, 26);
        confirm.setBounds(getWidth() - 100, getHeight() - 44, 82, 26);
    }
    void visibilityChanged() override {
        if (isShowing())
            editor.grabKeyboardFocus();
    }

  private:
    struct Notepad final : TextEditor {
        std::function<void()> apply;
        bool keyPressed(const KeyPress &key) override {
            if (key.getModifiers().isCtrlDown() &&
                (key.getKeyCode() == KeyPress::returnKey || key.getKeyCode() == 10)) {
                if (apply)
                    apply();
                return true;
            }
            return TextEditor::keyPressed(key);
        }
    } editor;
    TextButton cancel{localization::translate("Cancelar")}, confirm{localization::translate("Aplicar")};
    std::function<void(String)> commit;
    void apply() { commit(editor.getText()); }
};
} // namespace catlive
