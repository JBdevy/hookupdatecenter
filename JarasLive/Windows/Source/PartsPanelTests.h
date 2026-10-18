#pragma once
#include "PartsPanel.h"
#include "Workspace.h"
#include "UIFeatureTests.h"

namespace catlive {
struct PartsDividerTests {
    static void run(const File &directory) {
        const auto require=[](bool okay,const char *message){if(!okay)throw std::runtime_error(message);};
        jaras::Project project;project.id=uuid();project.name="Parts widths";
        jaras::Song song;song.id=uuid();song.name="Song";song.duration=40;
        song.parts={{uuid(),"First",0,20},{uuid(),"Second",20,40}};
        jaras::Track track;track.id=uuid();track.name="Audio";track.role.id="other";song.tracks={track};
        project.songs={song};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
        const auto preferences=directory.getNonexistentChildFile("parts-widths",".json");
        require(preferences.replaceWithText(R"({"jaras.trackColumnWidth":420,"jaras.setlistWidth":336})"),
                "Cannot create Parts width preferences");
        const auto drag=[](DragDivider &divider,int delta) {
            const Point<float> origin{3.f,divider.getHeight()*.5f};
            const auto event=[&](Point<float> at,bool down) {
                return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,
                    ModifierKeys(down?ModifierKeys::leftButtonModifier:0),1,0,0,0,0,&divider,&divider,
                    Time::getCurrentTime(),origin,Time::getCurrentTime(),1,at!=origin);
            };
            divider.mouseDown(event(origin,true));
            divider.mouseDrag(event({origin.x+(float)delta,origin.y},true));
            divider.mouseUp(event({origin.x+(float)delta,origin.y},false));
        };
        int savedLeft=0,savedRight=0;
        {
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);session.dirty=false;
            const auto before=JSON::toString(session.snapshot());
            Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,preferences);
            workspace.setSize(1920,900);workspace.toggleLeftParts();workspace.toggleRightParts();
            auto *left=workspace.partsLeft.get(),*right=workspace.partsSidebar.get();
            auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");
            auto *list=uiFeatureTests::find(workspace,"setlistPanel");
            require(canvas && list,"Parts resize fixture has no grid or Setlist");
            const auto checkDock=[&] {
                const auto grid=workspace.getLocalArea(canvas,canvas->getLocalBounds());
                require(grid.getWidth()>=100 && workspace.getLocalBounds().contains(grid),
                        "Parts resizing collapsed the grid below 100 pixels or placed it outside the window");
                if(workspace.partsLeftVisible) require(workspace.partsLeftDivider.isVisible() &&
                    workspace.partsLeftDivider.getX()+3==left->getRight() &&
                    left->getRight()==workspace.tracksViewport.getX(),"Left divider did not follow the Parts/Track Mixer boundary");
                if(workspace.partsRightVisible) require(workspace.partsRightDivider.isVisible() &&
                    workspace.partsRightDivider.getParentComponent()==&workspace &&
                    workspace.partsRightDivider.getX()+3==right->getX(),"Right divider did not follow its Parts boundary");
                require(workspace.mixerWidth==420 && workspace.setlistWidth==336 &&
                    (int)Appearance(preferences).value("jaras.trackColumnWidth",0)==420 &&
                    (int)Appearance(preferences).value("jaras.setlistWidth",0)==336,
                    "Resizing Parts changed another panel's stored width");
            };
            checkDock();const int initialLeft=left->getWidth(),initialRight=right->getWidth();
            drag(workspace.partsLeftDivider,64);savedLeft=initialLeft+64;
            require(left->getWidth()==savedLeft && right->getWidth()==initialRight &&
                    workspace.tracksViewport.getWidth()==420,"Left Parts drag resized the other panel or ignored its delta");
            drag(workspace.partsRightDivider,-80);savedRight=initialRight+80;
            require(right->getWidth()==savedRight && left->getWidth()==savedLeft && list->getWidth()==336,
                    "Right Parts drag changed Setlist width or used the wrong drag direction");checkDock();
            require((int)Appearance(preferences).value("catlive.partsLeftWidth",0)==savedLeft &&
                    (int)Appearance(preferences).value("catlive.partsRightWidth",0)==savedRight,
                    "Parts widths were not persisted at drag completion");
            FileOutputStream output(directory.getChildFile("parts-width-dividers.png"));
            require(output.openedOk(),"Cannot create Parts divider screenshot");output.setPosition(0);output.truncate();
            require(PNGImageFormat().writeImageToStream(workspace.createComponentSnapshot(workspace.getLocalBounds()),output),
                    "Cannot write Parts divider screenshot");
            workspace.toggleLeftParts();require(!workspace.partsLeftDivider.isVisible(),"Hidden left Parts retained a divider");
            workspace.toggleLeftParts();workspace.toggleRightParts();
            require(!workspace.partsRightDivider.isVisible(),"Hidden right Parts retained a divider");
            workspace.toggleRightParts();checkDock();
            require(left->getWidth()==savedLeft && right->getWidth()==savedRight,"Toggling Parts lost adjusted widths");
            for(const auto size:{Point<int>{900,700},Point<int>{1024,700},Point<int>{1366,768}}) {
                workspace.setSize(size.x,size.y);checkDock();
                require(workspace.partsLeftWidth==savedLeft && workspace.partsRightWidth==savedRight,
                        "Narrow-window layout overwrote the preferred Parts widths");
            }
            workspace.setSize(1920,900);checkDock();
            require(left->getWidth()==savedLeft && right->getWidth()==savedRight,"Widening the window did not restore preferred widths");
            using Placement=Workspace::SetlistPlacement;
            workspace.setSetlistPlacement(Placement::left);checkDock();
            require(!workspace.partsLeftDivider.isVisible(),"Moving Setlist left retained hidden left Parts resize bar");
            drag(workspace.partsRightDivider,40);savedRight-=40;
            require(right->getWidth()==savedRight && list->getX()==32,"Right Parts resize failed with Setlist on the left");
            workspace.setSetlistPlacement(Placement::detached);
            auto *window=workspace.setlistWindow.get();require(window && window->getContentComponent(),"Detached Setlist missing");
            auto *panel=window->getContentComponent();window->setSize(1000,700);panel->resized();
            require(workspace.partsRightDivider.getParentComponent()==panel &&
                    uiFeatureTests::find(*window,"partsRightDivider")==&workspace.partsRightDivider,
                    "Detaching duplicated or abandoned the Parts resize bar");
            const int detachedWidth=right->getWidth();drag(workspace.partsRightDivider,-50);savedRight=detachedWidth+50;
            require(right->getWidth()==savedRight && list->getRight()==right->getX() && list->getWidth()>=306 &&
                    workspace.partsRightDivider.getX()+3==right->getX(),"Detached Parts did not resize against the Setlist boundary");
            workspace.toggleRightParts();require(!workspace.partsRightDivider.isVisible() && list->getWidth()==panel->getWidth(),
                    "Closing detached Parts retained its resize bar or an empty column");
            workspace.toggleRightParts();require(right->getWidth()==savedRight,"Detached Parts did not restore its resized width");
            workspace.setSetlistPlacement(Placement::right);workspace.toggleLeftParts();checkDock();
            require(left->getWidth()==savedLeft && right->getWidth()==savedRight &&
                    !session.dirty && JSON::toString(session.snapshot())==before,
                    "Docking lost Parts widths or presentation changes dirtied the project");
        }
        Session restored;restored.inspection=true;restored.audio.prepareOffline(48000);
        restored.restoreSnapshot(ProjectCodec::encode(project));restored.audio.setOffline(true);
        Auth auth;Lighting lighting(restored);Workspace workspace(restored,auth,lighting,false,preferences);
        workspace.setSize(1920,900);workspace.toggleLeftParts();workspace.toggleRightParts();
        require(workspace.partsLeft->getWidth()==savedLeft && workspace.partsSidebar->getWidth()==savedRight,
                "A new editor session did not reload independent Parts widths");
    }
};
template <typename Register>
void addPartsPanelTests(const File &directory, Register &&test) {
        test("Parts sidebars resize independently, persist widths and retain their divider when Setlist is detached",[&] {
            PartsDividerTests::run(directory);
        });
        test("Parts list sorts both banks chronologically and keeps renamed/moved pad actions aligned", [] {
            const auto require = [](bool okay, const char *message) {
                if (!okay) throw std::runtime_error(message);
            };
            Session session; session.inspection = true; session.audio.prepareOffline(48000);
            jaras::Project project; project.id = uuid(); project.name = "Parts ordering";
            jaras::Song song; song.id = uuid(); song.name = "Ordering"; song.duration = 110;
            const std::array<ID, 2> regions{uuid(), uuid()};
            song.parts = {{regions[0], "Current", 0, 50}, {regions[1], "Queued", 60, 110}};
            song.markers.emplace();
            std::array<std::vector<ID>, 2> expected;
            for (int bank = 0; bank < 2; ++bank) {
                expected[bank].push_back(regions[bank]);
                std::vector<jaras::TimelineMarker> chronological;
                for (int i = 1; i <= 20; ++i) {
                    jaras::TimelineMarker marker{uuid(), "M" + std::to_string(i), bank * 60. + i * 2., 0x51ef93};
                    marker.section = true;
                    expected[bank].push_back(marker.id); chronological.push_back(marker);
                }
                // Creation/storage order must never be the displayed or clicked order.
                song.markers->insert(song.markers->end(), chronological.rbegin(), chronological.rend());
            }
            project.songs = {song};
            session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
            session.command(jaras::CommandKind::play);
            session.command(jaras::CommandKind::queueRegion, regions[1]);
            String failure;
            PartsPanel panel(session, [&](String error) { failure = error; });
            panel.setSize(360, 900); panel.refresh();
            const auto pads = [&](int bank) {
                // Both tabs own their own viewport. Inspect the real list geometry
                // rather than reconstructing the production layout.
                auto *component = panel.getChildComponent(bank);
                require(component, "Parts bank component is missing");
                Viewport *viewport = nullptr;
                for (auto *child : component->getChildren())
                    if (auto *candidate = dynamic_cast<Viewport *>(child)) viewport = candidate;
                require(viewport && viewport->getViewedComponent(), "Parts bank viewport is missing");
                std::vector<Button *> result;
                for (auto *child : viewport->getViewedComponent()->getChildren())
                    if (auto *button = dynamic_cast<Button *>(child); button && button->getName() == "part")
                        result.push_back(button);
                std::sort(result.begin(), result.end(), [](const auto *left, const auto *right) {
                    return left->getY() == right->getY() ? left->getX() < right->getX() : left->getY() < right->getY();
                });
                return result;
            };
            const auto verify = [&] {
                for (int bank = 0; bank < 2; ++bank) {
                    auto *tab=dynamic_cast<Button *>(uiFeatureTests::find(panel,bank ? "partsQueuedTab" : "partsCurrentTab"));
                    require(tab && bool(tab->onClick),"Parts bank tab is missing");tab->onClick();
                    require(panel.getChildComponent(bank)->isVisible() && !panel.getChildComponent(1-bank)->isVisible(),
                            "Parts bank tab did not reveal its own vertical list");
                    panel.refresh();
                    const auto ids = list(get(get(panel.diagnostics(), bank ? "queued" : "current"), "markers"));
                    const auto buttons = pads(bank);
                    require(ids.size() == 21 && buttons.size() == 21, "A Parts bank lost a section or its start pad");
                    for (size_t index = 0; index < buttons.size(); ++index) {
                        require(ids[(int)index].toString() == text(expected[bank][index]),
                                "Parts diagnostic order follows creation order or stale positions");
                        require(buttons[index]->getY() == buttons[0]->getY() + int(index) * 38 &&
                                    buttons[index]->getX() == buttons[0]->getX(),
                                "Visible Parts rows do not follow chronological vertical order");
                        session.command(jaras::CommandKind::cancelSection);
                        const auto playbackPosition = session.transport().position;
                        require(bool(buttons[index]->onClick), "Parts pad has no action");
                        buttons[index]->onClick();
                        require(failure.isEmpty() && session.transport().queuedSectionMarkerId == expected[bank][index],
                                "A visually ordered pad triggered another section ID");
                        double destination = bank * 60.;
                        if (index > 0)
                            for (const auto &marker : *session.song()->markers)
                                if (marker.id == expected[bank][index]) destination = marker.position;
                        require(session.transport().editPosition == destination && session.transport().playing &&
                                    session.transport().position == playbackPosition,
                                "Parts action did not preview its own marker without seeking playback");
                    }
                }
                session.command(jaras::CommandKind::cancelSection); panel.refresh();
            };
            verify();
            panel.setSize(360,360);
            const auto tabsBounds=uiFeatureTests::find(panel,"partsCurrentTab")->getBounds();
            for(int bank=0;bank<2;++bank) {
                auto *tab=dynamic_cast<Button*>(uiFeatureTests::find(panel,bank?"partsQueuedTab":"partsCurrentTab"));tab->onClick();
                auto *scroll=dynamic_cast<ScrollBar*>(uiFeatureTests::find(panel,bank?"partsQueuedScroll":"partsCurrentScroll"));
                auto *viewport=scroll?scroll->findParentComponentOfClass<Viewport>():nullptr;
                require(scroll&&viewport&&scroll->isVisible()&&scroll->getWidth()==8,
                        "Overflow Parts list has no narrow scrollbar on its right edge");
                require(scroll->getRight()==viewport->getWidth(),"Parts scrollbar is not on the list's right edge");
                scroll->setCurrentRangeStart(120,sendNotificationSync);
                require(viewport->getViewPositionY()>100 && uiFeatureTests::find(panel,"partsCurrentTab")->getBounds()==tabsBounds,
                        "Parts scrollbar did not scroll its list independently of the fixed header");
            }
            const std::array<ID, 2> moved{expected[0].back(), expected[1].back()};
            for (int bank = 0; bank < 2; ++bank) {
                expected[bank].pop_back(); expected[bank].insert(expected[bank].begin() + 1, moved[bank]);
            }
            session.edit([&](auto &edited) {
                for (auto &marker : *edited.songs.front().markers)
                    for (int bank = 0; bank < 2; ++bank) if (marker.id == moved[bank]) {
                        marker.position = bank * 60. + 1; marker.name = "RENAMED";
                    }
            }, false);
            panel.refresh();
            verify();
            session.command(jaras::CommandKind::stopAll);
        });
    test("Parts docks and track mixer remain independently visible with separate widths", [&] {
        const auto require=[](bool okay,const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        for (bool tracksInitiallyVisible : {true,false}) {
            jaras::Project project;project.id=uuid();project.name="Parts docking";
            jaras::Song song;song.id=uuid();song.name="Two banks";song.duration=40;
            song.parts={{uuid(),"Current",0,20},{uuid(),"Queued",20,40}};
            jaras::Track track;track.id=uuid();track.name="Track";track.role.id="other";song.tracks={track};
            song.markers=std::vector<jaras::TimelineMarker>{{uuid(),"Verse",4,0x54ff93},{uuid(),"Chorus",24,0x54ff93}};
            for (auto &marker:*song.markers) marker.section=true;
            project.songs={song};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            session.command(jaras::CommandKind::queueRegion,song.parts[1].id);
            const auto file=directory.getNonexistentChildFile("parts-docking",".json");
            require(file.replaceWithText(R"({"jaras.trackColumnWidth":420})"),"Cannot create docking preferences");
            Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,file);
            workspace.setSize(1366,900);
            auto button=[&](Component &parent,const char *id) {
                auto *result=dynamic_cast<Button *>(uiFeatureTests::find(parent,id));
                require(result && bool(result->onClick),"Parts docking control missing");return result;
            };
            auto click=[&](const char *id) {button(workspace,id)->onClick();};
            auto *left=dynamic_cast<PartsPanel *>(uiFeatureTests::find(workspace,"partsLeft"));
            auto *right=dynamic_cast<PartsPanel *>(uiFeatureTests::find(workspace,"partsRight"));
            auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");
            auto *row=uiFeatureTests::find(workspace,"trackRow:"+text(track.id));
            auto *trackViewport=row ? row->findParentComponentOfClass<Viewport>() : nullptr;
            require(left && right && left!=right && canvas && trackViewport,"Parts docks or track viewport missing");
            int panelCount=0;
            std::function<void(Component &)> countPanels=[&](Component &component) {
                if (dynamic_cast<PartsPanel *>(&component)) ++panelCount;
                for (auto *child:component.getChildren()) countPanels(*child);
            };
            countPanels(workspace);
            require(panelCount==2 && !uiFeatureTests::find(workspace,"railSections"),
                    "Removed footer Parts panel or old rail control remains in the editor");
            if (!tracksInitiallyVisible) click("mixer");
            bool tracksVisible=tracksInitiallyVisible;
            auto check=[&](bool leftVisible,bool rightVisible) {
                const auto state=workspace.diagnostics();
                require((bool)get(state,"partsLeftVisible")==leftVisible &&
                        (bool)get(state,"partsRightVisible")==rightVisible &&
                        left->isVisible()==leftVisible && right->isVisible()==rightVisible,
                        "A Parts dock toggle changed the other dock or disagreed with rendered visibility");
                require(trackViewport->isVisible()==tracksVisible,
                        "Parts visibility changed the independently controlled track mixer");
                const auto grid=workspace.getLocalArea(canvas,canvas->getLocalBounds());
                require(grid.getWidth()>0 && grid.getHeight()>0 && workspace.getLocalBounds().contains(grid),
                        "Parts docking collapsed the timeline or placed it outside the window");
                for (auto *panel:{left,right}) if (panel->isVisible()) {
                    const auto bounds=panel->getBounds();
                    require(bounds.getWidth()>0 && workspace.getLocalBounds().contains(bounds) &&
                            bounds.getY()==grid.getY() && bounds.getHeight()==grid.getHeight() && !bounds.intersects(grid),
                            "Parts dock overlaps the timeline, clips, or uses a footer-sized layout");
                    require(bounds.getX()<grid.getX() || bounds.getX()>=grid.getRight(),
                            "Parts dock is not beside the timeline");
                    for (auto *child:panel->getChildren()) if (child->isVisible())
                        require(panel->getLocalBounds().contains(child->getBounds()),"Parts controls extend outside their dock");
                }
                if (leftVisible && rightVisible)
                    require(left->getRight()<=grid.getX() && right->getX()>=grid.getRight(),
                            "Two Parts docks overlap or swap sides");
                if (leftVisible && tracksVisible) {
                    const auto tracks=workspace.getLocalArea(trackViewport,trackViewport->getLocalBounds());
                    require(left->getRight()==tracks.getX() && tracks.getRight()==grid.getX() &&
                            !left->getBounds().intersects(tracks),
                            "Left Parts must remain before the independently visible track mixer");
                }
                require((int)Appearance(file).value("jaras.trackColumnWidth",0)==420,
                        "Parts layout overwrote the user's track mixer width");
            };
            check(false,false);
            const int timelineHeight=canvas->getHeight();
            click("railParts");check(true,false);
            const int partsWidth=left->getWidth();
            click("mixer");tracksVisible=!tracksVisible;check(true,false);
            require(left->getWidth()==partsWidth,"Track mixer toggle resized the independent Parts sidebar");
            click("mixer");tracksVisible=!tracksVisible;check(true,false);
            click("setlistParts");check(true,true);
            button(*right,"partsQueuedTab")->onClick();
            require(!(bool)get(left->diagnostics(),"secondaryTab") && (bool)get(right->diagnostics(),"secondaryTab") &&
                    left->getChildComponent(0)->isVisible() && right->getChildComponent(1)->isVisible(),
                    "Right queued tab changed the left current tab");
            button(*left,"partsQueuedTab")->onClick();button(*right,"partsCurrentTab")->onClick();
            require((bool)get(left->diagnostics(),"secondaryTab") && !(bool)get(right->diagnostics(),"secondaryTab") &&
                    left->getChildComponent(1)->isVisible() && right->getChildComponent(0)->isVisible(),
                    "Parts tabs share selection state between docks");
            click("railParts");check(false,true);
            click("railParts");check(true,true);
            require((bool)get(left->diagnostics(),"secondaryTab"),"Reopening left Parts lost its selected bank");
            click("setlistParts");check(true,false);
            click("setlistParts");check(true,true);
            click("railMixer");click("railKeyboard");check(true,true);
            auto docked=workspace.diagnostics();
            require((bool)get(docked,"mixerVisible") && (bool)get(docked,"keyboardVisible") &&
                    (int)get(docked,"mixerDockHeight")>=232 && canvas->getHeight()<timelineHeight,
                    "Parts docks prevented the lower mixer or keyboard from opening");
            for (const auto size:{Point<int>{1024,700},Point<int>{1366,768},Point<int>{1920,1080}}) {
                workspace.setSize(size.x,size.y);check(true,true);
            }
            workspace.setSize(1366,900);
            click("railMixer");click("railKeyboard");check(true,true);
            require(!(bool)get(workspace.diagnostics(),"mixerVisible") &&
                    !(bool)get(workspace.diagnostics(),"keyboardVisible") && canvas->getHeight()==timelineHeight,
                    "Closing lower panels retained a removed Parts footer or lost timeline height");
            click("railParts");check(false,true);
            click("setlistParts");check(false,false);
            if (!tracksInitiallyVisible) click("mixer");
            require(trackViewport->isVisible() && (int)get(workspace.diagnostics(),"trackMixerWidth")==420 &&
                    (int)Appearance(file).value("jaras.trackColumnWidth",0)==420,
                    "Parts docking lost or overwrote the user's track mixer width");
        }
    });
    test("PDC queue presentation follows rendered audio and preserves ordered transitions", [] {
        const auto require = [](bool okay, const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        TransportPresentationQueues history;
        jaras::TransportState before; before.songId = uuid(); before.playing = true;
        before.queuedSectionMarkerId = uuid(); before.sectionQueueStartedAt = 3;
        before.queuedRegionId = uuid(); before.queueStartedAt = 2;
        auto consumed = before;
        consumed.queuedSectionMarkerId.reset(); consumed.queuedRegionId.reset();
        consumed.sectionJumpSerial++;
        history.advance(.25, 1.5, before, consumed);
        auto shown = consumed; history.apply(shown);
        require(shown.queuedSectionMarkerId == before.queuedSectionMarkerId &&
                shown.queuedRegionId == before.queuedRegionId && shown.sectionQueueStartedAt == 3,
                "Queue disappeared when the core consumed it, before the audible jump");
        history.advance(1.49, 1.5, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(shown.queuedSectionMarkerId == before.queuedSectionMarkerId,
                "Queue countdown ended before the complete latency had been rendered");
        // Repainting or waiting on the UI thread does not consume audio time.
        for (int n = 0; n < 100; ++n) { shown = consumed; history.apply(shown); }
        require(shown.queuedRegionId == before.queuedRegionId, "UI refresh advanced the audio clock");
        history.advance(.01, 1.5, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(!shown.queuedSectionMarkerId && !shown.queuedRegionId,
                "Consumed queue remained visible after its audible transition");

        history.reset();
        history.advance(.1, 1.5, before, consumed);
        auto automatic = consumed; automatic.queuedRegionId = uuid(); automatic.queueStartedAt = 10;
        history.advance(.5, 1.5, consumed, automatic);
        shown = automatic; history.apply(shown);
        require(shown.queuedRegionId == before.queuedRegionId, "Next automatic queue replaced the still audible outgoing queue");
        history.advance(1, 1.5, automatic, automatic);
        shown = automatic; history.apply(shown);
        require(!shown.queuedRegionId, "Queue history skipped its empty interval");
        history.advance(.5, 1.5, automatic, automatic);
        shown = automatic; history.apply(shown);
        require(shown.queuedRegionId == automatic.queuedRegionId && shown.queueStartedAt == 10,
                "Automatic queue did not appear with its own start position");

        history.reset(); history.advance(.1, 1.5, before, consumed);
        auto sectionAndLoop = before; sectionAndLoop.loop.enabled = true;
        auto sectionCancelled = sectionAndLoop;
        sectionCancelled.queuedSectionMarkerId.reset();
        history.command(jaras::CommandKind::escape, sectionAndLoop, sectionCancelled);
        shown = sectionCancelled; history.apply(shown);
        require(!shown.queuedSectionMarkerId && shown.loop.enabled &&
                shown.queuedRegionId == before.queuedRegionId,
                "Escape did not immediately hide the cancelled section while preserving loop and song queue");

        history.reset(); history.advance(.1, 1.5, before, consumed);
        auto looping = consumed; looping.loop.enabled = true;
        history.command(jaras::CommandKind::escape, looping, consumed);
        shown = consumed; history.apply(shown);
        require(shown.queuedSectionMarkerId == before.queuedSectionMarkerId &&
                shown.queuedRegionId == before.queuedRegionId,
                "Cancelling a loop also hid a pending audible jump");
        history.command(jaras::CommandKind::cancelSection, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(!shown.queuedSectionMarkerId && shown.queuedRegionId == before.queuedRegionId,
                "Manual section cancellation was delayed or erased an unrelated region queue");
        auto manual = consumed; manual.queuedRegionId = uuid();
        history.command(jaras::CommandKind::queueRegion, consumed, manual);
        shown = manual; history.apply(shown);
        require(shown.queuedRegionId == manual.queuedRegionId, "New user queue resurrected an old pending target");
        history.reset(); history.advance(.1, 1.5, before, consumed);
        history.command(jaras::CommandKind::seek, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(!shown.queuedRegionId && !shown.queuedSectionMarkerId, "Seek retained stale queue history");
        history.advance(.1, 1.5, before, consumed);
        auto stopped = consumed; stopped.playing = false;
        auto edit = stopped; edit.position = 42;
        history.command(jaras::CommandKind::editSeek, stopped, edit);
        shown = edit; history.apply(shown);
        require(!shown.queuedRegionId, "Stopped edit seek retained a queue from the preceding audio tail");
        history.advance(.1, 1.5, before, consumed);
        history.advance(.1, 0, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(!shown.queuedRegionId, "Removing PDC retained delayed queue state");
    });
    test("Parts presentation uses audible regions and does not count down to an already rendered boundary", [] {
        const auto require = [](bool okay, const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        jaras::Song song;
        const auto group = uuid(), first = uuid(), second = uuid();
        song.parts = {{group, "Group", 0, 20}, {first, "First", 0, 10}, {second, "Second", 10, 20}};
        song.parts[1].parentRegionID = group; song.parts[2].parentRegionID = group;
        song.markers = std::vector<jaras::TimelineMarker>{{uuid(), "Verse", 5, 0}, {uuid(), "Chorus", 9, 0}};
        for (auto &marker : *song.markers) marker.section = true;
        song.markers->push_back({uuid(), "Tempo", 4.2, 0});
        song.markers->back().section = true; song.markers->back().tempoBPM = 125;
        jaras::TransportState audible; audible.playing = true; audible.position = 3.8;
        audible.regionId = second; // Scheduling may already be in another region.
        audible.queuedSectionMarkerId = song.markers->at(1).id; audible.sectionQueueStartedAt = 5.3;
        const auto *part = partsPresentation::region(song, audible);
        require(part && part->id == first, "Parts selected the future core region instead of the audible child");
        require(partsPresentation::trigger(song, *part, audible) == 9,
                "PDC countdown targeted a boundary that had already been rendered when the jump was armed");
        audible.sectionQueueStartedAt = 3.8;
        require(partsPresentation::trigger(song, *part, audible) == 5, "Tempo marker changed the audible section boundary");
        audible.position = 11; audible.ignoreNextRegionId = first; audible.ignoreNextEnd = 13;
        part = partsPresentation::region(song, audible);
        require(part && part->id == first && partsPresentation::end(*part, audible) == 13,
                "Ignore Next lost its audible owner or tail end");
        audible.ignoreNextRegionId = second; audible.ignoreNextEnd = 18; audible.position = 8;
        part = partsPresentation::region(song, audible);
        require(part && part->id == first && partsPresentation::end(*part, audible) == 10,
                "Future Ignore Next state changed the preceding audible region end");
        audible.paused = true; audible.playing = false;
        require(!partsPresentation::trigger(song, *part, audible), "Paused presentation retained a running countdown");
    });
    test("Parts playback and countdown follow the actual queued jump boundary", [] {
        const auto require = [](bool okay, const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        Session session; session.inspection = true;
        jaras::Project project; project.id = uuid(); project.name = "Parts";
        jaras::Song song; song.id = uuid(); song.name = "Song"; song.duration = 12; song.bpm = 120;
        const auto region = uuid(), verse = uuid(), chorus = uuid(), bridge = uuid();
        song.parts = {{region, "Song", 0, 12}};
        song.markers = std::vector<jaras::TimelineMarker>{
            {verse, "Verse", 2, 0}, {chorus, "Chorus", 5, 0}, {bridge, "Bridge", 9, 0}};
        for (auto &marker : *song.markers) marker.section = true;
        // An ordinary cue must not shorten a section's progress or countdown.
        song.markers->push_back({uuid(), "Lighting cue", 4.5, 0});
        project.songs = {song}; session.core.loadProject(project);
        PartsPanel panel(session, [](String error) { throw std::runtime_error(utf8(error)); });
        panel.setSize(360, 640);
        auto pad = [&](int index) {
            panel.refresh();
            return list(get(get(panel.diagnostics(), "current"), "pads"))[index];
        };
        auto fraction = [&](int index, double expected) {
            require(std::abs((double)get(pad(index), "progress") - expected) < 1e-6,
                    "Parts bar fraction disagrees with the transport boundary");
        };
        session.core.execute({jaras::CommandKind::selectRegion, region});
        session.core.execute({jaras::CommandKind::play}); session.core.advance(3);
        fraction(1, 1. / 3.);
        session.core.execute({jaras::CommandKind::queueSection, bridge});
        require((bool)get(pad(3), "queued"), "Destination was not armed"); fraction(3, 1);
        session.core.advance(1); fraction(3, .5); fraction(1, 2. / 3.);
        session.core.advance(1.25);
        require(std::abs(session.transport().position - 9.25) < 1e-6,
                "Queued jump lost the remaining portion of the playback tick");
        require(!(bool)get(pad(3), "queued") && (bool)get(pad(3), "active"),
                "Countdown did not turn into playback progress at the destination");
        fraction(3, .25 / 3.);
        session.core.execute({jaras::CommandKind::queueSection, verse}); fraction(1, 1);
        session.core.advance(1.375); fraction(1, .5);
        session.core.execute({jaras::CommandKind::cancelSection}); fraction(1, 0);
        session.core.execute({jaras::CommandKind::pause}); fraction(3, 0);
    });
}
} // namespace catlive
