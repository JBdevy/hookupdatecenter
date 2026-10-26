#pragma once
#include "Localization.h"
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class CreateTrackPanel final : public Component {
  public:
    CreateTrackPanel(Session &owner, std::function<void(String)> failure)
        : session(owner), error(std::move(failure)) {
        type.setComponentID("createTrackType");
        confirm.setComponentID("createTrackConfirm");
        name.setComponentID("createTrackName");
        addAndMakeVisible(type);
        type.addItemList({String::fromUTF8("Padrão"), "Timecode", "Teleprompter 1",
                          "Teleprompter 2", "Cifras", "Click"},
                         1);
        type.setSelectedId(1, dontSendNotification);
        type.onChange = [this] { update(); };
        addAndMakeVisible(name);
        name.setFont(theme::font(13));
        name.setText("Pista " +
                     String(session.song() ? (int)session.song()->tracks.size() + 1 : 1));
        name.selectAll();
        name.onReturnKey = [this] { create(); };
        addAndMakeVisible(count);
        count.setInputRestrictions(3, "0123456789");
        count.setText("1");
        count.setJustification(Justification::centredRight);
        count.onReturnKey = [this] { create(); };
        if (auto *device = session.audio.devices.getCurrentAudioDevice())
            inputChannels = device->getInputChannelNames().size();
        addAndMakeVisible(cancel);
        addAndMakeVisible(confirm);
        cancel.onClick = [this] { ModalSheet::dismiss(*this); };
        confirm.onClick = [this] { create(); };
        for (auto *b : {&cancel, &confirm})
            b->setColour(TextButton::buttonColourId, Colour(0xff4d825c));
        update();
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        g.drawText(localization::translate("Tipo"), 28, 16, 36, 26, Justification::centredLeft);
        if (type.getSelectedId() == 1)
            g.drawText(localization::translate("Quantidade"), 190, 100, 82, 26, Justification::centredLeft);
        g.setColour(unavailable ? theme::yellow : theme::secondary);
        g.setFont(theme::font(11));
        g.drawFittedText(message, 28, 140, getWidth() - 56, 44, Justification::centredLeft, 3);
    }
    void resized() override {
        type.setBounds(64, 16, 140, 26);
        name.setBounds(28, 58, getWidth() - 56, 27);
        count.setBounds(getWidth() - 90, 100, 62, 26);
        cancel.setBounds(28, getHeight() - 58, 82, 40);
        confirm.setBounds(getWidth() - 84, getHeight() - 58, 56, 40);
    }
    void visibilityChanged() override {
        if (isShowing())
            name.grabKeyboardFocus();
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::returnKey) { create(); return true; }
        return false;
    }

  private:
    Session &session;
    std::function<void(String)> error;
    ComboBox type;
    TextEditor name, count;
    TextButton cancel{localization::translate("Cancelar")}, confirm{localization::translate("Criar")};
    int inputChannels = 0;
    bool unavailable = false;
    String message;
    std::string role() const {
        const char *roles[]{"other",       "timecode", "teleprompt",
                            "teleprompt2", "chords",   "generatedClick"};
        return roles[jlimit(0, 5, type.getSelectedId() - 1)];
    }
    void update() {
        const bool standard = type.getSelectedId() == 1;
        unavailable = false;
        if (!standard)
            for (const auto &song : session.project().songs)
                for (const auto &track : song.tracks)
                    if (track.role.id == role())
                        unavailable = true;
        name.setVisible(standard);
        count.setVisible(standard);
        confirm.setEnabled(!unavailable);
        message = unavailable ? String::fromUTF8("Já existe uma pista deste tipo no projeto.")
                  : !standard ? type.getText()
                  : inputChannels == 0 ? String::fromUTF8("Nenhuma entrada de áudio disponível.")
                                       : String();
        repaint();
    }
    void create() {
        if (unavailable)
            return;
        const auto kind = role();
        const int quantity = kind == "other" ? count.getText().getIntValue() : 1;
        const auto label = name.getText().trim();
        if (quantity < 1 || quantity > 512 || (kind == "other" && label.isEmpty())) {
            message = String::fromUTF8("Informe um nome e uma quantidade entre 1 e 512.");
            repaint();
            return;
        }
        const auto songID = session.song() ? session.song()->id : ID{};
        try {
            session.edit([&](jaras::Project &project) {
                for (auto &song : project.songs)
                    if (song.id == songID) {
                        for (int i = 0; i < quantity; ++i) {
                            jaras::Track track;
                            track.id = uuid();
                            track.role.id = kind;
                            if (kind == "other") track.color = 0x828282;
                            track.name =
                                kind == "other"
                                    ? utf8(label + (quantity > 1 ? " " + String(i + 1) : String()))
                                    : jaras::fixedTrackName(track.role);
                            if (kind == "other" && inputChannels > 0) {
                                track.inputPatch = jaras::OutputPatch{1, std::min(2, inputChannels)};
                            }
                            if (kind == "timecode") {
                                track.timecode = jaras::TimecodeSettings{};
                                track.patch = jaras::OutputPatch{-1, 2};
                            }
                            if (kind == "generatedClick") {
                                track.color = 0xffff00;
                                for (const auto &region : song.parts)
                                    if (!region.parentRegionID) {
                                        jaras::AudioClip clip;
                                        clip.id = uuid();
                                        clip.name = "Click";
                                        clip.startTime = region.startTime;
                                        clip.duration = region.endTime - region.startTime;
                                        clip.regionOwnerID = region.id;
                                        track.clips.push_back(clip);
                                    }
                            }
                            song.tracks.push_back(std::move(track));
                        }
                    }
            });
            ModalSheet::dismiss(*this);
        } catch (const std::exception &e) {
            message = String::fromUTF8(e.what());
            repaint();
        }
    }
};
} // namespace catlive
