#pragma once
#include "Localization.h"
#include "Normalization.h"
#include "Session.h"
#include "Appearance.h"
#include "ModalSheet.h"
namespace catlive {
class NormalizationPanel final : public Component {
  public:
    NormalizationPanel(Session &owner, Appearance &preferences, ID target)
        : session(owner), appearance(preferences), id(std::move(target)) {
        addAndMakeVisible(mode);
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
    }
    void resized() override {
        mode.setBounds(86, 18, getWidth() - 108, 26);
        level.setBounds(86, 62, getWidth() - 156, 26);
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
        g.drawFittedText(status, 22, 135, getWidth() - 44, 40, Justification::topLeft, 3);
    }

  private:
    Session &session;
    Appearance &appearance;
    ID id;
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
            std::optional<jaras::AudioClip> selected;
            if (auto *song = session.song())
                for (const auto &track : song->tracks)
                    if (jaras::fixedTrackName(track.role).empty())
                        for (const auto &clip : track.clips)
                            if (clip.id == id && !clip.midi &&
                                (clip.audioFile || track.audioFile)) {
                                selected = clip;
                                if (!selected->audioFile)
                                    selected->audioFile = track.audioFile;
                            }
            if (!selected)
                throw std::runtime_error("O item selecionado não tem arquivo de áudio.");
            const auto project = session.project().id;
            const auto preference = key();
            const auto directory = session.mediaDirectory;
            const auto selectedMode = (normalization::Mode)(mode.getSelectedId() - 1);
            auto safe = SafePointer<NormalizationPanel>(this);
            auto stop = cancelled;
            level.setText(String(target, 2));
            failed = false;
            status = String::fromUTF8("Analisando áudio…");
            setBusy(true);
            worker.addJob([safe, stop, clip = *selected, project, directory, selectedMode, target,
                           preference] {
                String failure;
                double result = 1;
                try {
                    result =
                        normalization::gain(normalization::measure(clip, directory, selectedMode,
                                                                   [stop] { return stop->load(); }),
                                            target);
                } catch (const std::exception &e) {
                    failure = String::fromUTF8(e.what());
                }
                MessageManager::callAsync(
                    [safe, stop, clip, project, target, preference, result, failure] {
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
                                                item.normalizationGain = result;
                                                return;
                                            }
                                throw std::runtime_error("O item não existe mais.");
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
