#pragma once
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class ItemTunerPanel final : public Component, private Timer {
  public:
    ItemTunerPanel(Session &owner, ID target, std::function<void(String)> failure)
        : session(owner), id(std::move(target)), error(std::move(failure)) {
        for (auto *button : {&minus, &plus, &close}) {
            addAndMakeVisible(button);
            button->setWantsKeyboardFocus(false);
        }
        minus.onClick = [this] { change(-1); };
        plus.onClick = [this] { change(1); };
        close.onClick = [this] { ModalSheet::dismiss(*this); };
        refresh();
        startTimerHz(10);
    }
    void resized() override {
        minus.setBounds(getWidth() - 160, 26, 28, 28);
        plus.setBounds(getWidth() - 64, 26, 28, 28);
        close.setBounds(getWidth() - 96, getHeight() - 42, 76, 26);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(theme::display);
        g.fillRoundedRectangle(20.f, 16.f, (float)getWidth() - 40, 48, 7);
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(13));
        g.drawFittedText(name, 30, 20, getWidth() - 198, 40, Justification::centredLeft, 2);
        g.setColour(theme::green);
        g.setFont(theme::font(13));
        g.drawText((pitch >= 0 ? "+" : "") +
                       String(pitch, 2).trimCharactersAtEnd("0").trimCharactersAtEnd(".") + " st",
                   getWidth() - 132, 26, 68, 28, Justification::centred);
    }

  private:
    Session &session;
    ID id;
    std::function<void(String)> error;
    TextButton minus{String::fromUTF8("−")}, plus{"+"}, close{"Fechar"};
    String name;
    double pitch = 0;
    void refresh() {
        bool found = false;
        if (auto *song = session.song())
            for (const auto &track : song->tracks)
                for (const auto &clip : track.clips)
                    if (clip.id == id) {
                        found = true;
                        name = text(clip.name);
                        pitch = clip.pitchSemitones.value_or(0);
                    }
        bool editable = found && !session.busy && !session.transport().playing &&
                        !session.transport().subPlay.playing;
        minus.setEnabled(editable && pitch > -12);
        plus.setEnabled(editable && pitch < 12);
        repaint();
    }
    void timerCallback() override { refresh(); }
    void change(int step) {
        try {
            session.edit([&](jaras::Project &project) {
                for (auto &song : project.songs)
                    for (auto &track : song.tracks)
                        for (auto &clip : track.clips)
                            if (clip.id == id && !clip.midi &&
                                jaras::fixedTrackName(track.role).empty()) {
                                clip.pitchSemitones =
                                    jlimit(-12., 12., clip.pitchSemitones.value_or(0) + step);
                                return;
                            }
                throw std::runtime_error("Este item não aceita transposição de áudio.");
            });
            refresh();
        } catch (const std::exception &e) {
            error(String::fromUTF8(e.what()));
        }
    }
};
} // namespace catlive
