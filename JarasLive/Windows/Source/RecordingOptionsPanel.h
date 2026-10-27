#pragma once
#include "Session.h"
#include "Appearance.h"
#include "Localization.h"

namespace catlive {
// Shared by both mixer views. Like TrackRecordButton on Mac, the REC context
// is an immediate settings popover; opening it never changes the armed state.
class RecordingOptionsPanel final : public Component, private Timer {
  public:
    static void show(Session &session, ID source, std::set<ID> selection,
                     Component &anchor, std::function<void(String)> error) {
        if (!selection.count(source)) selection = {source};
        CallOutBox::launchAsynchronously(
            std::make_unique<RecordingOptionsPanel>(session, std::move(source), std::move(selection), std::move(error)),
            anchor.getScreenBounds(), nullptr);
    }

    RecordingOptionsPanel(Session &owner, ID track, std::set<ID> selected, std::function<void(String)> failure)
        : session(owner), source(std::move(track)), targets(std::move(selected)),
          project(owner.project().id), error(std::move(failure)),
          modes({"Mono", "Stereo", "MIDI"}), monitor({"Monitor On", "Monitor Off"}),
          fader({"Pre-fader", "Post-fader"}), effects({"Pre-FX", "Post-FX"}), signal({"Entrada", "Saida"}) {
        setComponentID("trackRecordingOptions");
        addAndMakeVisible(modes);
        modes.setComponentID("recordingMode");
        modes.changed = [this](int choice) {
            if(this->track() && this->track()->role.id=="vinhetas" && choice==2)return;
            const int channels = choice == 2 ? 0 : choice + 1;
            change([channels](jaras::Track &track) {
                track.recordingChannels = channels;
                if (channels == 0 && !track.midiInput) track.midiInput = 1;
            });
        };
        addAndMakeVisible(format);
        format.setComponentID("recordingFormat");
        const Appearance settings;
        const auto inheritedFormat=settings.value("jaras.media.record.format","WAV").toString();
        const auto inheritedQuality=inheritedFormat=="MP3" ? String((int)settings.value("jaras.media.record.bitrate",320))+" kbps" : String((int)settings.value("jaras.media.record.bits",24))+"bit";
        format.addItem("Default - "+inheritedFormat+" "+inheritedQuality, 1);
        format.addItem(String::fromUTF8("WAV · 24-bit PCM"), 2);
        format.addItem(String::fromUTF8("WAV · 32-bit float"), 3);
        format.addItem(String::fromUTF8("MP3 · ") + String((int)settings.value("jaras.media.record.bitrate", 320)) + " kbps", 4);
        format.onChange = [this] {
            const int choice = format.getSelectedId();
            change([choice](jaras::Track &track) {
                if (choice == 1) track.recordingFormat.reset();
                else track.recordingFormat = choice == 2 ? "wav" : choice == 3 ? "wav32" : "mp3";
            });
        };
        addAndMakeVisible(monitor);
        monitor.setComponentID("inputMonitoring");
        monitor.changed = [this](int choice) {
            change([choice](jaras::Track &track) { track.inputMonitoring = choice == 0; }, true);
        };
        addAndMakeVisible(signal);
        signal.changed=[this](int choice){change([choice](jaras::Track &track){if(track.role.id!="vinhetas")track.recordingOutput=choice==1;});};
        addAndMakeVisible(fader); addAndMakeVisible(effects);
        fader.setComponentID("recordingFaderStage"); effects.setComponentID("recordingFXStage");
        fader.changed = [this](int choice) { change([choice](jaras::Track &track) { track.recordingPostFader = choice == 1; }); };
        effects.changed = [this](int choice) { change([choice](jaras::Track &track) { track.recordingPostFX = choice == 1; }); };
        setSize(318, 300);
        refresh();
        startTimerHz(5);
    }
    ~RecordingOptionsPanel() override { stopTimer(); }

    void paint(Graphics &g) override {
        g.setColour(Colours::white);
        g.setFont(theme::font(13.f, true));
        g.drawText(localization::translate("Recording mode"), 16, 12, getWidth() - 32, 24, Justification::centredLeft);
        g.setFont(theme::font(12.f));
        g.setColour(Colours::white.withMultipliedAlpha(midi ? .35f : 1.f));
        g.drawText(localization::translate("Format"), 16, 88, 66, 26, Justification::centredLeft);
    }
    void resized() override {
        modes.setBounds(16, 48, getWidth() - 32, 28);
        format.setBounds(84, 88, getWidth() - 100, 28);
        fader.setBounds(16, 172, getWidth() - 32, 28);
        effects.setBounds(16, 214, getWidth() - 32, 28);
        monitor.setBounds(16, 256, getWidth() - 32, 28);
        signal.setBounds(16, 130, getWidth() - 32, 28);
    }

