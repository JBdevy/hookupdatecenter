#pragma once
#include "Common.h"
#include "Localization.h"
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
            g.setColour(Colours::white); g.setFont(theme::mediumFont(13));
            g.drawText(getButtonText(), getLocalBounds(), Justification::centred);
        }
      private: bool primary;
    };
  public:
    CloseProjectSheet(bool playback = false, bool application = true) : playback(playback) {
        heading = playback ? (application ? "Encerrar o CatLive?" : "Fechar aba?") : "Deseja salvar este projeto?";
        message = application ? String::fromUTF8("A reprodução está em andamento. Deseja realmente encerrar o CatLive?")
                              : String::fromUTF8("A reprodução está em andamento. Deseja realmente fechar esta aba?");
        setName(localization::translate(heading)); setWantsKeyboardFocus(true);
        setFocusContainerType(FocusContainerType::focusContainer);
        for (auto *button : {&save, &discard, &cancel}) addAndMakeVisible(button);
        if (playback) {
            save.setButtonText("Cancelar");
            discard.setButtonText(application ? "Encerrar CatLive" : "Fechar aba");
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
        if (playback) {
            frame = juce::Rectangle<int>(320, 196).withCentre(getLocalBounds().getCentre());
            save.setBounds(frame.getX()+16, frame.getY()+118, 288, 28);
            discard.setBounds(frame.getX()+16, frame.getY()+152, 288, 28);
            return;
        }
        frame = juce::Rectangle<int>(260, 244).withCentre(getLocalBounds().getCentre());
        save.setBounds(frame.getX()+16, frame.getY()+132, 228, 28);
        discard.setBounds(frame.getX()+16, frame.getY()+166, 228, 28);
        cancel.setBounds(frame.getX()+16, frame.getY()+200, 228, 28);
    }
    void paint(Graphics &g) override {
        g.fillAll(Colours::black.withAlpha(.18f));
        DropShadow(Colours::black.withAlpha(.4f), 22, {0, 7}).drawForRectangle(g, frame);
        g.setGradientFill(ColourGradient(Colour(0xff303030).withAlpha(.92f), (float)frame.getX(), (float)frame.getY(),
                                         Colour(0xff39363e).withAlpha(.88f), (float)frame.getRight(), (float)frame.getBottom(), false));
        g.fillRoundedRectangle(frame.toFloat(), 25);
        g.setColour(Colour(0xff565656)); g.drawRoundedRectangle(frame.toFloat().reduced(.5f), 25, 1);
        if (playback) {
            g.setColour(Colour(0xffdddddd)); g.setFont(theme::font(14, true));
            g.drawText(localization::translate(heading), frame.getX()+22, frame.getY()+19, 276, 24, Justification::centredLeft);
            g.setFont(theme::font(13));
            g.drawFittedText(localization::translate(message), frame.getX()+22, frame.getY()+49, 276, 58, Justification::centredLeft, 3, 1.f);
            return;
        }
        g.drawImageWithin(icon, frame.getX()+98, frame.getY()+24, 64, 64, RectanglePlacement::centred);
        g.setColour(Colour(0xffdddddd)); g.setFont(theme::font(14, true));
        g.drawText(localization::translate(heading), frame.getX()+16, frame.getY()+98, 228, 24, Justification::centred);
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
