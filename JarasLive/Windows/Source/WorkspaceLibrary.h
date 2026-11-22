#pragma once
#include "ConfirmationPanel.h"
#include "DragDivider.h"
#include "DesktopToolbarSymbols.h"
#include "FXPresets.h"
#include "Instrument.h"
#include "InlineMixerTrackName.h"
#include "LibraryNoteEditor.h"
#include "LibraryMIDIChords.h"
#include "TimelineRegionLabels.h"
#include "VinhetasPanel.h"
#include "VST3Catalog.h"

namespace catlive {
class WorkspaceLibrary final : public Component, private Timer {
  public:
    explicit WorkspaceLibrary(Session &owner) : session(owner) {
        settings = JSON::parse(root().getChildFile("Library.json"));
        if (!settings.isObject()) settings = object();
        setComponentID("workspace-library-panel");
        addAndMakeVisible(folders);
        addAndMakeVisible(contents);
        addAndMakeVisible(divider);
        addAndMakeVisible(collapseCategories);
        collapseCategories.getProperties().set("icon", "arrow.up.and.down.text.horizontal");
        collapseCategories.getProperties().set("iconSize", 16.f);
        collapseCategories.setTitle(localization::translate("Collapse all categories"));
        collapseCategories.setTooltip(localization::translate("Collapse all categories"));
        collapseCategories.setComponentID("library-collapse-categories");
        collapseCategories.onClick = [this] {
            expanded.clear();
            rebuildFolders();
            folders.scrollToEnsureRowIsOnscreen(0);
        };
        addChildComponent(timelineName);
        timelineName.setComponentID("library-timeline-name");
        timelineName.navigate = [this](int direction) {
            const auto &entries = itemRows.entries;
            const int index = timelineNameRow();
            if (index < 0 || !isPositiveAndBelow(index + direction, int(entries.size()))) return;
            const auto next = entries[size_t(index + direction)];
            timelineName.confirm();
            beginTimelineRename(next);
        };
        addChildComponent(search);
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
        previewVolume.setSliderStyle(Slider::LinearHorizontal);
        previewVolume.setTextBoxStyle(Slider::NoTextBox, true, 0, 0);
        previewVolume.setRange(-60, 0, 1);
        previewVolume.textFromValueFunction = [](double db) {
            return db <= -60 ? String::fromUTF8("−∞ dB") : String(db, 0) + " dB";
        };
        previewVolume.setValue(num(settings, "samplerPreviewDB"), dontSendNotification);
        previewVolume.onValueChange = [this] {
            put(settings, "samplerPreviewDB", previewVolume.getValue());
            if (!previewingInstrument) session.audio.setLibrarySampleGain(previewGain());
            if (!previewVolume.isMouseButtonDown()) persist();
        };
        for (auto* list : { &folders, &contents }) {
            list->setColour(ListBox::backgroundColourId, Colours::transparentBlack);
            list->setOpaque(false);
        }
        folders.setRowHeight(26);
        contents.setRowHeight(28);
        contents.setRowSelectedOnMouseDown(false);
        previewVolume.onDragEnd = [this] { persist(); };
        divider.setThinRail(true);
        divider.setScrollRailVisible(false);
        divider.started = [this] { resizeStart = folders.getWidth(); };
        divider.moved = [this](int dx) {
            const auto next = jlimit(90, std::max(90, getWidth() - 99), resizeStart + dx);
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
    int maximumPanelWidth() const { return std::max(90, folderWidth) + 1 + 364; }
    void visibilityChanged() override {
        if (isVisible()) {
            refreshCatalogs();
            refreshTimelineEntries();
            startTimerHz(8);
        } else {
            timelineName.confirm();
            stopTimer();
            stopPreview();
        }
    }
    void refreshTimelineEntries() {
        if (!isVisible() || !timelineCategory()) return;
        const auto song = session.song() ? session.song()->id : ID{};
        if (timelineRevision == session.revision && timelineSong == song) return;
        timelineRevision = session.revision;
        if (timelineSong != song) selectedTimelineKey.clear();
        timelineSong = song;
        reloadEntries();
    }
    void resized() override {
        auto area = getLocalBounds();
        const int minimum = std::min(getWidth() / 2, 90);
        const int width = jlimit(minimum, std::max(minimum, getWidth() - 99), folderWidth);
        auto folderArea = area.removeFromLeft(width);
        area.removeFromLeft(1);
        auto toolbar = folderArea.removeFromTop(32).reduced(6, 4);
        collapseCategories.setBounds(toolbar.removeFromRight(25));
        folders.setBounds(folderArea);
        divider.setBounds(width - 3, 0, 6, getHeight());
        if (search.isVisible()) search.setBounds(area.removeFromTop(32).reduced(6, 4));
        if (previewVolume.isVisible()) previewVolume.setBounds(area.removeFromTop(32).reduced(6, 0));
        contents.setBounds(area);
        if (noteEditor) noteEditor->setBounds(area.reduced(4));
        layoutTimelineName();
        divider.toFront(false);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::mixerPanelBackground());
        g.setColour(theme::libraryEntriesBackground());
        g.fillRect(getLocalBounds().withTrimmedLeft(folders.getWidth()));
        g.setColour(theme::line);
        g.drawHorizontalLine(31, 0, float(folders.getWidth()));
    }

  private:
    struct Row { String title, key, kind; var payload; File file; bool separator = false; };
    struct Rows final : ListBoxModel {
        WorkspaceLibrary &owner;
        const bool navigation;
        std::vector<Row> entries;
        Rows(WorkspaceLibrary &panel, bool nav) : owner(panel), navigation(nav) {}
        int getNumRows() override { return int(entries.size()); }
        String getNameForRow(int row) override { return isPositiveAndBelow(row, getNumRows()) ? entries[size_t(row)].title : String{}; }
        void paintListBoxItem(int row, Graphics &g, int width, int height, bool) override {
            if (isPositiveAndBelow(row, getNumRows())) owner.paintRow(entries[size_t(row)], row, g, width, height, navigation);
        }
        void listBoxItemClicked(int row, const MouseEvent &e) override {
            if (isPositiveAndBelow(row, getNumRows())) owner.click(entries[size_t(row)], e, navigation);
        }
        void listWasScrolled() override {
            if (!navigation) owner.layoutTimelineName();
        }
        void returnKeyPressed(int row) override {
            if (navigation && isPositiveAndBelow(row, getNumRows()) && !entries[size_t(row)].separator)
                owner.select(entries[size_t(row)]);
        }
        var getDragSourceDescription(const SparseSet<int> &rows) override {
            if (navigation || rows.size() != 1 || !isPositiveAndBelow(rows[0], getNumRows())) return {};
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
            else if (row.kind == "sample") {
                auto payload = object();
                put(payload, "type", "catlive-library-sampler");
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
    var settings, presets;
    Rows folderRows{*this, true}, itemRows{*this, false};
    ListBox folders{"Library folders", &folderRows}, contents{"Library entries", &itemRows};
    QuietButton collapseCategories;
    TextEditor search;
    InlineMixerTrackName timelineName;
    String editingTimelineKey, selectedTimelineKey;
    ID timelineSong;
    uint64 timelineRevision = 0;
    std::vector<Row> categoryEntries;
    Slider previewVolume;
    DragDivider divider;
    int folderWidth = 146, resizeStart = 0;
    std::set<String> expanded;
    Row current;
    std::unique_ptr<LibraryNoteEditor> noteEditor;
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
    static constexpr int playOffset = 42, starOffset = 24;
    static File root() {
        return File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive/Library");
    }
    static ThreadPool &sampleWorker() { static ThreadPool worker(1); return worker; }
    static bool disclosure(const Row &row) { return row.kind == "folder" || row.kind == "user"; }
    bool persist() {
        auto folder = root();
        if (folder.createDirectory().wasOk() && folder.getChildFile("Library.json").replaceWithText(JSON::toString(settings)))
            return true;
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
        auto &rows = folderRows.entries;
        rows.clear();
        const auto folder = [&](String title, String key) {
            rows.push_back({title, key, "folder"});
            return expanded.count(key) != 0;
        };
        if (folder("Instruments", "instruments")) {
            for (auto [key, title] : std::vector<std::pair<String, String>>{
                {"user","User"}, {"pianos","Grand Pianos"}, {"upright","Upright"}, {"electric","Electric"}, {"keyboard","Keyboard"},
                {"organ","Organ"}, {"strings","Strings"}, {"guitar","Guitar"}, {"bass","Bass"}, {"synth","Synth"},
                {"synthPad","Synth Pad"}, {"lead","Lead"}, {"acordeon","Acordeon"}, {"brass","Brass"}, {"mallets","Mallets"}, {"drum","Drum"}
            }) rows.push_back({title, key, "instrumentCategory"});
        }
        rows.push_back({{}, {}, {}, {}, {}, true});
        if (folder("Plugins", "plugins")) {
            rows.push_back({"All", {}, "pluginCategory"});
            rows.push_back({"Native", "native", "pluginCategory"});
            for (const auto &type : libraryPluginCategories(VST3Catalog::shared())) rows.push_back({type, type, "pluginCategory"});
        }
        rows.push_back({{}, {}, {}, {}, {}, true});
        if (folder("Samplers", "samplers")) {
            rows.push_back({"User", "user", "user"});
            if (expanded.count("user"))
                for (const auto &category : list(get(settings, "samplerCategories")))
                    rows.push_back({str(category, "name"), str(category, "id"), "samplerCategory"});
            if (VinhetasPanel::padSampleDirectory().isDirectory())
                rows.push_back({"Pads", "Pads", "padSamplerCategory"});
            for (const auto &category : nativeSampleCategories())
                rows.push_back({category, category, "nativeSamplerCategory"});
        }
        rows.push_back({{}, {}, {}, {}, {}, true});
        if (folder("Midi", "midi")) {
            for (auto category : {"Major", "Minor", "Other"}) rows.push_back({category, category, "chordCategory"});
        }
        rows.push_back({{}, {}, {}, {}, {}, true});
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
        rows.push_back({{}, {}, {}, {}, {}, true});
        if (folder("Notes", "annotation")) {
            for (const auto &note : list(get(settings, "notes"))) {
                auto title = ItemTextColors::plain(str(note, "text")).upToFirstOccurrenceOf("\n", false, false).trim();
                rows.push_back({title.isNotEmpty() ? title : localization::translate("New note"), str(note, "id"), "note"});
            }
        }
        rows.push_back({{}, {}, {}, {}, {}, true});
        rows.push_back({"Region", {}, "regions"});
        rows.push_back({"Markers", {}, "markers"});
        folders.updateContent();
        folders.repaint();
    }
    std::unique_ptr<LibraryNoteEditor> makeNoteEditor(const Row &row) {
        for (auto note : list(get(settings, "notes"))) {
            if (str(note, "id") != row.key) continue;
            return std::make_unique<LibraryNoteEditor>(str(note, "text"), [this, note](String text) mutable {
                put(note, "text", std::move(text));
                persist();
                rebuildFolders();
            });
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
        if (row.kind != current.kind || row.key != current.key) {
            search.setText({}, false);
            if (previewingInstrument) stopPreview();
        }
        current = std::move(row);
        search.setVisible(current.kind != "note");
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
    static const StringArray &nativeSampleCategories() {
        static const StringArray categories{"Cymbals", "FX", "FX Brazil", "Kick", "Percussion", "Snare", "Toms"};
        return categories;
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
            for (const auto &category : nativeSampleCategories()) samplesFor(rows, category, true, true);
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
                    if (normalMarker(marker))
                        rows.push_back({text(marker.name), text(marker.id), "markerLabel", marker.position});
            }
            std::stable_sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) {
                return double(a.payload) < double(b.payload);
            });
        }
        const bool showPreview = current.kind == "samplerCategory" || current.kind == "padSamplerCategory" || current.kind == "nativeSamplerCategory" ||
            (current.kind == "favorites" && current.key == "samplers");
        if (showPreview)
            std::stable_sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) { return a.title.compareNatural(b.title) < 0; });
        if (previewVolume.isVisible() != showPreview) { previewVolume.setVisible(showPreview); resized(); }
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
    static bool normalMarker(const jaras::TimelineMarker &marker) {
        return !marker.tempoBPM && !marker.section.value_or(false) && !marker.unifiedRegionID && !marker.sourceRegionID;
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
            for (const auto &marker : *song->markers) if (marker.id == id && normalMarker(marker)) { value = text(marker.name); break; }
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
                    safe->session.edit([&](auto &draft) {
                        for (auto &song : draft.songs) if (song.id == songID) {
                            if (region) {
                                for (auto &part : song.parts) if (part.id == id) part.name = utf8(next);
                                if (song.markers) for (auto &marker : *song.markers)
                                    if (marker.sourceRegionID == id) marker.name = utf8(next);
                            } else if (song.markers) for (auto &marker : *song.markers)
                                if (marker.id == id && normalMarker(marker)) marker.name = utf8(next.substring(0, 256));
                        }
                    }, false);
                } catch (const std::exception &error) { safe->warn(String::fromUTF8(error.what())); }
            });
    }
    void paintRow(const Row &row, int index, Graphics &g, int width, int height, bool navigation) {
        if (row.separator) {
            g.setColour(theme::line);
            g.drawHorizontalLine(height / 2, 7, float(width - 7));
            return;
        }
        const bool selected = navigation ? row.kind == current.kind && row.key == current.key
                                         : timelineCategory() && row.key == selectedTimelineKey;
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
                else icon = "library." + row.key;
            } else if (row.kind == "note") icon = "doc.text";
            else if (row.kind == "regions") icon = "rectangle";
            else if (row.kind == "markers") icon = "flag";
            else if (row.kind == "pluginCategory" && row.key.isEmpty()) icon = "square.grid.2x2";
            drawControlIcon(g, icon, selected || (disclosure(row) && expanded.count(row.key)),
                            {19.f, y - 8.f, 16.f, 16.f}, 1.f);
            start = 39;
        } else if (row.kind == "sample" || row.kind == "native" || row.kind == "external") {
            const float y = height * .5f;
            g.setColour(favorited(row) ? theme::yellow : theme::secondary);
            Path star;
            star.addStar({float(width - starOffset + 8), y}, 5, 2.5f, 5.4f);
            if (favorited(row)) g.fillPath(star);
            else g.strokePath(star, PathStrokeType(1.f));
            trailing = starOffset;
            if (row.kind == "sample") {
                const float x = float(width - playOffset + 9);
                const bool playing = previewFile == row.file;
                g.setColour(playing ? theme::green : theme::secondary);
                if (playing) g.fillRect(x - 4, y - 4, 8.f, 8.f);
                else { Path play; play.addTriangle(x - 3, y - 4, x + 4, y, x - 3, y + 4); g.fillPath(play); }
                trailing = playOffset;
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
        if (row.separator) return;
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
            const auto &transport = session.transport();
            if (transport.playing || transport.subPlay.playing || transport.paused || session.busy || jaras::projectSync::readOnly()) return;
            if (!selectTimelineEntry) return;
            selectTimelineEntry(utf8(row.key), row.kind == "regionLabel", double(row.payload));
            selectedTimelineKey = row.key;
            contents.repaint();
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
        if (row.kind == "folder" && row.key == "instruments")
            menu.addItem(8, localization::translate(String::fromUTF8("Import SF2…")), !importingSoundFonts);
        if (row.kind == "user") menu.addItem(1, localization::translate("Create category"));
        if (row.kind == "samplerCategory") {
            menu.addItem(2, localization::translate("Add Samplers"), !importing);
            menu.addItem(6, localization::translate("Excluir"), !importing);
        }
        if (row.kind == "padSamplerCategory") menu.addItem(7, localization::translate("Excluir"));
        if (row.key == "annotation" && row.kind == "folder") menu.addItem(3, localization::translate("New note"));
        if (row.kind == "note") menu.addItem(4, localization::translate("Delete note"));
        if (row.kind == "instrument" && instrumentAssets::installedFile(row.key).existsAsFile())
            menu.addItem(5, localization::translate("Delete instrument"));
        if (!menu.getNumItems()) return;
        menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({position.x, position.y, 1, 1}),
            [safe = SafePointer<WorkspaceLibrary>(this), row](int choice) {
                if (!safe) return;
                switch (choice) {
                    case 1: safe->createCategory(); break;
                    case 2: safe->addSamples(row); break;
                    case 3: safe->createNote(); break;
                    case 4: safe->deleteNote(row.key); break;
                    case 6: safe->confirmDeleteCategory(row); break;
                    case 7: safe->confirmDeletePadSamples(); break;
                    case 8: safe->chooseSoundFonts(); break;
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
        CategoryInput(std::function<bool(String)> validate, std::function<bool(String)> save)
            : canSave(std::move(validate)), commit(std::move(save)) {
            setComponentID("library-category-popover");
            title.setText(localization::translate("Create category"), dontSendNotification);
            title.setFont(theme::semiboldFont(13));
            title.setColour(Label::textColourId, Colours::white);
            title.setBorderSize({});
            addAndMakeVisible(title);
            name.setComponentID("library-category-name");
            name.setInputRestrictions(12);
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
            create.setEnabled(false);
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
            CreateButton() : Button(localization::translate("Create")) {}
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
    bool categoryNameAvailable(const String &name) const {
        if (name.isEmpty()) return false;
        for (const auto &category : list(get(settings, "samplerCategories")))
            if (str(category, "name").equalsIgnoreCase(name)) return false;
        return true;
    }
    void createCategory() {
        auto *host = getTopLevelComponent();
        if (!host) return;
        const auto &rows = folderRows.entries;
        const auto user = std::find_if(rows.begin(), rows.end(), [](const Row &row) { return row.kind == "user"; });
        if (user == rows.end()) return;
        const auto bounds = folders.getRowPosition((int)std::distance(rows.begin(), user), true);
        const auto target = host->getLocalArea(&folders, bounds).removeFromRight(1);
        const SafePointer<WorkspaceLibrary> safe(this);
        auto input = std::make_unique<CategoryInput>(
            [safe](String name) { return safe && safe->categoryNameAvailable(name); },
            [safe](String name) {
                if (!safe || !safe->categoryNameAvailable(name)) return false;
                const auto previous = safe->settings.clone();
                auto categories = list(get(safe->settings, "samplerCategories"));
                const auto id = text(uuid());
                auto category = object(); put(category, "id", id); put(category, "name", name); categories.add(category);
                put(safe->settings, "samplerCategories", categories);
                if (!safe->persist()) { safe->settings = previous; return false; }
                safe->expanded.insert("user");
                safe->rebuildFolders();
                safe->select({name, id, "samplerCategory"});
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
        if (importing || !hasCategory(row.key)) return;
        ConfirmationPanel::show(MessageBoxIconType::QuestionIcon, localization::translate("Excluir") + " " + row.title,
            localization::english ? "Remove this category and its samples from the Library?"
                                  : String::fromUTF8("Excluir esta categoria e seus samples da Library?"),
            localization::translate("Excluir"), localization::translate("Cancelar"), this,
            ModalCallbackFunction::create([safe = SafePointer<WorkspaceLibrary>(this), id = row.key](int answer) {
                if (safe && answer == 1) safe->deleteCategory(id);
            }));
    }
    void deleteCategory(const String &id) {
        if (importing || !hasCategory(id)) return;
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
    void createNote() {
        auto notes = list(get(settings, "notes"));
        const auto id = text(uuid());
        auto note = object(); put(note, "id", id); put(note, "text", String{}); notes.add(note);
        put(settings, "notes", notes);
        persist();
        expanded.insert("annotation");
        rebuildFolders();
        select({localization::translate("New note"), id, "note"});
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
                safe->select({"User","user","instrumentCategory"});
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
    void addSamples(const Row &row) {
        if (importing) return;
        select(row);
        chooser = std::make_unique<FileChooser>(localization::translate("Add Samplers"), File{}, "*.wav;*.wave;*.aif;*.aiff;*.flac;*.mp3;*.ogg");
        chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles |
            FileBrowserComponent::canSelectMultipleItems, [safe = SafePointer<WorkspaceLibrary>(this), key = row.key](const FileChooser &chooser) {
                if (!safe || chooser.getResults().isEmpty() || !safe->hasCategory(key)) return;
                const auto files = chooser.getResults();
                const auto destination = root().getChildFile("Samplers").getChildFile(key);
                safe->importing = true;
                sampleWorker().addJob([safe, files, destination] {
                    StringArray failures;
                    AudioFormatManager formats; formats.registerBasicFormats();
                    for (const auto &file : files) {
                        if (destination.createDirectory().failed()) { failures.add(file.getFileName()); continue; }
                        TemporaryFile staging(destination.getNonexistentChildFile(file.getFileNameWithoutExtension(), file.getFileExtension(), false));
                        if (!file.copyFileTo(staging.getFile())) { failures.add(file.getFileName()); continue; }
                        std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(staging.getFile()));
                        const bool valid = reader && VinhetasAudio::acceptsDuration(reader->lengthInSamples, reader->sampleRate);
                        reader.reset();
                        if (!valid || !staging.overwriteTargetFileWithTemporary()) failures.add(file.getFileName());
                    }
                    MessageManager::callAsync([safe, failures] {
                        if (!safe) return;
                        safe->importing = false;
                        safe->reloadEntries();
                        if (!failures.isEmpty()) safe->warn(localization::translate("Samplers must be between 0 and 60 seconds.") + "\n" + failures.joinIntoString("\n"));
                    });
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
            String failure;
            try {
                if (instrument) {
                    decoded = std::make_shared<VinhetasAudio::Sample>();
                    decoded->pcm = Instrument::renderLibraryPreview(file, drums);
                    decoded->rate = Instrument::previewSampleRate;
                } else {
                    decoded = VinhetasAudio::decode(file, 3.);
                }
            } catch (const std::exception &error) {
                failure = String::fromUTF8(error.what());
            }
            MessageManager::callAsync([safe, generation, decoded = std::move(decoded), failure] {
                if (!safe || generation != safe->previewGeneration) return;
                safe->preparingPreview = false;
                if (failure.isNotEmpty()) { safe->stopPreview(); safe->warn(failure); return; }
                try { safe->session.audio.playLibrarySample(decoded, safe->previewingInstrument ? 1.f : safe->previewGain()); }
                catch (const std::exception &error) { safe->stopPreview(); safe->warn(String::fromUTF8(error.what())); }
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
