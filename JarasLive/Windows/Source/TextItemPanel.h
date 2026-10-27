#pragma once
#include "Localization.h"
#include "Session.h"
#include "ModalSheet.h"
#include "ItemTextColors.h"
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
        for(const auto &run:ItemTextColors::runs(initial)) {
            editor.setColour(TextEditor::textColourId,run.color?Colour(0xff000000|*run.color):Colours::white);
            const int before=editor.getText().length();editor.insertTextAtCaret(run.text);
            for(int i=before;i<editor.getText().length();++i)colors.push_back(run.color);
        }
        previous=editor.getText();
        editor.setCaretPosition(previous.length());
        editor.chooseColor=[this]{chooseColor();};
        editor.prepareInsertion=[this]{
            synchronize();const int at=editor.getHighlightedRegion().getStart();
            const auto color=at>0 && at<=(int)colors.size()?colors[(size_t)at-1]:std::optional<uint32>{};
            editor.setColour(TextEditor::textColourId,color?Colour(0xff000000|*color):Colours::white);
        };
        editor.apply = [this] { apply(); };
        editor.onEscapeKey = [this] { ModalSheet::dismiss(*this); };
        editor.onTextChange = [this] { synchronize(); repaint(); };
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
        std::function<void()> apply,chooseColor,prepareInsertion;
        bool coloring=false;
        void insertTextAtCaret(const String &text) override {
            if(!coloring && prepareInsertion)prepareInsertion();
            TextEditor::insertTextAtCaret(text);
        }
        void mouseDown(const MouseEvent &event) override {
            if(event.mods.isPopupMenu() && !getHighlightedRegion().isEmpty()) {if(chooseColor)chooseColor();return;}
            TextEditor::mouseDown(event);
        }
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
    std::vector<std::optional<uint32>> colors;
    String previous;
    void synchronize() {
        const auto now=editor.getText();if(now==previous)return;
        int first=0,lastOld=previous.length(),lastNew=now.length();
        while(first<lastOld && first<lastNew && previous[first]==now[first])++first;
        while(lastOld>first && lastNew>first && previous[lastOld-1]==now[lastNew-1]){--lastOld;--lastNew;}
        const auto inherited=first>0 && first<=(int)colors.size()?colors[(size_t)first-1]:std::optional<uint32>{};
        colors.erase(colors.begin()+first,colors.begin()+lastOld);
        colors.insert(colors.begin()+first,(size_t)(lastNew-first),inherited);
        previous=now;
    }
    struct Palette final : Component {
        std::function<void(uint32)> pick;
        std::array<TextButton,8> choices;
        TextButton cancel{localization::translate("Cancelar")};
        Palette(std::function<void(uint32)> callback):pick(std::move(callback)) {
            for(size_t i=0;i<choices.size();++i) {
                auto &button=choices[i];addAndMakeVisible(button);
                button.setColour(TextButton::buttonColourId,Colour(0xff000000|ItemTextColors::palette[i]));
                button.setColour(TextButton::buttonOnColourId,Colour(0xff000000|ItemTextColors::palette[i]));
                button.setTooltip("#"+String::toHexString((int)ItemTextColors::palette[i]).paddedLeft('0',6));
                button.onClick=[this,i]{auto callback=pick;const auto color=ItemTextColors::palette[i];ModalSheet::dismiss(*this);callback(color);};
            }
            addAndMakeVisible(cancel);cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        }
        void resized() override {for(int i=0;i<8;++i)choices[(size_t)i].setBounds(18+i*40,18,30,38);cancel.setBounds(130,76,96,26);}
    };
    void chooseColor() {
        synchronize();const auto selected=editor.getHighlightedRegion();if(selected.isEmpty())return;
        auto panel=std::make_unique<Palette>([safe=SafePointer<TextItemPanel>(this),selected](uint32 color){
            if(!safe)return;safe->synchronize();
            if(selected.getEnd()>safe->editor.getText().length())return;
            for(int i=selected.getStart();i<selected.getEnd();++i)safe->colors[(size_t)i]=color;
            const auto value=safe->editor.getTextInRange(selected);
            safe->editor.setHighlightedRegion(selected);
            safe->editor.setColour(TextEditor::textColourId,Colour(0xff000000|color));
            safe->editor.coloring=true;safe->editor.insertTextAtCaret(value);safe->editor.coloring=false;
            safe->editor.setHighlightedRegion(selected);
            safe->editor.grabKeyboardFocus();
        });
        auto *host=getTopLevelComponent();
        if(host)ModalSheet::open(*host,localization::translate("Text color"),std::move(panel),370,160);
    }
    void apply() {
        synchronize();std::vector<ItemTextColors::Run> runs;
        for(int i=0;i<previous.length();++i) {
            const auto color=colors[(size_t)i];const auto character=String::charToString(previous[i]);
            if(!runs.empty() && runs.back().color==color)runs.back().text+=character;
            else runs.push_back({character,color});
        }
        commit(ItemTextColors::encode(runs));
    }
};
} // namespace catlive
