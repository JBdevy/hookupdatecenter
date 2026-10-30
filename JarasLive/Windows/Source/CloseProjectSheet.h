#pragma once
#include "Common.h"
#include "Localization.h"
#include "ConfirmationStyle.h"
#include <BinaryData.h>
namespace catlive {
// Shared glass surface for close decisions; save retains the app logo.
class CloseProjectSheet final : public Component {
    class Action final : public Button {
      public:
        Action(String label, bool primary) : Button(label), primary(primary) { setButtonText(label); }
        void paintButton(Graphics &g, bool over, bool down) override {
            auto colour = primary ? Colour(0xff60b53d) : Colour(0xff48474b).withAlpha(.85f);
            g.setColour(down ? colour.darker(.15f) : over ? colour.brighter(.1f) : colour);
            g.fillRoundedRectangle(getLocalBounds().toFloat(), getHeight() / 2.f);
            if (hasKeyboardFocus(false)) { g.setColour(Colours::white.withAlpha(.5f)); g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(1), getHeight() / 2.f, 1); }
            g.setColour(primary ? Colours::black : Colours::white); g.setFont(theme::mediumFont(confirmationStyle::buttonSize));
            g.drawText(getButtonText(), getLocalBounds(), Justification::centred);
        }
      private: bool primary;
    };
  public:
    CloseProjectSheet(bool playback = false, bool application = true) : playback(playback) {
        heading = playback ? (application ? "Encerrar o CatLive?" : "Fechar aba?") : "Deseja salvar este projeto?";
        message = application ? localization::translate(String::fromUTF8("A reprodução está em andamento. Deseja realmente encerrar o CatLive?"))
                              : String::fromUTF8("A reprodução está em andamento. Deseja realmente fechar esta aba?");
        setName(localization::translate(heading)); setWantsKeyboardFocus(true);
        setFocusContainerType(FocusContainerType::focusContainer);
        for (auto *button : {&save, &discard, &cancel}) addAndMakeVisible(button);
        if (playback) {
            save.setButtonText(localization::translate("Cancelar"));
            discard.setButtonText(application ? localization::translate("Encerrar CatLive") : localization::translate("Fechar aba"));
            cancel.setVisible(false);
        }
        for (auto *button : {&save, &discard, &cancel}) button->setButtonText(localization::translate(button->getButtonText()));
        save.onClick = [this] { exitModalState(this->playback ? 0 : 1); };
        discard.onClick = [this] { exitModalState(2); };
        cancel.onClick = [this] { exitModalState(0); };
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::escapeKey) { exitModalState(0); return true; }
        if (key == KeyPress::returnKey) { exitModalState(playback ? 0 : 1); return true; }
        return false;
    }
    juce::Rectangle<int> contentFrame() const { return frame; }
    void resized() override {
        frame = juce::Rectangle<int>(playback ? confirmationStyle::width : confirmationStyle::iconWidth,playback ? 180 : 234).withCentre(getLocalBounds().getCentre());
        const int x=frame.getX()+confirmationStyle::margin,width=frame.getWidth()-2*confirmationStyle::margin;
        const int bottom=frame.getBottom()-confirmationStyle::margin;
        if (playback) {
            save.setBounds(x,bottom-2*confirmationStyle::buttonHeight-confirmationStyle::gap,width,confirmationStyle::buttonHeight);
            discard.setBounds(x,bottom-confirmationStyle::buttonHeight,width,confirmationStyle::buttonHeight);
        } else {
            save.setBounds(x,bottom-3*confirmationStyle::buttonHeight-2*confirmationStyle::gap,width,confirmationStyle::buttonHeight);
            discard.setBounds(x,save.getBottom()+confirmationStyle::gap,width,confirmationStyle::buttonHeight);
            cancel.setBounds(x,discard.getBottom()+confirmationStyle::gap,width,confirmationStyle::buttonHeight);
        }
    }
    void paint(Graphics &g) override {
        g.fillAll(Colours::black.withAlpha(.18f));
        DropShadow(Colours::black.withAlpha(.4f),22,{0,7}).drawForRectangle(g,frame);
        confirmationStyle::surface(g,frame.toFloat());
        const int x=frame.getX()+confirmationStyle::margin,width=frame.getWidth()-2*confirmationStyle::margin;
        g.setColour(Colour(0xffdddddd));g.setFont(theme::semiboldFont(confirmationStyle::titleSize));
        if(playback) {
            g.drawText(localization::translate(heading),x,frame.getY()+18,width,22,Justification::centredLeft);
            g.setFont(theme::font(confirmationStyle::bodySize));
            g.drawFittedText(localization::translate(message),x,frame.getY()+46,width,42,Justification::topLeft,3,1.f);
        } else {
            g.drawImageWithin(icon,frame.getCentreX()-24,frame.getY()+16,48,48,RectanglePlacement::centred);
            g.drawText(localization::translate(heading),x,frame.getY()+74,width,24,Justification::centred);
        }
    }
    static void open(Component &parent, std::function<void(int)> answer, bool playback = false, bool application = true) {
        auto *sheet = new CloseProjectSheet(playback, application);
        parent.addAndMakeVisible(sheet); sheet->setBounds(parent.getLocalBounds()); sheet->toFront(true);
        sheet->enterModalState(true, ModalCallbackFunction::create([safe=SafePointer<Component>(&parent), answer=std::move(answer)](int result) {
            if (safe) { safe->grabKeyboardFocus(); answer(result); }
        }), true);
    }
  private:
    bool playback = false;
    String heading, message;
    Action save{"Salvar", true}, discard{"Fechar sem salvar", false}, cancel{"Cancelar", false};
    Image icon = ImageCache::getFromMemory(BinaryData::icon2561x_png, BinaryData::icon2561x_pngSize);
    juce::Rectangle<int> frame;
};
}
