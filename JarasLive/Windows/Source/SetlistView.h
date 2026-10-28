// Included by Workspace.cpp inside namespace catlive after the timeline implementation.
class Workspace::Setlist final : public Component,
                                 public DragAndDropContainer,
                                 public DragAndDropTarget,
                                 private ListBoxModel,
                                 private ChangeListener, private Timer {
  public:
    bool stepPlaylist(int direction) {
        if (!w.session.song()) return false;
        auto state = currentState();
        std::vector<jaras::ID> ids;
        for (const auto &playlist : state.playlists)
            if (playlist.songId == w.session.song()->id) ids.push_back(playlist.id);
        if (ids.empty()) return false;
        const auto found = std::find(ids.begin(), ids.end(), state.selectedId.value_or(jaras::ID{}));
        const int count = (int)ids.size();
        const int index = found == ids.end() ? (direction > 0 ? 0 : count - 1)
            : ((int)std::distance(ids.begin(), found) + direction + count) % count;
        state.selectedId = ids[(size_t)index];
        apply(std::move(state));
        return true;
    }
    explicit Setlist(Workspace &owner) : w(owner) {
        w.appearance.addChangeListener(this);
        addAndMakeVisible(list);
        list.setComponentID("setlistRows");
        list.setModel(this);
        list.heightForRow = [this](int row) { return row >= 0 && row < (int)entries.size() && entries[(size_t)row].block ? 28 : 38; };
        list.dragNameForRow = [this](int row) { return row >= 0 && row < (int)entries.size() ? entries[(size_t)row].name : String{}; };
        list.setColour(ListBox::backgroundColourId, theme::background);
        list.setMultipleSelectionEnabled(true);
        list.setOutlineThickness(0);
        list.getViewport()->setScrollBarsShown(false, false, true, false);
        footerVisible = (bool)w.appearance.value("catlive.setlist.footerVisible", true);
        addAndMakeVisible(footerToggle);
        footerToggle.setComponentID("setlist-footer-visibility");
        footerToggle.onClick = [this] {
            const auto result = w.appearance.set("catlive.setlist.footerVisible", !footerVisible);
            if (result.failed()) w.showError(result.getErrorMessage());
            else { footerVisible = !footerVisible; resized(); repaint(); }
        };
        addAndMakeVisible(playlistMenu);
        playlistMenu.setName("Escolher playlist");
        playlistMenu.setComponentID("setlistPlaylistSelector");
        playlistMenu.context = [this] { playlistOptions(currentState().selectedId, false); };
        playlistMenu.open = [this] { choosePlaylist(); };
        playlistMenu.getProperties().set("outlined", true);
        playlistMenu.onChange = [this] {
            if (refreshing)
                return;
            auto state = currentState();
            auto index = playlistMenu.getSelectedId() - 2;
            if (index < 0)
                state.selectedId.reset();
            else if ((size_t)index < state.playlists.size()) {
                auto selected = state.playlists[(size_t)index];
                if (!w.session.song() || w.session.song()->id != selected.songId)
                    w.perform(
                        [&] { w.session.command(jaras::CommandKind::select, selected.songId); });
                state.selectedId = selected.id;
            }
            apply(std::move(state));
        };
        for (auto *button : std::initializer_list<Button *>{
                 &addPlaylist, &searchButton, &automatic, &blocks, &stop, &live, &bypass, &parts}) {
            addAndMakeVisible(button);
            button->setWantsKeyboardFocus(false);
        }
        addPlaylist.setTooltip("Criar playlist");
        addPlaylist.getProperties().set("fontSize", 17);
        searchButton.getProperties().set("icon", "search");
        for (auto *b : {&addPlaylist, &searchButton})
            b->getProperties().set("plain", true);
        for (auto *b : std::initializer_list<TextButton *>{&bypass, &live, &parts}) {
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 11);
        }
        for (auto *b : std::initializer_list<TextButton *>{&automatic, &blocks, &stop}) {
            b->getProperties().set("fontSize", 9);
            b->getProperties().set("boldWeight", true);
        }
        bypass.setColour(TextButton::buttonColourId, Colour(0xffff3030));
        bypass.setColour(TextButton::buttonOnColourId, Colour(0xffffd600));
        bypass.setColour(TextButton::textColourOffId, Colours::black);
        bypass.setColour(TextButton::textColourOnId, Colours::black);
        bypass.onClick = [this] {
            w.perform([&] { w.session.command(jaras::CommandKind::toggleMultiLoopBypass); });
        };
        live.setColour(TextButton::buttonColourId, theme::liveOffRed);
        live.setColour(TextButton::buttonOnColourId, theme::green);
        live.setColour(TextButton::textColourOffId, Colours::black);
        live.setColour(TextButton::textColourOnId, Colours::black);
        parts.setComponentID("setlistParts");
        parts.onClick = [this] {
            w.toggleRightParts();
        };
        addPlaylist.onClick = [this] { createPlaylist(); };
        searchButton.setTooltip("Search songs");
        searchButton.setComponentID("setlistSearchToggle");
        searchButton.onClick = [this] { setSearching(!searching); };
        addChildComponent(search);
        search.setComponentID("setlistSearchField");
        search.setFont(theme::font(13));
        search.setTextToShowWhenEmpty("Search songs", theme::secondary);
        search.onTextChange = [this] { if (searchPanel) searchPanel->refresh(true); };
        search.onEscapeKey = [this] { setSearching(false); };
        search.onTab = [this] { setSearching(false); };
        search.onReturnKey = [this] { if (searchPanel) searchPanel->chooseSelected(); };
        search.onMove = [this](int delta) { if (searchPanel) searchPanel->moveSelection(delta); };
        automatic.setTooltip("Queue the next song automatically");
        automatic.onClick = [this] {
            auto state = currentState();
            state.autoAdvance = !state.autoAdvance;
            apply(state);
        };
        automatic.context = [this](Point<int>) { autoOptions(); };
        blocks.setTooltip("Add a setlist block");
        blocks.onClick = [this] { addBlock(); };
        blocks.context = [this](Point<int>) { blockDefaults(); };
        stop.setTooltip("Stop automatically at the end of each region");
        stop.onClick = [this] {
            auto state = currentState();
            state.stopAtRegionEnd = !state.stopAtRegionEnd.value_or(false);
            apply(state);
        };
        live.setTooltip("Mark songs played during this show");
        auto safe = SafePointer<Setlist>(this);
        live.onClick = [this, safe] {
            auto change = [self = safe] {
                if (!self)
                    return;
                auto state = self->currentState();
                state.liveEnabled = !state.liveEnabled.value_or(false);
                state.playedLiveRegionIDs = std::vector<ID>{};
                self->apply(state);
            };
            if (currentState().liveEnabled.value_or(false))
                w.confirm("Turn off Live?", "This clears all played-song marks for this show.",
                          change);
            else
                change();
        };
        refresh();
    }
    ~Setlist() override { setSearching(false); w.appearance.removeChangeListener(this); }
    void toggleSearch() { setSearching(!searching); }
    bool selectAllItems() {
        if (getNumRows() > 0) list.selectRangeOfRows(0, getNumRows() - 1);
        list.repaint();
        return true;
    }
    bool deleteSelectedEntries() {
        requestEntryRemoval(selectedEntryIDs());
        return true;
    }
    int blockNumber(const ID &id) const {
        int number = 0;
        for (const auto &entry : entries) if (entry.block) {
            ++number;
            if (entry.id == id) return number;
        }
        return 0;
    }
    void focusBlock(int number) {
        if (number <= 0 || w.session.busy) return;
        refresh();
        int index = 0;
        bool found = false;
        for (int row = 0; row < (int)entries.size(); ++row) {
            const auto entry = entries[(size_t)row];
            if (entry.block) { if (++index == number) found = true; continue; }
            if (!found || entry.child) continue;
            // Identical to clicking this occurrence: select while stopped, queue
            // during playback. MIDI never adds an implicit Play command.
            w.session.command(entry.duplicate || w.session.transport().playing ? jaras::CommandKind::queueRegion
                                                                              : jaras::CommandKind::selectRegion, entry.id);
            selection = {entry.id}; selectedEntry = entry.id;
            list.selectRow(row); list.scrollToEnsureRowIsOnscreen(row);
            w.selectionAreas.activate(*this);
            return;
        }
    }
    void stepSelection(int direction) {
        std::vector<ID> ids;
        for (const auto &entry : entries) if (!entry.block) ids.push_back(entry.id);
        if (ids.empty() || w.session.busy) return;
        const auto anchor = w.session.focusedRegion.value_or(ID{});
        auto found = std::find(ids.begin(),ids.end(),anchor);
        int index = found == ids.end() ? (direction > 0 ? 0 : (int)ids.size()-1)
            : jlimit(0,(int)ids.size()-1,(int)std::distance(ids.begin(),found)+direction);
        keyboardTarget = ids[(size_t)index];
        if (w.session.transport().playing) w.session.focusSetlistRegion(keyboardTarget,true);
        else w.session.command(jaras::CommandKind::selectRegion,*keyboardTarget);
        w.selectionAreas.activate(*this);
        refresh();
    }
    bool activateSelection() {
        auto target = w.session.focusedRegion ? w.session.focusedRegion : keyboardTarget;
        if (!target || w.session.busy) return false;
        if (std::none_of(entries.begin(),entries.end(),[&](const auto &entry){return !entry.block && entry.id==*target;})) return false;
        keyboardTarget=target;
        const bool wasQueueing=w.session.transport().playing && w.session.transport().queuedRegionId.has_value();
        w.session.command(w.session.transport().playing ? jaras::CommandKind::queueRegion : jaras::CommandKind::selectRegion,*target);
        // Keyboard cancellation keeps the browsed row selected; pointer cancellation does not.
        if (wasQueueing && !w.session.transport().queuedRegionId && !w.session.focusedRegion)
            w.session.focusSetlistRegion(target,true);
        refresh();
        return true;
    }
    bool keyPressed(const KeyPress &key) override {
        if (dynamic_cast<TextEditor *>(Component::getCurrentlyFocusedComponent()))
            return retryEditorShortcut(key);
        const auto mods = key.getModifiers();
        const auto code = key.getKeyCode();
        if (code == KeyPress::tabKey && !mods.isCtrlDown() && !mods.isAltDown() && !mods.isShiftDown()) {
            toggleSearch(); return true;
        }
        if (mods.isCtrlDown() && !mods.isAltDown() && !mods.isShiftDown() &&
            (code == 'A' || code == 'a' || code == 1)) return selectAllItems();
        return false;
    }
    void resized() override {
        const int available = std::max(0, getWidth() - 16 - 6);
        int index = 0;
        for (auto *button : std::initializer_list<Button *>{&automatic, &blocks, &stop}) {
            const int left = available * index / 3;
            const int right = available * (index + 1) / 3;
            button->setBounds(8 + left + index * 3, 2, right - left, 26);
            ++index;
        }
        playlistMenu.setBounds(8, 34, std::max(0, getWidth() - 16 - 65), 30);
        addPlaylist.setBounds(playlistMenu.getRight() + 3, 32, 32, 35);
        searchButton.setBounds(addPlaylist.getRight() + 3, 34, 27, 30);
        if (!searchPanel) search.setVisible(false);
        const int footerHeight = footerVisible ? 28 : 16;
        const int top = 70;
        list.setBounds(8, top, getWidth() - 10,
                       std::max(0, getHeight() - top - footerHeight));
        const int cell = (getWidth() - 32) / 3;
        bypass.setBounds(8, getHeight() - 25, cell, 22);
        live.setBounds(12 + cell, getHeight() - 25, cell, 22);
        parts.setBounds(16 + cell * 2, getHeight() - 25, getWidth() - 16 - (16 + cell * 2), 22);
        for (auto *button : std::initializer_list<TextButton *>{&bypass, &live, &parts}) button->setVisible(footerVisible);
        footerToggle.setBounds(getWidth() - 16, getHeight() - footerHeight, 14, footerHeight);
        footerToggle.direction = footerVisible ? 1 : -1;
        footerToggle.setName(footerVisible ? "Hide setlist controls" : "Show setlist controls");
        footerToggle.setTooltip(footerVisible ? "Hide setlist controls" : "Show setlist controls");
        if (playlistEditor)
            playlistEditor->setBounds(getLocalBounds());
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setColour(theme::line);
        g.drawVerticalLine(0, 0, (float)getHeight());
        g.setColour(Colours::white.withAlpha(.12f));
        g.drawHorizontalLine(getHeight() - (footerVisible ? 28 : 16), 0, (float)getWidth());
        g.setColour(theme::secondary);
        g.setFont(theme::font(11));

        if (entries.empty())
            g.drawFittedText(search.getText().isEmpty() ? "No regions" : "No matching songs", 16,
                             92, getWidth() - 32, 44, Justification::centred, 2, 1.f);
    }
    void refresh() {
        refreshing = true;
        const bool reveal = focusRevision != w.session.setlistFocusRevision;
        focusRevision = w.session.setlistFocusRevision;
        if (reveal) {
            selection.clear();
            if (w.session.focusedRegion) selection.insert(*w.session.focusedRegion);
            if (searching) {
                setSearching(false);
            }
        }
        // Rows move when a unified region opens. Keep selection attached to IDs,
        // including multi-selection, instead of ListBox's previous row indices.
        const auto selectedIDs = selection;
        auto state = currentState();
        playlistMenu.clear(dontSendNotification);
        playlistMenu.addItem(localization::translate(String::fromUTF8("Todas as regiões")), 1);
        bypass.setActive(w.session.transport().multiLoopsBypassed);
        int selected = 1;
        for (size_t i = 0; i < state.playlists.size(); ++i) {
            playlistMenu.addItem(text(state.playlists[i].name), (int)i + 2);
            if (state.selectedId == state.playlists[i].id)
                selected = (int)i + 2;
        }
        playlistMenu.setSelectedId(selected, dontSendNotification);
        automatic.setToggleState(state.autoAdvance, dontSendNotification);
        stop.setActive(state.stopAtRegionEnd.value_or(false));
        live.setToggleState(state.liveEnabled.value_or(false), dontSendNotification);
        const auto *playlist = selectedPlaylist();
        blocks.setEnabled(playlist != nullptr);
        entries.clear();
        regionCount = 0;
        totalDuration = 0;
        auto *song = w.session.song();
        if (song) {
            std::vector<std::pair<ID, const jaras::Part *>> roots;
            std::map<ID, int> ids;
            for (size_t index=0;index<song->parts.size();++index)
                ids[song->parts[index].id]=(int)index+1;
            auto sorted = song->parts;
            std::stable_sort(sorted.begin(), sorted.end(), [](const auto &a, const auto &b) {
                if (a.startTime != b.startTime)
                    return a.startTime < b.startTime;
                return a.endTime > b.endTime;
            });
            if (playlist) {
                for (const auto &id : playlist->regionIds)
                    for (const auto &part : song->parts)
                        if (part.id == playlist->resolvedRegionId(id))
                            roots.push_back({id, &part});
            } else {
                for (const auto &part : song->parts)
                    if (!part.parentRegionID)
                        roots.push_back({part.id, &part});
                std::stable_sort(roots.begin(), roots.end(),
                                 [](const auto &a, const auto &b) { return a.second->startTime < b.second->startTime; });
            }
            auto addBlocks = [&](const std::optional<ID> &before) {
                if (!state.blocks)
                    return;
                for (const auto &block : *state.blocks)
                    if (block.songId == song->id &&
                        block.playlistId ==
                            (playlist ? std::optional<ID>(playlist->id) : std::nullopt) &&
                        block.beforeRegionId == before) {
                        Entry entry;
                        entry.block = true;
                        entry.blockSymbol = block.symbol.value_or(true);
                        entry.id = block.id;
                        entry.name = text(block.name);
                        entry.colour = Colour(0xff000000u | block.color);
                        entries.push_back(entry);
                    }
            };
            regionCount=(int)roots.size();
            for (const auto &root : roots)
                totalDuration += root.second->endTime - root.second->startTime;
            const auto parents=timelineRegionLabels::parents(*song);
            auto addPart = [&](const jaras::Part &part, int number, const ID &occurrence = ID{}, bool drawerChild = false) {
                Entry entry;
                entry.id=occurrence.empty()?part.id:occurrence;entry.sourceId=part.id;entry.duplicate=entry.id!=part.id;entry.name=timelineRegionLabels::displayName(part);
                entry.start=part.startTime;entry.end=part.endTime;
                entry.child=part.parentRegionID.has_value();entry.drawerChild=drawerChild;entry.number=number;
                entry.regionNumber=ids[part.id];
                entry.colour=Colour(0xff000000u|part.color.value_or(0x777777));
                entry.hasChildren=!entry.child && parents.count(part.id);
                entries.push_back(entry);
            };
            {
                int index=0;
                for (const auto &root:roots) {
                    const auto *part=root.second;
                    addBlocks(root.first);addPart(*part,++index,root.first);
                    if (root.first==part->id && parents.count(part->id) && expanded.count(root.first)) {
                        int childNumber=0;
                        for (const auto &child:sorted)
                            if (child.parentRegionID==part->id) addPart(child,++childNumber,ID{},true);
                    }
                }
                addBlocks(std::nullopt);
            }
        }
        list.updateContent();
        list.deselectAllRows();
        for (int row = 0; row < getNumRows(); ++row) {
            const auto &entry = entries[(size_t)row];
            bool selected = selectedIDs.count(entry.id) != 0;
            if (!selected && song && entry.hasChildren && !expanded.count(entry.id))
                selected = std::any_of(song->parts.begin(), song->parts.end(), [&](const auto &part) {
                    return part.parentRegionID == entry.id && selectedIDs.count(part.id);
                });
            if (selected) {
                list.selectRow(row, false, false);
                if (reveal) list.scrollToEnsureRowIsOnscreen(row);
            }
        }
        refreshing = false;
        if (searchPanel) searchPanel->refresh();
        list.repaint();
        repaint();
    }
    void scroll(int count) { list.getViewport()->setViewPosition(0, scrollY() + count * 38); }
    void toggleParts() { parts.onClick(); }
    void setPartsVisible(bool value) { parts.setToggleState(value, dontSendNotification); }
    double duration() const { return totalDuration; }
    std::vector<ID> orderedRoots() const {
        std::vector<ID> result;
        if (const auto *playlist = selectedPlaylist())
            return playlist->regionIds;
        if (const auto *song = w.session.song()) {
            std::vector<const jaras::Part *> sorted;
            for (const auto &part : song->parts)
                if (!part.parentRegionID)
                    sorted.push_back(&part);
            std::stable_sort(sorted.begin(), sorted.end(),
                             [](auto *a, auto *b) { return a->startTime < b->startTime; });
            for (auto *part : sorted)
                result.push_back(part->id);
        }
        return result;
    }
    DragDivider::ScrollMetrics scrollMetrics() const {
        auto *view=list.getViewport();auto *document=view->getViewedComponent();
        return {view->getViewPositionY(),view->getViewHeight(),document?document->getHeight():0};
    }
    void scrollTo(int y) { auto *view=list.getViewport();const auto m=scrollMetrics();view->setViewPosition(0,jlimit(0,std::max(0,m.document-m.viewport),y)); }
    int scrollY() const { return list.getViewport()->getViewPositionY(); }
    var diagnostics() const {
        auto result = object();
        auto bounds = object();
        auto button = w.getLocalArea(&parts, parts.getLocalBounds());
        put(bounds, "x", button.getX());
        put(bounds, "y", button.getY());
        put(bounds, "width", button.getWidth());
        put(bounds, "height", button.getHeight());
        put(result, "partsButton", bounds);
        put(result, "rows", (int)entries.size());
        Array<var> selected, visibleSelected, rowNumbers, rowRegionNumbers, rowIDs;
        for (const auto &id : selection) selected.add(text(id));
        for (const auto &id : selectedEntryIDs()) visibleSelected.add(text(id));
        for (const auto &entry : entries) {
            rowNumbers.add(entry.number);rowRegionNumbers.add(entry.regionNumber);rowIDs.add(text(entry.id));
        }
        put(result, "selectedEntries", selected);
        put(result, "visibleSelectedEntries", visibleSelected);
        put(result, "rowNumbers", rowNumbers);
        put(result, "rowRegionNumbers", rowRegionNumbers);
        put(result, "rowIDs", rowIDs);
        Array<var> displayedNumbers;
        for (const auto &entry : entries) displayedNumbers.add(entry.block ? var() : var(w.appearance.regionIDs() ? entry.regionNumber : entry.number));
        put(result, "displayedNumbers", displayedNumbers);
        put(result, "searchResultIDs", searchPanel ? searchPanel->identifiers() : var(Array<var>()));
        put(result, "searching", searching);
        put(result, "searchQuery", search.getText());
        put(result, "footerVisible", footerVisible);
        put(result, "fontStyle", w.appearance.fontStyle());
        put(result, "fontFace", w.appearance.setlistFont().getTypefaceStyle());
        put(result, "regionIDs", w.appearance.regionIDs());
        put(result, "playlist", selectedPlaylist() != nullptr);
        put(result, "playlistEditor", playlistEditor != nullptr);
        put(result, "playlistCount", (int)currentState().playlists.size());
        put(result, "playlistRegions",
            selectedPlaylist() ? (int)selectedPlaylist()->regionIds.size() : 0);
        put(result, "allRegionsColour",
            w.appearance.setlistColour(false, false).toDisplayString(false));
        put(result, "playlistColour",
            w.appearance.setlistColour(true, false).toDisplayString(false));
        put(result, "drawerColour", w.appearance.setlistColour(false, true).toDisplayString(false));
        return result;
    }

  private:
    class RegionStopButton final : public QuietButton, private Timer {
      public:
        RegionStopButton() : QuietButton("STOP") {}
        void setActive(bool active) {
            if (getToggleState() == active) return;
            setToggleState(active, dontSendNotification);
            setAlpha(1.f); bright = true;
            if (active) startTimer(550); else stopTimer();
        }
        void paintButton(Graphics &g, bool, bool) override {
            const auto bounds = getLocalBounds().toFloat().reduced(.5f);
            const auto colour = getToggleState() ? theme::green : Colours::red;
            g.setColour(theme::panel); g.fillRoundedRectangle(bounds, 4.f);
            g.setColour(colour); g.drawRoundedRectangle(bounds, 4.f, 1.f);
            g.setFont(theme::font(9).boldened());
            g.drawText("STOP", getLocalBounds(), Justification::centred);
        }
      private:
        bool bright = true;
        void timerCallback() override { bright = !bright; setAlpha(bright ? 1.f : .4f); }
    };
    class BypassButton final : public QuietButton, private Timer {
      public:
        BypassButton() : QuietButton("ByPass") {}
        void setActive(bool active) {
            if (getToggleState() == active) return;
            setToggleState(active, dontSendNotification);
            bright = true;
            setColour(TextButton::buttonOnColourId, Colour(0xffffd600));
            if (active) startTimer(150); else stopTimer();
        }
      private:
        bool bright = true;
        void timerCallback() override {
            bright = !bright;
            setColour(TextButton::buttonOnColourId, Colour(0xffffd600).withAlpha(bright ? 1.f : .2f));
        }
    };
    // Vector chevrons keep the Mac drawer geometry without depending on a symbol font.
    class DrawerButton final : public Button {
      public:
        DrawerButton() : Button("Show unified songs") { setWantsKeyboardFocus(false); }
        int direction = 0; // right, down, up
        void paintButton(Graphics &g, bool, bool) override {
            const float x = getWidth() * .5f, y = getHeight() * .5f;
            Path path;
            if (direction == 0) {
                path.startNewSubPath(x - 2, y - 4);
                path.lineTo(x + 2, y); path.lineTo(x - 2, y + 4);
            } else {
                path.startNewSubPath(x - 4, y - direction * 2.f);
                path.lineTo(x, y + direction * 2.f);
                path.lineTo(x + 4, y - direction * 2.f);
            }
            g.setColour(theme::green);
            g.strokePath(path, PathStrokeType(1.8f, PathStrokeType::curved, PathStrokeType::rounded));
        }
    };
    class RowDrawer final : public Component {
      public:
        DrawerButton button;
        RowDrawer() { setInterceptsMouseClicks(false, true); addAndMakeVisible(button); }
        void resized() override { button.setBounds(getWidth() - 14, 0, 14, 34); }
    };
    struct Entry {
        ID id, sourceId;
        bool duplicate = false;
        String name;
        double start = 0, end = 0;
        int number = 0, regionNumber = 0;
        Colour colour;
        bool child = false, drawerChild = false, block = false, hasChildren = false, blockSymbol = true;
    };
    Workspace &w;
    SetlistRows list;
    class PlaylistBox final : public ComboBox {
      public:
        PlaylistBox() {
            setWantsKeyboardFocus(false);
            setMouseClickGrabsKeyboardFocus(false);
        }
        std::function<void()> context, open;
        void mouseDown(const MouseEvent &e) override { if(e.mods.isPopupMenu()) { if(context)context(); } else if(open)open(); }
        void mouseUp(const MouseEvent &) override {}
        bool keyPressed(const KeyPress &key) override {
            // Space belongs to the transport, including after dismissing the
            // playlist callout. Let it bubble to the normal workspace routing.
            if(key==KeyPress::returnKey || key==KeyPress::downKey) { if(open)open();return true; }
            return false;
        }
    } playlistMenu;
    class PlaylistChoices final : public Component, private ListBoxModel {
      public:
        PlaylistChoices(Setlist &value) : owner(&value), rows("Playlists",this) {
            state=value.currentState(); addAndMakeVisible(rows); rows.setRowHeight(30);
            choices.push_back({{},String::fromUTF8("Todas as regiões")});
            for(const auto &p:state.playlists) if(value.w.session.song() && p.songId==value.w.session.song()->id) choices.push_back({p.id,text(p.name)});
            rows.setColour(ListBox::backgroundColourId,theme::panel);rows.setOutlineThickness(0);
            rows.getViewport()->setScrollBarsShown(true,false);
            rows.updateContent();
            setSize(220,std::min(360,(int)choices.size()*30));
        }
        void resized() override {rows.setBounds(getLocalBounds());}
      private:
        SafePointer<Setlist> owner; ListBox rows; jaras::RegionSetlist state;
        std::vector<std::pair<std::optional<ID>,String>> choices;
        int getNumRows() override {return (int)choices.size();}
        void paintListBoxItem(int row,Graphics &g,int width,int height,bool) override {
            if(row<0||row>=getNumRows())return;g.setColour(theme::background);g.fillRect(0,1,width,height-2);
            g.setFont(theme::font(12));g.setColour(Colours::white);g.drawText(choices[row].second,8,0,width-30,height,Justification::centredLeft);
            if(state.selectedId==choices[row].first){g.setColour(theme::green);g.drawText(String::fromUTF8("✓"),width-24,0,18,height,Justification::centred);}
        }
        void listBoxItemClicked(int row,const MouseEvent &event) override {
            if(!owner||row<0||row>=getNumRows())return;
            const auto id=choices[row].first;
            if(event.mods.isPopupMenu()) {
                owner->playlistOptions(id,true,this,event.getScreenPosition());
                return;
            }
            if(auto *box=findParentComponentOfClass<CallOutBox>())box->dismiss();
            MessageManager::callAsync([safe=owner,id] {
                if(!safe)return;
                auto next=safe->currentState();next.selectedId=id;safe->apply(next);
            });
        }
    };
    class SearchPanel final : public Component, private ListBoxModel {
      public:
        explicit SearchPanel(Setlist &value):owner(&value) {
            setComponentID("setlistSearchPopover");
            addAndMakeVisible(value.search);addAndMakeVisible(clear);addAndMakeVisible(rows);
            clear.getProperties().set("icon","close");clear.setComponentID("setlistSearchClear");
            clear.onClick=[this] {if(owner){owner->search.clear();owner->search.grabKeyboardFocus();}};
            rows.setComponentID("setlistSearchResults");rows.setModel(this);rows.setRowHeight(34);
            rows.setColour(ListBox::backgroundColourId,theme::panel);
            rows.getViewport()->setScrollBarsShown(false,false);
            refresh();setSize(324,360);
        }
        ~SearchPanel() override {
            if(owner && owner->searchPanel==this) {
                owner->searchPanel=nullptr;owner->searching=false;
                owner->addChildComponent(owner->search);owner->search.setVisible(false);owner->search.setText({},false);
            }
        }
        void refresh(bool resetSelection = false) {
            const int previous = rows.getSelectedRow();
            const ID selected = previous >= 0 && previous < (int)results.size() ? results[(size_t)previous].id : ID{};
            results.clear();numbers.clear();
            if(owner) if(const auto *song=owner->w.session.song()) {
                for(size_t i=0;i<song->parts.size();++i) numbers[song->parts[i].id]=(int)i+1;
                for(const auto *part:setlistSearch::results(*song,owner->search.getText(),owner->w.appearance.regionIDs())) results.push_back(*part);
            }
            rows.updateContent();
            int next = results.empty() ? -1 : 0;
            if (!resetSelection && !selected.empty())
                for (size_t i=0;i<results.size();++i) if(results[i].id==selected) {next=(int)i;break;}
            if(next<0) rows.deselectAllRows(); else rows.selectRow(next,false,true);
            rows.setVisible(!results.empty());rows.repaint();repaint();
        }
        var identifiers() const { Array<var> ids;for(const auto &part:results)ids.add(text(part.id));return ids; }
        void moveSelection(int delta) {
            if(results.empty()) return;
            rows.selectRow(jlimit(0,(int)results.size()-1,rows.getSelectedRow()+delta),false,true);
            rows.scrollToEnsureRowIsOnscreen(rows.getSelectedRow());
        }
        void chooseSelected() {
            const int row=rows.getSelectedRow();
            if(row>=0 && row<(int)results.size()) choose(results[(size_t)row].id);
        }
        void resized() override {
            if(owner) owner->search.setBounds(32,12,getWidth()-76,28);
            clear.setBounds(getWidth()-40,12,28,28);rows.setBounds(12,48,getWidth()-24,300);
        }
        void paint(Graphics &g) override {
            g.fillAll(theme::panel);g.setColour(theme::secondary);
            g.drawEllipse(14.f,19.f,9.f,9.f,1.5f);g.drawLine(22.f,27.f,26.f,31.f,1.5f);
            if(results.empty()){g.setFont(theme::font(12));g.drawText("No results",12,60,getWidth()-24,28,Justification::centred);}
        }
      private:
        SafePointer<Setlist> owner;ListBox rows;QuietButton clear{""};
        std::vector<jaras::Part> results;std::map<ID,int> numbers;
        int getNumRows() override {return (int)results.size();}
        void choose(ID id) {if(owner)owner->chooseSearchResult(id);}
        void listBoxItemClicked(int row,const MouseEvent &event) override {
            if(!event.mods.isPopupMenu() && row>=0 && row<(int)results.size())choose(results[(size_t)row].id);
        }
        void returnKeyPressed(int) override { chooseSelected(); }
        void paintListBoxItem(int row,Graphics &g,int width,int height,bool selected) override {
            if(!owner || row<0 || row>=(int)results.size())return;
            const auto &part=results[(size_t)row];g.setColour(selected?Colour(0xff246fc7):theme::background);
            g.fillRoundedRectangle(0,1,(float)width,(float)height-3,4);int x=8;
            if(owner->w.appearance.regionIDs()) {
                const auto number=String(numbers[part.id]).paddedLeft('0',2);g.setFont(theme::font(12));g.setColour(theme::secondary);
                const int numberWidth=(int)std::ceil(GlyphArrangement::getStringWidth(g.getCurrentFont(),number))+8;
                g.drawText(number,x,0,numberWidth,height,Justification::centredLeft);x+=numberWidth;
            }
            const int seconds=(int)std::round(std::max(0.0,part.endTime-part.startTime));
            const auto duration=seconds>=3600?String::formatted("%dh %02dm %02ds",seconds/3600,seconds/60%60,seconds%60)
                :seconds>=60?String::formatted("%dm %02ds",seconds/60,seconds%60):String(seconds)+"s";
            g.setFont(theme::font(10));const int right=(int)std::ceil(GlyphArrangement::getStringWidth(g.getCurrentFont(),duration));
            g.setColour(theme::secondary);g.drawText(duration,width-right-8,0,right,height,Justification::centredRight);
            g.setFont(theme::font(12));g.setColour(Colours::white);
            g.drawText(timelineRegionLabels::displayName(part),x,0,std::max(0,width-right-x-16),height,Justification::centredLeft,true);
        }
    };
    SafePointer<SearchPanel> searchPanel;
    std::unique_ptr<PlaylistEditor> playlistEditor;
    int dropRow = -1;
    QuietButton addPlaylist{"+"}, searchButton{String::fromUTF8("⌕")},
        live{"Live"}, parts{"Parts"};
    RegionStopButton stop;
    QuietButton blocks{localization::translate("Blocos").toUpperCase()};
    BypassButton bypass;
    QuietButton automatic{"AUTO"};
    struct SearchEditor final : TextEditor {
        std::function<void()> onTab;
        std::function<void(int)> onMove;
        bool keyPressed(const KeyPress &key) override {
            const auto mods=key.getModifiers();
            if(key.getKeyCode()==KeyPress::tabKey && !mods.isCtrlDown() && !mods.isAltDown() && !mods.isShiftDown()) {
                if(onTab) onTab();
                return true;
            }
            if ((key.getKeyCode()==KeyPress::upKey || key.getKeyCode()==KeyPress::downKey) &&
                !mods.isCtrlDown() && !mods.isAltDown() && !mods.isCommandDown() && !mods.isShiftDown()) {
                if(onMove) onMove(key.getKeyCode()==KeyPress::downKey ? 1 : -1);
                return true;
            }
            return TextEditor::keyPressed(key);
        }
    } search;
    bool refreshing = false, searching = false, footerVisible = true, ignoreSearchDoubleClick = false;
    uint64 focusRevision = 0;
    DrawerButton footerToggle;
    std::vector<Entry> entries;
    std::set<ID> expanded;
    std::set<ID> selection;
    ID selectedEntry;
    std::optional<ID> keyboardTarget;
    int regionCount = 0;
    double totalDuration = 0;
    void setSearching(bool value) {
        if (value && searchPanel) { if (search.isShowing()) search.grabKeyboardFocus(); return; }
        if (!value) {
            searching=false;
            w.heldShortcutKeys.erase(KeyPress::tabKey);
            auto panel=searchPanel; searchPanel=nullptr;
            addChildComponent(search); search.setVisible(false); search.setText({},false);
            if (panel) { panel->setComponentID({});panel->setVisible(false);if (auto *box=panel->findParentComponentOfClass<CallOutBox>()) box->dismiss(); }
            MessageManager::callAsync([safe=SafePointer<Setlist>(this)] {
                if(safe && !safe->searching)safe->w.grabKeyboardFocus();
            });
            return;
        }
        if (!w.session.song()) return;
        searching=true;
        auto panel=std::make_unique<SearchPanel>(*this);searchPanel=panel.get();
        auto *host=getTopLevelComponent();
        auto &box=CallOutBox::launchAsynchronously(std::move(panel),host->getLocalArea(&searchButton,searchButton.getLocalBounds()),host);
        box.setDismissalMouseClicksAreAlwaysConsumed(true);
        MessageManager::callAsync([safe=SafePointer<Setlist>(this)] {
            if (safe && safe->searchPanel && safe->search.isShowing()) safe->search.grabKeyboardFocus();
        });
    }
    void chooseSearchResult(ID id) {
        const auto *song=w.session.song();
        if (!searching || !song || w.session.busy) return;
        const auto found=std::find_if(song->parts.begin(),song->parts.end(),[&](const auto &part){return part.id==id;});
        if (found==song->parts.end()) return;
        const auto parent=found->parentRegionID;
        const auto listedID=parent.value_or(id);
        w.perform([&] {
            if (const auto *playlist=selectedPlaylist(); playlist &&
                std::find(playlist->regionIds.begin(),playlist->regionIds.end(),listedID)==playlist->regionIds.end()) {
                auto state=currentState();state.selectedId.reset();
                w.session.configureSetlist(std::move(state));
            }
            if (parent) expanded.insert(*parent);
            w.session.command(w.session.transport().playing ? jaras::CommandKind::queueRegion
                                                            : jaras::CommandKind::selectRegion,id);
            selection={id};selectedEntry=id;
            // The normal list replaces the results immediately. The remainder
            // of this double-click must not activate its new row at that index.
            ignoreSearchDoubleClick=true;
            setSearching(false);
            refresh();
            for (int row=0;row<getNumRows();++row)
                if (entries[(size_t)row].id==id) {list.scrollToEnsureRowIsOnscreen(row);break;}
        });
    }
    std::set<ID> selectedEntryIDs() const {
        std::set<ID> result;
        const auto rows = list.getSelectedRows();
        for (int i = 0; i < rows.size(); ++i)
            if (rows[i] >= 0 && rows[i] < (int)entries.size()) result.insert(entries[(size_t)rows[i]].id);
        return result;
    }
    void requestEntryRemoval(const std::set<ID> &targets) {
        if (searching || !w.session.song()) return;
        std::set<ID> blocks, regions;
        for (const auto &entry : entries) if (targets.count(entry.id) && !entry.child)
            (entry.block ? blocks : regions).insert(entry.id);
        if (blocks.empty() && regions.empty()) return;
        const auto projectID = w.session.project().id, songID = w.session.song()->id;
        const std::optional<ID> playlist = selectedPlaylist() ? std::optional<ID>(selectedPlaylist()->id) : std::nullopt;
        const bool blocksOnly = regions.empty();
        const auto title = localization::translate(blocksOnly ? "Delete selected blocks?" :
            playlist ? "Remove selected items from this playlist?" : "Delete selected regions from the project?");
        const auto message = localization::translate(blocksOnly
            ? "Only the selected block headers will be removed. Songs and timeline items will be kept."
            : playlist ? "Remove selected items from this playlist?"
            : "The selected regions, their items and markers will be removed from the timeline. Media files will remain in the project folder.");
        w.confirm(title, message, [self=SafePointer<Setlist>(this),projectID,songID,playlist,blocks,regions] {
            if (!self || self->w.session.project().id != projectID || !self->w.session.song() ||
                self->w.session.song()->id != songID) return;
            const std::optional<ID> current = self->selectedPlaylist()
                ? std::optional<ID>(self->selectedPlaylist()->id) : std::nullopt;
            if (current != playlist) return;
            self->w.perform([&] {
                if (playlist || regions.empty()) {
                    auto state = self->currentState();
                    playlistOccurrences::removeBlocks(state, songID, playlist, blocks);
                    if (playlist) playlistOccurrences::remove(state, *playlist, regions);
                    self->w.session.configureSetlist(std::move(state));
                } else {
                    self->w.session.editTimeline([&](jaras::Project &project) {
                        if (project.regionSetlist) playlistOccurrences::removeBlocks(*project.regionSetlist, songID, playlist, blocks);
                        regionEditing::erase(project, songID, regions, true);
                    });
                }
                for (const auto &id : blocks) self->selection.erase(id);
                for (const auto &id : regions) self->selection.erase(id);
                if (blocks.count(self->selectedEntry) || regions.count(self->selectedEntry)) self->selectedEntry.clear();
            });
        });
    }
    jaras::RegionSetlist currentState() const {
        return w.session.project().regionSetlist.value_or(jaras::RegionSetlist{});
    }
    const jaras::RegionPlaylist *selectedPlaylist() const {
        const auto &state = w.session.project().regionSetlist;
        if (state)
            for (const auto &playlist : state->playlists)
                if (state->selectedId == playlist.id && w.session.song() &&
                    playlist.songId == w.session.song()->id)
                    return &playlist;
        return nullptr;
    }
    void apply(jaras::RegionSetlist state) {
        w.perform([&] { w.session.configureSetlist(std::move(state)); });
    }
    void changeListenerCallback(ChangeBroadcaster *) override {
        footerVisible = (bool)w.appearance.value("catlive.setlist.footerVisible", true);
        resized();refresh();
    }
    int getNumRows() override { return (int)entries.size(); }
    void selectedRowsChanged(int) override {
        if (!refreshing) selection = selectedEntryIDs();
    }
    Component *refreshComponentForRow(int row, bool, Component *existing) override {
        auto *drawer = static_cast<RowDrawer *>(existing);
        if (!drawer) drawer = new RowDrawer();
        const bool available = row >= 0 && row < getNumRows() && entries[(size_t)row].hasChildren && !entries[(size_t)row].duplicate;
        drawer->button.setVisible(available);
        drawer->button.onClick = {};
        if (available) {
            const auto id = entries[(size_t)row].id;
            drawer->button.setComponentID("setlist-drawer-" + text(id));
            drawer->button.direction = expanded.count(id) ? 1 : 0;
            drawer->button.setTooltip("Show unified songs");
            drawer->button.onClick = [self = SafePointer<Setlist>(this), id] {
                if (!self) return;
                if (!self->expanded.erase(id)) self->expanded.insert(id);
                self->refresh();
            };
        }
        return drawer;
    }
    void paintListBoxItem(int row, Graphics &g, int width, int height, bool selected) override {
        if (row < 0 || row >= getNumRows())
            return;
        const auto &entry = entries[(size_t)row];
        if (entry.block) {
            const juce::Rectangle<float> bounds(0.f, 0.f, (float)width, 24.f);
            if (selected) {
                g.setGradientFill(ColourGradient(Colour(0xff2457a9), 0.f, 0.f,
                                                 Colour(0xff152b58), (float)width, 0.f, false));
            } else g.setColour(entry.colour.withAlpha(.15f));
            g.fillRoundedRectangle(bounds, 4.f);
            g.setColour(entry.colour.withAlpha(.5f));
            g.drawRoundedRectangle(bounds.reduced(.5f), 4.f, 1.f);
            if (selected) { g.setColour(theme::green); g.drawRoundedRectangle(bounds.reduced(.5f), 4.f, 1.f); }
            float textX=10.f;
            if (entry.blockSymbol && (bool)w.appearance.value("jaras.blocks.symbol", true)) {
                Path arrow;
                arrow.startNewSubPath(10.f,12.f); arrow.lineTo(72.f,12.f);
                arrow.startNewSubPath(66.f,6.f); arrow.lineTo(72.f,12.f); arrow.lineTo(66.f,18.f);
                g.setColour(Colour(0xffffff00));
                g.strokePath(arrow,PathStrokeType(1.5f,PathStrokeType::curved,PathStrokeType::rounded));
                textX=80.f;
            }
            g.setFont(w.appearance.setlistFont()); g.setColour(w.appearance.colour("jaras.setlist.blockTextColor", 0x69ed91));
            g.drawText(entry.name, juce::Rectangle<float>(textX,0.f,jmax(0.f,(float)width-textX-10.f),24.f),Justification::centredLeft,true);
            return;
        }
        const auto t = w.session.presentationTransport();
        const bool active = t.playing && (entry.child ? t.regionId==entry.sourceId : t.playlistEntryId.value_or(t.regionId.value_or(ID{})) == entry.id),
                   queued = t.playing && playlistOccurrences::queuedVisibleEntry(w.session.song(), t.queuedRegionId, t.queuedPlaylistEntryId, expanded) == entry.id;
        const auto state = currentState();
        const bool played = state.playedLiveRegionIDs &&
            std::find(state.playedLiveRegionIDs->begin(), state.playedLiveRegionIDs->end(), entry.sourceId) != state.playedLiveRegionIDs->end();
        const bool prepareOnly = state.prepareWithoutPlayback.value_or(false);
        const int left = entry.child ? 18 : 0;
        if (entry.drawerChild) {
            // Match the track-mixer group rail, inside the existing drawer gutter.
            // The final child closes its branch; standalone/duplicate entries have no rail.
            const bool last = row + 1 >= getNumRows() || !entries[(size_t)row + 1].drawerChild;
            const int x = left - 11;
            g.setColour(theme::green.withAlpha(.7f));
            g.drawVerticalLine(x, 0, last ? 17.f : (float)height);
            g.drawHorizontalLine(17, (float)x, (float)left - 4);
        }
        auto bounds = juce::Rectangle<float>((float)left, 0, (float)width - left - (entry.block ? 0 : 14), 34);
        g.setColour(played ? Colour(0xff451010) : theme::panel);
        g.fillRoundedRectangle(bounds, 5);
        if (active || queued || selected) {
            const auto start = active ? 0xff8b2026u : queued ? (prepareOnly ? 0xff19633au : 0xffa84b13u) : 0xff2457a9u;
            const auto end = active ? 0xff4c171cu : queued ? (prepareOnly ? 0xff123b27u : 0xff572808u) : 0xff152b58u;
            g.setGradientFill(ColourGradient(Colour(start), bounds.getX(), 0,
                                             Colour(end), bounds.getRight(), 0, false));
            g.fillRoundedRectangle(bounds, 5);
            if (selected && !active && !queued) {
                g.setColour(theme::green);
                g.drawRoundedRectangle(bounds.reduced(.75f), 5, 1.5f);
            }
        }
        g.setColour(active ? Colours::red : queued ? (prepareOnly ? theme::green : Colour(0xffff9500)) : entry.colour);
        g.fillRoundedRectangle((float)left + 8, 7, 3, 20, 2);
        g.setFont(theme::font(9));
        g.setColour(theme::secondary);
        const int number = w.appearance.regionIDs() ? entry.regionNumber : entry.number;
        const bool showNumber=!entry.block;
        const auto numberLabel = String(number).paddedLeft('0', 2);
        const int numberWidth = (int)std::ceil(GlyphArrangement::getStringWidth(g.getCurrentFont(), numberLabel)) + 4;
        if (showNumber)
            g.drawText(numberLabel, left + 17, 0, numberWidth, 34,
                       Justification::centredLeft, false);
        const int nameX = left + (showNumber ? 23 + numberWidth : 18),
                  right = (int)bounds.getRight() - 8;
        const int seconds = (int)std::max(0.0, active ? std::ceil(entry.end - t.position)
                                                   : std::round(entry.end - entry.start));
        const auto duration = seconds >= 3600 ? String::formatted("%dh %02dm %02ds", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : seconds >= 60 ? String::formatted("%dm %02ds", seconds / 60, seconds % 60)
                            : String(seconds) + "s";
        const int durationWidth = (int)std::ceil(GlyphArrangement::getStringWidth(theme::mediumFont(9), duration));
        g.setFont(theme::mediumFont(9));
        g.setColour(Colours::white);
        if (!entry.block)
            g.drawText(duration, right - durationWidth, 0, durationWidth, 34, Justification::centredRight);
        g.setFont(w.appearance.setlistFont());
        g.setColour(entry.block
                        ? Colours::white
                        : w.appearance.setlistColour(selectedPlaylist() != nullptr, entry.child));
        const int nameWidth = std::max(0, right - nameX - (entry.block ? 0 : durationWidth + 6));
        g.drawText(entry.name, nameX, 0, nameWidth, 34, Justification::centredLeft, true);
        if (played) g.drawHorizontalLine(17, (float)nameX, nameX + std::min((float)nameWidth,
            GlyphArrangement::getStringWidth(g.getCurrentFont(), entry.name)));
        if (active && entry.end > entry.start) {
            g.setColour(theme::green);
            g.fillRect(
                bounds.getX(), 32.f,
                bounds.getWidth() *
                    (float)jlimit(0.0, 1.0, (t.position - entry.start) / (entry.end - entry.start)),
                2.f);
        }
    }
    void listBoxItemClicked(int row, const MouseEvent &event) override {
        if (event.getNumberOfClicks()>1 && ignoreSearchDoubleClick) return;
        if (event.getNumberOfClicks()==1) ignoreSearchDoubleClick=false;
        if (row < 0 || row >= getNumRows())
            return;
        auto entry = entries[(size_t)row];
        if(entry.duplicate && event.getNumberOfClicks()>1)return;
        selectedEntry = entry.id;
        if (event.mods.isPopupMenu()) {
            ++w.contextCount;
            contextMenu(entry);
            return;
        }
        if (entry.block || event.mods.isCtrlDown() || event.mods.isShiftDown())
            return;
        w.perform([&] {
            w.session.command(entry.duplicate || w.session.transport().playing ? jaras::CommandKind::queueRegion
                                                                               : jaras::CommandKind::selectRegion,
                              entry.id);
        });
    }
    void listBoxItemDoubleClicked(int row, const MouseEvent &) override {
        if (ignoreSearchDoubleClick) return;
        if (row >= 0 && row < getNumRows() && !entries[(size_t)row].block && !entries[(size_t)row].duplicate)
            w.perform([&] {
                const auto &entry = entries[(size_t)row];
                w.session.command(jaras::CommandKind::selectRegion, entry.id);
            });
    }
    void createPlaylist(bool editing = false, std::optional<ID> target = {}) {
        if (!w.session.song())
            return;
        auto state = currentState();
        const jaras::RegionPlaylist *existing = nullptr;
        if(editing) for(const auto &p:state.playlists) if(p.id==target.value_or(state.selectedId.value_or(ID{}))) existing=&p;
        auto self = SafePointer<Setlist>(this);
        auto finish = [self] {
            MessageManager::callAsync([self] {
                if (self)
                    self->playlistEditor.reset();
            });
        };
        playlistEditor = std::make_unique<PlaylistEditor>(
            *w.session.song(), existing,
            [self, finish](jaras::RegionPlaylist playlist) {
                if (!self)
                    return;
                auto state = self->currentState();
                bool found = false;
                for (auto &p : state.playlists)
                    if (p.id == playlist.id) {
                        p = playlist;
                        found = true;
                        break;
                    }
                if (!found)
                    state.playlists.push_back(playlist);
                state.selectedId = playlist.id;
                try {
                    self->w.session.configureSetlist(state);
                    finish();
                } catch (const std::exception &e) {
                    self->w.showError(String::fromUTF8(e.what()));
                }
            },
            finish, editing);
        addAndMakeVisible(*playlistEditor);
        playlistEditor->toFront(true);
        resized();
    }
    void choosePlaylist() {
        if(!w.session.song())return;
        CallOutBox::launchAsynchronously(std::make_unique<PlaylistChoices>(*this),playlistMenu.getScreenBounds(),nullptr);
    }
    void copyPlaylist(std::optional<ID> id) {
        const auto *song=w.session.song();if(!song)return;
        SystemClipboard::copyTextToClipboard(setlistShareText(*song,currentState(),id));
    }
    void playlistOptions(std::optional<ID> selected, bool row, Component *choices = nullptr, Point<int> position = {}) {
        PopupMenu menu; menu.addItem(1,localization::translate("Copiar para compartilhar"),w.session.song()!=nullptr);
        if(row && selected) {menu.addSeparator();menu.addItem(2,localization::translate(String::fromUTF8("Adicionar regiões")));menu.addItem(3,localization::translate("Editar"));menu.addItem(4,localization::translate("Clonar playlist"));menu.addItem(5,localization::translate("Delete playlist"));}
        const auto project=w.session.project().id;
        auto options = PopupMenu::Options().withTargetComponent(choices ? choices : &playlistMenu);
        if(choices) options = options.withTargetScreenArea({position.x,position.y,1,1});
        menu.showMenuAsync(options,
            [self=SafePointer<Setlist>(this),parent=SafePointer<Component>(choices),selected,project](int action) {
                if(action && parent) if(auto *box=parent->findParentComponentOfClass<CallOutBox>())box->dismiss();
                if(!self || self->w.session.project().id!=project)return;
                if(action==1){self->copyPlaylist(selected);return;}
                if(!selected)return;
                if(action==2)self->createPlaylist(true,selected);
                if(action==3){auto state=self->currentState();for(const auto &p:state.playlists)if(p.id==selected){
                    self->w.prompt("Editar playlist","Nome",text(p.name),[self,selected,project](String name){
                        if(!self || self->w.session.project().id!=project)return;auto state=self->currentState();
                        for(auto &p:state.playlists)if(p.id==selected)p.name=utf8(name);self->apply(state);
                    });break;}}
                if(action==4){auto state=self->currentState();for(const auto &p:state.playlists)if(p.id==selected){
                    auto copy=p;copy.id=uuid();const auto remapped=playlistOccurrences::reidentifyCopies(copy,[]{return uuid();});copy.name += " (cópia)";
                    if(state.blocks){auto blocks=*state.blocks;for(auto block:blocks)if(block.playlistId==selected){block.id=uuid();block.playlistId=copy.id;if(block.beforeRegionId)if(auto at=remapped.find(*block.beforeRegionId);at!=remapped.end())block.beforeRegionId=at->second;state.blocks->push_back(block);}}
                    state.selectedId=copy.id;state.playlists.push_back(copy);self->apply(state);break;}}
                if(action==5)self->w.confirm(localization::translate("Delete playlist"),String::fromUTF8("Excluir esta playlist? As músicas continuam no projeto."),[self,selected,project]{
                    if(!self || self->w.session.project().id!=project)return;auto state=self->currentState();
                    state.playlists.erase(std::remove_if(state.playlists.begin(),state.playlists.end(),[&](const auto &p){return p.id==selected;}),state.playlists.end());
                    if(state.blocks)state.blocks->erase(std::remove_if(state.blocks->begin(),state.blocks->end(),[&](const auto &b){return b.playlistId==selected;}),state.blocks->end());
                    if(state.selectedId==selected)state.selectedId.reset();self->apply(state);
                });
            });
    }
    var getDragSourceDescription(const SparseSet<int> &rows) override {
        if (searching || !selectedPlaylist())
            return {};
        Array<var> ids;
        for (int i = 0; i < rows.size(); ++i) {
            const int row = rows[i];
            if (row >= 0 && row < (int)entries.size() && !entries[(size_t)row].child)
                ids.add(text(entries[(size_t)row].id));
        }
        if (ids.isEmpty())
            return {};
        auto payload = object();
        put(payload, "type", "catlive-playlist-regions");
        put(payload, "ids", ids);
        put(payload, "project", text(w.session.project().id));
        put(payload, "song", text(selectedPlaylist()->songId));
        put(payload, "playlist", text(selectedPlaylist()->id));
        return payload;
    }
    bool isInterestedInDragSource(const SourceDetails &details) override {
        const auto *playlist = selectedPlaylist();
        return !searching && playlist && str(details.description, "type") == "catlive-playlist-regions" &&
            str(details.description, "project") == text(w.session.project().id) &&
            str(details.description, "song") == text(playlist->songId) &&
            str(details.description, "playlist") == text(playlist->id);
    }
    void itemDragEnter(const SourceDetails &details) override { itemDragMove(details); }
    void updateDropPosition(std::optional<Point<int>> position = std::nullopt) {
        const auto local=position ? list.getLocalPoint(this,*position) : list.getLocalPoint(nullptr,Desktop::getMousePosition());
        list.getViewport()->autoScroll(local.x,local.y,40,18);
        dropRow=jlimit(0,(int)entries.size(),list.insertionRow(local.y+scrollY()));
        repaint();
    }
    void timerCallback() override {
        if(!isDragAndDropActive() || !ModifierKeys::getCurrentModifiersRealtime().isAnyMouseButtonDown()) {
            stopTimer();dropRow=-1;repaint();return;
        }
        updateDropPosition();
    }
    void itemDragMove(const SourceDetails &details) override {
        if(!isTimerRunning()) startTimerHz(30);
        updateDropPosition(details.localPosition);
    }
    void itemDragExit(const SourceDetails &) override {
        stopTimer();
        dropRow = -1;
        repaint();
    }
    void itemDropped(const SourceDetails &details) override {
        stopTimer();
        if (!isInterestedInDragSource(details)) { dropRow = -1; repaint(); return; }
        updateDropPosition(details.localPosition);
        const auto payload = listValues(details.description);
        auto state = currentState();
        std::optional<ID> before;
        for (int row = std::max(0, dropRow); row < (int)entries.size(); ++row)
            if (!entries[(size_t)row].child &&
                !payload.count(entries[(size_t)row].id)) {
                before = entries[(size_t)row].id;
                break;
            }
        const auto *playlist = selectedPlaylist();
        const bool moved = playlistOccurrences::moveEntries(state, playlist->songId, playlist->id, payload, before);
        dropRow = -1;
        if (moved) apply(state);
        repaint();
    }
    static std::set<ID> listValues(const var &payload) {
        std::set<ID> result;
        for (auto value : catlive::list(get(payload, "ids")))
            result.insert(utf8(value.toString()));
        return result;
    }
    void paintOverChildren(Graphics &g) override {
        if (dropRow >= 0) {
            g.setColour(theme::green);
            g.fillRect(list.getX() + 4, list.getY() + list.rowTop(dropRow) - scrollY(), list.getWidth() - 8,
                       2);
        }
    }
    void addBlock() {
        auto *playlist = selectedPlaylist();
        if (!playlist || !w.session.song())
            return;
        auto state = currentState();
        if (!state.blocks)
            state.blocks.emplace();
        jaras::SetlistBlock block;
        block.id = uuid();
        block.songId = playlist->songId;
        block.playlistId = playlist->id;
        const auto count = std::count_if(state.blocks->begin(),state.blocks->end(),[&](const auto &entry){return entry.songId==block.songId && entry.playlistId==block.playlistId;});
        block.name = utf8(localization::translate("Bloco") + " " + String((int)count+1).paddedLeft('0',2));
        auto &random=Random::getSystemRandom();
        block.color = ((80+random.nextInt(151))<<16) | ((80+random.nextInt(151))<<8) | (80+random.nextInt(151));
        block.symbol = (bool)w.appearance.value("jaras.blocks.symbol",true);
        if (std::find(playlist->regionIds.begin(), playlist->regionIds.end(), selectedEntry) !=
            playlist->regionIds.end())
            block.beforeRegionId = selectedEntry;
        else if (!playlist->regionIds.empty()) block.beforeRegionId=playlist->regionIds.front();
        state.blocks->push_back(block);
        apply(state);
    }
    class BlockDefaultsPanel final : public Component {
      public:
        BlockDefaultsPanel(bool enabled, std::function<void(bool)> save, std::function<void()> close) {
            symbol.setButtonText(localization::translate("SIMBOL"));
            symbol.setComponentID("blockDefaultSymbol");
            symbol.setToggleState(enabled,dontSendNotification);
            cancel.setButtonText(localization::translate("Cancel"));
            apply.setButtonText(localization::translate("Save"));
            cancel.onClick=close;
            apply.onClick=[this,save,close] { save(symbol.getToggleState()); close(); };
            for(auto *button : std::initializer_list<Button*>{&symbol,&cancel,&apply}) addAndMakeVisible(button);
        }
        void resized() override {
            symbol.setBounds(18,14,getWidth()-36,28);
            cancel.setBounds(18,getHeight()-48,100,30);
            apply.setBounds(getWidth()-118,getHeight()-48,100,30);
        }
      private:
        ToggleButton symbol;
        TextButton cancel,apply;
    };
    void blockDefaults() {
        auto self=SafePointer<Setlist>(this);
        auto close=[self] {
            if(self) for(auto *child : self->w.getChildren())
                if(auto *sheet=dynamic_cast<ModalSheet*>(child);sheet && sheet->getName()==localization::translate("Blocks")) sheet->exitModalState(0);
        };
        ModalSheet::open(w,localization::translate("Blocks"),std::make_unique<BlockDefaultsPanel>(
            (bool)w.appearance.value("jaras.blocks.symbol",true),
            [self](bool enabled){if(self){auto result=self->w.appearance.set("jaras.blocks.symbol",enabled);if(result.failed())self->w.showError(result.getErrorMessage());}},close),280,118);
    }
    class SubplayTracksPanel final : public Component {
      public:
        SubplayTracksPanel(const jaras::Song& song,const std::vector<ID>& selected,
                           std::function<void(std::vector<ID>)> save,std::function<void()> close) {
            for(const auto& track:song.tracks) {
                if(!jaras::fixedTrackName(track.role).empty() || track.role.id=="vinhetas")continue;
                auto row=std::make_unique<ToggleButton>(text(track.name));
                row->setComponentID("subplayExclusiveTrack:"+text(track.id));
                row->setToggleState(std::find(selected.begin(),selected.end(),track.id)!=selected.end(),dontSendNotification);
                rows.addAndMakeVisible(*row);ids.push_back(track.id);checks.push_back(std::move(row));
            }
            viewport.setViewedComponent(&rows,false);addAndMakeVisible(viewport);
            explanation.setText(localization::translate("On these tracks, automatic Subplay stops items from the previous song and keeps only the incoming song's items."),dontSendNotification);
            explanation.setFont(theme::font(12));explanation.setColour(Label::textColourId,theme::secondary);
            addAndMakeVisible(explanation);
            cancel.setButtonText(localization::translate("Cancel"));apply.setButtonText(localization::translate("Apply"));
            cancel.onClick=close;apply.onClick=[this,save,close]{std::vector<ID> chosen;for(size_t i=0;i<checks.size();++i)if(checks[i]->getToggleState())chosen.push_back(ids[i]);save(std::move(chosen));close();};
            addAndMakeVisible(cancel);addAndMakeVisible(apply);
        }
        void resized() override {
            explanation.setBounds(18,10,getWidth()-36,54);
            viewport.setBounds(14,72,getWidth()-28,getHeight()-136);
            rows.setSize(std::max(1,viewport.getWidth()-18),std::max(1,int(checks.size())*34));
            for(size_t i=0;i<checks.size();++i)checks[i]->setBounds(4,int(i)*34,rows.getWidth()-8,32);
            cancel.setBounds(18,getHeight()-48,110,30);apply.setBounds(getWidth()-128,getHeight()-48,110,30);
        }
      private:
        Component rows;Viewport viewport;Label explanation;TextButton cancel,apply;
        std::vector<ID> ids;std::vector<std::unique_ptr<ToggleButton>> checks;
    };
    void chooseSubplayTracks() {
        if(!w.session.song())return;
        auto self=SafePointer<Setlist>(this);
        auto close=[self]{if(self)for(auto* child:self->w.getChildren())if(auto* sheet=dynamic_cast<ModalSheet*>(child);sheet&&sheet->getName()==localization::translate("Choose tracks"))sheet->exitModalState(0);};
        ModalSheet::open(w,localization::translate("Choose tracks"),std::make_unique<SubplayTracksPanel>(*w.session.song(),
            currentState().subplayExclusiveTrackIDs.value_or(std::vector<ID>{}),
            [self](std::vector<ID> ids){if(self){auto next=self->currentState();next.subplayExclusiveTrackIDs=std::move(ids);self->apply(std::move(next));}},close),460,430);
    }
    class AutoOptionsPanel final : public Component {
      public:
        AutoOptionsPanel(std::function<jaras::RegionSetlist()> readState,
                         std::function<void(jaras::RegionSetlist)> writeState, std::function<void()> choose)
            : read(std::move(readState)),write(std::move(writeState)) {
            untilBlock.setButtonText(localization::translate("Run queue until the end of the block"));
            withoutPlayback.setButtonText(localization::translate("Without playback"));
            subplay.setButtonText(localization::translate("Automatic Subplay"));
            untilBlock.setComponentID("autoUntilBlockEnd");withoutPlayback.setComponentID("autoWithoutPlayback");subplay.setComponentID("autoSubplay");
            leadLabel.setText(localization::translate("Start before the end"),dontSendNotification);
            leadLabel.setFont(theme::font(12));
            for(auto *button : {&untilBlock,&withoutPlayback,&subplay}) addAndMakeVisible(button);
            addAndMakeVisible(leadLabel);addAndMakeVisible(lead);
            lead.setComponentID("autoSubplayLead");
            chooseTracks.setButtonText(localization::translate("Choose tracks"));chooseTracks.setComponentID("autoSubplayChooseTracks");addAndMakeVisible(chooseTracks);
            chooseTracks.onClick=[this,choose]{if(auto* box=findParentComponentOfClass<CallOutBox>())box->dismiss();MessageManager::callAsync(choose);};
            for(int i=1;i<=5;++i) {
                lead.addItem(String(i)+"s",i*2-1);
                lead.addItem(String(i)+" "+localization::translate(i==1?"bar":"bars"),i*2);
            }
            lead.addItem("Next",11);
            untilBlock.onClick=[this]{auto next=read();next.autoUntilBlockEnd=untilBlock.getToggleState();write(next);sync();};
            withoutPlayback.onClick=[this]{auto next=read();next.prepareWithoutPlayback=withoutPlayback.getToggleState();write(next);sync();};
            subplay.onClick=[this]{auto next=read();next.automaticSubplay=subplay.getToggleState();write(next);sync();};
            lead.onChange=[this]{
                const int selection=lead.getSelectedId();if(selection<1)return;
                auto next=read();const int count=(selection+1)/2;
                next.automaticSubplayNext=selection==11;
                if(selection==11){write(next);return;}
                if(selection%2==0)next.automaticSubplayBars=count;
                else {next.automaticSubplayBars.reset();next.automaticSubplaySeconds=count;}
                write(next);
            };
            sync();
        }
        void resized() override {
            const int width=getWidth()-36;
            untilBlock.setBounds(18,12,width,38);withoutPlayback.setBounds(18,60,width,28);
            subplay.setBounds(18,102,width,28);leadLabel.setBounds(18,144,width-134,28);lead.setBounds(getWidth()-148,144,130,28);chooseTracks.setBounds(18,184,width,30);
        }
      private:
        TextButton chooseTracks;
        ToggleButton untilBlock,withoutPlayback,subplay;
        Label leadLabel;
        ComboBox lead;
        std::function<jaras::RegionSetlist()> read;
        std::function<void(jaras::RegionSetlist)> write;
        void sync() {
            const auto state=read();const bool hidden=state.prepareWithoutPlayback.value_or(false);
            untilBlock.setToggleState(state.autoUntilBlockEnd,dontSendNotification);
            withoutPlayback.setToggleState(hidden,dontSendNotification);
            subplay.setToggleState(state.automaticSubplay.value_or(false),dontSendNotification);
            lead.setSelectedId(state.automaticSubplayNext.value_or(false) ? 11 : state.automaticSubplayBars ? jlimit(1,5,*state.automaticSubplayBars)*2 : jlimit(1,5,(int)state.automaticSubplaySeconds.value_or(1))*2-1,dontSendNotification);
            subplay.setVisible(!hidden);leadLabel.setVisible(!hidden);lead.setVisible(!hidden);
            lead.setEnabled(state.automaticSubplay.value_or(false));leadLabel.setEnabled(state.automaticSubplay.value_or(false));
            chooseTracks.setVisible(!hidden);
            setSize(350,hidden?106:232);
        }
    };
    void autoOptions() {
        auto self=SafePointer<Setlist>(this);
        auto panel=std::make_unique<AutoOptionsPanel>(
            [self]{return self?self->currentState():jaras::RegionSetlist{};},
            [self](jaras::RegionSetlist next){if(self)self->apply(std::move(next));},[self]{if(self)self->chooseSubplayTracks();});
        CallOutBox::launchAsynchronously(std::move(panel),automatic.getScreenBounds(),nullptr);
    }
    class ConfigInitPanel final : public Component {
      public:
        ConfigInitPanel(const jaras::Part& part,std::function<void(int)> save,std::function<void()> close) {
            name.setText(String::fromUTF8(part.name.c_str()),dontSendNotification);
            label.setText(localization::translate("Initial playback"),dontSendNotification);
            for(int i=1;i<=5;++i) {
                lead.addItem(String(i)+"s",i*2-1);
                lead.addItem(String(i)+" "+localization::translate(i==1?"bar":"bars"),i*2);
            }
            lead.setSelectedId(part.subplayInitBars ? jlimit(1,5,*part.subplayInitBars)*2 : jlimit(1,5,(int)part.subplayInitSeconds.value_or(1))*2-1,dontSendNotification);
            apply.setButtonText(localization::translate("Save"));cancel.setButtonText(localization::translate("Cancel"));
            apply.onClick=[this,save]{save(lead.getSelectedId());};cancel.onClick=std::move(close);
            for(Component* child:std::initializer_list<Component*>{&name,&label,&lead,&apply,&cancel}) addAndMakeVisible(child);
        }
        void resized() override {
            name.setBounds(18,12,getWidth()-36,26);label.setBounds(18,48,getWidth()-172,28);
            lead.setBounds(getWidth()-148,48,130,28);cancel.setBounds(18,100,100,30);apply.setBounds(getWidth()-118,100,100,30);
        }
      private:
        Label name,label;ComboBox lead;TextButton apply,cancel;
    };
    void configInit(Entry entry) {
        const auto* song=w.session.song();if(!song)return;
        const auto at=std::find_if(song->parts.begin(),song->parts.end(),[&](const auto& p){return p.id==entry.sourceId;});
        if(at==song->parts.end())return;
        auto self=SafePointer<Setlist>(this);
        auto close=[self]{if(self)for(auto* child:self->w.getChildren())if(auto* sheet=dynamic_cast<ModalSheet*>(child);sheet&&sheet->getName()=="Config Init"){sheet->exitModalState(0);break;}};
        auto save=[self,entry,close](int selection){
            if(!self || selection<1 || selection>10)return;
            try {
                self->w.session.edit([&](jaras::Project& project){
                    for(auto& song:project.songs)for(auto& part:song.parts)if(part.id==entry.sourceId){
                        if(selection%2==0)part.subplayInitBars=(selection+1)/2;
                        else {part.subplayInitBars.reset();part.subplayInitSeconds=(selection+1)/2;}
                    }
                },false);
                close();
            } catch(const std::exception& e){self->w.showError(String::fromUTF8(e.what()));}
        };
        ModalSheet::open(w,"Config Init",std::make_unique<ConfigInitPanel>(*at,save,close),360,150);
    }
    void contextMenu(Entry entry) {
        if (entry.block) {
            auto targets = selectedEntryIDs();
            if (!targets.count(entry.id)) targets = {entry.id};
            for (const auto &row : entries) if (!row.block) targets.erase(row.id);
            PopupMenu menu;
            menu.addItem(1, localization::translate("Edit block"));
            const int number = blockNumber(entry.id);
            menu.addItem(3, "Learn MIDI", number > 0);
            menu.addSeparator();
            menu.addItem(2, localization::translate(targets.size() > 1 ? "Delete blocks" : "Delete block"));
            menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({Desktop::getMousePosition().x,Desktop::getMousePosition().y,1,1}),
                [self=SafePointer<Setlist>(this),entry,targets,number](int action) {
                    if (!self) return;
                    if (action == 1) self->editEntry(entry);
                    if (action == 2) self->requestEntryRemoval(targets);
                    if (action == 3 && number > 0)
                        ModalSheet::open(self->w, localization::translate("Map control"),
                            std::make_unique<SetlistBlockMIDIPanel>(self->w.actions, number), 400, 224);
                });
            return;
        }
        auto targets = selectedEntryIDs();
        if (!targets.count(entry.id)) targets = {entry.id};
        for (const auto &row : entries) if (row.block) targets.erase(row.id);
        PopupMenu menu;
        menu.addItem(4, localization::translate(String::fromUTF8("Editar música")));
        menu.addItem(2, localization::translate(String::fromUTF8("Detectar BPM…")));
        if (targets.size() == 1 && !entry.hasChildren) menu.addItem(1, "Multiloops");
        const auto playlist = selectedPlaylist() ? selectedPlaylist()->id : ID{};
        if (!playlist.empty() && targets.size()==1 && !entry.child && !searching)
            menu.addItem(7, localization::translate("Duplicate region"));
        menu.addItem(6,"Config Init");
        menu.addItem(3, localization::translate(String::fromUTF8("Exportar áudio")));
        if (!entry.child) menu.addItem(5, selectedPlaylist() ? localization::translate("Remover da playlist") : localization::translate(String::fromUTF8("Excluir região")));
        std::set<ID> sources;
        for (const auto &id : targets) sources.insert(selectedPlaylist() ? selectedPlaylist()->resolvedRegionId(id) : id);
        menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({Desktop::getMousePosition().x,Desktop::getMousePosition().y,1,1}),
            [self=SafePointer<Setlist>(this),entry,targets,sources,playlist](int action) {
                if(!self)return;
                if(action==1)self->w.editMultiLoops(entry.sourceId);
                if(action==2)self->w.detectRegions(sources);
                if(action==3)self->w.exportRegions(sources);
                if(action==4)self->editEntry(entry,sources);
                if(action==6)self->configInit(entry);
                if(action==7 && targets.size()==1 && !entry.child) {
                    self->w.perform([&] {
                        const auto copy=self->w.session.duplicatePlaylistRegion(playlist,entry.id);
                        if(!copy.empty()){self->selection={copy};self->selectedEntry=copy;self->refresh();}
                    });
                }
                if(action==5){
                    if(playlist.empty()) self->w.deleteRegions({entry.id},true);
                    else self->w.confirm("Remover da playlist", String::fromUTF8("Remover esta música da playlist?"), [self,entry,playlist] {
                        if(!self)return;auto state=self->currentState();
                        playlistOccurrences::remove(state,playlist,{entry.id});
                        self->apply(state);
                    });
                }
            });
    }
    void editEntry(Entry entry, std::set<ID> targets = {}) {
        if (targets.empty()) targets.insert(entry.block ? entry.id : entry.sourceId);
        if (!entry.block && targets.size() == 1) { w.editRegion(entry.sourceId); return; }
        const auto self = SafePointer<Setlist>(this);
        bool uppercase = true;
        String name = entry.name;
        if (auto *song = w.session.song())
            for (const auto &p : song->parts)
                if (p.id == entry.sourceId) {
                    uppercase = p.uppercaseName.value_or(true);
                    name = text(p.name);
                }
        auto close = [self] {
            if (self)
                for (auto *child : self->w.getChildren())
                    if (auto *sheet = dynamic_cast<ModalSheet *>(child))
                        if (sheet->getName() == String::fromUTF8("Editar música") ||
                            sheet->getName() == "Editar bloco") {
                            sheet->exitModalState(0);
                            break;
                        }
        };
        auto save = [self, entry, targets, close](String name, unsigned colour, bool uppercase) {
            if (!self)
                return;
            try {
                if (entry.block) {
                    auto state = self->currentState();
                    if (state.blocks)
                        for (auto &b : *state.blocks)
                            if (b.id == entry.id) {
                                b.name = utf8(name);
                                b.color = colour;
                            }
                    self->w.session.configureSetlist(state);
                } else
                    self->w.session.edit(
                        [&](jaras::Project &project) {
                            for (auto &song : project.songs)
                                for (auto &p : song.parts)
                                    if (targets.count(p.id)) {
                                        p.color = colour;
                                        if (song.markers) for (auto &marker : *song.markers) if (marker.sourceRegionID == p.id) {
                                            marker.name = p.name; marker.color = colour;
                                        }
                                    }
                        },
                        false);
                close();
            } catch (const std::exception &e) {
                self->w.showError(String::fromUTF8(e.what()));
            }
        };
        ModalSheet::open(w, entry.block ? "Editar bloco" : String::fromUTF8("Editar música"),
                         std::make_unique<RegionEditor>(name, entry.colour.getARGB() & 0xffffff,
                                                        uppercase, save, close, entry.block, entry.block),
                         300, 404);
    }
    void removeRegion(Entry entry) { w.deleteRegions({entry.sourceId}, true); }
};
