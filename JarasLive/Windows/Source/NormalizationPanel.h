#pragma once
#include "Localization.h"
#include "Normalization.h"
#include "Session.h"
#include "Appearance.h"
#include "ModalSheet.h"
namespace catlive {
class NormalizationPanel final : public Component, private Timer {
  public:
    NormalizationPanel(Session &owner, Appearance &preferences, ID target)
        : NormalizationPanel(owner, preferences, std::set<ID>{std::move(target)}) {}
    NormalizationPanel(Session &owner, Appearance &preferences, std::set<ID> targets)
        : session(owner), appearance(preferences), ids(std::move(targets)) {
        addAndMakeVisible(mode);
        addAndMakeVisible(itemView); itemView.setViewedComponent(&itemRows, false);
        itemView.setScrollBarsShown(true, false); itemView.setScrollBarThickness(6);
        itemView.setComponentID("normalizationProgress");
        if (const auto *song = session.song()) for (const auto &track : song->tracks)
            for (const auto &clip : track.clips) if (ids.count(clip.id) && !clip.midi && (clip.audioFile || track.audioFile))
                itemRows.names.push_back(text(clip.name));
        addAndMakeVisible(level);
        addAndMakeVisible(cancel);
        addAndMakeVisible(applyButton);
        mode.setComponentID("normalizationMode");level.setComponentID("normalizationTarget");
        applyButton.setComponentID("normalizationApply");
        mode.addItemList({"LUFS-I", "RMS-I", "Peak", "True Peak"}, 1);
        mode.setSelectedId(3, dontSendNotification);
        mode.onChange = [this] { restore(); };
        level.setFont(theme::font(13));
        level.onReturnKey = [this] { apply(); };
        cancel.onClick = [this] {
            cancelled->store(true);
            ModalSheet::dismiss(*this);
        };
        applyButton.onClick = [this] { apply(); };
        for (auto *button : {&cancel, &applyButton})
            button->setWantsKeyboardFocus(false);
        restore();
    }
    ~NormalizationPanel() override {
        cancelled->store(true);
        worker.removeAllJobs(true, 10000);
        itemView.setViewedComponent(nullptr, false);
    }
    void resized() override {
        mode.setBounds(86, 18, getWidth() - 108, 26);
        level.setBounds(86, 62, getWidth() - 156, 26);
        itemView.setBounds(22, 133, getWidth() - 44, std::max(36, getHeight() - 244));
        itemRows.setSize(itemView.getWidth() - 8, std::max(itemView.getHeight(), (int)itemRows.names.size() * 36));
        cancel.setBounds(22, getHeight() - 48, 86, 26);
        applyButton.setBounds(getWidth() - 118, getHeight() - 48, 96, 26);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        g.drawText(localization::translate("Modo"), 22, 18, 60, 26, Justification::centredLeft);
        g.drawText(localization::translate("Alvo"), 22, 62, 60, 26, Justification::centredLeft);
        g.drawText(mode.getSelectedId() == 1   ? "LUFS"
                   : mode.getSelectedId() == 4 ? "dBTP"
                                               : "dB",
                   getWidth() - 64, 62, 46, 26, Justification::centredLeft);
        g.setColour(theme::secondary);
        g.setFont(theme::font(11));
        g.drawFittedText(String::fromUTF8("Ganho de normalização independente: até +24 dB"), 22,
                         101, getWidth() - 44, 30, Justification::topLeft, 2);
        g.setColour(failed ? Colour(0xffff5b5b) : theme::secondary);
        g.drawFittedText(status, 22, getHeight() - 100, getWidth() - 44, 42, Justification::topLeft, 3);
    }

