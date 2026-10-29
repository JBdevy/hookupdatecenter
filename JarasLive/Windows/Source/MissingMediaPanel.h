#pragma once
#include "Localization.h"
#include "ModalSheet.h"
#include "ProjectMediaRecovery.h"
namespace catlive {
class MissingMediaPanel final : public Component {
  public:
    MissingMediaPanel(File project, StringArray missing, std::function<void(bool)> finished)
        : document(std::move(project)), paths(std::move(missing)), completion(std::move(finished)) {
        setComponentID("missingMediaRecovery");
        setWantsKeyboardFocus(true);
        cancel.setButtonText(localization::translate("Cancel"));
        open.setButtonText(localization::translate("Open anyway"));
        search.setButtonText(localization::translate("Search"));
        for (auto *button : {&cancel, &open, &search}) addAndMakeVisible(button);
        addAndMakeVisible(details);
        details.setMultiLine(true); details.setReadOnly(true); details.setScrollbarsShown(true);
        details.setColour(TextEditor::backgroundColourId, theme::background);
        search.setColour(TextButton::buttonColourId, theme::green);
        search.setColour(TextButton::textColourOffId, Colours::black);
        cancel.onClick = [this] { finish(false); };
        open.onClick = [this] { finish(true); };
        search.onClick = [this] { chooseFolder(); };
        refresh();
    }
    ~MissingMediaPanel() override {
        cancelled->store(true);
        // Escape and the sheet's close button are also cancellation.
        if (completion) MessageManager::callAsync([done = std::move(completion)] { done(false); });
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(theme::secondary); g.setFont(theme::font(12));
        g.drawText(busy ? localization::translate(String::fromUTF8("Searching for missing audio…"))
                           : localization::translate(paths.size() == 1 ? "%d audio file is missing" : "%d audio files are missing")
                                 .replace("%d", String(paths.size())),
                   20, 12, getWidth()-40, 22, Justification::centredLeft);
    }
    void resized() override {
        details.setBounds(20, 42, getWidth()-40, std::max(50, getHeight()-112));
        cancel.setBounds(20,getHeight()-50,88,30);
        search.setBounds(getWidth()-112,getHeight()-50,92,30);
        open.setBounds(getWidth()-286,getHeight()-50,164,30);
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::returnKey && !busy) { finish(true); return true; }
        return false;
    }
  private:
    File document;
    StringArray paths, errors;
    std::function<void(bool)> completion;
    TextEditor details;
    TextButton cancel{localization::translate(String::fromUTF8("Cancelar"))}, open{String::fromUTF8("Abrir mesmo assim")},
               search{String::fromUTF8("Procurar")};
    std::unique_ptr<FileChooser> chooser;
    std::shared_ptr<std::atomic<bool>> cancelled = std::make_shared<std::atomic<bool>>(false);
    bool busy = false;
    void refresh() {
        details.setText(paths.joinIntoString("\n") + (errors.isEmpty() ? String() : "\n\n" + errors.joinIntoString("\n")), false);
        open.setEnabled(!busy); search.setEnabled(!busy); repaint();
    }
    void finish(bool proceed) {
        cancelled->store(true);
        auto done = std::move(completion);
        ModalSheet::dismiss(*this);
        if (done) MessageManager::callAsync([done, proceed] { done(proceed); });
    }
    void chooseFolder() {
        chooser = std::make_unique<FileChooser>(localization::translate("Locate missing files"),
                                                document.getParentDirectory(), "", true);
        chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectDirectories,
            [safe = SafePointer<MissingMediaPanel>(this)](const FileChooser &fc) {
                if (!safe || fc.getResult() == File()) return;
                safe->busy = true; safe->refresh();
                const auto folder = fc.getResult(), directory = safe->document.getParentDirectory();
                const auto missing = safe->paths; const auto token = safe->cancelled;
                Thread::launch([safe, folder, directory, missing, token] {
                    projectMediaRecovery::Result result;
                    try { result = projectMediaRecovery::restore(missing, directory, folder, *token); }
                    catch (const std::exception &e) { result.remaining = missing; result.errors.add(String::fromUTF8(e.what())); }
                    MessageManager::callAsync([safe, result, token] {
                        if (!safe || token->load()) return;
                        safe->busy = false; safe->paths = result.remaining; safe->errors = result.errors;
                        if (safe->paths.isEmpty()) safe->finish(true);
                        else safe->refresh();
                    });
                });
            });
    }
};
} // namespace catlive
