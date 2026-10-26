#pragma once
#include "Localization.h"
#include "Session.h"
#include "ModalSheet.h"
#include "PortablePackage.h"
namespace catlive {
class PortableExportPanel final : public Component, private Timer {
    struct Work {
        std::atomic<bool> cancel{false};
        std::atomic<double> progress{0};
    };
    Session &session;
    std::function<void(std::function<void()>)> save;
    TextButton close{localization::translate("Fechar")}, saveButton{localization::translate("Salvar")}, exportButton{localization::translate("Exportar para CatLive iPadOS")},
        reveal{"Mostrar na pasta"};
    std::unique_ptr<FileChooser> chooser;
    std::shared_ptr<Work> work;
    String error, excluded;
    File exported;
    bool requiresSave() const { return session.dirty || !session.document.existsAsFile(); }
    void start(const File &destination, const File &document, const ID &identity) {
        if (session.document != document || session.project().id != identity || requiresSave() ||
            session.busy || session.audio.isRecording()) {
            error = String::fromUTF8("Salve o projeto antes de exportar.");
            repaint();
            return;
        }
        var committed;
        try {
            committed = ProjectCodec::read(document);
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
            repaint();
            return;
        }
        work = std::make_shared<Work>();
        error = {};
        exported = {};
        ModalSheet::blockDismiss(*this, true);
        close.setButtonText(localization::translate("Cancelar"));
        timerCallback();
        const auto safe = SafePointer<PortableExportPanel>(this);
        auto state = work;
        Thread::launch([safe, state, committed, document, destination] {
            String failure;
            try {
                portablePackage::exportPackage(committed, document.getParentDirectory(), destination,
                                               [state](double value) {
                                                   if (state->cancel)
                                                       throw std::runtime_error("Export canceled.");
                                                   state->progress = value;
                                               });
            } catch (const std::exception &e) {
                failure = String::fromUTF8(e.what());
            }
            MessageManager::callAsync([safe, failure, destination] {
                if (!safe)
                    return;
                safe->work.reset();
                safe->error = failure;
                if (failure.isEmpty())
                    safe->exported = destination;
                ModalSheet::blockDismiss(*safe, false);
                safe->close.setButtonText(localization::translate("Fechar"));
                safe->timerCallback();
            });
        });
    }

  public:
    PortableExportPanel(Session &value, std::function<void(std::function<void()>)> saveAction)
        : session(value), save(std::move(saveAction)) {
        StringArray removed;
        std::set<String> capabilities;
        portablePackage::portableCopy(session.snapshot(), removed, capabilities);
        excluded = removed.joinIntoString("\n");
        getProperties().set("selfContainedSheet", true);
        for (auto *button : {&close, &saveButton, &exportButton, &reveal}) {
            addAndMakeVisible(*button);
            button->getProperties().set("flat", true);
        }
        exportButton.setColour(TextButton::buttonColourId, theme::green);
        close.onClick = [this] {
            if (work) {
                work->cancel = true;
                close.setEnabled(false);
            } else
                ModalSheet::dismiss(*this);
        };
        const auto owner = SafePointer<PortableExportPanel>(this);
        saveButton.onClick = [owner] {
            if (owner)
                owner->save([owner] {
                    if (owner)
                        owner->timerCallback();
                });
        };
        reveal.onClick = [this] { exported.revealToUser(); };
        exportButton.onClick = [this, owner] {
            if (requiresSave() || work || session.busy || session.audio.isRecording())
                return;
            const auto document = session.document;
            const auto identity = session.project().id;
            chooser = std::make_unique<FileChooser>(
                "Exportar para CatLive iPadOS", document.withFileExtension("ziplive"), "*.ziplive", true);
            chooser->launchAsync(FileBrowserComponent::saveMode | FileBrowserComponent::canSelectFiles |
                                     FileBrowserComponent::warnAboutOverwriting,
                                 [safe = owner, document, identity](const FileChooser &fc) {
                                     if (safe && fc.getResult() != File{})
                                         safe->start(fc.getResult().withFileExtension("ziplive"),
                                                     document, identity);
                                 });
        };
        startTimerHz(10);
        timerCallback();
    }
    ~PortableExportPanel() override {
        if (work)
            work->cancel = true;
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::font(18, true));
        g.drawText(localization::translate("Exportar para CatLive iPadOS"), 24, 22, getWidth() - 48, 24, Justification::centredLeft);
        g.setColour(theme::secondary);
        g.setFont(theme::font(13));
        g.drawFittedText(
            String::fromUTF8(
                "Crie um pacote .ziplive com este projeto, suas mídias e instrumentos nativos."),
            24, 62, getWidth() - 48, 42, Justification::topLeft, 2, 1);
        g.setColour(theme::yellow);
        g.drawFittedText(
            String::fromUTF8(
                "Plugins VST3 externos não serão incluídos. Os efeitos nativos serão preservados."),
            24, 116, getWidth() - 48, 42, Justification::topLeft, 2, 1);
        g.setColour(theme::secondary);
        g.setFont(theme::font(11));
        g.drawFittedText(excluded, 24, 170, getWidth() - 48, 72, Justification::topLeft, 5, 1);
        g.setColour(error.isNotEmpty() ? Colour(0xffff7777)
                    : requiresSave()   ? theme::yellow
                                       : theme::green);
        const auto status =
            error.isNotEmpty() ? error
            : work ? String::fromUTF8("Exportando projeto… ") + String((int)(work->progress * 100)) + "%"
            : exported.existsAsFile() ? "Projeto exportado com sucesso."
            : requiresSave()          ? "Salve o projeto antes de exportar."
                                      : String{};
        g.drawFittedText(status, 24, 250, getWidth() - 48, 42, Justification::topLeft, 3, 1);
        if (work) {
            const juce::Rectangle<float> bar(24.f, 298.f, (float)getWidth() - 48.f, 5.f);
            g.setColour(theme::secondary.withAlpha(.2f));
            g.fillRoundedRectangle(bar, 2.5f);
            g.setColour(theme::green);
            g.fillRoundedRectangle(bar.withWidth(bar.getWidth() * (float)jlimit(0., 1., work->progress.load())), 2.5f);
        }
    }
    void resized() override {
        close.setBounds(24, getHeight() - 50, 84, 26);
        saveButton.setBounds(getWidth() - 338, getHeight() - 50, 80, 26);
        exportButton.setBounds(getWidth() - 242, getHeight() - 50, 218, 26);
        reveal.setBounds(24, 296, 150, 24);
    }
    void timerCallback() override {
        saveButton.setVisible(requiresSave());
        saveButton.setEnabled(!work && !session.busy);
        exportButton.setEnabled(!requiresSave() && !work && !session.busy &&
                                !session.audio.isRecording());
        close.setEnabled(!work || !work->cancel);
        reveal.setVisible(exported.existsAsFile());
        repaint();
    }
};
} // namespace catlive
