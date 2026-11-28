#pragma once
#include "ConfirmationPanel.h"
#include "DragDivider.h"
#include "DesktopToolbarSymbols.h"
#include "FXPresets.h"
#include "ExternalMediaDrop.h"
#include "GridMediaClipboard.h"
#include "MIDIItemExport.h"
#include "Instrument.h"
#include "InterfaceIcons.h"
#include "InlineMixerTrackName.h"
#include "LibraryNoteEditor.h"
#include "LibraryMIDIChords.h"
#include "MixerPanel.h"
#include "TimelineRegionLabels.h"
#include "VinhetasPanel.h"
#include "VST3Catalog.h"
#include <iterator>

namespace catlive {
inline void styleLibraryScrollbar(Viewport &viewport) {
    static MixerScrollLook look;
    viewport.setScrollBarThickness(10);
    viewport.getVerticalScrollBar().setLookAndFeel(&look);
}

class WorkspaceFilesPane final : public Component {
    struct Entry { File file; String name; bool folder, volume; };
    using Path = std::vector<File>;

    class Rows final : public ListBoxModel {
    public:
        Rows(WorkspaceFilesPane &pane, bool left) : owner(pane), parent(left) {}
        int getNumRows() override { return int(entries().size()); }
        String getNameForRow(int row) override {
            const auto *entry = at(row);
            return entry ? entry->name : String{};
        }
        void paintListBoxItem(int row, Graphics &g, int width, int height, bool selected) override {
            const auto *entry = at(row);
            if (!entry) return;
            const bool highlighted = selected || (parent && !owner.path.empty() && owner.path.back() == entry->file);
            if (highlighted || row % 2 == 0) {
                g.setColour(highlighted ? theme::green.withAlpha(.26f) : theme::display);
                g.fillRoundedRectangle(1.f, 1.f, float(width - 2), float(height - 2), 4.f);
            }
            const float middle = height * .5f;
            g.setColour(entry->folder ? theme::green : theme::secondary);
            drawDesktopToolbarSymbol(g, entry->volume ? "externaldrive" : entry->folder ? "library.file-folder" : "doc",
                                     {8.f, middle - 7.f, 14.f, 14.f});
            g.setColour(Colours::white);
            g.setFont(theme::font(12));
            g.drawText(entry->name, 28, 0, std::max(0, width - 43), height, Justification::centredLeft, true);
            if (entry->folder) {
                g.setColour(theme::secondary);
                drawDesktopToolbarSymbol(g, "chevron.right", {float(width - 15), middle - 5.f, 10.f, 10.f});
            }
        }
        void listBoxItemClicked(int row, const MouseEvent &event) override {
            if (owner.columns && !event.mods.isPopupMenu()) open(row);
        }
        void listBoxItemDoubleClicked(int row, const MouseEvent &event) override {
            if (!owner.columns && !event.mods.isPopupMenu()) open(row);
        }
        void returnKeyPressed(int row) override { open(row); }
        var getDragSourceDescription(const SparseSet<int> &rows) override {
            const auto *entry = rows.size() == 1 ? at(rows[0]) : nullptr;
            if (!entry || entry->folder) return {};
            const bool audio = entry->file.hasFileExtension("wav;wave;aif;aiff;flac;mp3;ogg;m4a;aac");
            if (!audio && !externalMedia::supported(entry->file) && !entry->file.hasFileExtension("jl;bkjl;ziplive;jllyrics"))
                return {};
            auto data = object();
            put(data, "type", audio ? "catlive-library-sampler" : "catlive-library-media");
            put(data, "file", entry->file.getFullPathName());
            return data;
        }
    private:
        WorkspaceFilesPane &owner;
        bool parent;
        const std::vector<Entry> &entries() const { return parent ? owner.parentEntries : owner.filtered; }
        const Entry *at(int row) const {
            return isPositiveAndBelow(row, int(entries().size())) ? &entries()[size_t(row)] : nullptr;
        }
        void open(int row) {
            const auto *entry = at(row);
            if (!entry || !entry->folder) return;
            auto destination = owner.path;
            if (parent && !destination.empty()) destination.pop_back();
            destination.push_back(entry->file);
            owner.navigate(std::move(destination));
        }
    };

public:
    WorkspaceFilesPane() {
        configure(back, "Back", "chevron.left", [this] { goBack(); });
        configure(forward, "Forward", "chevron.right", [this] { goForward(); });
        configure(locations, "Locations", "externaldrive", [this] { navigate({}); });
        configure(home, "Home folder", "house",
                  [this] { navigate({File::getSpecialLocation(File::userHomeDirectory)}); });
        configure(documents, "Documents folder", "doc",
                  [this] { navigate({File::getSpecialLocation(File::userDocumentsDirectory)}); });
        configure(listView, "List view", "setlist", [this] { setColumns(false); });
        configure(columnView, "Column view", "rectangle.split.2x1", [this] { setColumns(true); });
        configure(refreshButton, "Refresh folders", "refresh", [this] { refresh(); });
        configure(choose, "Choose folder", "folder.badge.plus", [this] { chooseFolder(); });
        for (auto *button : {&listView, &columnView}) {
            button->setColour(TextButton::buttonOnColourId, theme::green);
            button->setColour(TextButton::textColourOnId, Colours::black);
        }
        addAndMakeVisible(breadcrumb);
        breadcrumb.setViewedComponent(&pathContent, false);
        breadcrumb.setScrollBarsShown(false, false, false, true);
        breadcrumb.setScrollOnDragMode(Viewport::ScrollOnDragMode::all);
        addAndMakeVisible(search);
        search.setTitle(localization::translate("Search files"));
        search.setTextToShowWhenEmpty(search.getTitle(), theme::secondary);
        search.setIndents(22, 4);
        search.setBorder(BorderSize<int>(1, 2, 1, 22));
        configure(clearSearch, "Clear search", "xmark.circle.fill", [this] { search.clear(); });
        clearSearch.setVisible(false);
        search.onTextChange = [this] { applySearch(); };
        addAndMakeVisible(list);
        addAndMakeVisible(parentList);
        addChildComponent(status);
        status.setFont(theme::font(11));
        status.setJustificationType(Justification::centred);
        for (auto *box : {&list, &parentList}) {
            box->setRowHeight(25);
            box->setColour(ListBox::backgroundColourId, Colours::transparentBlack);
            styleLibraryScrollbar(*box->getViewport());
        }
        setColumns(true);
        updatePath();
    }
    ~WorkspaceFilesPane() override {
        list.setModel(nullptr);
        parentList.setModel(nullptr);
        breadcrumb.setViewedComponent(nullptr, false);
    }

    void refresh() {
        const auto request = ++revision;
        const auto currentPath = path;
        const auto savedLocations = additionalLocations;
        const auto folder = currentPath.empty() ? File{} : currentPath.back();
        const auto parentFolder = currentPath.size() < 2 ? File{} : currentPath[currentPath.size() - 2];
        loading = true;
        unavailable = false;
        entries.clear();
        parentEntries.clear();
        updatePath();
        applySearch();
        parentList.updateContent();
        static ThreadPool worker(3);
        worker.addJob([safe = SafePointer<WorkspaceFilesPane>(this), request, folder, parentFolder,
                       showParent = !currentPath.empty(), savedLocations] {
            const bool valid = folder == File{} || folder.isDirectory();
            auto result = browse(folder, savedLocations);
            auto parent = showParent ? browse(parentFolder, savedLocations) : std::vector<Entry>{};
            MessageManager::callAsync([safe, request, valid, result = std::move(result), parent = std::move(parent)]() mutable {
                if (!safe || request != safe->revision) return;
                safe->loading = false;
                safe->unavailable = !valid;
                safe->entries = std::move(result);
                safe->parentEntries = std::move(parent);
                safe->parentList.updateContent();
                if (!safe->parentEntries.empty()) safe->parentList.scrollToEnsureRowIsOnscreen(0);
                safe->applySearch();
                if (!safe->filtered.empty()) safe->list.scrollToEnsureRowIsOnscreen(0);
                safe->updatePath();
            });
        });
    }

    void resized() override {
        auto area = getLocalBounds();
        auto bar = area.removeFromTop(33).reduced(6, 4);
        for (auto *button : {&back, &forward, &locations, &home, &documents}) {
            button->setBounds(bar.removeFromLeft(std::min(bar.getWidth(), 25)));
            bar.removeFromLeft(button == &forward ? 5 : 2);
        }
        columnView.setBounds(bar.removeFromRight(std::min(bar.getWidth(), 25)));
        bar.removeFromRight(2);
        listView.setBounds(bar.removeFromRight(std::min(bar.getWidth(), 25)));
        breadcrumb.setBounds(area.removeFromTop(24).reduced(6, 0));
        auto find = area.removeFromTop(35).reduced(6, 4);
        choose.setBounds(find.removeFromRight(25));
        find.removeFromRight(3);
        refreshButton.setBounds(find.removeFromRight(25));
        find.removeFromRight(3);
        search.setBounds(find);
        clearSearch.setBounds(find.removeFromRight(22));
        area.reduce(5, 1);
        const bool showParent = columns && !path.empty();
        parentList.setVisible(showParent);
        if (showParent) {
            parentList.setBounds(area.removeFromLeft(area.getWidth() / 2));
            area.removeFromLeft(3);
        }
        list.setBounds(area);
        status.setBounds(area);
    }

    void paint(Graphics &g) override {
        g.setColour(theme::display);
        g.fillRoundedRectangle(breadcrumb.getBounds().toFloat(), 5.f);
        g.fillRoundedRectangle(back.getBounds().getUnion(forward.getBounds()).toFloat(), 5.f);
        g.fillRoundedRectangle(listView.getBounds().getUnion(columnView.getBounds()).toFloat(), 5.f);
        if (parentList.isVisible()) {
            g.setColour(theme::line);
            g.drawVerticalLine(parentList.getRight() + 1, float(parentList.getY()), float(parentList.getBottom()));
        }
    }

    void paintOverChildren(Graphics &g) override {
        const auto area = search.getBounds().toFloat().removeFromLeft(22.f);
        g.setColour(theme::secondary);
        drawDesktopToolbarSymbol(g, "search", area.withSizeKeepingCentre(13.f, 13.f));
    }

private:
    std::vector<Entry> entries, filtered, parentEntries;
    Path path, additionalLocations;
    std::vector<Path> past, future;
    uint64 revision = 0;
    bool columns = true, loading = false, unavailable = false;
    TextButton back, forward, locations, home, documents, listView, columnView, refreshButton, choose, clearSearch;
    Viewport breadcrumb;
    Component pathContent;
    OwnedArray<TextButton> crumbs;
    TextEditor search;
    Label status;
    Rows currentRows{*this, false}, parentRows{*this, true};
    ListBox list{"Files", &currentRows}, parentList{"Folders", &parentRows};
    std::unique_ptr<FileChooser> picker;