  private:
    class Segmented final : public Component {
      public:
        explicit Segmented(const StringArray &names) {
            for (int index = 0; index < names.size(); ++index) {
                auto *button = buttons.add(new Segment(localization::translate(names[index])));
                addAndMakeVisible(button);
                button->onClick = [this, index] { if (changed) changed(index); };
            }
        }
        std::function<void(int)> changed;
        void select(int selected) {
            for (int index = 0; index < buttons.size(); ++index)
                buttons[index]->setToggleState(index == selected, dontSendNotification);
        }
        void allowLast(bool allow) { buttons.getLast()->setVisible(allow); visibleCount=buttons.size()-(allow?0:1); resized(); }
        void resized() override {
            for (int index = 0; index < buttons.size(); ++index) {
                const int left = index * getWidth() / (visibleCount?visibleCount:buttons.size());
                const int right = (index + 1) * getWidth() / (visibleCount?visibleCount:buttons.size());
                buttons[index]->setBounds(left + 2, 2, right - left - 4, getHeight() - 4);
            }
        }
        void paint(Graphics &g) override {
            g.setColour(Colour(0xff383838));
            g.fillRoundedRectangle(getLocalBounds().toFloat(), 5.f);
        }
      private:
        class Segment final : public Button {
          public:
            explicit Segment(String title) : Button(std::move(title)) { setWantsKeyboardFocus(true); }
            void paintButton(Graphics &g, bool over, bool down) override {
                if (getToggleState() || over || down) {
                    g.setColour(Colour(getToggleState() ? 0xff666666 : 0xff494949).withMultipliedAlpha(isEnabled() ? 1.f : .4f));
                    g.fillRoundedRectangle(getLocalBounds().toFloat(), 3.f);
                }
                g.setFont(theme::font(12.f));
                g.setColour(Colours::white.withMultipliedAlpha(isEnabled() ? 1.f : .35f));
                g.drawText(getName(), getLocalBounds().reduced(4, 0), Justification::centred, false);
            }
        };
        OwnedArray<Segment> buttons;
        int visibleCount=0;
    };
    Session &session;
    ID source;
    std::set<ID> targets;
    ID project;
    std::function<void(String)> error;
    Segmented modes, monitor, fader, effects, signal;
    ComboBox format;
    bool midi = false;

    const jaras::Track *track() const {
        if (session.project().id == project)
            if (const auto *song = session.song())
                for (const auto &candidate : song->tracks)
                    if (candidate.id == source && jaras::fixedTrackName(candidate.role).empty()) return &candidate;
        return nullptr;
    }
    void refresh() {
        const auto *current = track();
        if (!current) {
            setEnabled(false);
            if (auto *box = findParentComponentOfClass<CallOutBox>()) box->dismiss();
            return;
        }
        const bool vinhetas=current->role.id=="vinhetas";
        const bool output=vinhetas||current->recordingOutput.value_or(false);
        modes.allowLast(!vinhetas);
        signal.select(output?1:0);
        const int channels = vinhetas?std::max(1,current->recordingChannels.value_or(2)):current->recordingChannels.value_or(2);
        midi = channels == 0;
        modes.select(channels == 0 ? 2 : channels - 1);
        modes.setEnabled(!session.busy && !session.audio.isRecording());
        format.setEnabled(!midi && !session.busy && !session.audio.isRecording());
        monitor.setEnabled(!midi && !session.busy);
        signal.setEnabled(!midi && !vinhetas && !session.busy && !session.audio.isRecording());
        fader.setEnabled(!midi && output && !session.busy && !session.audio.isRecording());
        effects.setEnabled(!midi && output && !session.busy && !session.audio.isRecording());
        format.setSelectedId(!current->recordingFormat ? 1 : current->recordingFormat == "wav" ? 2 : current->recordingFormat == "wav32" ? 3 : 4, dontSendNotification);
        monitor.select(current->inputMonitoring.value_or(true) ? 0 : 1);
        fader.select(output && current->recordingPostFader.value_or(true) ? 1 : 0);
        effects.select(output && current->recordingPostFX.value_or(true) ? 1 : 0);
        // Match the Mac: changing recording mode must not resize/reanchor the
        // callout. Audio-only options stay visible and disabled in MIDI mode.
        monitor.setVisible(!vinhetas);
        setSize(318, (vinhetas ? 256 : 300));
        repaint();
    }
    void timerCallback() override { refresh(); }
    void change(const std::function<void(jaras::Track &)> &edit, bool monitoring = false) {
        if (!track() || session.busy || (!monitoring && session.audio.isRecording())) { refresh(); return; }
        bool changed = false;
        for (const auto &song : session.project().songs)
            for (const auto &track : song.tracks)
                if (targets.count(track.id) && jaras::fixedTrackName(track.role).empty()) {
                    auto after = track; edit(after);
                    changed = changed || after.recordingChannels != track.recordingChannels ||
                              after.recordingFormat != track.recordingFormat || after.inputMonitoring != track.inputMonitoring ||
                              after.midiInput != track.midiInput || after.midiChannel != track.midiChannel || after.recordingPostFader != track.recordingPostFader ||
                              after.recordingPostFX != track.recordingPostFX || after.recordingOutput != track.recordingOutput;
                }
        if (!changed) return;
        try {
            session.edit([&](jaras::Project &project) {
                for (auto &song : project.songs)
                    for (auto &track : song.tracks)
                        if (targets.count(track.id) && jaras::fixedTrackName(track.role).empty()) edit(track);
            }, false);
        } catch (const std::exception &failure) {
            if (error) error(String::fromUTF8(failure.what()));
        }
        refresh();
    }
};
} // namespace catlive
