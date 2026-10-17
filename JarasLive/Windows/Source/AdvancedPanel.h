#pragma once
#include "Appearance.h"
#include "Session.h"
namespace catlive {
class AdvancedPanel final : public Component {
  public:
    AdvancedPanel(Appearance &, Session &, std::function<void(String)>);
    void paint(Graphics &) override;
    void resized() override;
    bool keyPressed(const KeyPress &key) override {
        if(key.getModifiers().isCtrlDown() && !key.getModifiers().isAltDown() &&
           (key.getKeyCode()=='Z'||key.getKeyCode()=='z'||key.getKeyCode()==26) && !dynamic_cast<TextEditor*>(Component::getCurrentlyFocusedComponent())) {
            try {if(key.getModifiers().isShiftDown())session.redo();else session.undo();}
            catch(const std::exception &e){if(error)error(String::fromUTF8(e.what()));}
            return true;
        }
        return false;
    }

  private:
    Appearance &appearance;
    Session &session;
    std::function<void(String)> error;
    OwnedArray<TextButton> tabs;
    TextButton close{"Cancelar"}, apply{"Aplicar"};
    Viewport viewport;
    Component page;
    OwnedArray<Component> fields;
    int selected = 0, contentHeight = 300;
    TextEditor *bpm = nullptr, *beats = nullptr, *unit = nullptr;
    ComboBox *timebase = nullptr;
    ToggleButton *automation = nullptr;
    void select(int);
    void save(const String &, var);
    Label &label(const String &, int, int, int, int = 26, bool = false);
    ComboBox &choice(const String &, const StringArray &, int, int, int, int,
                     std::function<void(int)>);
    ToggleButton &toggle(const String &, const String &, bool, int);
    void colourRow(const String &, const String &, uint32, int, bool = false);
    void applyTiming();
};
} // namespace catlive
