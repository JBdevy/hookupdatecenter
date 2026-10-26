#include "Localization.h"
#include "ProjectBrowser.h"
#include "InterfaceIcons.h"
#include "RecentProjectStorage.h"
namespace catlive {
void ProjectBrowser::Action::paintButton(Graphics &g, bool over, bool down) {
    g.setColour(theme::panel.brighter(down ? .12f : over ? .06f : 0.f));
    g.fillRoundedRectangle(getLocalBounds().toFloat(), 6);
    g.setColour(Colours::white.withAlpha(isEnabled() ? 1.f : .45f));
    auto font = theme::mediumFont(12);
    g.setFont(font);
    const auto title = localization::translate(getButtonText());
    const float textWidth = GlyphArrangement::getStringWidth(font, title);
    float x = (getWidth() - textWidth - 24) * .5f, y = (getHeight() - 16) * .5f;
    Path path;
    if (icon == recording) {
        drawInterfaceIcon(g, "record", {x, y, 16, 16});
    } else if (icon == piano) {
        drawInterfaceIcon(g, "piano", {x, y, 16, 16});
    } else if (icon == folder || icon == plusFolder) {
        path.startNewSubPath(x, y + 3);
        path.lineTo(x + 6, y + 3);
        path.lineTo(x + 8, y + 5);
        path.lineTo(x + 16, y + 5);
        path.lineTo(x + 16, y + 14);
        path.lineTo(x, y + 14);
        path.closeSubPath();
    } else if (icon == waveform) {
        for (int i = 0; i < 6; ++i) {
            float h = (i == 2 || i == 3) ? 14.f : (i == 1 || i == 4) ? 9.f : 4.f;
            path.startNewSubPath(x + i * 3, y + 8 - h / 2);
            path.lineTo(x + i * 3, y + 8 + h / 2);
        }
    } else if (icon == back) {
        path.startNewSubPath(x + 8, y + 3);
        path.lineTo(x + 3, y + 8);
        path.lineTo(x + 8, y + 13);
        path.startNewSubPath(x + 3, y + 8);
        path.lineTo(x + 16, y + 8);
    } else {
        path.addRoundedRectangle(x + 1, y + 2, 14, 12, 1.5f);
    }
    if (icon == plusDocument || icon == plusFolder) {
        path.startNewSubPath(x + 8, y + 7);
        path.lineTo(x + 8, y + 12);
        path.startNewSubPath(x + 5.5f, y + 9.5f);
        path.lineTo(x + 10.5f, y + 9.5f);
    }
    if (icon == archive)
        for (int i = 0; i < 4; ++i)
            path.addRectangle(x + 7, y + 3 + i * 2.5f, 2, 1);
    g.strokePath(path, PathStrokeType(1.2f, PathStrokeType::curved, PathStrokeType::rounded));
    g.drawText(title, juce::Rectangle<float>(x + 24, 0, textWidth + 2, (float)getHeight()),
               Justification::centredLeft);
}
ProjectBrowser::ProjectBrowser() {
    setOpaque(true);
    for (auto *button :
         {&create, &add, &recent, &empty, &stems, &reaper, &logic, &recording, &package, &back}) {
        addAndMakeVisible(*button);
        button->setComponentID(button->getName());
    }
    addAndMakeVisible(browseButton);
    addChildComponent(cancelLoading);
    cancelLoading.setComponentID("cancelProjectLoading");
    cancelLoading.onClick = [this] {
        if (!loading || !cancelLoadingAction) return;
        auto action = std::move(cancelLoadingAction);
        setLoadingCancellation({});
        action();
    };
    addAndMakeVisible(search);
    addAndMakeVisible(recents);
    for (auto *label : {&loadingStatus, &loadingError}) {
        addChildComponent(*label);
        label->setFont(theme::font(11));
        label->setJustificationType(Justification::centredLeft);
        label->setBorderSize({});
    }
    loadingStatus.setComponentID("projectLoadingStatus");
    loadingError.setComponentID("projectLoadingError");
    loadingError.setColour(Label::textColourId, Colours::red);
    create.onClick = [this] { selectMode(mode == creating ? none : creating); };
    add.onClick = [this] { selectMode(mode == adding ? none : adding); };
    recent.onClick = [this] { selectMode(opening); };
    empty.onClick = [this] {
        if (createEmpty)
            createEmpty();
    };
    empty.contextMenu = [this](const MouseEvent &event) {
        if (!projectOpen || loading || !createEmptyInNewTab) return;
        PopupMenu menu;
        menu.addItem(1, localization::translate("Open in new tab"));
        const auto position = event.getScreenPosition();
        const Component::SafePointer<ProjectBrowser> safe(this);
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&empty)
            .withTargetScreenArea({position.x, position.y, 1, 1}),
            [safe](int result) {
                if (result == 1 && safe && safe->projectOpen && !safe->loading && safe->createEmptyInNewTab)
                    safe->createEmptyInNewTab();
            });
    };
    reaper.onClick = [this] {
        if (createReaper)
            createReaper();
    };
    logic.onClick = [this] {
        if (createLogic)
            createLogic();
    };
    recording.onClick = [this] { if (createRecording) createRecording(); };
    stems.onClick = [this] {
        auto action = mode == adding ? addStems : createStems;
        if (action)
            action();
    };
    package.onClick = [this] {
        if (addPackage)
            addPackage();
    };
    browseButton.onClick = [this] {
        if (browse)
            browse();
    };
    back.onClick = [this] {
        if (resume)
            resume();
    };
    search.setTextToShowWhenEmpty(localization::translate("Buscar projetos recentes"), theme::secondary);
    search.setFont(theme::font(12));
    search.setBorder(BorderSize<int>(9));
    search.setColour(TextEditor::outlineColourId, Colours::transparentBlack);
    search.onTextChange = [this] { refresh(); };
    recents.setModel(this);
    recents.setRowHeight(56);
    recents.setOutlineThickness(0);
    recents.setMultipleSelectionEnabled(false);
    refresh();
}
void ProjectBrowser::setProjectOpen(bool value) {
    projectOpen = value;
    resized();
}
void ProjectBrowser::selectMode(Mode value) {
    if (loading) return;
    mode = value;
    refresh();
    resized();
    repaint();
}
void ProjectBrowser::beginLoading(const File &file) {
    if (loading) return;
    loading = true;
    cancelLoadingAction = {};
    mode = opening;
    loadingError.setText({}, dontSendNotification);
    loadingStatus.setText(localization::translate(String::fromUTF8("Carregando projeto…")), dontSendNotification);
    // Preserve the recent list and its selected row throughout preparation.
    // A file chosen through Browse can still show progress without being added
    // to Recents until it has opened successfully.
    for (int row = 0; row < filtered.size(); ++row)
        if (File(filtered[row]) == file) {
            recents.selectRow(row);
            break;
        }
    updateEnabled();
    startTimerHz(24);
    resized();
    repaint();
}
void ProjectBrowser::setLoadingCancellation(std::function<void()> action) {
    cancelLoadingAction = loading ? std::move(action) : std::function<void()>{};
    cancelLoading.setButtonText(localization::translate("Cancelar"));
    updateEnabled();
    resized();
}
void ProjectBrowser::updateLoading(const String &status) {
    if (loading) loadingStatus.setText(localization::translate(status), dontSendNotification);
}
void ProjectBrowser::finishLoading(const String &error) {
    loading = false;
    cancelLoadingAction = {};
    stopTimer();
    loadingStatus.setText({}, dontSendNotification);
    loadingError.setText(error, dontSendNotification);
    updateEnabled();
    resized();
    repaint();
}
void ProjectBrowser::updateEnabled() {
    for (auto *button : {&create, &add, &recent, &empty, &stems, &reaper,
                         &logic, &recording, &package, &back})
        button->setEnabled(!loading);
    browseButton.setEnabled(!loading);
    cancelLoading.setEnabled(!loading || (bool)cancelLoadingAction);
    search.setEnabled(!loading);
    recents.setEnabled(!loading);
}
void ProjectBrowser::refresh() {
    for (auto *button : {&create, &add, &recent, &empty, &stems, &reaper, &logic, &recording, &package, &back})
        button->setButtonText(localization::translate(button->getName()));
    browseButton.setButtonText(localization::translate(String::fromUTF8("Browse…")));
    search.setTextToShowWhenEmpty(localization::translate("Search recent projects"), theme::secondary);
    filtered.clear();
    for (auto &path : RecentProjects::read())
        if (search.getText().trim().isEmpty() || path.containsIgnoreCase(search.getText().trim()))
            filtered.add(path);
    recents.updateContent();
    if (mode == opening) refreshStorage();
    repaint();
}
void ProjectBrowser::refreshStorage() {
    StringArray pending;
    const auto now = Time::getMillisecondCounterHiRes();
    for (const auto &path : filtered) {
        const auto cached = storageSizes.find(path);
        if (!storagePending.count(path) && (cached == storageSizes.end() || now - cached->second.first > 30000)) {
            storagePending.insert(path); pending.add(path);
        }
    }
    if (pending.isEmpty()) return;
    const SafePointer<ProjectBrowser> safe(this);
    const auto cancelled = storageCancelled;
    Thread::launch([safe, cancelled, pending] {
        for (const auto &path : pending) {
            if (cancelled->load()) return;
            String size = String::fromUTF8("—");
            try { size = recentProjectStorageDescription(recentProjectStorageBytes(File(path))); } catch (...) {}
            MessageManager::callAsync([safe, cancelled, path, size] {
                if (cancelled->load() || !safe) return;
                safe->storagePending.erase(path);
                safe->storageSizes[path] = {Time::getMillisecondCounterHiRes(), size};
                safe->recents.repaint();
            });
        }
    });
}
void ProjectBrowser::paint(Graphics &g) {
    g.fillAll(theme::background);
    g.setColour(Colours::white);
    g.setFont(theme::font(18, true));
    g.drawText("CatLive", 24, 24, getWidth() - 48, 20, Justification::centredLeft);
    if (mode == opening) {
        g.setFont(theme::font(11));
        g.setColour(theme::secondary);
        g.drawText(localization::translate("Projetos recentes"), 24, 114, getWidth() - 150, 24, Justification::centredLeft);
        if (filtered.isEmpty())
            g.drawText(localization::translate("Nenhum projeto recente encontrado."), 24, 202, getWidth() - 48, 24,
                       Justification::centredLeft);
    }
    if (loading)
        getLookAndFeel().drawSpinningWaitAnimation(g, theme::secondary,
            spinnerBounds.getX(), spinnerBounds.getY(), spinnerBounds.getWidth(), spinnerBounds.getHeight());
}
void ProjectBrowser::resized() {
    int width = getWidth() - 48, cell = (width - 20) / 3;
    create.setBounds(24, 60, cell, 38);
    add.setBounds(34 + cell, 60, cell, 38);
    recent.setBounds(44 + 2 * cell, 60, width - 2 * cell - 20, 38);
    stems.setVisible(mode == creating || mode == adding);
    empty.setVisible(mode == creating);
    package.setVisible(mode == adding);
    reaper.setVisible(mode == creating);
    logic.setVisible(mode == creating);
    recording.setVisible(mode == creating);
    // ProjectBrowserView on macOS: three creation choices, then two imports.
    // These inner HStacks use an 8-point gap; the top navigation uses 10.
    if (mode == creating) {
        const int creationWidth = (width - 16) / 3;
        stems.setBounds(24, 114, creationWidth, 38);
        empty.setBounds(32 + creationWidth, 114, creationWidth, 38);
        recording.setBounds(40 + 2 * creationWidth, 114, width - 2 * creationWidth - 16, 38);
        const int importWidth = (width - 8) / 2;
        reaper.setBounds(24, 160, importWidth, 38);
        logic.setBounds(32 + importWidth, 160, width - importWidth - 8, 38);
    } else if (mode == adding) {
        const int optionWidth = (width - 10) / 2;
        stems.setBounds(24, 114, optionWidth, 38);
        package.setBounds(34 + optionWidth, 114, width - optionWidth - 10, 38);
    }
    browseButton.setVisible(mode == opening);
    search.setVisible(mode == opening);
    recents.setVisible(mode == opening);
    browseButton.setBounds(getWidth() - 100, 114, 76, 24);
    search.setBounds(24, 148, width, 35);
    const bool hasError = loadingError.getText().isNotEmpty();
    const int statusHeight = loading ? 60 : hasError ? 44 : 0;
    const int contentBottom = projectOpen ? getHeight() - 64 : getHeight() - 24;
    const int listHeight = std::min(170, std::max(0, contentBottom - 193 - statusHeight));
    recents.setBounds(24, 193, width, listHeight);
    const int statusY = recents.getBottom() + 10;
    const bool canCancel = loading && (bool)cancelLoadingAction;
    spinnerBounds = {getWidth() / 2 - 10, statusY, 20, 20};
    loadingStatus.setJustificationType(Justification::centred);
    loadingStatus.setBounds(24, statusY + 26, width, 22);
    cancelLoading.setBounds(getWidth() - 104, statusY - 2, 80, 24);
    cancelLoading.setVisible(canCancel);
    loadingError.setBounds(24, statusY, width, 34);
    loadingStatus.setVisible(loading);
    loadingError.setVisible(hasError);
    back.setVisible(projectOpen);
    back.setBounds(24, getHeight() - 52, 150, 28);
}
void ProjectBrowser::paintListBoxItem(int row, Graphics &g, int width, int height, bool selected) {
    if (!isPositiveAndBelow(row, filtered.size()))
        return;
    File file(filtered[row]);
    g.setColour(selected ? theme::panel.darker(.12f) : theme::panel);
    g.fillRect(0, 0, width, height - 6);
    g.setColour(selected ? Colours::white.darker(.18f) : Colours::white);
    g.setFont(theme::font(14, true));
    const auto cached = storageSizes.find(filtered[row]);
    const auto size = cached == storageSizes.end() ? String::fromUTF8("…") : cached->second.second;
    const int sizeWidth = (int)std::ceil(GlyphArrangement::getStringWidth(theme::font(11), size)) + 12;
    g.drawText(file.getFileNameWithoutExtension(), 10, 6, std::max(0, width - 40 - sizeWidth), 19,
               Justification::centredLeft);
    g.setColour(theme::secondary);
    g.setFont(theme::font(11));
    g.drawText(size, width - 30 - sizeWidth, 6, sizeWidth, 19, Justification::centredRight);
    g.setFont(theme::font(10));
    g.drawText(file.getParentDirectory().getFullPathName(), 10, 26, width - 40, 17,
               Justification::centredLeft);
    Path chevron;
    chevron.startNewSubPath((float)width - 20, 19);
    chevron.lineTo((float)width - 15, 24);
    chevron.lineTo((float)width - 20, 29);
    g.strokePath(chevron, PathStrokeType(1.3f));
}
void ProjectBrowser::returnKeyPressed(int row) {
    if (loading) return;
    if (isPositiveAndBelow(row, filtered.size()) && open)
        open(File(filtered[row]));
}
void ProjectBrowser::listBoxItemClicked(int row, const MouseEvent &event) {
    if (loading || !isPositiveAndBelow(row, filtered.size()))
        return;
    if (!event.mods.isPopupMenu()) {
        returnKeyPressed(row);
        return;
    }
    File file(filtered[row]);
    PopupMenu menu;
    const bool missing=!file.existsAsFile();
    if (projectOpen && !missing && openInNewTab)
        menu.addItem(2,localization::translate("Open in new tab"));
    menu.addItem(1,localization::translate(missing?"Remove from recents":"Delete project"));
    const auto position = event.getScreenPosition();
    menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&recents)
                           .withTargetScreenArea({position.x, position.y, 1, 1}),[safe=Component::SafePointer<ProjectBrowser>(this),file,missing](int result){
        if(!safe || safe->loading)return;
        if(result==2){if(safe->projectOpen && file.existsAsFile() && safe->openInNewTab)safe->openInNewTab(file);return;}
        if(result!=1)return;
        if(missing){RecentProjects::forget(file);safe->refresh();}
        else if(safe->deleteProject)safe->deleteProject(file);
    });
}
} // namespace catlive