    void configure(TextButton &button, const char *title, const char *symbol, std::function<void()> action) {
        addAndMakeVisible(button);
        button.setTitle(localization::translate(title));
        button.setTooltip(button.getTitle());
        button.getProperties().set("icon", symbol);
        button.getProperties().set("iconSize", 14.f);
        button.getProperties().set("transportDrawing", true);
        button.getProperties().set("plain", true);
        button.onClick = std::move(action);
    }
    void setColumns(bool enabled) {
        columns = enabled;
        listView.setToggleState(!enabled, dontSendNotification);
        columnView.setToggleState(enabled, dontSendNotification);
        resized();
        repaint();
    }
    void navigate(Path destination) {
        if (path == destination) return;
        past.push_back(path);
        if (past.size() > 64) past.erase(past.begin());
        future.clear();
        setPath(std::move(destination));
    }
    void goBack() {
        if (past.empty()) return;
        future.push_back(path);
        auto destination = std::move(past.back());
        past.pop_back();
        setPath(std::move(destination));
    }
    void goForward() {
        if (future.empty()) return;
        past.push_back(path);
        auto destination = std::move(future.back());
        future.pop_back();
        setPath(std::move(destination));
    }
    void setPath(Path destination) {
        path = std::move(destination);
        search.clear();
        list.deselectAllRows();
        parentList.deselectAllRows();
        resized();
        refresh();
    }
    void chooseFolder() {
        picker = std::make_unique<FileChooser>(localization::translate("Choose folder"),
            path.empty() ? File::getSpecialLocation(File::userDocumentsDirectory) : path.back());
        picker->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectDirectories,
            [safe = SafePointer<WorkspaceFilesPane>(this)](const FileChooser &source) {
                if (!safe) return;
                const auto selected = source.getResult();
                if (selected == File{}) return;
                if (std::find(safe->additionalLocations.begin(), safe->additionalLocations.end(), selected) == safe->additionalLocations.end())
                    safe->additionalLocations.push_back(selected);
                safe->navigate({selected});
            });
    }
    void updatePath() {
        back.setEnabled(!past.empty());
        forward.setEnabled(!future.empty());
        const int count = int(path.size()) + 1;
        // Keep the pressed breadcrumb alive until its callback has returned.
        while (crumbs.size() < count) {
            auto *button = crumbs.add(new TextButton());
            button->getProperties().set("plain", true);
            button->getProperties().set("centredIconLabel", true);
            button->getProperties().set("transportDrawing", true);
            button->getProperties().set("fontSize", 11.f);
            pathContent.addAndMakeVisible(*button);
            const int index = crumbs.size() - 1;
            button->onClick = [this, index] {
                if (index <= int(path.size())) navigate(Path(path.begin(), path.begin() + index));
            };
        }
        int x = 2;
        const auto font = theme::semiboldFont(11);
        for (int index = 0; index < crumbs.size(); ++index) {
            auto &button = *crumbs[index];
            button.setVisible(index < count);
            if (!button.isVisible()) continue;
            const auto title = index == 0 ? localization::translate("Locations") : displayName(path[size_t(index - 1)]);
            button.getProperties().set("leadingIcon", index == 0 ? "externaldrive" : "chevron.right");
            button.setButtonText(title);
            button.setTooltip(index == 0 ? title : path[size_t(index - 1)].getFullPathName());
            const auto width = int(std::ceil(GlyphArrangement::getStringWidth(font, title))) + 24;
            button.setBounds(x, 0, width, 24);
            x += width;
        }
        pathContent.setSize(x, 24);
        breadcrumb.setViewPosition(std::max(0, x - breadcrumb.getWidth()), 0);
        repaint();
    }
    void applySearch() {
        const auto term = search.getText().trim();
        clearSearch.setVisible(search.getText().isNotEmpty());
        filtered.clear();
        std::copy_if(entries.begin(), entries.end(), std::back_inserter(filtered), [&](const Entry &entry) {
            return term.isEmpty() || entry.name.containsIgnoreCase(term);
        });
        list.updateContent();
        const auto key = loading ? "Loading" : unavailable ? "Folder unavailable" :
            term.isEmpty() ? "Empty folder" : "No matching files";
        status.setText(localization::translate(key), dontSendNotification);
        status.setVisible(filtered.empty());
    }
    static String displayName(const File &file) {
        const auto name = file.getFileName();
        return name.isEmpty() ? file.getFullPathName() : name;
    }
    static std::vector<Entry> browse(const File &folder, const Path &additional) {
        std::vector<Entry> result;
        if (folder == File{}) {
            Array<File> volumes;
            File::findFileSystemRoots(volumes);
            for (const auto &volume : volumes) {
                const auto label = volume.getVolumeLabel(), prefix = volume.getFullPathName();
                result.push_back({volume, label.isEmpty() ? prefix : label + " (" + prefix + ")", true, true});
            }
            const auto add = [&](const File &shortcut) {
                if (shortcut.isDirectory() && std::none_of(result.begin(), result.end(),
                    [&](const Entry &entry) { return entry.file == shortcut; }))
                    result.push_back({shortcut, displayName(shortcut), true, false});
            };
            for (auto location : {File::userHomeDirectory, File::userDesktopDirectory, File::userDocumentsDirectory})
                add(File::getSpecialLocation(location));
            add(File::getSpecialLocation(File::userHomeDirectory).getChildFile("Downloads"));
            for (const auto &shortcut : additional) add(shortcut);
        } else if (folder.isDirectory()) {
            for (const auto &item : RangedDirectoryIterator(folder, false, "*", File::findFilesAndDirectories | File::ignoreHiddenFiles)) {
                const auto file = item.getFile();
                if (!item.isDirectory() && !externalMedia::supported(file) &&
                    !file.hasFileExtension("jl;bkjl;ziplive;jllyrics;mid;midi;sf2;rpp")) continue;
                result.push_back({file, file.getFileName(), item.isDirectory(), false});
            }
            std::sort(result.begin(), result.end(), [](const auto &left, const auto &right) {
                return left.folder != right.folder ? left.folder : left.name.compareNatural(right.name) < 0;
            });
        }
        return result;
    }
};

