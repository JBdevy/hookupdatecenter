// Included by Workspace.cpp inside namespace catlive after the timeline implementation.
class Workspace::Setlist final : public Component,
                                 public DragAndDropContainer,
                                 public DragAndDropTarget,
                                 private ListBoxModel,
                                 private ChangeListener {
  public:
    explicit Setlist(Workspace &owner) : w(owner) {
        w.appearance.addChangeListener(this);
        addAndMakeVisible(list);
        list.setModel(this);
        list.setRowHeight(38);
        list.setColour(ListBox::backgroundColourId, Colour(0xff151b22));
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
        live.setColour(TextButton::buttonColourId, Colour(0xffff3030));
        live.setColour(TextButton::buttonOnColourId, theme::green);
        live.setColour(TextButton::textColourOffId, Colours::black);
        live.setColour(TextButton::textColourOnId, Colours::black);
        parts.onClick = [this] {
            w.openPartsList();
        };
        addPlaylist.onClick = [this] { createPlaylist(); };
        searchButton.setTooltip("Search songs");
        searchButton.onClick = [this] {
            searching = !searching;
            search.setVisible(searching);
            if (!searching)
                search.setText({}, true);
            else
                search.grabKeyboardFocus();
            resized();
        };
        addChildComponent(search);
        search.setFont(theme::font(13));
        search.setTextToShowWhenEmpty("Search songs", theme::secondary);
        search.onTextChange = [this] { refresh(); };
        search.onEscapeKey = [this] {
            searching = false;
            search.setText({});
            resized();
        };
        automatic.setTooltip("Queue the next song automatically");
        automatic.onClick = [this] {
            auto state = currentState();
            state.autoAdvance = !state.autoAdvance;
            apply(state);
        };
        automatic.context = [this](Point<int>) { autoOptions(); };
        blocks.setTooltip("Add a setlist block");
        blocks.onClick = [this] { addBlock(); };
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
    ~Setlist() override { w.appearance.removeChangeListener(this); }
    bool selectAllItems() {
        if (getNumRows() > 0) list.selectRangeOfRows(0, getNumRows() - 1);
        list.repaint();
        return true;
    }
    bool keyPressed(const KeyPress &key) override {
        if (dynamic_cast<TextEditor *>(Component::getCurrentlyFocusedComponent()))
            return retryEditorShortcut(key);
        const auto mods = key.getModifiers();
        const auto code = key.getKeyCode();
        if (mods.isCtrlDown() && !mods.isAltDown() && !mods.isShiftDown() &&
            (code == 'A' || code == 'a' || code == 1)) return selectAllItems();
        return false;
    }
    void resized() override {
        int x = 8, y = 2;
        playlistMenu.setBounds(x, y, std::max(70, getWidth() - 184), 30);
        x = playlistMenu.getRight() + 3;
        for (auto item : std::initializer_list<std::pair<Button *, int>>{{&addPlaylist, 22},
                                                                         {&searchButton, 22},
                                                                         {&automatic, 34},
                                                                         {&blocks, 38},
                                                                         {&stop, 38}}) {
            item.first->setBounds(x, y + 2, item.second, 26);
            x += item.second + 3;
        }
        search.setVisible(searching);
        search.setBounds(8, 38, getWidth() - 16, 28);
        const int footerHeight = footerVisible ? 28 : 16;
        const int top = searching ? 72 : 38;
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
        g.fillAll(Colour(0xff151b22));
        g.setColour(theme::line);
        g.drawVerticalLine(0, 0, (float)getHeight());
        g.setColour(Colours::white.withAlpha(.12f));
        g.drawHorizontalLine(getHeight() - (footerVisible ? 28 : 16), 0, (float)getWidth());
        g.setColour(theme::secondary);
        g.setFont(theme::font(11));

        if (entries.empty())
            g.drawFittedText(search.getText().isEmpty() ? "No regions" : "No matching songs", 16,
                             searching ? 90 : 60, getWidth() - 32, 44, Justification::centred, 2);
    }
    void refresh() {
        refreshing = true;
        const bool reveal = focusRevision != w.session.setlistFocusRevision;
        focusRevision = w.session.setlistFocusRevision;
        if (reveal) {
            selection.clear();
            if (w.session.focusedRegion) selection.insert(*w.session.focusedRegion);
        }
        // Rows move when a unified region opens. Keep selection attached to IDs,
        // including multi-selection, instead of ListBox's previous row indices.
        const auto selectedIDs = selection;
        auto state = currentState();
        playlistMenu.clear(dontSendNotification);
        playlistMenu.addItem(String::fromUTF8("Todas as regiões"), 1);
        bypass.setActive(w.session.transport().multiLoopsBypassed);
        int selected = 1;
        for (size_t i = 0; i < state.playlists.size(); ++i) {
            playlistMenu.addItem(text(state.playlists[i].name), (int)i + 2);
            if (state.selectedId == state.playlists[i].id)
                selected = (int)i + 2;
        }
        playlistMenu.setSelectedId(selected, dontSendNotification);
        automatic.setToggleState(state.autoAdvance, dontSendNotification);
        stop.setToggleState(state.stopAtRegionEnd.value_or(false), dontSendNotification);
        live.setToggleState(state.liveEnabled.value_or(false), dontSendNotification);
        const auto *playlist = selectedPlaylist();
        blocks.setEnabled(playlist != nullptr);
        entries.clear();
        regionCount = 0;
        totalDuration = 0;
        auto *song = w.session.song();
        if (song) {
            std::vector<const jaras::Part *> roots;
            std::map<ID, int> ids;
            auto sorted = song->parts;
            std::stable_sort(sorted.begin(), sorted.end(), [](const auto &a, const auto &b) {
                if (a.startTime != b.startTime)
                    return a.startTime < b.startTime;
                return a.endTime > b.endTime;
            });
            int index = 0;
            for (const auto &part : sorted)
                ids[part.id] = ++index;
            if (playlist) {
                for (const auto &id : playlist->regionIds)
                    for (const auto &part : song->parts)
                        if (part.id == id)
                            roots.push_back(&part);
            } else {
                for (const auto &part : song->parts)
                    if (!part.parentRegionID)
                        roots.push_back(&part);
                std::stable_sort(roots.begin(), roots.end(),
                                 [](auto *a, auto *b) { return a->startTime < b->startTime; });
            }
            const auto query = search.getText().trim();
            auto addBlocks = [&](const std::optional<ID> &before) {
                if (!state.blocks)
                    return;
                for (const auto &block : *state.blocks)
                    if (block.songId == song->id &&
                        block.playlistId ==
                            (playlist ? std::optional<ID>(playlist->id) : std::nullopt) &&
                        block.beforeRegionId == before &&
                        (query.isEmpty() || text(block.name).containsIgnoreCase(query))) {
                        Entry entry;
                        entry.block = true;
                        entry.id = block.id;
                        entry.name = text(block.name);
                        entry.colour = Colour(0xff000000u | block.color);
                        entries.push_back(entry);
                    }
            };
            index = 0;
            for (auto *part : roots) {
                ++index;
                ++regionCount;
                totalDuration += part->endTime - part->startTime;
                addBlocks(part->id);
                const bool children =
                    std::any_of(song->parts.begin(), song->parts.end(),
                                [&](const auto &p) { return p.parentRegionID == part->id; });
                auto addPart = [&](const jaras::Part &p, int number) {
                    auto name = text(p.name);
                    if (p.uppercaseName.value_or(true))
                        name = unicodeCase(name);
                    if (query.isNotEmpty() && !name.containsIgnoreCase(query))
                        return;
                    Entry entry;
                    entry.id = p.id;
                    entry.name = name;
                    entry.start = p.startTime;
                    entry.end = p.endTime;
                    entry.child = p.parentRegionID.has_value();
                    entry.number = number;
                    entry.regionNumber = ids[p.id];
                    entry.colour = Colour(0xff000000u | p.color.value_or(0x777777));
                    entry.hasChildren = !entry.child && children;
                    entries.push_back(entry);
                };
                addPart(*part, index);
                if (children && (expanded.count(part->id) || query.isNotEmpty())) {
                    int childNumber = 0;
                    for (const auto &child : sorted)
                        if (child.parentRegionID == part->id)
                            addPart(child, ++childNumber);
                }
            }
            addBlocks(std::nullopt);
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
                list.selectRow(row, true, false);
                if (reveal) list.scrollToEnsureRowIsOnscreen(row);
            }
        }
        refreshing = false;
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
        Array<var> selected, visibleSelected, rowNumbers;
        for (const auto &id : selection) selected.add(text(id));
        for (const auto &id : selectedEntryIDs()) visibleSelected.add(text(id));
        for (const auto &entry : entries) rowNumbers.add(entry.number);
        put(result, "selectedEntries", selected);
        put(result, "visibleSelectedEntries", visibleSelected);
        put(result, "rowNumbers", rowNumbers);
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
    class BypassButton final : public TextButton, private Timer {
      public:
        BypassButton() : TextButton("ByPass") {}
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
        ID id;
        String name;
        double start = 0, end = 0;
        int number = 0, regionNumber = 0;
        Colour colour;
        bool child = false, block = false, hasChildren = false;
    };
    Workspace &w;
    ListBox list;
    class PlaylistBox final : public ComboBox {
      public:
        std::function<void()> context, open;
        void mouseDown(const MouseEvent &e) override { if(e.mods.isPopupMenu()) { if(context)context(); } else if(open)open(); }
        void mouseUp(const MouseEvent &) override {}
        bool keyPressed(const KeyPress &key) override {
            if(key==KeyPress::spaceKey || key==KeyPress::returnKey || key==KeyPress::downKey) { if(open)open();return true; }
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
    std::unique_ptr<PlaylistEditor> playlistEditor;
    int dropRow = -1;
    TextButton addPlaylist{"+"}, searchButton{String::fromUTF8("⌕")}, blocks{"Blocos"},
        stop{"STOP"}, live{"Live"}, parts{"Parts"};
    BypassButton bypass;
    QuietButton automatic{"AUTO"};
    TextEditor search;
    bool refreshing = false, searching = false, footerVisible = true;
    uint64 focusRevision = 0;
    DrawerButton footerToggle;
    std::vector<Entry> entries;
    std::set<ID> expanded;
    std::set<ID> selection;
    ID selectedEntry;
    int regionCount = 0;
    double totalDuration = 0;
    std::set<ID> selectedEntryIDs() const {
        std::set<ID> result;
        const auto rows = list.getSelectedRows();
        for (int i = 0; i < rows.size(); ++i)
            if (rows[i] >= 0 && rows[i] < (int)entries.size()) result.insert(entries[(size_t)rows[i]].id);
        return result;
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
        resized(); repaint(); list.repaint();
    }
    int getNumRows() override { return (int)entries.size(); }
    void selectedRowsChanged(int) override {
        if (!refreshing) selection = selectedEntryIDs();
    }
    Component *refreshComponentForRow(int row, bool, Component *existing) override {
        auto *drawer = static_cast<RowDrawer *>(existing);
        if (!drawer) drawer = new RowDrawer();
        const bool available = row >= 0 && row < getNumRows() && entries[(size_t)row].hasChildren;
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
    void paintListBoxItem(int row, Graphics &g, int width, int, bool selected) override {
        if (row < 0 || row >= getNumRows())
            return;
        const auto &entry = entries[(size_t)row];
        const auto t = w.session.presentationTransport();
        const bool active = t.playing && t.regionId == entry.id,
                   queued = t.playing && t.queuedRegionId == entry.id;
        const auto state = currentState();
        const bool played = state.playedLiveRegionIDs &&
            std::find(state.playedLiveRegionIDs->begin(), state.playedLiveRegionIDs->end(), entry.id) != state.playedLiveRegionIDs->end();
        const bool prepareOnly = state.prepareWithoutPlayback.value_or(false);
        const int left = entry.child ? 18 : 0;
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
        if (!entry.block)
            g.drawText(String(number).paddedLeft('0', 2), left + 17, 0, 22, 34,
                       Justification::centredLeft);
        const int nameX = left + (entry.block ? 18 : 23 + std::max(2, String(number).length()) * 6),
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
        if (row < 0 || row >= getNumRows())
            return;
        auto entry = entries[(size_t)row];
        selectedEntry = entry.id;
        if (event.mods.isPopupMenu()) {
            ++w.contextCount;
            contextMenu(entry);
            return;
        }
        if (entry.block || event.mods.isCtrlDown() || event.mods.isShiftDown())
            return;
        w.perform([&] {
            w.session.command(w.session.transport().playing ? jaras::CommandKind::queueRegion
                                                            : jaras::CommandKind::selectRegion,
                              entry.id);
        });
    }
    void listBoxItemDoubleClicked(int row, const MouseEvent &) override {
        if (row >= 0 && row < getNumRows() && !entries[(size_t)row].block)
            w.perform([&] {
                w.session.command(jaras::CommandKind::selectRegion, entries[(size_t)row].id);
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
        PopupMenu menu; menu.addItem(1,"Copiar para compartilhar",w.session.song()!=nullptr);
        if(row && selected) {menu.addSeparator();menu.addItem(2,String::fromUTF8("Adicionar regiões"));menu.addItem(3,"Editar");menu.addItem(4,"Clonar playlist");menu.addItem(5,"Excluir playlist");}
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
                    auto copy=p;copy.id=uuid();copy.name += " (cópia)";
                    if(state.blocks){auto blocks=*state.blocks;for(auto block:blocks)if(block.playlistId==selected){block.id=uuid();block.playlistId=copy.id;state.blocks->push_back(block);}}
                    state.selectedId=copy.id;state.playlists.push_back(copy);self->apply(state);break;}}
                if(action==5)self->w.confirm("Excluir playlist",String::fromUTF8("Excluir esta playlist? As músicas continuam no projeto."),[self,selected,project]{
                    if(!self || self->w.session.project().id!=project)return;auto state=self->currentState();
                    state.playlists.erase(std::remove_if(state.playlists.begin(),state.playlists.end(),[&](const auto &p){return p.id==selected;}),state.playlists.end());
                    if(state.blocks)state.blocks->erase(std::remove_if(state.blocks->begin(),state.blocks->end(),[&](const auto &b){return b.playlistId==selected;}),state.blocks->end());
                    if(state.selectedId==selected)state.selectedId.reset();self->apply(state);
                });
            });
    }
    var getDragSourceDescription(const SparseSet<int> &rows) override {
        if (!selectedPlaylist())
            return {};
        Array<var> ids;
        for (int i = 0; i < rows.size(); ++i) {
            const int row = rows[i];
            if (row >= 0 && row < (int)entries.size() && !entries[(size_t)row].block &&
                !entries[(size_t)row].child)
                ids.add(text(entries[(size_t)row].id));
        }
        if (ids.isEmpty())
            return {};
        auto payload = object();
        put(payload, "type", "catlive-playlist-regions");
        put(payload, "ids", ids);
        return payload;
    }
    bool isInterestedInDragSource(const SourceDetails &details) override {
        return selectedPlaylist() && str(details.description, "type") == "catlive-playlist-regions";
    }
    void itemDragMove(const SourceDetails &details) override {
        auto local = details.localPosition - list.getPosition();
        list.getViewport()->autoScroll(local.x, local.y, 24, 12);
        dropRow = jlimit(0, (int)entries.size(), (local.y + scrollY() + 19) / 38);
        repaint();
    }
    void itemDragExit(const SourceDetails &) override {
        dropRow = -1;
        repaint();
    }
    void itemDropped(const SourceDetails &details) override {
        if (!selectedPlaylist())
            return;
        const auto payload = listValues(details.description);
        auto state = currentState();
        std::optional<ID> before;
        for (int row = std::max(0, dropRow); row < (int)entries.size(); ++row)
            if (!entries[(size_t)row].block && !entries[(size_t)row].child &&
                !payload.count(entries[(size_t)row].id)) {
                before = entries[(size_t)row].id;
                break;
            }
        for (auto &p : state.playlists)
            if (state.selectedId == p.id) {
                std::vector<ID> moving;
                for (const auto &id : p.regionIds)
                    if (payload.count(id))
                        moving.push_back(id);
                p.regionIds.erase(std::remove_if(p.regionIds.begin(), p.regionIds.end(),
                                                 [&](const ID &id) { return payload.count(id); }),
                                  p.regionIds.end());
                const auto position =
                    before ? std::find(p.regionIds.begin(), p.regionIds.end(), *before)
                           : p.regionIds.end();
                p.regionIds.insert(position, moving.begin(), moving.end());
            }
        dropRow = -1;
        apply(state);
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
            g.fillRect(list.getX() + 4, list.getY() + dropRow * 38 - scrollY(), list.getWidth() - 8,
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
        block.name = "Block " + std::to_string(state.blocks->size() + 1);
        block.color = 0x6d647e;
        if (std::find(playlist->regionIds.begin(), playlist->regionIds.end(), selectedEntry) !=
            playlist->regionIds.end())
            block.beforeRegionId = selectedEntry;
        state.blocks->push_back(block);
        apply(state);
    }
    void autoOptions() {
        auto state = currentState();
        PopupMenu menu;
        menu.addItem(1, "Run queue until the end of the block", true, state.autoUntilBlockEnd);
        menu.addItem(2, "Without playback", true, state.prepareWithoutPlayback.value_or(false));
        menu.addItem(3, "Automatic Subplay", !state.prepareWithoutPlayback.value_or(false),
                     state.automaticSubplay.value_or(false));
        PopupMenu lead;
        for (int i = 1; i <= 5; ++i)
            lead.addItem(10 + i, String(i) + "s", true,
                         (int)state.automaticSubplaySeconds.value_or(1) == i);
        menu.addSubMenu("Start before the end", lead);
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&automatic),
                           [self = SafePointer<Setlist>(this)](int action) {
                               if (!self || !action)
                                   return;
                               auto next = self->currentState();
                               if (action == 1)
                                   next.autoUntilBlockEnd = !next.autoUntilBlockEnd;
                               if (action == 2)
                                   next.prepareWithoutPlayback =
                                       !next.prepareWithoutPlayback.value_or(false);
                               if (action == 3)
                                   next.automaticSubplay = !next.automaticSubplay.value_or(false);
                               if (action > 10)
                                   next.automaticSubplaySeconds = action - 10;
                               self->apply(next);
                           });
    }
    void contextMenu(Entry entry) {
        if (entry.block) { editEntry(entry); return; }
        auto targets = selectedEntryIDs();
        if (!targets.count(entry.id)) targets = {entry.id};
        for (const auto &row : entries) if (row.block) targets.erase(row.id);
        PopupMenu menu;
        if (targets.size() == 1 && !entry.hasChildren) menu.addItem(1, "Multiloops");
        menu.addItem(2, String::fromUTF8("Detectar BPM…"));
        menu.addItem(3, String::fromUTF8("Exportar áudio"));
        menu.addItem(4, String::fromUTF8("Editar música"));
        if (!entry.child) menu.addItem(5, selectedPlaylist() ? "Remover da playlist" : String::fromUTF8("Excluir região"));
        const auto playlist = selectedPlaylist() ? selectedPlaylist()->id : ID{};
        menu.showMenuAsync(PopupMenu::Options().withTargetScreenArea({Desktop::getMousePosition().x,Desktop::getMousePosition().y,1,1}),
            [self=SafePointer<Setlist>(this),entry,targets,playlist](int action) {
                if(!self)return;
                if(action==1)self->w.editMultiLoops(entry.id);
                if(action==2)self->w.detectRegions(targets);
                if(action==3)self->w.exportRegions(targets);
                if(action==4)self->editEntry(entry,targets);
                if(action==5){
                    if(playlist.empty()) self->w.deleteRegions({entry.id},true);
                    else self->w.confirm("Remover da playlist", String::fromUTF8("Remover esta música da playlist?"), [self,entry,playlist] {
                        if(!self)return;auto state=self->currentState();
                        for(auto &list:state.playlists)if(list.id==playlist){
                            const auto at=std::find(list.regionIds.begin(),list.regionIds.end(),entry.id);if(at==list.regionIds.end())break;
                            const std::optional<ID> next=at+1==list.regionIds.end()?std::optional<ID>{}:std::optional<ID>{*(at+1)};
                            if(state.blocks)for(auto &block:*state.blocks)if(block.playlistId==playlist&&block.beforeRegionId==entry.id)block.beforeRegionId=next;
                            list.regionIds.erase(at);
                        }
                        self->apply(state);
                    });
                }
            });
    }
    void editEntry(Entry entry, std::set<ID> targets = {}) {
        if (targets.empty()) targets.insert(entry.id);
        const auto self = SafePointer<Setlist>(this);
        bool uppercase = true;
        String name = entry.name;
        if (auto *song = w.session.song())
            for (const auto &p : song->parts)
                if (p.id == entry.id) {
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
                                        p.name = utf8(name);
                                        p.color = colour;
                                        p.uppercaseName = uppercase;
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
                                                        uppercase, save, close),
                         300, 404);
    }
    void removeRegion(Entry entry) { w.deleteRegions({entry.id}, true); }
};
