#pragma once
#include "Localization.h"
#include "MultitrackExport.h"
#include "Session.h"
#include "ModalSheet.h"

namespace catlive {
class MultitrackExportPanel final : public Component, private Timer {
public:
    MultitrackExportPanel(Session &owner, std::vector<MultitrackExportProject> initial, const ID &active)
        : session(owner), projects(std::move(initial)), progressBar(progressValue) {
        for (auto *control : std::initializer_list<Component *>{&tabs, &destination, &browse, &checkAll, &uncheckAll,
                &mutedTracks, &mutedItems, &foldersTitle, &viewport, &status, &progressBar, &close, &exportButton})
            addAndMakeVisible(*control);
        tabs.setViewedComponent(&tabContent, false);
        tabs.setScrollBarsShown(false, projects.size() > 4);
        tabs.setScrollBarThickness(5);
        tabs.getHorizontalScrollBar().setColour(ScrollBar::thumbColourId, theme::green);
        tabs.getHorizontalScrollBar().setColour(ScrollBar::trackColourId, theme::line);
        viewport.setViewedComponent(&regions, false);
        viewport.setScrollBarsShown(true, false);
        destination.setTextToShowWhenEmpty(localization::translate("Destination"), theme::secondary);
        foldersTitle.setText(localization::translate("Region folders"), dontSendNotification);
        status.setJustificationType(Justification::centredLeft);
        for (int i = 0; i < int(projects.size()); ++i) {
            auto *tab = tabButtons.add(new TextButton(text(projects[i].project.name)));
            tab->setTooltip(text(projects[i].project.name));
            tab->setColour(TextButton::buttonOnColourId, theme::green);
            tab->setColour(TextButton::textColourOnId, Colours::black);
            tab->onClick = [this, i] { index = i; refresh(); };
            tabContent.addAndMakeVisible(*tab);
            if (projects[i].tab == active) index = i;
        }
        tabs.setVisible(projects.size() > 1);
        destination.onTextChange = [this] {
            auto path = destination.getText().trim();
            config().destination = File::isAbsolutePath(path) ? File(path) : File{};
            updateExportButton();
        };
        checkAll.onClick = [this] { selectRegions(true); };
        uncheckAll.onClick = [this] { selectRegions(false); };
        mutedTracks.onClick = [this] { config().ignoreMutedTracks = mutedTracks.getToggleState(); };
        mutedItems.onClick = [this] { config().ignoreMutedItems = mutedItems.getToggleState(); };
        browse.onClick = [this] { chooseDirectory(); };
        close.onClick = [this] { if (started && session.busy) session.cancelExport(); else ModalSheet::dismiss(*this); };
        exportButton.onClick = [this] {
            try {
                const SafePointer<MultitrackExportPanel> safe(this);
                session.exportMultitrack(projects, [safe] {
                    if (!safe) return;
                    ModalSheet::blockDismiss(*safe, false);
                    ModalSheet::dismiss(*safe);
                });
                started = session.busy;
                if (started) { timerCallback(); startTimerHz(12); }
            } catch (const std::exception &error) { status.setText(String::fromUTF8(error.what()), dontSendNotification); }
        };
        exportButton.setColour(TextButton::buttonColourId, theme::green);
        progressBar.setVisible(false);
        refresh();
    }
    ~MultitrackExportPanel() override { tabs.setViewedComponent(nullptr, false); viewport.setViewedComponent(nullptr, false); }
    void resized() override {
        auto bounds = getLocalBounds().reduced(18);
        if (tabs.isVisible()) {
            const int count = std::min(4, tabButtons.size());
            const int width = std::max(1, (bounds.getWidth() - 4 * (count - 1)) / count);
            tabs.setBounds(bounds.removeFromTop(projects.size() > 4 ? 35 : 28));
            tabContent.setSize(tabButtons.size() * (width + 4) - 4, 28);
            for (int i = 0; i < tabButtons.size(); ++i) tabButtons[i]->setBounds(i * (width + 4), 0, width, 28);
            tabs.setViewPosition(std::max(0, index - 3) * (width + 4), 0);
            bounds.removeFromTop(10);
        }
        auto path = bounds.removeFromTop(28);
        browse.setBounds(path.removeFromRight(104));
        destination.setBounds(path.withTrimmedRight(8));
        bounds.removeFromTop(8);
        for (auto *toggle : {&mutedTracks, &mutedItems}) toggle->setBounds(bounds.removeFromTop(28));
        auto header = bounds.removeFromTop(27);
        uncheckAll.setBounds(header.removeFromRight(124));
        header.removeFromRight(6);
        checkAll.setBounds(header.removeFromRight(104));
        foldersTitle.setBounds(header);
        auto buttons = bounds.removeFromBottom(30);
        close.setBounds(buttons.removeFromLeft(104));
        exportButton.setBounds(buttons.removeFromRight(104));
        status.setBounds(bounds.removeFromBottom(36));
        progressBar.setBounds(bounds.removeFromBottom(9));
        viewport.setBounds(bounds.reduced(0, 4));
        layoutRegions();
    }
    void paint(Graphics &g) override { g.fillAll(theme::panel); }
private:
    Session &session;
    std::vector<MultitrackExportProject> projects;
    Viewport tabs;
    Component tabContent;
    OwnedArray<TextButton> tabButtons;
    TextEditor destination;
    TextButton browse{localization::translate("Browse…")}, close{localization::translate("Close")}, exportButton{localization::translate("Export")};
    TextButton checkAll{localization::translate("Check all")}, uncheckAll{localization::translate("Uncheck all")};
    ToggleButton mutedTracks{localization::translate("Ignore muted tracks")},
                 mutedItems{localization::translate("Ignore muted items")};
    Label foldersTitle, status;
    Viewport viewport;
    Component regions;
    OwnedArray<ToggleButton> regionButtons;
    std::unique_ptr<FileChooser> picker;
    double progressValue = 0;
    ProgressBar progressBar;
    int index = 0;
    bool started = false;