class WorkspaceLibrary final : public Component, public FileDragAndDropTarget, private Timer {
    friend struct WorkspaceLibraryTestAccess;
    struct SharedSettings {
        var value;
        uint64 revision = 0;
        std::set<String> importingCategories;
        ID timelineSong;
        String selectedRegion;
        String selectedMarker;
    };
  public:
    enum class Presentation { library, notes, samplers };
    static constexpr int minimumDetailsWidth = 140;
    static constexpr int minimumPanelWidth = 90 + 1 + minimumDetailsWidth;
    std::function<void()> openPluginSettings;
    explicit WorkspaceLibrary(Session &owner, WorkspaceLibrary *source = nullptr)
        : session(owner), store(source ? source->store : std::make_shared<SharedSettings>()), settings(store->value) {
        if (!source) {
            settings = JSON::parse(root().getChildFile("Library.json"));
            if (!settings.isObject()) settings = object();
        }
        setComponentID("workspace-library-panel");
        addAndMakeVisible(folders);
        addAndMakeVisible(contents);
        addAndMakeVisible(divider);
        addAndMakeVisible(collapseCategories);
        addChildComponent(picker);
        picker.setTitle("Library categories");
        picker.setTooltip("Library categories");
        picker.getProperties().set("icon", "setlist");
        picker.getProperties().set("transportDrawing", true);
        picker.getProperties().set("flat", true);
        picker.onClick = [this] { openPicker(); };
        addChildComponent(pickerTitle);
        pickerTitle.setFont(theme::semiboldFont(12));
        pickerTitle.setBorderSize({});
        addChildComponent(noteEdit);
        noteEdit.setComponentID("notes-edit-toggle");
        noteEdit.setWantsKeyboardFocus(false);
        noteEdit.setMouseClickGrabsKeyboardFocus(false);
        noteEdit.getProperties().set("flat", true);
        noteEdit.setColour(TextButton::buttonOnColourId, theme::green);
        noteEdit.setColour(TextButton::textColourOnId, Colours::black);
        noteEdit.onClick = [this] { setNoteEditing(!editingNote); };
        syncNoteEditButton();
        const std::array<const char *, 3> titles{"Notes", "Region", "Markers"};
        for (size_t index = 0; index < notesTabs.size(); ++index) {
            auto &tab = notesTabs[index];
            addChildComponent(tab);
            tab.setButtonText(titles[index]);
            tab.getProperties().set("flat", true);
            tab.setColour(TextButton::buttonOnColourId, theme::green);
            tab.setColour(TextButton::textColourOnId, Colours::black);
            tab.onClick = [this, index] { selectNotesTab(index); };
        }
        addChildComponent(filesPane);
        for (size_t index = 0; index < samplerTabs.size(); ++index) {
            auto &tab = samplerTabs[index];
            addChildComponent(tab);
            tab.setButtonText(localization::translate(index == 0 ? "Samplers" : "Files"));
            tab.getProperties().set("flat", true);
            tab.setColour(TextButton::buttonOnColourId, theme::green);
            tab.setColour(TextButton::textColourOnId, Colours::black);
            tab.onClick = [this, index] { selectSamplerTab(index != 0); };
        }
        collapseCategories.getProperties().set("icon", "arrow.up.and.down.text.horizontal");
        collapseCategories.getProperties().set("iconSize", 16.f);
        collapseCategories.getProperties().set("flat", true);
        collapseCategories.setTitle(localization::translate("Collapse all categories"));
        collapseCategories.setTooltip(localization::translate("Collapse all categories"));
        collapseCategories.setComponentID("library-collapse-categories");
        collapseCategories.onClick = [this] {
            expanded.clear();
            rebuildFolders();
            folders.getViewport()->setViewPosition(0, 0);
        };
        addChildComponent(timelineName);
        timelineName.setComponentID("library-timeline-name");
        timelineName.navigate = [this](int direction) {
            const auto &entries = itemRows.entries;
            const int index = timelineNameRow();
            if (index < 0 || !isPositiveAndBelow(index + direction, int(entries.size()))) return;
            const auto next = entries[size_t(index + direction)];
            beginTimelineRename(next);
            navigateTimeline(next, true);
        };
        addChildComponent(search);
        search.onKey = [this](const KeyPress &key) {
            if (key == KeyPress::tabKey) return focusTimelineSearch();
            return stepTimeline(key);
        };
        search.setComponentID("library-category-search");
        search.setTitle(localization::translate("Search"));
        search.setTextToShowWhenEmpty(localization::translate("Search"), theme::secondary);
        search.setFont(theme::font(12));
        search.setIndents(7, 4);
        search.onTextChange = [this] {
            filterEntries();
            contents.getViewport()->setViewPosition(0, 0);
        };
        addChildComponent(previewVolume);
        previewVolume.setComponentID("library-sampler-preview-volume");
        previewVolume.setTitle(localization::translate("Sample preview volume"));
        previewVolume.setSliderStyle(Slider::RotaryVerticalDrag);
        previewVolume.setTextBoxStyle(Slider::NoTextBox, true, 0, 0);
        previewVolume.setRange(-60, 0, 1);
        previewVolume.setDoubleClickReturnValue(true, 0);
        previewVolume.setMouseDragSensitivity(120);
        previewVolume.textFromValueFunction = [](double db) {
            return db <= -60 ? String::fromUTF8("−∞ dB") : String(db, 0) + " dB";
        };
        previewVolume.setValue(num(settings, "samplerPreviewDB"), dontSendNotification);
        previewVolume.onValueChange = [this] {
            put(settings, "samplerPreviewDB", previewVolume.getValue());
            if (!previewingInstrument) session.audio.setLibrarySampleGain(previewGain());
            if (!previewVolume.isMouseButtonDown()) persist();
            repaint(previewDBBounds);
        };
        contents.setColour(ListBox::backgroundColourId, Colours::transparentBlack);
        contents.setOpaque(false);
        contents.setRowHeight(28);
        contents.setRowSelectedOnMouseDown(false);
        styleLibraryScrollbar(*contents.getViewport());
        styleLibraryScrollbar(*folders.getViewport());
        previewVolume.onDragEnd = [this] { persist(); };
        divider.setThinRail(true);
        divider.setScrollRailVisible(false);
        divider.started = [this] { resizeStart = folders.getWidth(); };
        divider.moved = [this](int dx) {
            const int maximum = std::max(0, getWidth() - 1 - minimumDetailsWidth);
            const auto next = jlimit(std::min(90, maximum), maximum, resizeStart + dx);
            if (folderWidth == next) return;
            folderWidth = next;
            resized();
            if (folderWidthChanged) folderWidthChanged();
        };
        divider.ended = [this] { put(settings, "folderWidth", folderWidth); persist(); };
        folderWidth = int(num(settings, "folderWidth", 146));
        rebuildFolders();
    }
    ~WorkspaceLibrary() override { stopPreview(); }
    std::function<void()> folderWidthChanged;
    std::function<void(const ID &, bool, double)> selectTimelineEntry;
    std::function<void()> openTimelineTab;
    std::function<void()> openLibraryTimeline;
    std::function<void()> timelineSelectionChanged;
    void refreshTimelineSelection() {
        if (!isVisible() || !timelineCategory()) return;
        if (timelineName.isVisible() && editingTimelineKey != selectedTimelineKey()) timelineName.confirm();
        contents.repaint();
    }
    int maximumPanelWidth() const { return std::max(90, folderWidth) + 1 + 364; }
    void showCollection(Presentation requested) {
        if (presentation == requested) return;
        presentation = requested;
        folders.setVisible(requested == Presentation::library);
        collapseCategories.setVisible(requested == Presentation::library);
        divider.setVisible(requested == Presentation::library);
        for (auto &tab : notesTabs) tab.setVisible(requested == Presentation::notes);
        for (auto &tab : samplerTabs) tab.setVisible(requested == Presentation::samplers);
        filesPane.setVisible(false);
        if (requested == Presentation::notes) {
            selectNotesTab(0);
            return;
        }
        picker.setVisible(requested != Presentation::library);
        pickerTitle.setVisible(requested != Presentation::library);
        const auto rows = pickerRows();
        select(rows.empty() ? Row{} : rows.front());
        if (requested == Presentation::samplers) selectSamplerTab(filesSelected, true);
    }
    bool focusTimelineSearch() {
        if (!showingTimeline() || !search.isVisible()) return false;
        search.grabKeyboardFocus();
        return true;
    }
    bool showingTimeline() const { return isShowing() && timelineCategory(); }
    void showNotesTab() {
        if (presentation == Presentation::notes && timelineCategory()) selectNotesTab(0);
    }
    void clearTimelineCategory() {
        if (presentation == Presentation::library && timelineCategory()) select(Row{});
    }
    bool isInterestedInFileDrag(const StringArray &files) override {
        if (filesPane.isVisible()) return false;
        return !importing && std::any_of(files.begin(), files.end(), [](const String &path) {
            return File(path).hasFileExtension("wav;wave;aif;aiff;flac;mp3;ogg;mid;midi");
        });
    }
    void filesDropped(const StringArray &files, int x, int y) override {
        if (!isInterestedInFileDrag(files)) return;
        const auto point = Point<int>(x,y);
        Row target = current;
        if (folders.isVisible() && folders.getBounds().contains(point)) {
            const auto *folder = folders.rowAt(folders.getLocalPoint(this, point));
            if (!folder) return;
            target = *folder;
        } else if (!contents.getBounds().contains(point)) {
            return;
        }
        if (target.kind != "samplerCategory" && target.kind != "midiCategory") return;
        Array<File> selected;
        for (const auto &path : files) {
            const File file(path);
            if (file.hasFileExtension(target.kind == "midiCategory" ? "mid;midi" : "wav;wave;aif;aiff;flac;mp3;ogg"))
                selected.add(file);
        }
        if (selected.isEmpty()) return;
        select(target);
        if (target.kind == "midiCategory") importMIDI(target.key, selected, {});
        else importSamples(target.key, selected);
    }
    void visibilityChanged() override {
        if (isVisible()) {
            refreshCatalogs();
            refreshTimelineEntries();
            if (filesPane.isVisible()) filesPane.refresh();
            startTimerHz(8);
        } else {
            timelineName.confirm();
            if (editingNote) setNoteEditing(false);
            stopTimer();
            stopPreview();
        }
    }
    void refreshTimelineEntries() {
        if (!isVisible() || !timelineCategory()) return;
        const auto song = session.song() ? session.song()->id : ID{};
        if (timelineRevision == session.revision && timelineSong == song) return;
        timelineRevision = session.revision;
        timelineSong = song;
        reloadEntries();
    }
    void resized() override {
        auto area = getLocalBounds();
        if (presentation == Presentation::library) {
            const int maximum = std::max(0, getWidth() - 1 - minimumDetailsWidth);
            const int width = jlimit(std::min(90, maximum), maximum, folderWidth);
            auto folderArea = area.removeFromLeft(width);
            area.removeFromLeft(1);
            auto toolbar = folderArea.removeFromTop(32).reduced(6, 4);
            collapseCategories.setBounds(toolbar.removeFromRight(25));
            folders.setBounds(folderArea);
            divider.setBounds(width - 3, 0, 6, getHeight());
            if (noteEdit.isVisible()) {
                auto bar = area.removeFromTop(32).reduced(6, 4);
                noteEdit.setBounds(bar.removeFromRight(28));
                pickerTitle.setBounds(bar);
            }
        } else {
            if (presentation == Presentation::notes) {
                auto tabs = area.removeFromTop(32).reduced(5, 4);
                const int segment = tabs.getWidth() / int(notesTabs.size());
                for (auto &tab : notesTabs) tab.setBounds(tabs.removeFromLeft(segment).reduced(2, 0));
            }
            if (presentation == Presentation::samplers) {
                auto tabs = area.removeFromTop(32).reduced(5, 4);
                samplerTabs[0].setBounds(tabs.removeFromLeft(tabs.getWidth() / 2).reduced(2, 0));
                samplerTabs[1].setBounds(tabs.reduced(2, 0));
                if (filesPane.isVisible()) { filesPane.setBounds(area); return; }
            }
            if (picker.isVisible()) {
                auto bar = area.removeFromTop(32).reduced(5,4);
                picker.setBounds(bar.removeFromLeft(28));
                if (noteEdit.isVisible()) noteEdit.setBounds(bar.removeFromRight(28));
                pickerTitle.setBounds(bar.withTrimmedLeft(6));
            }
        }
        if (search.isVisible()) search.setBounds(area.removeFromTop(32).reduced(6, 4));
        if (previewVolume.isVisible()) {
            auto preview = area.removeFromTop(32).reduced(6, 0);
            previewSpeakerBounds = preview.removeFromLeft(14);
            previewDBBounds = preview.removeFromRight(36);
            preview.removeFromRight(3);
            previewVolume.setBounds(preview.removeFromRight(24).reduced(0, 2));
        }
        contents.setBounds(area);
        if (noteEditor) noteEditor->setBounds(area.reduced(4));
        layoutTimelineName();
        divider.toFront(false);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::mixerPanelBackground());
        g.setColour(theme::libraryEntriesBackground());
        g.fillRect(getLocalBounds().withTrimmedLeft(presentation == Presentation::library ? folders.getWidth() : 0));
        g.setColour(theme::line);
        g.drawHorizontalLine(31, 0, float(folders.getWidth()));
        if (previewVolume.isVisible()) {
            g.setColour(theme::secondary);
            if (!drawControlIcon(g, "speaker.wave.2", false, previewSpeakerBounds.toFloat(), 1.f))
                drawDesktopToolbarSymbol(g, "speaker.wave.2", previewSpeakerBounds.toFloat());
            g.setColour(Colours::white);
            g.setFont(theme::font(10));
            g.drawText(previewVolume.getTextFromValue(previewVolume.getValue()), previewDBBounds,
                       Justification::centredLeft, false);
        }
    }

  private:
    struct Row { String title, key, kind; var payload; File file; int dividerHeight = 0; };
    class FolderList final : public TreeView {
        struct Root final : TreeViewItem {
            int getItemHeight() const override { return 0; }
            bool mightContainSubItems() override { return true; }
        };
        struct Item final : TreeViewItem {
            WorkspaceLibrary &owner;
            Row row;

            Item(WorkspaceLibrary &panel, Row value) : owner(panel), row(std::move(value)) {}
            int getItemHeight() const override { return row.dividerHeight > 0 ? row.dividerHeight : 27; }
            String getAccessibilityName() override { return row.title; }
            bool mightContainSubItems() override { return false; }
            bool canBeSelected() const override { return row.dividerHeight == 0; }
            void paintItem(Graphics &g, int width, int height) override {
                owner.paintRow(row, getIndexInParent(), g, width, height, true);
            }
            void itemClicked(const MouseEvent &event) override { owner.click(row, event, true); }
        };

      public:
        explicit FolderList(WorkspaceLibrary &panel) : TreeView("Library folders"), owner(panel) {
            setRootItemVisible(false);
            setOpenCloseButtonsVisible(false);
            setIndentSize(0);
            for (const auto colour : {backgroundColourId, selectedItemBackgroundColourId, oddItemsColourId, evenItemsColourId})
                setColour(colour, Colours::transparentBlack);
            getViewport()->setScrollBarsShown(true, false);
        }
        ~FolderList() override {
            if (root) root->clearSubItems();
            setRootItem(nullptr);
        }

        void replaceRows(std::vector<Row> rows) {
            const auto position = getViewport()->getViewPosition();
            const auto *previous = static_cast<Item *>(getSelectedItem(0));
            auto next = std::make_unique<Root>();
            for (auto &row : rows) {
                auto item = std::make_unique<Item>(owner, std::move(row));
                if (previous && previous->row.kind == item->row.kind && previous->row.key == item->row.key)
                    item->setSelected(true, false, dontSendNotification);
                next->addSubItem(item.release());
            }
            // Delete the rows while still attached so JUCE removes their view
            // components, including the row that still has mouse capture.
            if (root) root->clearSubItems();
            setRootItem(next.get());
            root = std::move(next);
            getViewport()->setViewPosition(position);
        }
        const Row *rowAt(Point<int> position) const {
            if (position.x >= getViewport()->getViewArea().getWidth()) return nullptr;
            const auto *item = static_cast<Item *>(getItemAt(position.y));
            return item ? &item->row : nullptr;
        }
        const TreeViewItem *findKind(const String &kind) const {
            if (!root) return nullptr;
            for (int index = 0; index < root->getNumSubItems(); ++index) {
                const auto *item = static_cast<Item *>(root->getSubItem(index));
                if (item->row.kind == kind) return item;
            }
            return nullptr;
        }
        bool keyPressed(const KeyPress &key) override {
            if (key == KeyPress::returnKey) {
                if (const auto *item = static_cast<Item *>(getSelectedItem(0))) owner.select(item->row);
                return true;
            }
            if (key == KeyPress::leftKey || key == KeyPress::rightKey) return false;
            return TreeView::keyPressed(key);
        }

      private:
        WorkspaceLibrary &owner;
        std::unique_ptr<Root> root;
    };
    struct Rows final : ListBoxModel {
        WorkspaceLibrary &owner;
        std::vector<Row> entries;
        explicit Rows(WorkspaceLibrary &panel) : owner(panel) {}
        int getNumRows() override { return int(entries.size()); }
        String getNameForRow(int row) override { return isPositiveAndBelow(row, getNumRows()) ? entries[size_t(row)].title : String{}; }
        void paintListBoxItem(int row, Graphics &g, int width, int height, bool) override {
            if (isPositiveAndBelow(row, getNumRows())) owner.paintRow(entries[size_t(row)], row, g, width, height, false);
        }
        void listBoxItemClicked(int row, const MouseEvent &e) override {
            if (isPositiveAndBelow(row, getNumRows())) owner.click(entries[size_t(row)], e, false);
        }
        void backgroundClicked(const MouseEvent &) override {
            if (owner.current.kind == "midiCategory") owner.contents.grabKeyboardFocus();
        }
        void listWasScrolled() override { owner.layoutTimelineName(); }
        var getDragSourceDescription(const SparseSet<int> &rows) override {
            if (rows.size() != 1 || !isPositiveAndBelow(rows[0], getNumRows())) return {};
            const auto &row = entries[size_t(rows[0])];
            String identity;
            if (row.kind == "midiChord") {
                auto payload = object();
                put(payload, "type", "catlive-midi-chord");
                put(payload, "name", row.key);
                return payload;
            }
            if (row.kind == "native") identity = row.key;
            else if (row.kind == "external") identity = "vst3:" + str(row.payload, "classID").toUpperCase();
            else if (row.kind == "preset") identity = str(row.payload, "plugin");
            else if (row.kind == "instrument") identity = "native:Instruments:" + row.key;
            else if (row.kind == "sample" || row.kind == "midiFile") {
                auto payload = object();
                put(payload, "type", row.kind == "sample" ? "catlive-library-sampler" : "catlive-library-media");
                put(payload, "file", row.file.getFullPathName());
                return payload;
            }
            if (identity.isEmpty()) return {};
            auto payload = object();
            put(payload, "type", "catlive-library-effect");
            put(payload, "project", text(owner.session.project().id));
            put(payload, "identity", identity);
            if (row.kind == "preset") put(payload, "preset", row.key);
            return payload;
        }
    };
    Session &session;
    std::shared_ptr<SharedSettings> store;
    var &settings;
    var presets;
    Presentation presentation = Presentation::library;
    uint64 loadedRevision = 0;
    Rows itemRows{*this};
    class EntryList final : public ListBox {
      public:
        EntryList(WorkspaceLibrary &panel, ListBoxModel *model)
            : ListBox("Library entries", model), owner(panel) {}
        bool keyPressed(const KeyPress &key) override {
            if (key == KeyPress::tabKey && owner.focusTimelineSearch()) return true;
            if (owner.stepTimeline(key) || owner.pasteMIDI(key)) return true;
            return ListBox::keyPressed(key);
        }
      private:
        WorkspaceLibrary &owner;
    };
    FolderList folders{*this};
    EntryList contents{*this, &itemRows};
    QuietButton collapseCategories, picker;
    std::array<QuietButton, 3> notesTabs;
    std::array<QuietButton, 2> samplerTabs;
    WorkspaceFilesPane filesPane;
    bool filesSelected = false;
    String dockNoteKey;
    Label pickerTitle;
    QuietButton noteEdit;
    bool editingNote = false;
    class SearchField final : public TextEditor {
      public:
        ~SearchField() override { Desktop::getInstance().removeGlobalMouseListener(&outsideClick); }
        std::function<bool(const KeyPress &)> onKey;
        bool keyPressed(const KeyPress &key) override {
            if (onKey && onKey(key)) return true;
            return TextEditor::keyPressed(key);
        }

        void focusGained(FocusChangeType cause) override {
            TextEditor::focusGained(cause);
            Desktop::getInstance().addGlobalMouseListener(&outsideClick);
        }
        void focusLost(FocusChangeType cause) override {
            Desktop::getInstance().removeGlobalMouseListener(&outsideClick);
            TextEditor::focusLost(cause);
        }

      private:
        struct OutsideClick final : MouseListener {
            explicit OutsideClick(SearchField &field) : search(field) {}
            void mouseDown(const MouseEvent &event) override {
                auto *target = event.eventComponent;
                if (target != &search && !search.isParentOf(target) && search.hasKeyboardFocus(true))
                    search.giveAwayKeyboardFocus();
            }
            SearchField &search;
        } outsideClick{*this};
    };
    SearchField search;
    InlineMixerTrackName timelineName;
    String editingTimelineKey;
    uint64 timelineNavigationVersion = 0;
    ID timelineSong;
    uint64 timelineRevision = 0;
    std::vector<Row> categoryEntries;
    Slider previewVolume;
    juce::Rectangle<int> previewSpeakerBounds, previewDBBounds;
    DragDivider divider;
    int folderWidth = 146, resizeStart = 0;
    std::set<String> expanded;
    Row current;
    std::unique_ptr<LibraryNoteEditor> noteEditor;
    String loadedNoteText;
    std::unique_ptr<FileChooser> chooser;
    std::map<String, std::shared_ptr<instrumentAssets::Download>> downloads;
    uint64 pluginRevision = 0;
    int64 presetRevision = -1;
    File previewFile;
    unsigned previewGeneration = 0;
    bool preparingPreview = false;
    bool previewingInstrument = false;
    bool importing = false;
    bool importingSoundFonts = false;
    bool importingMIDI = false;
    static constexpr int playOffset = 42, starOffset = 24;
    static constexpr auto userSoundFontCategoryName = "User-Sf2";
    static File root() {
        return File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive/Library");
    }
    static ThreadPool &sampleWorker() { static ThreadPool worker(1); return worker; }
    static bool disclosure(const Row &row) { return row.kind == "folder" || row.kind == "user" || row.kind == "midiUser"; }
    bool persist() {
        auto folder = root();
        if (folder.createDirectory().wasOk() && folder.getChildFile("Library.json").replaceWithText(JSON::toString(settings))) {
            loadedRevision = ++store->revision;
            return true;
        }
        warn("Could not save the Library.");
        return false;
    }
    void warn(const String &message) {
        AlertWindow::showMessageBoxAsync(MessageBoxIconType::WarningIcon, "Library", localization::translate(message));
    }
    static String pluginName(String identity) {
        if (identity == "native:Limiter") return "CatLive Limiter";
        if (identity.startsWith("native:Instruments:")) return instrumentAssets::name(identity.fromFirstOccurrenceOf("native:Instruments:", false, false));
        if (identity.startsWith("native:")) return identity.substring(7);
        if (identity.startsWith("vst3:")) {
            auto id = identity.substring(5);
            for (const auto &plugin : VST3Catalog::shared().plugins)
                if (str(plugin, "classID").equalsIgnoreCase(id)) return str(plugin, "name");
            return id;
        }
        return identity;
    }
    void rebuildFolders() {
        collapseCategories.setToggleState(!expanded.empty(), dontSendNotification);
        std::vector<Row> rows;
        // The category row already includes one of the Mac divider's two inter-row gaps.
        const auto divider = [&](int padding = 5) { rows.push_back({{}, {}, {}, {}, {}, 1 + 2 * padding + 2}); };
        const auto folder = [&](String title, String key) {
            rows.push_back({title, key, "folder"});
            return expanded.count(key) != 0;
        };
        if (folder("Instruments", "instruments")) {
            for (auto [key, title] : std::vector<std::pair<String, String>>{
                {"user",userSoundFontCategoryName}, {"pianos","Grand Pianos"}, {"upright","Upright"}, {"electric","Electric"}, {"keyboard","Keyboard"},
                {"organ","Organ"}, {"strings","Strings"}, {"guitar","Guitar"}, {"bass","Bass"}, {"synth","Synth"},
                {"synthPad","Synth Pad"}, {"lead","Lead"}, {"acordeon","Acordeon"}, {"brass","Brass"}, {"mallets","Mallets"}, {"drum","Drum"}
            }) rows.push_back({title, key, "instrumentCategory"});
        }
        divider(3);
        if (folder("Plugins", "plugins")) {
            rows.push_back({"All", {}, "pluginCategory"});
            rows.push_back({"Native", "native", "pluginCategory"});
            for (const auto &type : libraryPluginCategories(VST3Catalog::shared())) rows.push_back({type, type, "pluginCategory"});
        }
        divider(3);
        if (folder("Samplers", "samplers")) {
            rows.push_back({"User", "user", "user"});
            if (expanded.count("user")) {
                const auto categories = userCategories();
                rows.insert(rows.end(), categories.begin(), categories.end());
            }
            appendBuiltInSamplerFolders(rows);
        }
        divider();
        if (folder("Midi", "midi")) {
            rows.push_back({"User", "midiUser", "midiUser"});
            if (expanded.count("midiUser")) {
                const auto categories = userCategories(true);
                rows.insert(rows.end(), categories.begin(), categories.end());
            }
            for (auto category : {"Major", "Minor", "Other"}) rows.push_back({category, category, "chordCategory"});
        }
        divider();
        if (folder("Presets", "presets")) {
            StringArray identities;
            for (const auto &preset : list(get(presets, "presets"))) identities.addIfNotAlreadyThere(str(preset, "plugin"));
            std::sort(identities.begin(), identities.end(), [](const auto &a, const auto &b) {
                return pluginName(a).compareNatural(pluginName(b)) < 0;
            });
            for (const auto &id : identities) rows.push_back({pluginName(id), id, "presetCategory"});
        }
        if (folder("Favorites", "favorites")) {
            rows.push_back({"Plugins", "plugins", "favorites"});
            rows.push_back({"Samplers", "samplers", "favorites"});
        }
        divider();
        if (folder("Notes", "annotation")) {
            for (const auto &note : list(get(settings, "notes"))) {
                rows.push_back({noteTitle(note), str(note, "id"), "note"});
            }
        }
        divider();
        rows.push_back({"Region", {}, "regions"});
        rows.push_back({"Markers", {}, "markers"});
        folders.replaceRows(std::move(rows));
    }
    static String noteTitle(const var &note) {
        const auto name = str(note,"name").trim();
        return name.isNotEmpty() ? name : localization::translate("Untitled note");
    }
    static const char *categoryKey(bool midi) { return midi ? "midiCategories" : "samplerCategories"; }
    static const char *categoryKind(bool midi) { return midi ? "midiCategory" : "samplerCategory"; }
    std::vector<Row> userCategories(bool midi = false) const {
        std::vector<Row> rows;
        for (const auto &category : list(get(settings, categoryKey(midi))))
            rows.push_back({str(category,"name"),str(category,"id"),categoryKind(midi)});
        std::stable_sort(rows.begin(), rows.end(), [](const Row &a, const Row &b) { return a.title.compareNatural(b.title) < 0; });
        return rows;
    }
    std::vector<Row> pickerRows() const {
        std::vector<Row> rows;
        if (presentation == Presentation::notes) {
            for (const auto &note : list(get(settings,"notes")))
                rows.push_back({noteTitle(note),str(note,"id"),"note"});
        } else if (presentation == Presentation::samplers) {
            rows = userCategories();
            appendBuiltInSamplerFolders(rows);
        }
        return rows;
    }
    void openPicker() {
        if (presentation == Presentation::library) return;
        auto rows = pickerRows();
        PopupMenu menu;
        menu.addItem(1,localization::translate("Create"));
        if (presentation == Presentation::notes && current.kind == "note")
            menu.addItem(2,localization::translate("Rename note"));
        if (!rows.empty()) menu.addSeparator();
        for (size_t i=0;i<rows.size();++i)
            menu.addItem(int(i)+3,rows[i].title,true,rows[i].key == current.key && rows[i].kind == current.kind);
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&picker),
            [safe=SafePointer<WorkspaceLibrary>(this), rows=std::move(rows)](int result) {
                if (!safe || result <= 0) return;
                if (result == 1) {
                    if (safe->presentation == Presentation::notes) safe->createNote();
                    else if (safe->presentation == Presentation::samplers) safe->createCategory();
                } else if (result == 2 && safe->current.kind == "note") {
                    safe->createNote(safe->current.key);
                } else if (isPositiveAndBelow(result-3,int(rows.size()))) {
                    safe->select(rows[(size_t)(result-3)]);
                }
            });
    }
    void syncNoteEditButton() {
        const auto label = localization::translate(editingNote ? "Confirm note edit" : "Edit note");
        noteEdit.setVisible(current.kind == "note");
        if (presentation == Presentation::library) pickerTitle.setVisible(current.kind == "note");
        noteEdit.setTitle(label);
        noteEdit.setTooltip(label);
        noteEdit.getProperties().set("icon", editingNote ? "check" : "note.pencil");
        noteEdit.setToggleState(editingNote, dontSendNotification);
        noteEdit.repaint();
    }
    void setNoteEditing(bool editing) {
        if (current.kind != "note" || editingNote == editing) return;
        editingNote = editing;
        if (!editing)
            if (auto *peer = getPeer()) ::SetFocus(static_cast<HWND>(peer->getNativeHandle()));
        noteEditor = makeNoteEditor(current, editing);
        if (noteEditor) addAndMakeVisible(*noteEditor);
        contents.setVisible(!noteEditor);
        syncNoteEditButton();
        resized();
    }
    std::unique_ptr<LibraryNoteEditor> makeNoteEditor(const Row &row, bool focus = true) {
        for (const auto &note : list(get(settings,"notes"))) {
            if (str(note,"id") != row.key) continue;
            loadedNoteText = str(note,"text");
            return std::make_unique<LibraryNoteEditor>(loadedNoteText, [this,id=row.key](String text) {
                for (auto entry : list(get(settings,"notes"))) {
                    if (str(entry,"id") != id) continue;
                    put(entry,"text",text);
                    loadedNoteText = text;
                    persist();
                    rebuildFolders();
                    break;
                }
            }, focus && editingNote, editingNote);
        }
        return {};
    }
    void select(Row row) {
        timelineName.confirm();
        if (disclosure(row)) {
            if (!expanded.insert(row.key).second) expanded.erase(row.key);
            rebuildFolders();
            return;
        }
        if (noteEditor && row.kind == "note" && row.key == current.key) return;
        const bool categoryChanged = row.kind != current.kind || row.key != current.key;
        if (categoryChanged) {
            ++timelineNavigationVersion;
            search.setText({}, false);
            if (previewingInstrument) stopPreview();
        }
        current = std::move(row);
        editingNote = false;
        syncNoteEditButton();
        if (presentation == Presentation::notes && current.kind == "note") dockNoteKey = current.key;
        const auto fallbackTitle = presentation == Presentation::notes ? "Notes" : "Samplers";
        pickerTitle.setText(current.title.isEmpty() ? localization::translate(fallbackTitle) : current.title, dontSendNotification);
        const bool dockTimeline = presentation == Presentation::notes && timelineCategory();
        search.setVisible((presentation == Presentation::library && current.kind != "note") || dockTimeline);
        if (presentation == Presentation::library && timelineCategory() && openLibraryTimeline) openLibraryTimeline();
        noteEditor.reset();
        if (current.kind == "note") {
            noteEditor = makeNoteEditor(current);
            if (noteEditor) addAndMakeVisible(*noteEditor);
        }
        contents.setVisible(!noteEditor);
        reloadEntries();
        folders.repaint();
        contents.getViewport()->setViewPosition(0, 0);
        resized();
    }
    void selectNotesTab(size_t index) {
        for (size_t position = 0; position < notesTabs.size(); ++position)
            notesTabs[position].setToggleState(position == index, dontSendNotification);
        picker.setVisible(index == 0);
        pickerTitle.setVisible(index == 0);
        if (index == 0) {
            const auto rows = pickerRows();
            const auto note = std::find_if(rows.begin(), rows.end(), [&](const auto &row) { return row.key == dockNoteKey; });
            select(note != rows.end() ? *note : rows.empty() ? Row{} : rows.front());
        } else {
            select(index == 1 ? Row{"Region", {}, "regions"} : Row{"Markers", {}, "markers"});
            if (openTimelineTab) openTimelineTab();
        }
        resized();
    }
    void selectSamplerTab(bool files, bool force = false) {
        if (!force && files == filesSelected) return;
        filesSelected = files;
        samplerTabs[0].setToggleState(!files, dontSendNotification);
        samplerTabs[1].setToggleState(files, dontSendNotification);
        picker.setVisible(!files);
        pickerTitle.setVisible(!files);
        contents.setVisible(!files);
        filesPane.setVisible(files);
        if (files) {
            stopPreview();
            previewVolume.setVisible(false);
            filesPane.refresh();
        } else reloadEntries();
        resized();
    }
    bool favorited(const Row &row) const {
        if (row.kind == "external") return VST3Catalog::shared().isFavorite(row.payload);
        for (const auto &key : list(get(settings, "favorites"))) if (key.toString() == row.key) return true;
        return false;
    }
    void favorite(const Row &row) {
        if (row.kind == "external") VST3Catalog::shared().toggleFavorite(row.payload);
        else {
            auto keys = list(get(settings, "favorites"));
            if (favorited(row)) keys.removeAllInstancesOf(row.key);
            else keys.add(row.key);
            put(settings, "favorites", keys);
            persist();
        }
        reloadEntries();
    }
    static const StringArray &voiceGuideCategories() {
        static const StringArray categories{"Guia Pack PT-BR 1", "Guia Pack PT-BR 2", "Guia Pack ENG 1", "Guia Pack ENG 2"};
        return categories;
    }
    static const StringArray &otherNativeSampleCategories() {
        static const StringArray categories{"Cymbals", "FX", "FX Brazil", "Kick", "Percussion", "Snare", "Toms"};
        return categories;
    }
    static void appendBuiltInSamplerFolders(std::vector<Row> &rows) {
        for (const auto &name : voiceGuideCategories()) rows.push_back({name, name, "nativeSamplerCategory"});
        if (VinhetasPanel::padSampleDirectory().isDirectory()) rows.push_back({"Pads", "Pads", "padSamplerCategory"});
        for (const auto &name : otherNativeSampleCategories()) rows.push_back({name, name, "nativeSamplerCategory"});
    }
    void samplesFor(std::vector<Row> &rows, const String &category, bool onlyFavorites, bool native = false) const {
        const auto base = native ? File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("NativeSamples")
                                 : root().getChildFile("Samplers");
        const auto folder = category == "Pads" ? VinhetasPanel::padSampleDirectory() : base.getChildFile(category);
        for (const auto &file : folder.findChildFiles(File::findFiles | File::ignoreHiddenFiles, false)) {
            if ((native || category == "Pads") && !file.hasFileExtension("wav;wave;aif;aiff;mp3")) continue;
            Row row{file.getFileNameWithoutExtension(), category + "/" + file.getFileName(), "sample", {}, file};
            if (!onlyFavorites || favorited(row)) rows.push_back(std::move(row));
        }
    }
    void reloadEntries() {
        auto &rows = categoryEntries;
        rows.clear();
        if (current.kind == "instrumentCategory") {
            for (const auto &item : instrumentAssets::availableCatalog(session.mediaDirectory))
                if (str(item, "category") == current.key)
                    rows.push_back({str(item, "name"), str(item, "id"), "instrument", item});
        } else if (current.kind == "pluginCategory" || (current.kind == "favorites" && current.key == "plugins")) {
            const bool favorites = current.kind == "favorites";
            for (const auto &[name, type] : libraryNativePlugins()) {
                Row row{pluginName("native:" + name), "native:" + name, "native"};
                if (favorites ? favorited(row) : current.key.isEmpty() || current.key == type || current.key == "native")
                    rows.push_back(std::move(row));
            }
            if (current.key != "native")
                for (const auto &plugin : favoritePluginMatches(VST3Catalog::shared(), {}, favorites ? String{} : current.key, {}, true, favorites))
                    rows.push_back({str(plugin, "name"), VST3Catalog::favoriteID(plugin), "external", plugin});
        } else if (current.kind == "samplerCategory" || current.kind == "padSamplerCategory") {
            samplesFor(rows, current.key, false);
        } else if (current.kind == "nativeSamplerCategory") {
            samplesFor(rows, current.key, false, true);
        } else if (current.kind == "favorites" && current.key == "samplers") {
            for (const auto &category : list(get(settings, "samplerCategories")))
                samplesFor(rows, str(category, "id"), true);
            samplesFor(rows, "Pads", true);
            for (const auto &category : voiceGuideCategories()) samplesFor(rows, category, true, true);
            for (const auto &category : otherNativeSampleCategories()) samplesFor(rows, category, true, true);
        } else if (current.kind == "midiCategory") {
            const auto folder = root().getChildFile("MIDI").getChildFile(current.key);
            for (const auto &file : folder.findChildFiles(File::findFiles, false))
                if (file.hasFileExtension("mid;midi"))
                    rows.push_back({file.getFileNameWithoutExtension(), file.getFullPathName(), "midiFile", {}, file});
            std::stable_sort(rows.begin(), rows.end(), [](const Row &a, const Row &b) { return a.title.compareNatural(b.title) < 0; });
        } else if (current.kind == "chordCategory") {
            if (auto* chords = libraryChords::catalog().getArray())
                for (const auto& chord : *chords)
                    if (str(chord,"category") == current.key)
                        rows.push_back({str(chord,"name"),str(chord,"name"),"midiChord"});
        } else if (current.kind == "presetCategory") {
            for (const auto &preset : fxpresets::Store::entries(presets, current.key))
                rows.push_back({pluginName(current.key) + " - " + str(preset, "name"), str(preset, "id"), "preset", preset});
        } else if (const auto *song = session.song(); song && timelineCategory()) {
            if (current.kind == "regions") {
                for (const auto &part : song->parts)
                    rows.push_back({timelineRegionLabels::displayName(part), text(part.id), "regionLabel", part.startTime});
            } else if (song->markers) {
                for (const auto &marker : *song->markers)
                    if (timelineRegionLabels::isNavigationMarker(marker)) {
                        const auto *source = timelineRegionLabels::markerSource(*song, marker);
                        rows.push_back({source ? timelineRegionLabels::displayName(*source) : text(marker.name),
                                        text(marker.id), "markerLabel", marker.position});
                    }
            }
            std::stable_sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) {
                return double(a.payload) < double(b.payload);
            });
        }
        const bool showPreview = current.kind == "samplerCategory" || current.kind == "padSamplerCategory" || current.kind == "nativeSamplerCategory" ||
            (current.kind == "favorites" && current.key == "samplers");
        if (showPreview)
            std::stable_sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) { return a.title.compareNatural(b.title) < 0; });
        const bool showVolume = showPreview && !filesPane.isVisible();
        if (previewVolume.isVisible() != showVolume) { previewVolume.setVisible(showVolume); resized(); }
        filterEntries();
    }
    void filterEntries() {
        const auto query = search.getText().trim();
        auto &results = itemRows.entries;
        results.clear();
        for (const auto &row : categoryEntries)
            if (query.isEmpty() || row.title.containsIgnoreCase(query)) results.push_back(row);
        contents.updateContent();
        layoutTimelineName();
        contents.repaint();
    }
    bool timelineCategory() const { return current.kind == "regions" || current.kind == "markers"; }
    String selectedTimelineKey() const {
        const auto *song = session.song();
        if (!song || song->id != store->timelineSong) return {};
        return current.kind == "regions" ? store->selectedRegion : store->selectedMarker;
    }
    bool canNavigateTimeline() const {
        const auto &transport = session.transport();
        return session.song() && !transport.playing && !transport.subPlay.playing && !transport.paused &&
            !session.busy && !jaras::projectSync::readOnly() && static_cast<bool>(selectTimelineEntry);
    }
    bool stepTimeline(const KeyPress &key) {
        const auto mods = key.getModifiers();
        if (!timelineCategory() || mods.isAnyModifierKeyDown()) return false;
        const int code = key.getKeyCode();
        if (code != KeyPress::upKey && code != KeyPress::downKey) return false;
        const auto &entries = itemRows.entries;
        const bool down = code == KeyPress::downKey;
        const auto selected = selectedTimelineKey();
        const auto row = std::find_if(entries.begin(), entries.end(), [&](const auto &item) { return item.key == selected; });
        const int index = row == entries.end() ? (down ? 0 : int(entries.size()) - 1) :
            int(row - entries.begin()) + (down ? 1 : -1);
        if (isPositiveAndBelow(index, int(entries.size()))) {
            navigateTimeline(entries[size_t(index)], true);
            contents.scrollToEnsureRowIsOnscreen(index);
        }
        return true;
    }
    void navigateTimeline(const Row &row, bool deferred) {
        if (!session.song() || session.busy || jaras::projectSync::readOnly() || !selectTimelineEntry) return;
        const auto songID = session.song()->id;
        const auto projectID = session.project().id;
        if (store->timelineSong != songID) {
            store->timelineSong = songID;
            store->selectedRegion.clear();
            store->selectedMarker.clear();
        }
        const bool region = row.kind == "regionLabel";
        (region ? store->selectedRegion : store->selectedMarker) = row.key;
        contents.repaint();
        if (timelineSelectionChanged) timelineSelectionChanged();
        const auto version = ++timelineNavigationVersion;
        if (!canNavigateTimeline()) return;
        if (!deferred) {
            MessageManager::callAsync([safe = SafePointer<WorkspaceLibrary>(this), projectID, songID, version, row, region] {
                if (safe && safe->timelineNavigationVersion == version && safe->canNavigateTimeline() &&
                    safe->session.project().id == projectID && safe->session.song()->id == songID)
                    safe->selectTimelineEntry(utf8(row.key), region, double(row.payload));
            });
            return;
        }
        finishTimelineNavigation(projectID, songID, version, row, region);
    }
    void finishTimelineNavigation(const ID &projectID, const ID &songID, uint64 version, const Row &row, bool region) {
        Timer::callAfterDelay(200, [safe = SafePointer<WorkspaceLibrary>(this), projectID, songID, version, row, region] {
            if (!safe || !safe->isShowing() || safe->timelineNavigationVersion != version || !safe->canNavigateTimeline() ||
                safe->session.project().id != projectID || safe->session.song()->id != songID || safe->selectedTimelineKey() != row.key) return;
            if (KeyPress::isKeyCurrentlyDown(KeyPress::upKey) || KeyPress::isKeyCurrentlyDown(KeyPress::downKey)) {
                safe->finishTimelineNavigation(projectID, songID, version, row, region);
                return;
            }
            safe->selectTimelineEntry(utf8(row.key), region, double(row.payload));
        });
    }
    int timelineNameRow() const {
        const auto &entries = itemRows.entries;
        const auto row = std::find_if(entries.begin(), entries.end(), [&](const auto &item) { return item.key == editingTimelineKey; });
        return row == entries.end() ? -1 : int(row - entries.begin());
    }
    juce::Rectangle<int> timelineNameBounds(int index) const {
        return getLocalArea(&contents, contents.getRowPosition(index, true)).reduced(5, 1)
            .getIntersection(contents.getBounds());
    }
    void layoutTimelineName() {
        if (!timelineName.isVisible()) return;
        const int index = timelineNameRow();
        if (index < 0) { timelineName.confirm(); return; }
        timelineName.layoutIn(timelineNameBounds(index));
    }
    void beginTimelineRename(const Row &row) {
        const bool region = row.kind == "regionLabel";
        if ((!region && row.kind != "markerLabel") || session.busy || jaras::projectSync::readOnly()) return;
        const auto *song = session.song();
        if (!song) return;
        const auto id = utf8(row.key);
        String value;
        if (region) {
            for (const auto &part : song->parts) if (part.id == id) { value = text(part.name); break; }
        } else if (song->markers) {
            for (const auto &marker : *song->markers) if (marker.id == id && timelineRegionLabels::isNavigationMarker(marker)) {
                const auto *source = timelineRegionLabels::markerSource(*song, marker);
                value = text(source ? source->name : marker.name);
                break;
            }
        }
        if (value.isEmpty()) return;
        timelineName.confirm();
        editingTimelineKey = row.key;
        const int index = timelineNameRow();
        if (index < 0) return;
        contents.scrollToEnsureRowIsOnscreen(index);
        timelineName.setTitle(region ? "Region name" : "Marker name");
        const auto project = session.project().id;
        const auto songID = song->id;
        timelineName.open(timelineNameBounds(index), value,
            [safe = SafePointer<WorkspaceLibrary>(this), project, songID, id, region, value](String next) {
                if (!safe || !safe->session.song() || safe->session.project().id != project ||
                    safe->session.song()->id != songID || value == next) return;
                try {
                    safe->session.renameTimelineLabel(id, region, next);
                } catch (const std::exception &error) { safe->warn(String::fromUTF8(error.what())); }
            });
    }
    void paintRow(const Row &row, int index, Graphics &g, int width, int height, bool navigation) {
        if (row.dividerHeight > 0) {
            g.setColour(theme::line);
            g.drawHorizontalLine(height / 2, 7, float(width - 7));
            return;
        }
        const bool selected = navigation ? row.kind == current.kind && row.key == current.key
                                         : timelineCategory() && row.key == selectedTimelineKey();
        g.setColour(selected ? theme::green.withAlpha(.20f) : Colours::white.withAlpha(index % 2 ? .045f : 0.f));
        g.fillRoundedRectangle(4.f, 1.f, float(std::max(1, width - 8)), float(height - 2), 4.f);
        int start = 8, trailing = 8;
        if (navigation) {
            if (disclosure(row)) {
                const float y = height * .5f;
                Path caret;
                if (expanded.count(row.key)) { caret.startNewSubPath(8, y - 2); caret.lineTo(11, y + 1); caret.lineTo(14, y - 2); }
                else { caret.startNewSubPath(9, y - 3); caret.lineTo(12, y); caret.lineTo(9, y + 3); }
                g.setColour(theme::secondary);
                g.strokePath(caret, PathStrokeType(1.2f));
            }
            const float y = height * .5f;
            String icon = "folder.fill";
            if (row.kind == "folder") {
                if (row.key == "favorites") icon = "star.fill";
                else if (row.key == "annotation") icon = "note.text";
                else if (row.key == "midi") icon = "pianokeys";
            } else if (row.kind == "note") icon = "doc.text";
            else if (row.kind == "regions") icon = "rectangle";
            else if (row.kind == "markers") icon = "flag";
            else if (row.kind == "pluginCategory" && row.key.isEmpty()) icon = "square.grid.2x2";
            const juce::Rectangle<float> bounds{19.f, y - 8.f, 16.f, 16.f};
            if (icon == "folder.fill") {
                g.setColour(theme::green);
                drawInterfaceIcon(g, "folderFilled", bounds);
            } else {
                drawControlIcon(g, icon, selected || (disclosure(row) && expanded.count(row.key)), bounds, 1.f);
            }
            start = 39;
        } else if (row.kind == "sample" || row.kind == "native" || row.kind == "external") {
            const float y = height * .5f;
            const bool favorite = favorited(row);
            g.setColour(favorite ? theme::yellow : theme::secondary);
            drawDesktopToolbarSymbol(g, favorite ? "star.fill" : "star",
                                     {float(width - starOffset + 4), y - 5.5f, 11.f, 11.f});
            trailing = starOffset;
            if (row.kind != "sample") {
                const bool native = row.kind == "native";
                const bool ara = !native && (flag(row.payload,"supportsARA") || str(row.payload,"name").containsIgnoreCase("Melodyne"));
                const int badgeWidth = native ? 43 : 38;
                constexpr int badgeGap = 5;
                const auto badge = juce::Rectangle<int>{width - starOffset - badgeWidth - badgeGap,
                    (height - 16) / 2, badgeWidth, 16};
                g.setColour(ara ? theme::green.withAlpha(.19f) : Colours::white.withAlpha(.15f));
                g.fillRoundedRectangle(badge.toFloat(), 3.f);
                g.setColour(ara ? theme::green : Colours::white);
                g.setFont(theme::semiboldFont(10));
                g.drawText(native ? "Native" : ara ? "ARA2" : "VST3", badge, Justification::centred, false);
                trailing += badgeWidth + badgeGap * 2;
            }
            if (row.kind == "sample") {
                const bool playing = previewFile == row.file;
                g.setColour(playing ? theme::green : theme::secondary);
                drawDesktopToolbarSymbol(g, playing ? "stopall" : "play",
                                         {float(width - playOffset + 3), y - 5.5f, 11.f, 11.f});
                g.setColour(theme::secondary);
                drawDesktopToolbarSymbol(g, "waveform", {10.f, y - 6.f, 12.f, 12.f});
                start = 27;
                trailing = playOffset + 2;
            }
        } else if (row.kind == "instrument") {
            const auto file = instrumentAssets::resolve(row.key, session.mediaDirectory);
            const bool available = file.existsAsFile();
            {
                const float x = float(width - 17), y = height * .5f;
                g.setColour(Colours::white.withAlpha(.10f));
                g.fillEllipse(x - 9, y - 9, 18.f, 18.f);
                g.setColour(theme::secondary);
                trailing = 29;
                if (available) {
                    const bool playing = previewingInstrument && previewFile == file;
                    g.setColour(playing ? theme::green : Colours::white);
                    if (playing) g.fillRect(x - 3, y - 3, 6.f, 6.f);
                    else {
                        Path play;
                        play.addTriangle(x - 2.5f, y - 4, x + 4, y, x - 2.5f, y + 4);
                        g.fillPath(play);
                    }
                } else if (const auto job = downloads.find(row.key); job != downloads.end()) {
                    g.setFont(theme::font(8));
                    g.drawText(String(job->second->progress.load() * 100., 0) + "%", width - 36, 0, 35, height, Justification::centred);
                    trailing = 36;
                } else {
                    g.drawArrow(Line<float>(x, y - 4, x, y + 4), 1.1f, 5.f, 3.f);
                }
            }
        }
        g.setColour(Colours::white);
        g.setFont(theme::mediumFont(12));
        g.drawFittedText(row.title, start, 0, std::max(1, width - start - trailing), height, Justification::centredLeft, 1);
    }
    void click(Row row, const MouseEvent &event, bool navigation) {
        if (row.dividerHeight > 0) return;
        if (event.mods.isPopupMenu()) {
            if (row.kind == "regionLabel" || row.kind == "markerLabel") {
                MessageManager::callAsync([safe = SafePointer<WorkspaceLibrary>(this), row] {
                    if (safe) safe->beginTimelineRename(row);
                });
                return;
            }
            contextMenu(row, event.getScreenPosition());
            return;
        }
        if (navigation) { select(std::move(row)); return; }
        if (row.kind == "regionLabel" || row.kind == "markerLabel") {
            if (timelineName.isVisible() && editingTimelineKey != row.key) timelineName.confirm();
            contents.grabKeyboardFocus();
            navigateTimeline(row, false);
            return;
        }
        const int width = contents.getViewport()->getViewWidth();
        if ((row.kind == "sample" || row.kind == "native" || row.kind == "external") && event.x >= width - starOffset) {
            favorite(row);
        } else if (row.kind == "sample") {
            togglePreview(row.file);
        } else if (row.kind == "instrument" && event.x >= width - 29) {
            const auto file = instrumentAssets::resolve(row.key, session.mediaDirectory);
            if (file.existsAsFile()) {
                togglePreview(file, true, str(row.payload, "category") == "drum");
            } else if (!downloads.count(row.key)) {
                downloads[row.key] = instrumentAssets::startDownload(row.payload);
                contents.repaint();
            }
        }
    }
    void contextMenu(const Row &row, Point<int> position) {
        PopupMenu menu;
        if (row.kind == "folder" && row.key == "plugins" && openPluginSettings)
            menu.addItem(10, localization::translate("Scan Plugins"));
        if (row.kind == "folder" && row.key == "instruments")
            menu.addItem(8, localization::translate(String::fromUTF8("Import SF2…")), !importingSoundFonts);
        if (row.kind == "user" || row.kind == "midiUser") menu.addItem(1, localization::translate("Create category"));
        if (row.kind == "samplerCategory") {
            menu.addItem(2, localization::translate("Add Samplers"), !importing);
            menu.addItem(6, localization::translate("Excluir"), !importing);
        }
        if (row.kind == "padSamplerCategory") menu.addItem(7, localization::translate("Excluir"));
        if (row.key == "annotation" && row.kind == "folder") menu.addItem(3, localization::translate("New note"));
        if (row.kind == "note") {
            menu.addItem(9,localization::translate("Rename note"));
            menu.addItem(4,localization::translate("Delete note"));
        }
        if (row.kind == "instrument" && instrumentAssets::installedFile(row.key).existsAsFile())
            menu.addItem(5, localization::translate("Delete instrument"));
        if (!menu.getNumItems()) return;
        menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({position.x, position.y, 1, 1}),
            [safe = SafePointer<WorkspaceLibrary>(this), row](int choice) {
                if (!safe) return;
                switch (choice) {
                    case 1: safe->createCategory(row.kind == "midiUser"); break;
                    case 2: safe->addSamples(row); break;
                    case 3: safe->createNote(); break;
                    case 4: safe->deleteNote(row.key); break;
                    case 6: safe->confirmDeleteCategory(row); break;
                    case 7: safe->confirmDeletePadSamples(); break;
                    case 8: safe->chooseSoundFonts(); break;
                    case 9: safe->createNote(row.key); break;
                    case 10: if (safe->openPluginSettings) safe->openPluginSettings(); break;
                    case 5:
                        try {
                            const auto file = instrumentAssets::installedFile(row.key);
                            instrumentAssets::uninstall(row.key);
                            if (safe->previewFile == file) safe->stopPreview();
                            safe->reloadEntries();
                        }
                        catch (const std::exception &error) { safe->warn(String::fromUTF8(error.what())); }
                        break;
                }
            });
    }
    class CategoryCalloutLook final : public LookAndFeel_V4 {
      public:
        int getCallOutBoxBorderSize(const CallOutBox &) override { return 14; }
        float getCallOutBoxCornerSize(const CallOutBox &) override { return 19.f; }
        void drawCallOutBoxBackground(CallOutBox &box, Graphics &g, const Path &path, Image &shadow) override {
            if (shadow.isNull()) {
                shadow = Image(Image::ARGB, box.getWidth(), box.getHeight(), true);
                Graphics surface(shadow);
                DropShadow(Colours::black.withAlpha(.48f), 6, {0, 3}).drawForPath(surface, path);
            }
            g.drawImageAt(shadow, 0, 0);
            g.setGradientFill(ColourGradient(Colour(0xff404040), 0.f, 0.f, Colour(0xff383838),
                                             0.f, (float)box.getHeight(), false));
            g.fillPath(path);
            g.setColour(Colour(0xff737373));
            g.strokePath(path, PathStrokeType(.85f, PathStrokeType::curved));
        }
    };
    class CategoryInput final : public Component {
      public:
        CategoryInput(std::function<bool(String)> validate, std::function<bool(String)> save,
                      String heading = "Create category", int limit = 12, String initial = {}, String action = "Create")
            : create(localization::translate(action)), canSave(std::move(validate)), commit(std::move(save)) {
            setComponentID("library-category-popover");
            title.setText(localization::translate(heading), dontSendNotification);
            title.setFont(theme::semiboldFont(13));
            title.setColour(Label::textColourId, Colours::white);
            title.setBorderSize({});
            addAndMakeVisible(title);
            name.setComponentID("library-category-name");
            name.setInputRestrictions(limit);
            name.setText(initial,false);
            name.setIndents(5, 2);
            name.setFont(theme::font(13));
            name.setColour(TextEditor::textColourId, Colours::white);
            name.setColour(TextEditor::backgroundColourId, Colours::transparentBlack);
            name.setColour(TextEditor::outlineColourId, Colours::transparentBlack);
            name.setColour(TextEditor::focusedOutlineColourId, Colours::transparentBlack);
            name.setColour(TextEditor::shadowColourId, Colours::transparentBlack);
            name.setColour(CaretComponent::caretColourId, Colour(0xff78a967));
            name.onTextChange = [this] { create.setEnabled(canSave(name.getText().trim())); };
            name.onReturnKey = [this] { submit(); };
            name.onEscapeKey = [this] { dismiss(); };
            addAndMakeVisible(name);
            create.setComponentID("library-category-create");
            create.setEnabled(canSave(initial.trim()));
            create.onClick = [this] { submit(); };
            addAndMakeVisible(create);
            setSize(186, 89);
        }
        void focus() { name.grabKeyboardFocus(); }
        void resized() override {
            title.setBounds(7, 5, getWidth() - 14, 18);
            name.setBounds(7, 30, getWidth() - 14, 22);
            create.setBounds(7, 58, 54, 24);
        }
        void paint(Graphics &g) override {
            g.setColour(Colour(0xff1f1f1f));
            g.fillRoundedRectangle(name.getBounds().toFloat().expanded(1.f), 6.f);
        }
        void paintOverChildren(Graphics &g) override {
            g.setColour(name.hasKeyboardFocus(false) ? Colour(0xff78a967) : Colour(0xff515151));
            g.drawRoundedRectangle(name.getBounds().toFloat().expanded(1.1f), 7.f, 2.8f);
        }
        void focusOfChildComponentChanged(FocusChangeType) override { repaint(); }
      private:
        class NameEditor final : public TextEditor {
          public:
            NameEditor() : hint(localization::translate("Name")) { setTitle(hint); }
            void paintOverChildren(Graphics &g) override {
                TextEditor::paintOverChildren(g);
                if (getTotalNumChars() != 0) return;
                g.setColour(Colour(0xff999999));
                g.setFont(getFont());
                g.drawText(hint, getLocalBounds().withTrimmedLeft(6), Justification::centredLeft, false);
            }
          private:
            String hint;
        };
        class CreateButton final : public Button {
          public:
            explicit CreateButton(String label) : Button(label) {}
            void paintButton(Graphics &g, bool over, bool) override {
                g.setColour(Colour(isEnabled() && over ? 0xff666666 : 0xff515151));
                g.fillRoundedRectangle(getLocalBounds().toFloat(), 5.f);
                g.setColour(Colours::white.withAlpha(isEnabled() ? 1.f : .36f));
                g.setFont(theme::semiboldFont(13));
                g.drawText(getName(), getLocalBounds(), Justification::centred, false);
            }
        } create;
        Label title;
        NameEditor name;
        std::function<bool(String)> canSave, commit;
        void submit() { if (create.isEnabled() && commit(name.getText().trim())) dismiss(); }
        void dismiss() { if (auto *box = findParentComponentOfClass<CallOutBox>()) box->dismiss(); }
    };
    bool hasCategory(const String &key) const {
        const auto categories = list(get(settings, "samplerCategories"));
        return std::any_of(categories.begin(), categories.end(), [&](const var &category) { return str(category, "id") == key; });
    }
    bool categoryNameAvailable(const String &name, bool midi) const {
        if (name.isEmpty()) return false;
        for (const auto &category : list(get(settings, categoryKey(midi))))
            if (str(category, "name").equalsIgnoreCase(name)) return false;
        return true;
    }
    void createCategory(bool midi = false) {
        auto *host = getTopLevelComponent();
        if (!host) return;
        const auto *user = folders.findKind(midi ? "midiUser" : "user");
        if (!user && presentation == Presentation::library) return;
        const auto target = presentation == Presentation::library
            ? host->getLocalArea(&folders, user->getItemPosition(true)).removeFromRight(1)
            : host->getLocalArea(&picker,picker.getLocalBounds());
        const SafePointer<WorkspaceLibrary> safe(this);
        auto input = std::make_unique<CategoryInput>(
            [safe, midi](String name) { return safe && safe->categoryNameAvailable(name, midi); },
            [safe, midi](String name) {
                if (!safe || !safe->categoryNameAvailable(name, midi)) return false;
                const auto previous = safe->settings.clone();
                auto categories = list(get(safe->settings, categoryKey(midi)));
                const auto id = text(uuid());
                auto category = object(); put(category, "id", id); put(category, "name", name); categories.add(category);
                put(safe->settings, categoryKey(midi), categories);
                if (!safe->persist()) { safe->settings = previous; return false; }
                safe->expanded.insert(midi ? "midiUser" : "user");
                safe->rebuildFolders();
                safe->select({name, id, categoryKind(midi)});
                return true;
            });
        const SafePointer<CategoryInput> field(input.get());
        static CategoryCalloutLook look;
        auto &box = CallOutBox::launchAsynchronously(std::move(input), target, host);
        box.setLookAndFeel(&look);
        box.setArrowSize(13);
        const auto area = host->getLocalBounds();
        if (area.getRight() - target.getRight() >= 220)
            box.updatePosition(target, area.withLeft(target.getX()));
        MessageManager::callAsync([field] { if (field) field->focus(); });
    }
    void confirmDeleteCategory(const Row &row) {
        if (importing || store->importingCategories.count(row.key) || !hasCategory(row.key)) return;
        ConfirmationPanel::show(MessageBoxIconType::QuestionIcon, localization::translate("Excluir") + " " + row.title,
            localization::english ? "Remove this category and its samples from the Library?"
                                  : String::fromUTF8("Excluir esta categoria e seus samples da Library?"),
            localization::translate("Excluir"), localization::translate("Cancelar"), this,
            ModalCallbackFunction::create([safe = SafePointer<WorkspaceLibrary>(this), id = row.key](int answer) {
                if (safe && answer == 1) safe->deleteCategory(id);
            }));
    }
    void deleteCategory(const String &id) {
        if (importing || store->importingCategories.count(id) || !hasCategory(id)) return;
        const auto samplerRoot = root().getChildFile("Samplers");
        const auto directory = samplerRoot.getChildFile(id);
        if (directory.getParentDirectory() != samplerRoot) return;
        if (previewFile != File{} && previewFile.getParentDirectory() == directory) stopPreview();
        File staged;
        if (directory.exists()) {
            staged = samplerRoot.getNonexistentChildFile(".removed-category", {}, false);
            if (!directory.moveFileTo(staged)) { warn("Could not remove the sampler category."); return; }
        }
        const auto previous = settings.clone();
        auto categories = list(get(settings, "samplerCategories"));
        for (int i = categories.size(); --i >= 0;)
            if (str(categories[i], "id") == id) categories.remove(i);
        auto favorites = list(get(settings, "favorites"));
        for (int i = favorites.size(); --i >= 0;)
            if (favorites[i].toString().startsWith(id + "/")) favorites.remove(i);
        put(settings, "samplerCategories", categories);
        put(settings, "favorites", favorites);
        if (!persist()) {
            settings = previous;
            if (staged.exists() && !staged.moveFileTo(directory)) warn("Could not restore the sampler category.");
            return;
        }
        if (staged.exists()) staged.moveToTrash();
        if (current.kind == "samplerCategory" && current.key == id) select({});
        rebuildFolders();
        reloadEntries();
    }
    void confirmDeletePadSamples() {
        ConfirmationPanel::show(MessageBoxIconType::QuestionIcon, localization::translate("Delete Pads?"),
            localization::translate("Delete these samples and clear them from all Pads that use them?"),
            localization::translate("Excluir"), localization::translate("Cancelar"), this,
            ModalCallbackFunction::create([safe = SafePointer<WorkspaceLibrary>(this)](int answer) {
                if (!safe || answer != 1) return;
                if (safe->previewFile.getParentDirectory() == VinhetasPanel::padSampleDirectory()) safe->stopPreview();
                const auto result = VinhetasPanel::deletePadSamples();
                if (result.failed()) { safe->warn(localization::translate(result.getErrorMessage())); return; }
                auto favorites = list(get(safe->settings, "favorites"));
                for (int i = favorites.size(); --i >= 0;)
                    if (favorites[i].toString().startsWith("Pads/")) favorites.remove(i);
                put(safe->settings, "favorites", favorites);
                safe->persist();
                safe->refreshPadSamples();
            }));
    }
    void createNote(String existing = {}) {
        auto *host = getTopLevelComponent();
        if (!host) return;
        String initial;
        if (existing.isNotEmpty())
            for (const auto &note : list(get(settings,"notes"))) if (str(note,"id") == existing) initial = str(note,"name");
        const SafePointer<WorkspaceLibrary> safe(this);
        auto field = std::make_unique<CategoryInput>([](String name) { return name.isNotEmpty(); },
            [safe,existing](String name) {
                if (!safe || name.isEmpty()) return false;
                const auto snapshot = safe->settings.clone();
                auto notes = list(get(safe->settings,"notes"));
                String id = existing;
                if (id.isEmpty()) {
                    id = text(uuid());
                    auto note = object();
                    put(note,"id",id); put(note,"text",String{}); put(note,"name",name);
                    notes.add(note);
                } else {
                    for (auto note : notes) if (str(note,"id") == id) put(note,"name",name);
                }
                put(safe->settings,"notes",notes);
                if (!safe->persist()) { safe->settings = snapshot; return false; }
                safe->expanded.insert("annotation");
                safe->rebuildFolders();
                safe->pickerTitle.setText(name,dontSendNotification);
                safe->select({name,id,"note"});
                return true;
            }, existing.isEmpty() ? "Note name" : "Rename note", 0, initial, existing.isEmpty() ? "Create" : "Save");
        const SafePointer<CategoryInput> input(field.get());
        static CategoryCalloutLook look;
        const auto target = presentation != Presentation::library ? host->getLocalArea(&picker,picker.getLocalBounds())
            : host->getLocalArea(this,getLocalBounds().withHeight(32).withWidth(std::max(1,folders.getWidth())).removeFromRight(1));
        auto &box = CallOutBox::launchAsynchronously(std::move(field),target,host);
        box.setLookAndFeel(&look);
        MessageManager::callAsync([input] { if (input) input->focus(); });
    }
    void deleteNote(const String &id) {
        auto notes = list(get(settings, "notes"));
        for (int index = notes.size(); --index >= 0;) if (str(notes[index], "id") == id) notes.remove(index);
        put(settings, "notes", notes);
        persist();
        if (current.kind == "note" && current.key == id) select({});
        rebuildFolders();
    }
    void chooseSoundFonts() {
        if (importingSoundFonts) return;
        chooser = std::make_unique<FileChooser>(localization::translate(String::fromUTF8("Import SF2…")),
                                               File::getSpecialLocation(File::userDocumentsDirectory), "*.sf2");
        chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles |
            FileBrowserComponent::canSelectMultipleItems, [safe=SafePointer<WorkspaceLibrary>(this)](const FileChooser &dialog) {
                const auto files = dialog.getResults();
                if (!safe || files.isEmpty()) return;
                safe->expanded.insert("instruments");
                safe->rebuildFolders();
                safe->select({userSoundFontCategoryName,"user","instrumentCategory"});
                safe->search.setText({},sendNotificationSync);
                safe->importingSoundFonts = true;
                sampleWorker().addJob([safe,files] {
                    StringArray failures;
                    const auto destination = instrumentAssets::library().getChildFile("User");
                    const auto directory = destination.createDirectory();
                    for (const auto &file : files) {
                        try {
                            if (directory.failed()) throw std::runtime_error("Could not create the User instrument folder.");
                            const auto label = file.getFileNameWithoutExtension();
                            File target;
                            for (int index = 1; ; ++index) {
                                const auto suffix = index == 1 ? String{} : " (" + String(index) + ")";
                                auto name = label;
                                auto id = instrumentAssets::userInstrumentID(name+suffix);
                                while (!instrumentAssets::validID(id)) {
                                    name = name.dropLastCharacters(1);
                                    id = instrumentAssets::userInstrumentID(name+suffix);
                                }
                                target = destination.getChildFile(id+".sf2");
                                if (!target.exists()) break;
                            }
                            TemporaryFile staging(target);
                            if (!file.copyFileTo(staging.getFile())) throw std::runtime_error("Could not copy SF2.");
                            Instrument bank;
                            bank.loadSoundFont(staging.getFile());
                            if (!staging.overwriteTargetFileWithTemporary()) throw std::runtime_error("Could not save SF2.");
                        } catch (const std::exception &) { failures.add(file.getFileName()); }
                    }
                    MessageManager::callAsync([safe,failures] {
                        if (!safe) return;
                        safe->importingSoundFonts = false;
                        safe->reloadEntries();
                        if (!failures.isEmpty())
                            safe->warn(localization::translate("Could not import SF2:") + " " + failures.joinIntoString(", "));
                    });
                });
            });
    }
    bool pasteMIDI(const KeyPress &key) {
        const auto mods = key.getModifiers();
        const auto code = key.getKeyCode();
        // WM_CHAR can deliver Ctrl+V as the control character 22.
        if (current.kind != "midiCategory" || !mods.isCtrlDown() || mods.isAltDown() || mods.isShiftDown() ||
            (code != 'V' && code != 'v' && code != 22)) return false;
        if (importingMIDI) return true;
        std::vector<jaras::AudioClip> clips;
        Array<File> files;
        try {
            if (gridMediaClipboard::ownsItems(gridMediaClipboard::sharedItems.has_value(),
                    gridMediaClipboard::sharedSequence, GetClipboardSequenceNumber())) {
                for (const auto &track : gridMediaClipboard::sharedItems->tracks)
                    for (const auto &clip : track.clips) if (clip.midi) clips.push_back(clip);
            } else {
                for (const auto &path : gridMediaClipboard::files()) {
                    const File file(path);
                    if (file.hasFileExtension("mid;midi")) files.add(file);
                }
            }
        } catch (const std::exception &error) { warn(String::fromUTF8(error.what())); return true; }
        if (clips.empty() && files.isEmpty()) warn("Copy one or more MIDI items first.");
        else importMIDI(current.key, files, std::move(clips));
        return true;
    }
    void importMIDI(const String &key, const Array<File> &files, std::vector<jaras::AudioClip> clips) {
        if (importingMIDI) return;
        importingMIDI = true;
        const auto folder = root().getChildFile("MIDI").getChildFile(key);
        sampleWorker().addJob([safe = SafePointer<WorkspaceLibrary>(this), folder, files, clips = std::move(clips)] {
            StringArray failures;
            if (folder.createDirectory().failed()) failures.add("Could not create the MIDI folder.");
            else {
                for (const auto &source : files) {
                    MidiFile midi;
                    FileInputStream stream(source);
                    if (source.getSize() > 64 * 1024 * 1024 || !stream.openedOk() || !midi.readFrom(stream) ||
                        !source.copyFileTo(folder.getNonexistentChildFile(source.getFileNameWithoutExtension(), ".mid", false)))
                        failures.add(source.getFileName());
                }
                for (const auto &clip : clips) {
                    auto name = File::createLegalFileName(text(clip.name)).substring(0, 60).trim();
                    if (name.isEmpty()) name = "MIDI";
                    try { exportMIDIItem(clip, folder.getNonexistentChildFile(name, ".mid", true)); }
                    catch (const std::exception &) { failures.add(name); }
                }
            }
            MessageManager::callAsync([safe, failures] {
                if (!safe) return;
                safe->importingMIDI = false;
                if (safe->current.kind == "midiCategory") safe->reloadEntries();
                if (!failures.isEmpty()) safe->warn("MIDI: " + failures.joinIntoString(", "));
            });
        });
    }
    void addSamples(const Row &row) {
        if (importing) return;
        select(row);
        chooser = std::make_unique<FileChooser>(localization::translate("Add Samplers"), File{}, "*.wav;*.wave;*.aif;*.aiff;*.flac;*.mp3;*.ogg");
        chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles |
            FileBrowserComponent::canSelectMultipleItems, [safe = SafePointer<WorkspaceLibrary>(this), key = row.key](const FileChooser &chooser) {
                if (safe) safe->importSamples(key, chooser.getResults());
            });
    }
    void importSamples(const String &key, const Array<File> &files) {
        if (importing || files.isEmpty() || !hasCategory(key) || !store->importingCategories.insert(key).second) return;
        const auto destination = root().getChildFile("Samplers").getChildFile(key);
        importing = true;
        sampleWorker().addJob([safe = SafePointer<WorkspaceLibrary>(this), shared = store, key, files, destination] {
            StringArray failures;
            AudioFormatManager formats; formats.registerBasicFormats();
            for (const auto &file : files) {
                if (destination.createDirectory().failed()) { failures.add(file.getFileName()); continue; }
                TemporaryFile staging(destination.getNonexistentChildFile(file.getFileNameWithoutExtension(), file.getFileExtension(), false));
                if (!file.copyFileTo(staging.getFile())) { failures.add(file.getFileName()); continue; }
                std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(staging.getFile()));
                const bool valid = reader && reader->lengthInSamples > 0 && std::isfinite(reader->sampleRate) && reader->sampleRate > 0;
                reader.reset();
                if (!valid || !staging.overwriteTargetFileWithTemporary()) failures.add(file.getFileName());
            }
            MessageManager::callAsync([safe, shared, key, failures] {
                shared->importingCategories.erase(key);
                ++shared->revision;
                if (!safe) return;
                safe->importing = false;
                safe->loadedRevision = shared->revision;
                safe->reloadEntries();
                if (!failures.isEmpty()) safe->warn(localization::translate("Could not import these samples.") + "\n" + failures.joinIntoString("\n"));
            });
        });
    }
    void togglePreview(const File &file, bool instrument = false, bool drums = false) {
        const bool same = previewFile == file;
        stopPreview();
        if (same) return;
        previewFile = file;
        previewingInstrument = instrument;
        preparingPreview = true;
        const auto generation = previewGeneration;
        auto safe = SafePointer<WorkspaceLibrary>(this);
        sampleWorker().addJob([safe, generation, file, instrument, drums] {
            std::shared_ptr<VinhetasAudio::Sample> decoded;
            std::shared_ptr<LibrarySampleStream> stream;
            String failure;
            try {
                if (instrument) {
                    decoded = std::make_shared<VinhetasAudio::Sample>();
                    decoded->pcm = Instrument::renderLibraryPreview(file, drums);
                    decoded->rate = Instrument::previewSampleRate;
                } else {
                    stream = LibrarySampleStream::open(file);
                }
            } catch (const std::exception &error) {
                failure = String::fromUTF8(error.what());
            }
            MessageManager::callAsync([safe, generation, decoded = std::move(decoded), stream = std::move(stream), failure] {
                if (!safe || generation != safe->previewGeneration) return;
                safe->preparingPreview = false;
                if (failure.isNotEmpty()) { safe->stopPreview(); safe->warn(failure); return; }
                try {
                    if (stream) safe->session.audio.playLibrarySample(stream, safe->previewGain());
                    else safe->session.audio.playLibrarySample(decoded, 1.f);
                } catch (const std::exception &error) { safe->stopPreview(); safe->warn(String::fromUTF8(error.what())); }
            });
        });
        contents.repaint();
    }
    float previewGain() const {
        const auto db = float(previewVolume.getValue());
        return Decibels::decibelsToGain(db, -60.f);
    }
    void stopPreview() {
        ++previewGeneration;
        preparingPreview = false;
        previewingInstrument = false;
        if (previewFile != File{}) session.audio.stopLibrarySample();
        previewFile = File{};
        contents.repaint();
    }
    void refreshCatalogs() {
        auto &plugins = VST3Catalog::shared();
        const auto revision = fxpresets::Store().revision();
        if (pluginRevision == plugins.revision && presetRevision == revision) return;
        pluginRevision = plugins.revision;
        presetRevision = revision;
        try { presets = fxpresets::Store().read(); }
        catch (const std::exception &) { presets = var{}; }
        rebuildFolders();
        reloadEntries();
    }
    uint64_t padSamplesRevision = 0;
    void refreshPadSamples() {
        const auto revision = VinhetasPanel::padSamplesRevision();
        if (padSamplesRevision == revision) return;
        padSamplesRevision = revision;
        if (current.kind == "padSamplerCategory" && !VinhetasPanel::padSampleDirectory().isDirectory()) select({});
        rebuildFolders();
        if (current.kind == "padSamplerCategory" || (current.kind == "favorites" && current.key == "samplers")) reloadEntries();
    }
    void timerCallback() override {
        if (loadedRevision != store->revision) {
            loadedRevision = store->revision;
            rebuildFolders();
            if (current.kind != "note") {
                reloadEntries();
            } else {
                const auto notes = list(get(settings,"notes"));
                const auto item = std::find_if(notes.begin(),notes.end(),[this](const var &note) { return str(note,"id") == current.key; });
                if (item == notes.end()) {
                    const auto available = pickerRows();
                    select(available.empty() ? Row{} : available.front());
                } else {
                    pickerTitle.setText(noteTitle(*item),dontSendNotification);
                    if (!noteEditor || (str(*item,"text") != loadedNoteText && GetFocus() != noteEditor->nativeEditor())) {
                        noteEditor = makeNoteEditor(current,false);
                        if (noteEditor) addAndMakeVisible(*noteEditor);
                        contents.setVisible(!noteEditor);
                        resized();
                    }
                }
            }
        }
        refreshPadSamples();
        if (noteEditor) noteEditor->syncAppearance();
        for (auto it = downloads.begin(); it != downloads.end();) {
            const auto state = it->second->state.load(std::memory_order_acquire);
            if (state < 0) warn(it->second->error);
            if (state != 0) it = downloads.erase(it);
            else ++it;
        }
        if (previewFile != File{} && !preparingPreview && !session.audio.librarySamplePlaying()) stopPreview();
        refreshCatalogs();
        if (current.kind == "instrumentCategory") contents.repaint();
    }
};
} // namespace catlive