  private:
    Session &session;
    Appearance &appearance;
    std::set<ID> ids;
    struct Progress { std::atomic<double> fraction{0}; std::atomic<int> current{0}; };
    std::shared_ptr<Progress> progress = std::make_shared<Progress>();
    int total = 0;
    struct ItemRows final : Component {
        std::vector<String> names; double completed = 0; int current = -1;
        void paint(Graphics &g) override {
            g.setFont(theme::font(12));
            for (size_t i = 0; i < names.size(); ++i) {
                const auto y = float(i * 36);
                g.setColour((int)i == current ? Colours::white : theme::secondary);
                g.drawText(names[i], 0, (int)y, getWidth(), 22, Justification::centredLeft, true);
                theme::progressBar(g, {0.f, y + 25, float(getWidth()), 6.f}, jlimit(0., 1., completed - i));
            }
        }
    } itemRows;
    Viewport itemView;
    int lastCurrent = -1;
    void timerCallback() override {
        itemRows.completed = total * progress->fraction.load();
        itemRows.current = std::max(0, progress->current.load() - 1);
        const auto name = itemRows.current < (int)itemRows.names.size() ? itemRows.names[(size_t)itemRows.current] : String{};
        status = localization::translate(String::fromUTF8("Analisando áudio…")) + " " + name;
        if (lastCurrent != itemRows.current) { lastCurrent = itemRows.current; itemView.setViewPosition(0, std::max(0, lastCurrent * 36 - itemView.getHeight() / 2)); }
        itemRows.repaint();
        repaint();
    }
    ComboBox mode;
    TextEditor level;
    TextButton cancel{localization::translate("Cancelar")}, applyButton{localization::translate("Normalizar")};
    String status;
    bool failed = false, busy = false;
    ThreadPool worker{1};
    std::shared_ptr<std::atomic<bool>> cancelled = std::make_shared<std::atomic<bool>>(false);
    String key() const {
        return "jaras.normalization.target." +
               normalization::name((normalization::Mode)(mode.getSelectedId() - 1));
    }
    void restore() {
        level.setText(String(jlimit(-60., 12., (double)appearance.value(key(), -1.)), 2));
        failed = false;
        status.clear();
        repaint();
    }
    void setBusy(bool value) {
        busy = value;

        ModalSheet::blockDismiss(*this, value);
        if (value) { timerCallback(); startTimerHz(20); } else stopTimer();
        mode.setEnabled(!value);
        level.setEnabled(!value);
        applyButton.setEnabled(!value);
        repaint();
    }
    void apply() {
        if (busy)
            return;
        try {
            auto raw = level.getText().trim().replaceCharacter(',', '.');
            size_t parsed = 0;
            const auto input = utf8(raw);
            const double target = std::stod(input, &parsed);
            if (parsed != input.size() || !std::isfinite(target) || target < -60 || target > 12)
                throw std::runtime_error("Informe um alvo entre -60 e +12.");
            if (session.busy || session.audio.isRecording())
                throw std::runtime_error("Conclua a gravação e aguarde as operações antes de normalizar.");
            std::vector<jaras::AudioClip> selected;
            if (auto *song = session.song())
                for (const auto &track : song->tracks)
                    if (jaras::fixedTrackName(track.role).empty())
                        for (const auto &clip : track.clips)
                            if (ids.count(clip.id) && !clip.midi &&
                                (clip.audioFile || track.audioFile)) {
                                selected.push_back(clip);
                                if (!selected.back().audioFile)
                                    selected.back().audioFile = track.audioFile;
                            }
            if (selected.empty())
                throw std::runtime_error("O item selecionado não tem arquivo de áudio.");
            const auto project = session.project().id;
            const auto preference = key();
            const auto directory = session.mediaDirectory;
            const auto selectedMode = (normalization::Mode)(mode.getSelectedId() - 1);
            auto safe = SafePointer<NormalizationPanel>(this);
            auto stop = cancelled;
            level.setText(String(target, 2));
            failed = false;
            itemRows.names.clear(); for (const auto &clip : selected) itemRows.names.push_back(text(clip.name));
            total = (int)selected.size(); progress->fraction = 0; progress->current = 1; lastCurrent = -1;
            resized();
            auto progressState = progress;
            setBusy(true);
            worker.addJob([safe, stop, clips = std::move(selected), project, directory, selectedMode, target,
                           preference, progressState] {
                String failure;
                std::vector<double> results;
                try {
                    for (size_t index=0; index<clips.size(); ++index) {
                        progressState->current = (int)index+1;
                        results.push_back(normalization::gain(normalization::measure(clips[index], directory, selectedMode,
                            [stop] { return stop->load(); }, [progressState,index,count=clips.size()](double fraction) {
                                progressState->fraction = (index+fraction)/count;
                            }), target));
                    }
                } catch (const std::exception &e) {
                    const auto index = std::min(clips.size()-1, size_t(std::max(1, progressState->current.load())-1));
                    failure = text(clips[index].audioFile->path).replaceCharacter('\\', '/').fromLastOccurrenceOf("/", false, false) + ": " + String::fromUTF8(e.what());
                }
                MessageManager::callAsync(
                    [safe, stop, clips, project, target, preference, results, failure] {
                        if (!safe || stop->load())
                            return;
                        safe->setBusy(false);
                        if (failure.isNotEmpty()) {
                            safe->status = failure;
                            safe->failed = true;
                            safe->repaint();
                            return;
                        }
                        try {
                            if (safe->session.project().id != project || safe->session.busy)
                                throw std::runtime_error("O projeto mudou durante a análise.");
                            safe->session.editItemControls([&](jaras::Project &p) {
                                size_t applied = 0;
                                for (size_t index=0; index<clips.size(); ++index) {
                                const auto &clip = clips[index];
                                bool found = false;
                                for (auto &song : p.songs)
                                    for (auto &track : song.tracks)
                                        for (auto &item : track.clips)
                                            if (item.id == clip.id) {
                                                const auto file = item.audioFile ? item.audioFile
                                                                                 : track.audioFile;
                                                if (!file || item.midi ||
                                                    file->path != clip.audioFile->path ||
                                                    item.sourceOffset != clip.sourceOffset ||
                                                    item.duration != clip.duration ||
                                                    item.playbackRate != clip.playbackRate ||
                                                    item.loopStart != clip.loopStart ||
                                                    item.loopLength != clip.loopLength)
                                                    throw std::runtime_error(
                                                        "O item mudou durante a análise.");
                                                item.normalizationGain = results[index];
                                                found = true;
                                            }
                                if (!found) throw std::runtime_error("O item não existe mais.");
                                ++applied;
                                }
                                if (applied != clips.size()) throw std::runtime_error("A seleção mudou durante a análise.");
                            });
                            auto saved = safe->appearance.set(preference, target);
                            if (saved.failed())
                                throw std::runtime_error(utf8(saved.getErrorMessage()));
                            ModalSheet::dismiss(*safe);
                        } catch (const std::exception &e) {
                            safe->status = String::fromUTF8(e.what());
                            safe->failed = true;
                            safe->repaint();
                        }
                    });
            });
        } catch (const std::exception &e) {
            status = String::fromUTF8(e.what());
            failed = true;
            repaint();
        }
    }
};
} // namespace catlive
