#pragma once
#include "Localization.h"
#include "Appearance.h"
#include "Session.h"
namespace catlive {
class AdvancedPanel final : public Component, private Timer {
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
    TextButton close{localization::translate("Cancelar")}, apply{localization::translate("Aplicar")};
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
    std::optional<jaras::ProjectTimebase> observedTimebase;
    void timerCallback() override {
        const auto current=session.song()?session.song()->timeSettings.value_or(jaras::ProjectTimeSettings{}).timebase:jaras::ProjectTimebase::free;
        if(observedTimebase && *observedTimebase!=current && timebase)
            timebase->setSelectedId(current==jaras::ProjectTimebase::relative?2:1,dontSendNotification);
        observedTimebase=current;
    }
    void applyTiming();
};
} // namespace catlive