    MultitrackExportProject &config() { return projects[static_cast<size_t>(index)]; }
    void updateExportButton() {
        const bool selected = std::any_of(projects.begin(), projects.end(), [](const auto &p) { return !p.selection.empty(); });
        const bool ready = std::all_of(projects.begin(), projects.end(), [](const auto &p) { return p.selection.empty() || p.destination.isDirectory(); });
        exportButton.setEnabled(selected && ready && !session.busy);
        checkAll.setEnabled(!session.busy && config().selection.size() < static_cast<size_t>(regionButtons.size()));
        uncheckAll.setEnabled(!session.busy && !config().selection.empty());
    }
    void selectRegions(bool selected) {
        auto &current = config();
        current.selection.clear();
        if (selected)
            for (const auto &part : current.song.parts)
                if (multitrackExport::rootRegion(part)) current.selection.insert(part.id);
        for (auto *row : regionButtons) row->setToggleState(selected, dontSendNotification);
        updateExportButton();
    }
    void refresh() {
        for (int i = 0; i < tabButtons.size(); ++i) tabButtons[i]->setToggleState(i == index, dontSendNotification);
        destination.setText(config().destination.getFullPathName(), false);
        mutedTracks.setToggleState(config().ignoreMutedTracks, dontSendNotification);
        mutedItems.setToggleState(config().ignoreMutedItems, dontSendNotification);
        refreshRegions();
    }
    void refreshRegions() {
        regionButtons.clear();
        auto &current = config();
        std::vector<const jaras::Part *> parts;
        for (const auto &part : current.song.parts)
            if (multitrackExport::rootRegion(part)) parts.push_back(&part);
        std::stable_sort(parts.begin(), parts.end(), [](auto *a, auto *b) { return a->startTime < b->startTime; });
        for (const auto *part : parts) {
            auto name = multitrackExport::safeName(timelineRegionLabels::displayName(*part));
            auto *row = regionButtons.add(new ToggleButton(name));
            row->setToggleState(current.selection.count(part->id) != 0, dontSendNotification);
            row->onClick = [this, id = part->id, row] {
                if (row->getToggleState()) config().selection.insert(id);
                else config().selection.erase(id);
                updateExportButton();
            };
            regions.addAndMakeVisible(*row);
        }
        layoutRegions();
        updateExportButton();
    }
    void layoutRegions() {
        const auto width = std::max(1, viewport.getWidth() - viewport.getScrollBarThickness());
        regions.setSize(width, std::max(viewport.getHeight(), regionButtons.size() * 27));
        for (int i = 0; i < regionButtons.size(); ++i) regionButtons[i]->setBounds(0, i * 27, width, 27);
    }
    void chooseDirectory() {
        picker = std::make_unique<FileChooser>(localization::translate("Destination"), config().destination);
        picker->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectDirectories,
            [safe = SafePointer<MultitrackExportPanel>(this), tab = index](const FileChooser &dialog) {
                if (!safe || !dialog.getResult().isDirectory()) return;
                safe->projects[static_cast<size_t>(tab)].destination = dialog.getResult();
                safe->refresh();
            });
    }
    void timerCallback() override {
        const bool running = session.busy;
        ModalSheet::blockDismiss(*this, running);
        for (auto *c : std::initializer_list<Component *>{&tabs, &destination, &browse, &checkAll, &uncheckAll, &mutedTracks, &mutedItems, &viewport})
            c->setEnabled(!running);
        progressValue = session.importProgress;
        progressBar.setVisible(running);
        progressBar.repaint();
        status.setText(session.message, dontSendNotification);
        close.setButtonText(localization::translate(running ? "Cancel" : "Close"));
        updateExportButton();
        if (!running) { started = false; stopTimer(); }
    }
};
} // namespace catlive
