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
        list.setColour(ListBox::backgroundColourId, theme::background);
        list.setMultipleSelectionEnabled(true);
        addAndMakeVisible(playlistMenu);
        playlistMenu.setName("Escolher playlist");
        playlistMenu.context = [this] { playlistOptions(); };
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
        for (auto *b : {&bypass, &live, &parts}) {
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 11);
        }
        bypass.setColour(TextButton::buttonColourId, Colour(0xff454021));
        bypass.setColour(TextButton::buttonOnColourId, theme::yellow);
        bypass.onClick = [this] {
            w.perform([&] { w.session.command(jaras::CommandKind::toggleMultiLoopBypass); });
        };
        live.setColour(TextButton::buttonColourId, Colour(0xffff3036));
        live.setColour(TextButton::buttonOnColourId, Colour(0xffff3036));
        live.setColour(TextButton::textColourOffId, Colours::black);
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
        list.setBounds(4, searching ? 72 : 38, getWidth() - 8,
                       std::max(0, getHeight() - (searching ? 104 : 70)));
        const int cell = (getWidth() - 20) / 3;
        bypass.setBounds(8, getHeight() - 27, cell, 23);
        live.setBounds(11 + cell, getHeight() - 27, cell, 23);
        parts.setBounds(14 + cell * 2, getHeight() - 27, cell, 23);
        if (playlistEditor)
            playlistEditor->setBounds(getLocalBounds());
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setColour(theme::line);
        g.drawVerticalLine(0, 0, (float)getHeight());
        g.setColour(theme::secondary);
        g.setFont(theme::font(11));

        if (entries.empty())
            g.drawFittedText(search.getText().isEmpty() ? "No regions" : "No matching songs", 16,
                             searching ? 90 : 60, getWidth() - 32, 44, Justification::centred, 2);
    }
    void refresh() {
        refreshing = true;
        auto state = currentState();
        playlistMenu.clear(dontSendNotification);
        playlistMenu.addItem(String::fromUTF8("Todas as regiões"), 1);
        bypass.setToggleState(w.session.transport().multiLoopsBypassed, dontSendNotification);
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
                if (children && (expanded.count(part->id) || query.isNotEmpty()))
                    for (const auto &child : sorted)
                        if (child.parentRegionID == part->id)
                            addPart(child, index);
            }
            addBlocks(std::nullopt);
        }
        refreshing = false;
        list.updateContent();
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
        std::function<void()> context;
        void mouseDown(const MouseEvent &e) override {
            if (e.mods.isPopupMenu()) {
                if (context)
                    context();
            } else
                ComboBox::mouseDown(e);
        }
    } playlistMenu;
    std::unique_ptr<PlaylistEditor> playlistEditor;
    int dropRow = -1;
    TextButton addPlaylist{"+"}, searchButton{String::fromUTF8("⌕")}, blocks{"Blocos"},
        stop{"STOP"}, live{"Live"}, bypass{"ByPass"}, parts{"Parts"};
    QuietButton automatic{"AUTO"};
    TextEditor search;
    bool refreshing = false, searching = false;
    std::vector<Entry> entries;
    std::set<ID> expanded;
    ID selectedEntry;
    int regionCount = 0;
    double totalDuration = 0;
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
    void changeListenerCallback(ChangeBroadcaster *) override { list.repaint(); }
    int getNumRows() override { return (int)entries.size(); }
    void paintListBoxItem(int row, Graphics &g, int width, int, bool selected) override {
        if (row < 0 || row >= getNumRows())
            return;
        const auto &entry = entries[(size_t)row];
        const auto &t = w.session.transport();
        const bool active = t.playing && t.regionId == entry.id,
                   queued = t.playing && t.queuedRegionId == entry.id;
        const int left = entry.child ? 22 : 4;
        auto bounds = juce::Rectangle<float>((float)left, 0, (float)width - left - 4, 34);
        g.setColour(theme::panel);
        g.fillRoundedRectangle(bounds, 5);
        if (active || queued || selected) {
            auto colour = active ? Colour(0xffba423e) : queued ? theme::yellow : theme::green;
            g.setGradientFill(ColourGradient(colour.withAlpha(.35f), bounds.getX(), 0,
                                             colour.withAlpha(.03f), bounds.getRight(), 0, false));
            g.fillRoundedRectangle(bounds, 5);
            if (selected) {
                g.setColour(theme::green);
                g.drawRoundedRectangle(bounds.reduced(.6f), 5, 1);
            }
        }
        g.setColour(active ? Colour(0xfffa5655) : queued ? Colour(0xfff6ac4e) : entry.colour);
        g.fillRoundedRectangle((float)left + 8, 7, 3, 20, 2);
        g.setFont(theme::font(11));
        g.setColour(theme::secondary);
        const int number = w.appearance.regionIDs() ? entry.regionNumber : entry.number;
        if (!entry.block)
            g.drawText(String(number).paddedLeft('0', 2), left + 17, 0, 22, 34,
                       Justification::centredLeft);
        const int nameX = left + (entry.block ? 18 : 42),
                  right = width - 12 - (entry.hasChildren ? 16 : 0);
        const int seconds = (int)(active ? std::ceil(std::max(0.0, entry.end - t.position))
                                         : entry.end - entry.start);
        const auto duration =
            (seconds >= 60 ? String(seconds / 60) + "m  " : String()) + String(seconds % 60) + "s";
        g.setColour(Colours::white);
        if (!entry.block)
            g.drawText(duration, right - 42, 0, 42, 34, Justification::centredRight);
        g.setFont(w.appearance.setlistFont());
        g.setColour(entry.block
                        ? Colours::white
                        : w.appearance.setlistColour(selectedPlaylist() != nullptr, entry.child));
        g.drawFittedText(entry.name, nameX, 0, std::max(0, right - nameX - (entry.block ? 0 : 48)),
                         34, Justification::centredLeft, 1);
        if (entry.hasChildren) {
            g.setFont(theme::font(12));
            g.setColour(theme::secondary);
            g.drawText(expanded.count(entry.id) ? String::fromUTF8("⌄") : String::fromUTF8("›"),
                       width - 27, 0, 16, 34, Justification::centred);
        }
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
        if (entry.hasChildren && event.x > list.getWidth() - 32) {
            if (!expanded.erase(entry.id))
                expanded.insert(entry.id);
            refresh();
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
    void createPlaylist(bool editing = false) {
        if (!w.session.song())
            return;
        auto self = SafePointer<Setlist>(this);
        auto finish = [self] {
            MessageManager::callAsync([self] {
                if (self)
                    self->playlistEditor.reset();
            });
        };
        playlistEditor = std::make_unique<PlaylistEditor>(
            *w.session.song(), editing ? selectedPlaylist() : nullptr,
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
            finish);
        addAndMakeVisible(*playlistEditor);
        playlistEditor->toFront(true);
        resized();
    }
    void playlistOptions() {
        const auto *playlist = selectedPlaylist();
        PopupMenu menu;
        menu.addItem(1, "Nova playlist");
        menu.addItem(2, "Editar playlist", playlist != nullptr);
        menu.addItem(3, "Excluir playlist", playlist != nullptr);
        const auto selected = playlist ? playlist->id : ID();
        menu.showMenuAsync(
            PopupMenu::Options().withTargetComponent(&playlistMenu),
            [self = SafePointer<Setlist>(this), selected](int action) {
                if (!self)
                    return;
                if (action == 1)
                    self->createPlaylist();
                if (action == 2)
                    self->createPlaylist(true);
                if (action == 3)
                    self->w.confirm(
                        "Excluir playlist",
                        String::fromUTF8("Excluir esta playlist? As músicas continuam no projeto."),
                        [self, selected] {
                            if (!self)
                                return;
                            auto state = self->currentState();
                            state.playlists.erase(
                                std::remove_if(state.playlists.begin(), state.playlists.end(),
                                               [&](const auto &p) { return p.id == selected; }),
                                state.playlists.end());
                            if (state.blocks)
                                state.blocks->erase(
                                    std::remove_if(
                                        state.blocks->begin(), state.blocks->end(),
                                        [&](const auto &b) { return b.playlistId == selected; }),
                                    state.blocks->end());
                            state.selectedId.reset();
                            self->apply(state);
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
        PopupMenu menu;
        if (!entry.block) {
            menu.addItem(1, "Select song");
            menu.addItem(2, "Queue song");
            menu.addSeparator();
        }
        menu.addItem(3, entry.block ? "Editar bloco" : String::fromUTF8("Editar música"));
        if (selectedPlaylist()) {
            if (!entry.block) {
                menu.addItem(4, "Move up");
                menu.addItem(5, "Move down");
            }
            menu.addItem(6, entry.block ? "Delete block" : "Remove from playlist");
        } else if (!entry.block && !entry.child)
            menu.addItem(7, String::fromUTF8("Excluir região"));
        menu.showMenuAsync(
            PopupMenu::Options().withTargetComponent(&list),
            [self = SafePointer<Setlist>(this), entry](int action) {
                if (!self || !action)
                    return;
                auto &w = self->w;
                if (action == 1 || action == 2)
                    w.perform([&] {
                        w.session.command(action == 1 ? jaras::CommandKind::selectRegion
                                                      : jaras::CommandKind::queueRegion,
                                          entry.id);
                    });
                if (action == 3)
                    self->editEntry(entry);
                if (action == 7)
                    self->removeRegion(entry);
                if (action >= 4 && action <= 6) {
                    auto state = self->currentState();
                    if (entry.block && state.blocks)
                        state.blocks->erase(
                            std::remove_if(state.blocks->begin(), state.blocks->end(),
                                           [&](const auto &b) { return b.id == entry.id; }),
                            state.blocks->end());
                    else
                        for (auto &playlist : state.playlists)
                            if (state.selectedId == playlist.id) {
                                auto position = std::find(playlist.regionIds.begin(),
                                                          playlist.regionIds.end(), entry.id);
                                if (position == playlist.regionIds.end())
                                    break;
                                if (action == 4 && position != playlist.regionIds.begin())
                                    std::iter_swap(position, position - 1);
                                if (action == 5 && position + 1 != playlist.regionIds.end())
                                    std::iter_swap(position, position + 1);
                                if (action == 6) {
                                    auto next = position + 1 == playlist.regionIds.end()
                                                    ? std::optional<ID>{}
                                                    : std::optional<ID>(*(position + 1));
                                    if (state.blocks)
                                        for (auto &b : *state.blocks)
                                            if (b.playlistId == playlist.id &&
                                                b.beforeRegionId == entry.id)
                                                b.beforeRegionId = next;
                                    playlist.regionIds.erase(position);
                                }
                            }
                    self->apply(state);
                }
            });
    }
    void editEntry(Entry entry) {
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
        auto save = [self, entry, close](String name, unsigned colour, bool uppercase) {
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
                                    if (p.id == entry.id) {
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
    void removeRegion(Entry entry) {
        const auto self = SafePointer<Setlist>(this);
        w.confirm(
            String::fromUTF8("Excluir região"),
            String::fromUTF8("Excluir esta região e suas partes? As mídias permanecem nas pistas."),
            [self, entry] {
                if (!self)
                    return;
                self->w.perform([&] {
                    self->w.session.edit([&](jaras::Project &project) {
                        std::set<ID> removed{entry.id};
                        bool changed = true;
                        while (changed) {
                            changed = false;
                            for (const auto &song : project.songs)
                                for (const auto &part : song.parts)
                                    if (part.parentRegionID &&
                                        removed.count(*part.parentRegionID) &&
                                        removed.insert(part.id).second)
                                        changed = true;
                        }
                        for (auto &song : project.songs) {
                            for (auto &track : song.tracks)
                                for (auto &clip : track.clips)
                                    if (clip.regionOwnerID && removed.count(*clip.regionOwnerID))
                                        clip.regionOwnerID.reset();
                            song.parts.erase(
                                std::remove_if(song.parts.begin(), song.parts.end(),
                                               [&](const auto &p) { return removed.count(p.id); }),
                                song.parts.end());
                        }
                        if (project.regionSetlist) {
                            auto &state = *project.regionSetlist;
                            for (auto &playlist : state.playlists)
                                playlist.regionIds.erase(
                                    std::remove_if(playlist.regionIds.begin(),
                                                   playlist.regionIds.end(),
                                                   [&](const ID &id) { return removed.count(id); }),
                                    playlist.regionIds.end());
                            if (state.blocks)
                                for (auto &b : *state.blocks)
                                    if (b.beforeRegionId && removed.count(*b.beforeRegionId))
                                        b.beforeRegionId.reset();
                            if (state.playedLiveRegionIDs)
                                state.playedLiveRegionIDs->erase(
                                    std::remove_if(state.playedLiveRegionIDs->begin(),
                                                   state.playedLiveRegionIDs->end(),
                                                   [&](const ID &id) { return removed.count(id); }),
                                    state.playedLiveRegionIDs->end());
                        }
                    });
                });
            });
    }
};
