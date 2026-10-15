#pragma once
#include "Common.h"
#include <BinaryData.h>
namespace catlive {
// Match the Mac save decision: app icon, one question, three stacked actions.
class CloseProjectSheet final : public Component {
    class Action final : public Button {
      public:
        Action(String label, bool primary) : Button(label), primary(primary) { setButtonText(label); }
        void paintButton(Graphics &g, bool over, bool down) override {
            auto colour = primary ? Colour(0xff60b53d) : Colour(0xff303030);
            g.setColour(down ? colour.darker(.15f) : over ? colour.brighter(.1f) : colour);
            g.fillRoundedRectangle(getLocalBounds().toFloat(), getHeight() / 2.f);
            if (hasKeyboardFocus(false)) { g.setColour(Colours::white.withAlpha(.5f)); g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(1), getHeight() / 2.f, 1); }
            g.setColour(Colours::white); g.setFont(theme::mediumFont(13));
            g.drawText(getButtonText(), getLocalBounds(), Justification::centred);
        }
      private: bool primary;
    };
  public:
    CloseProjectSheet() {
        setName("Deseja salvar este projeto?"); setWantsKeyboardFocus(true);
        setFocusContainerType(FocusContainerType::focusContainer);
        for (auto *button : {&save, &discard, &cancel}) addAndMakeVisible(button);
        save.onClick = [this] { exitModalState(1); };
        discard.onClick = [this] { exitModalState(2); };
        cancel.onClick = [this] { exitModalState(0); };
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::escapeKey) { exitModalState(0); return true; }
        if (key == KeyPress::returnKey) { exitModalState(1); return true; }
        return false;
    }
    void resized() override {
        frame = juce::Rectangle<int>(260, 244).withCentre(getLocalBounds().getCentre());
        save.setBounds(frame.getX()+16, frame.getY()+132, 228, 28);
        discard.setBounds(frame.getX()+16, frame.getY()+166, 228, 28);
        cancel.setBounds(frame.getX()+16, frame.getY()+200, 228, 28);
    }
    void paint(Graphics &g) override {
        g.fillAll(Colours::black.withAlpha(.18f));
        DropShadow(Colours::black.withAlpha(.4f), 22, {0, 7}).drawForRectangle(g, frame);
        g.setColour(Colour(0xff222222)); g.fillRoundedRectangle(frame.toFloat(), 25);
        g.setColour(Colour(0xff565656)); g.drawRoundedRectangle(frame.toFloat().reduced(.5f), 25, 1);
        g.drawImageWithin(icon, frame.getX()+98, frame.getY()+24, 64, 64, RectanglePlacement::centred);
        g.setColour(Colour(0xffdddddd)); g.setFont(theme::font(14, true));
        g.drawText("Deseja salvar este projeto?", frame.getX()+16, frame.getY()+98, 228, 24, Justification::centred);
    }
    static void open(Component &parent, std::function<void(int)> answer) {
        auto *sheet = new CloseProjectSheet;
        parent.addAndMakeVisible(sheet); sheet->setBounds(parent.getLocalBounds()); sheet->toFront(true);
        sheet->enterModalState(true, ModalCallbackFunction::create([safe=SafePointer<Component>(&parent), answer=std::move(answer)](int result) {
            if (safe) { safe->grabKeyboardFocus(); answer(result); }
        }), true);
    }
  private:
    Action save{"Salvar", true}, discard{"Fechar sem salvar", false}, cancel{"Cancelar", false};
    Image icon = ImageCache::getFromMemory(BinaryData::icon2561x_png, BinaryData::icon2561x_pngSize);
    juce::Rectangle<int> frame;
};
}
