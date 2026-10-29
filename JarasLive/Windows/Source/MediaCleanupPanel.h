#pragma once
#include "Localization.h"
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class MediaCleanupPanel final : public Component, private Timer {
  public:
    explicit MediaCleanupPanel(Session &value) : session(value) {
        addAndMakeVisible(cancel);
        addAndMakeVisible(remove);
        remove.getProperties().set("flat", true);
        remove.setColour(TextButton::buttonColourId, Colour(0xffc44848));
        cancel.onClick = [this] {
            if (!working)
                ModalSheet::dismiss(*this);
        };
        remove.onClick = [this] {
            if (!available() || Time::getMillisecondCounterHiRes() < readyAt)
                return;
            const auto safe = SafePointer<MediaCleanupPanel>(this);
            try {
                working = true;
                ModalSheet::blockDismiss(*this, true);
                cancel.setEnabled(false);
                remove.setEnabled(false);
                repaint();
                session.cleanTimelineMedia([safe](String failure) {
                    if (!safe)
                        return;
                    ModalSheet::blockDismiss(*safe, false);
                    if (failure.isEmpty())
                        ModalSheet::dismiss(*safe);
                    else {
                        safe->working = false;
                        safe->failure = failure;
                        safe->cancel.setEnabled(true);
                        safe->repaint();
                    }
                });
            } catch (const std::exception &e) {
                working = false;
                ModalSheet::blockDismiss(*this, false);
                failure = String::fromUTF8(e.what());
                cancel.setEnabled(true);
                repaint();
            }
        };
        if (!session.document.existsAsFile())
            failure = String::fromUTF8("Salve o projeto antes de limpar suas mídias.");
        startTimerHz(10);
        timerCallback();
    }
    void paint(Graphics &g) override {
        g.setFont(theme::font(13));
        g.setColour(Colours::white);
        g.drawFittedText(
            String::fromUTF8(
                "Isso salva o projeto e exclui permanentemente das pastas Stems e Videos os "
                "arquivos removidos da timeline. Arquivos ainda em uso são mantidos. Os backups de "
                "recuperação deste projeto também serão excluídos. O histórico de desfazer será limpo. Esta "
                "limpeza não pode ser desfeita."),
            24, 14, getWidth() - 48, 132, Justification::topLeft, 7, 1.f);
        g.setFont(theme::font(11));
        g.setColour(theme::secondary);
        g.drawFittedText(session.document.getParentDirectory().getFullPathName(), 24, 156,
                         getWidth() - 48, 40, Justification::topLeft, 2, 1.f);
        g.setColour(failure.isNotEmpty() ? Colour(0xffff7777) : theme::green);
        g.drawFittedText(working ? String::fromUTF8("Excluindo backups antigos e mídias sem uso… ") +
                                       String((int)(session.importProgress * 100)) + "%"
                                 : failure,
                         24, 204, getWidth() - 48, 42, Justification::topLeft, 2, 1.f);
    }
    void resized() override {
        cancel.setBounds(24, getHeight() - 46, 88, 26);
        remove.setBounds(getWidth() - 154, getHeight() - 46, 130, 26);
    }

  private:
    Session &session;
    TextButton cancel{localization::translate("Cancelar")}, remove{localization::translate("Excluir")};
    bool working = false;
    String failure;
    double readyAt = Time::getMillisecondCounterHiRes() + 3000;
    bool available() const {
        return !working && !session.busy && session.document.existsAsFile() &&
               !session.transport().playing && !session.transport().subPlay.playing &&
               !session.audio.isRecording();
    }
    void timerCallback() override {
        const int seconds =
            std::max(0, (int)std::ceil((readyAt - Time::getMillisecondCounterHiRes()) / 1000));
        remove.setButtonText(seconds > 0 ? "Excluir em " + String(seconds) + "s" : localization::translate("Excluir"));
        remove.setEnabled(available() && seconds == 0);
        if (working)
            repaint();
    }
};
} // namespace catlive
