#pragma once
#include "FloatingControlTests.h"
#include "RemotePresentation.h"

namespace catlive::remoteSetlistSelectionTests {
inline void require(bool value,const char *message) { if (!value) throw std::runtime_error(message); }
inline jaras::Project fixture() {
    auto project=floatingControlTests::fixture();auto &song=project.songs[0];
    song.duration=300;song.parts.clear();
    for(int i=0;i<26;++i) song.parts.push_back({uuid(),"Song "+std::to_string(i+1),i*10.,(i+1)*10.});
    const auto parent=uuid();
    song.parts.push_back({parent,"Unified",260,280});
    song.parts.push_back({uuid(),"Child A",260,270});song.parts.back().parentRegionID=parent;
    song.parts.push_back({uuid(),"Child B",270,280});song.parts.back().parentRegionID=parent;
    song.parts.push_back({uuid(),"Last",280,300});
    jaras::RegionSetlist state;
    state.playlists={{uuid(),"Only last",song.id,{song.parts.back().id}},
                     {uuid(),"Unified playlist",song.id,{parent}}};
    project.regionSetlist=state;return project;
}
inline var request(const Session &session,const ID &target) {
    auto value=object();put(value,"id",remote::wireID(uuid()));
    put(value,"project",remote::wireID(session.project().id));
    put(value,"song",remote::wireID(session.song()->id));
    put(value,"action","selectRegion");put(value,"target",remote::wireID(target));
    put(value,"value",0);return value;
}
inline std::vector<String> strings(const var &value) {
    std::vector<String> result;for(const auto &item:list(value))result.push_back(item.toString());return result;
}
inline int rowFor(const Workspace &workspace,const ID &id) {
    const auto rows=strings(get(get(workspace.diagnostics(),"setlist"),"rowIDs"));
    const auto found=std::find(rows.begin(),rows.end(),text(id));
    return found==rows.end()?-1:(int)std::distance(rows.begin(),found);
}
inline void selectedAndRevealed(Workspace &workspace,SetlistRows &rows,const ID &id,const ID &visible={}) {
    const auto state=get(workspace.diagnostics(),"setlist");
    const auto visibleID=visible.empty()?id:visible;
    require(strings(get(state,"selectedEntries"))==std::vector<String>{text(id)} &&
            strings(get(state,"visibleSelectedEntries"))==std::vector<String>{text(visibleID)},
            "Remote did not select exactly the requested Setlist row");
    const auto row=rowFor(workspace,visibleID);require(row>=0,"Selected Remote song is absent from the list");
    const auto top=rows.rowTop(row),scroll=rows.getViewport()->getViewPositionY();
    require(top>=scroll && top+rows.getRowHeight(row)<=scroll+rows.getViewport()->getViewHeight(),
            "Remote selection did not scroll its row fully into view");
}
inline void click(SetlistRows &rows,int row) {
    rows.selectRow(row);
    const Point<float> at{20.f,(float)(rows.rowTop(row)+15)};
    rows.getModel()->listBoxItemClicked(row,MouseEvent(Desktop::getInstance().getMainMouseSource(),at,
        ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,&rows,&rows,Time::getCurrentTime(),at,
        Time::getCurrentTime(),1,false));
}
template <typename Test> void registerTests(const File &directory,Test &test) {
    test("Setlist drawer preserves browsing position and metadata reorder avoids workspace rebuild",[&] {
        const auto project=fixture(); const auto &parts=project.songs[0].parts;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("setlist-browse",".json"));workspace.setSize(1366,768);
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));require(rows,"Setlist rows missing");
        click(*rows,0); rows->getViewport()->setViewPosition(0,rows->rowTop(17));
        const int before=rows->getViewport()->getViewPositionY();
        auto *drawer=dynamic_cast<Button *>(uiFeatureTests::find(workspace,"setlist-drawer-"+text(parts[26].id)));
        require(drawer && drawer->onClick,"Drawer missing");drawer->onClick();
        require(rows->getViewport()->getViewPositionY()==before,"Opening another drawer revealed the selected row");
        drawer->onClick(); require(rows->getViewport()->getViewPositionY()==before,"Closing drawer revealed selected row");
        int rebuilds=0,updates=0;auto changed=session.changed, setlistChanged=session.setlistChanged;
        session.changed=[&]{++rebuilds;if(changed)changed();};session.setlistChanged=[&]{++updates;if(setlistChanged)setlistChanged();};
        auto state=*session.project().regionSetlist;auto original=state.playlists[0].regionIds;
        state.playlists[0].regionIds.insert(state.playlists[0].regionIds.begin(),parts[0].id);
        session.configureSetlist(state);require(rebuilds==0 && updates==1,"Playlist edit rebuilt the workspace");
        session.undo();require(session.project().regionSetlist->playlists[0].regionIds==original,"Playlist undo lost original ordering");
        session.redo();require(session.project().regionSetlist->playlists[0].regionIds==state.playlists[0].regionIds,"Playlist redo lost new ordering");
        require(rebuilds==0 && updates==3,"Playlist undo/redo rebuilt the workspace");
        for(double scale:{.05,.3,1.,3.,10.,20.}) {
            const auto ticks=timelineGrid::ticks(*session.song(),0,100,scale);
            for(const auto &tick:ticks) if(!tick.primary) require(std::abs(timelineGrid::snap(tick.time+.001,*session.song(),scale,false,false)-tick.time)<.00001,"Secondary grid line rejected snapping");
        }
    });
    test("Remote section cues preserve Parts timing and armed destination for observers", [&] {
        auto project=fixture();project.regionSetlist.reset();auto &song=project.songs[0];song.parts={{uuid(),"Playing",0,20}};
        const auto region=song.parts[0].id,next=uuid(),target=uuid();
        song.markers=std::vector<jaras::TimelineMarker>{{next,"Chorus",10,0},{target,"Bridge",2,0}};
        for(auto &marker:*song.markers)marker.section=true;
        Session session;session.inspection=true;session.core.loadProject(project);
        Appearance preferences(directory.getNonexistentChildFile("remote-section-cues",".json"));
        StageState stage(preferences);remote::Presentation presentation(session,stage);
        session.core.execute({jaras::CommandKind::selectRegion,region});
        session.core.execute({jaras::CommandKind::play});session.core.advance(5);
        auto packet=presentation.snapshot(0),section=get(packet,"sectionPlayback");
        require(str(section,"currentRegion")==remote::wireID(region)&&num(section,"position")==5,
                "Observer needs the audible section region and position without subscribing to Parts");
        require(list(get(packet,"markers")).size()==2,"Observer needs section names");
        session.core.execute({jaras::CommandKind::queueSection,target});
        section=get(presentation.snapshot(2),"sectionPlayback");
        require(str(section,"queuedMarker")==remote::wireID(target)&&num(section,"nextTrigger")==10,
                "Observer TP must announce the armed destination at the actual trigger, not its old timestamp");
        session.core.execute({jaras::CommandKind::cancelSection});
        require(get(get(presentation.snapshot(0),"sectionPlayback"),"queuedMarker").isVoid(),
                "Cancelling must clear observer's armed warning");
    });
    test("Unified Remote tempo returns to white after repeated BPM round trips", [&] {
        auto project=fixture();auto &song=project.songs[0];song.timeSettings=jaras::ProjectTimeSettings{};
        song.timeSettings->timebase=jaras::ProjectTimebase::relative;
        song.parts={{uuid(),"First",0,12},{uuid(),"Second",10,30},{uuid(),"Unified",0,30}};
        const auto groupID=song.parts[2].id;
        song.parts[0].parentRegionID=groupID;song.parts[1].parentRegionID=groupID;
        project.regionSetlist=jaras::RegionSetlist{};
        auto a=tempoEditing::boundary(song,0),b=tempoEditing::boundary(song,10.5);
        a.tempoBPM=120;a.tempoReferenceBPM=120;a.regionOwnerID=song.parts[0].id;
        b.tempoBPM=160;b.tempoReferenceBPM=160;b.regionOwnerID=song.parts[1].id;
        song.markers=std::vector<jaras::TimelineMarker>{a,b};
        for(int index=0;index<2;++index) {
            jaras::AudioClip clip;clip.id=uuid();clip.startTime=song.parts[index].startTime;
            clip.duration=song.parts[index].endTime-clip.startTime;clip.regionOwnerID=song.parts[index].id;
            clip.audioFile=jaras::AudioFile{"source.wav",{}};song.tracks[0].clips.push_back(clip);
        }
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Appearance preferences(directory.getNonexistentChildFile("remote-unified-tempo",".json"));
        StageState stage(preferences);remote::Presentation presentation(session,stage);
        require(presentation.apply(remote::Command::decode(request(session,groupID))),"Unified selection failed");
        for(int index=0;index<10;++index) {
            session.setTempo(index%2?120:121);
            require(flag(presentation.snapshot(0),"tempoNeedsRender")==!(index%2),
                ("Unified tempo indicator mismatch at step "+std::to_string(index)+", BPM "+std::to_string(session.tempoBPM())).c_str());
            require(session.song()->markers->size()==3,"Unified tempo restoration generated extra boundary markers");
        }
    });
    test("Remote tempo indicator follows effective rates, region selection and completed renders", [&] {
        auto project=fixture();auto &song=project.songs[0];song.bpm=120;
        jaras::AudioClip clip;clip.id=uuid();clip.duration=4;clip.audioFile=jaras::AudioFile{"source.wav",{}};
        clip.playbackRate=1.25;clip.regionOwnerID=song.parts[0].id;
        song.tracks[0].clips={clip,clip};song.tracks[0].clips[1].id=uuid();
        jaras::TimelineMarker marker;marker.id=uuid();marker.position=10;marker.name="Tempo";marker.tempoBPM=140;
        song.markers=std::vector<jaras::TimelineMarker>{marker};
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Appearance preferences(directory.getNonexistentChildFile("remote-tempo",".json"));
        StageState stage(preferences);remote::Presentation presentation(session,stage);
        auto select=[&](int index){require(presentation.apply(remote::Command::decode(request(session,song.parts[index].id))),"Tempo fixture region selection failed");};
        select(0);require(flag(presentation.snapshot(0),"tempoNeedsRender"),"Changed source rate must highlight Remote BPM");
        select(1);const auto other=presentation.snapshot(0);
        require(!flag(other,"tempoNeedsRender") && num(other,"bpm")==140,
                "Remote must show the selected region's tempo and must not inherit another region's altered rate");
        select(0);song.tracks[0].clips[0].playbackRate=1;
        session.restoreSnapshot(ProjectCodec::encode(project));
        require(flag(presentation.snapshot(0),"tempoNeedsRender"),"Partial render must retain yellow BPM");
        song.tracks[0].clips[1].playbackRate=1;song.tracks[0].clips[1].tempoBasePlaybackRate=.8;
        session.restoreSnapshot(ProjectCodec::encode(project));
        require(!flag(presentation.snapshot(0),"tempoNeedsRender"),"Unity-rate items must clear yellow BPM despite historical reference rates");
        song.tracks[0].clips[1].playbackRate=1.1;
        session.restoreSnapshot(ProjectCodec::encode(project));
        require(flag(presentation.snapshot(0),"tempoNeedsRender"),"A later rate change must invalidate the cached indicator");
    });

    test("Setlist drag preview is one compact title strip at display resolution",[&] {
        struct Model final : ListBoxModel {
            int paints=0;
            int getNumRows() override {return 9;}
            void paintListBoxItem(int,Graphics &g,int,int,bool) override {
                ++paints;g.fillAll(Colours::red);
            }
            var getDragSourceDescription(const SparseSet<int> &selection) override {
                return selection.contains(1)?var{}:var("song");
            }
        } model;
        SetlistRows rows;rows.setModel(&model);rows.setSize(500,100);rows.updateContent();
        int namedRow=-1;
        rows.dragNameForRow=[&](int row){namedRow=row;return "Song "+String(row);};
        rows.selectRow(0,false,true);
        auto single=rows.createDragPreview(2).getImage();
        const auto background=single.getPixelAt(20,4);
        require(single.getHeight()==68 && single.getWidth()==600 && namedRow==0 &&
                    background.getRed()<32 && background.getAlpha()>200 && model.paints==0,
                "Preview must be a dark 300x34 strip, rendered at display resolution without copying the row");
        rows.selectRow(1,false,false);rows.selectRow(2,false,false);
        auto multiple=rows.createDragPreview(2,2).getImage();
        require(multiple.getHeight()==68 && multiple.getWidth()==600 && namedRow==2,
                "A multi-song drag must show only the pressed song's title, not stack selected rows");
        rows.getViewport()->setViewPosition(0,200);
        auto scrolled=rows.createDragPreview(2,2).getImage();
        require(scrolled.getHeight()==68 && namedRow==2,
                "Scrolling must not clip or change the drag title strip");
        rows.selectRangeOfRows(0,8);
        require(rows.createDragPreview(2,5).getImage().getHeight()==68 && namedRow==5 &&
                    rows.getSelectedRows().size()==9,
                "Large selections must keep one title strip while preserving all selected entries");
        rows.selectRow(1,false,true);
        require(rows.createDragPreview().getImage().isNull(),
                "Protected unified child rows must not acquire a drag preview");
        rows.setModel(nullptr);
    });
    test("Setlist group drag retains selected songs until release and a plain click collapses on mouse-up",[&] {
        struct Model final : ListBoxModel {
            SetlistRows &rows;int clicks=0;
            explicit Model(SetlistRows &value):rows(value) {}
            int getNumRows() override {return 4;}
            void paintListBoxItem(int,Graphics &,int,int,bool) override {}
            void listBoxItemClicked(int row,const MouseEvent &) override {++clicks;rows.selectRow(row,false,true);}
        };
        SetlistRows rows;Model model(rows);rows.setModel(&model);rows.setSize(300,200);rows.updateContent();
        rows.selectRangeOfRows(0,1);
        auto *row=rows.getViewport()->getViewedComponent()->getChildComponent(0);
        require(row,"First Setlist row missing");
        const Point<float> start{20,15};
        const auto event=[&](Point<float> at,bool moved) {
            return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,
                ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,row,row,Time::getCurrentTime(),start,
                Time::getCurrentTime(),1,moved);
        };
        row->mouseDown(event(start,false));
        require(rows.getSelectedRows().size()==2 && model.clicks==0,"Mouse-down collapsed selection before drag");
        row->mouseDrag(event({20,90},true));row->mouseUp(event({20,90},true));
        require(rows.getSelectedRows().size()==2 && model.clicks==0,"Group drag activated a single song");
        row->mouseDown(event(start,false));row->mouseUp(event(start,false));
        require(rows.getSelectedRows().size()==1 && rows.getSelectedRows().contains(0) && model.clicks==1,
                ("Plain click must select its song only on release: selected="+std::to_string(rows.getSelectedRows().size())+" clicks="+std::to_string(model.clicks)+" bounds="+row->getBounds().toString().toStdString()).c_str());
        rows.setModel(nullptr);
    });
    test("Actual Setlist preserves multiple songs through mouse-down, refresh, drag payload and release",[&] {
        auto project=fixture();const auto &parts=project.songs[0].parts;
        auto &state=*project.regionSetlist;
        state.playlists[0].regionIds={parts[0].id,parts[1].id,parts[2].id,parts[3].id};
        state.selectedId=state.playlists[0].id;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        const auto settings=directory.getNonexistentChildFile("setlist-group-press",".json");
        Workspace workspace(session,auth,lighting,false,settings);workspace.setSize(1366,768);
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));
        require(rows,"Setlist rows missing");
        rows->selectRow(0,false,true);rows->selectRow(2,false,false);
        auto *row=rows->getViewport()->getViewedComponent()->getChildComponent(0);
        const Point<float> start{20,15};
        const auto event=[&](bool moved) {
            return MouseEvent(Desktop::getInstance().getMainMouseSource(),start,
                ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,row,row,Time::getCurrentTime(),start,
                Time::getCurrentTime(),1,moved);
        };
        const auto revision=session.setlistFocusRevision;
        row->mouseDown(event(false));
        require(rows->getSelectedRows().size()==2 && session.setlistFocusRevision==revision,
                "Actual Setlist activated one song on mouse-down before group drag");
        // Normal project notifications must not discard the pending group drag.
        session.configureSetlist(*session.project().regionSetlist);
        const auto payload=rows->getModel()->getDragSourceDescription(rows->getSelectedRows());
        require(strings(get(payload,"ids"))==std::vector<String>{text(parts[0].id),text(parts[2].id)},
                "Refresh lost a selected song or changed the drag payload order");
        row->mouseUp(event(true));
        require(rows->getSelectedRows().size()==2 && session.setlistFocusRevision==revision,
                "Drag release collapsed selection or activated a song");
        row->mouseDown(event(false));
        require(rows->getSelectedRows().size()==2,"Second press collapsed group selection");
        row->mouseUp(event(false));
        require(rows->getSelectedRows().size()==1 && rows->getSelectedRows().contains(0) && session.focusedRegion==parts[0].id,
                "Plain release failed to select and focus only the clicked song");
    });
    test("Remote region commands select and reveal the same Setlist row as local clicks, including repeated selections and unified children",[&] {
        const auto project=fixture();const auto &parts=project.songs[0].parts;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        const auto settings=directory.getNonexistentChildFile("remote-setlist-selection",".json");
        Workspace workspace(session,auth,lighting,false,settings);workspace.setSize(1366,768);
        Appearance preferences(settings);StageState stage(preferences);remote::Presentation presentation(session,stage);
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));
        require(rows,"Setlist rows missing");
        // This is the same decode/apply path called by Host::perform after authentication.
        auto select=[&](const ID &id){require(presentation.apply(remote::Command::decode(request(session,id))),"Remote rejected a current region command");};
        const auto focusBefore=session.setlistFocusRevision;
        select(parts.back().id);
        require(session.focusedRegion==parts.back().id && session.setlistFocusRevision>focusBefore &&
                session.transport().editPosition==280 && !session.transport().playing,
                "Stopped Remote selection did not focus the requested song and its edit cursor");
        selectedAndRevealed(workspace,*rows,parts.back().id);
        rows->selectRow(0);rows->getViewport()->setViewPosition(0,0);
        const auto sameBefore=session.setlistFocusRevision;select(parts.back().id);
        require(session.setlistFocusRevision>sameBefore,"Selecting the same song remotely did not request another reveal");
        selectedAndRevealed(workspace,*rows,parts.back().id);
        click(*rows,rowFor(workspace,parts[12].id));
        const auto localPosition=session.transport().position,localEdit=session.transport().editPosition;
        selectedAndRevealed(workspace,*rows,parts[12].id);
        select(parts[0].id);select(parts[12].id);
        require(session.transport().position==localPosition && session.transport().editPosition==localEdit,
                "Remote stopped selection differs from a local Setlist click");
        selectedAndRevealed(workspace,*rows,parts[12].id);
        auto playlist=*session.project().regionSetlist;playlist.selectedId=playlist.playlists[0].id;
        session.configureSetlist(playlist);select(parts[27].id);
        require(!session.project().regionSetlist->selectedId && session.transport().editPosition==260,
                "Remote child outside the playlist did not reveal All Regions at the child's start");
        selectedAndRevealed(workspace,*rows,parts[27].id,parts[26].id);
        auto *drawer=dynamic_cast<Button *>(uiFeatureTests::find(workspace,"setlist-drawer-"+text(parts[26].id)));
        require(drawer && drawer->onClick,"Unified region drawer missing");drawer->onClick();select(parts[27].id);
        selectedAndRevealed(workspace,*rows,parts[27].id);
        playlist=*session.project().regionSetlist;playlist.selectedId=playlist.playlists[1].id;
        session.configureSetlist(playlist);select(parts[28].id);
        require(session.project().regionSetlist->selectedId==playlist.selectedId,
                "Remote child already represented by its parent discarded the selected playlist");
        selectedAndRevealed(workspace,*rows,parts[28].id);
        auto *toggle=dynamic_cast<TextButton *>(uiFeatureTests::find(workspace,"setlistSearchToggle"));
        auto *search=dynamic_cast<TextEditor *>(uiFeatureTests::find(workspace,"setlistSearchField"));
        require(toggle && search,"Setlist search controls missing");toggle->onClick();
        search->setText("no matching song",false);search->onTextChange();select(parts[27].id);
        require(!flag(get(workspace.diagnostics(),"setlist"),"searching"),"A search filter hid the remotely selected song");
        selectedAndRevealed(workspace,*rows,parts[27].id);
        const auto validFocus=session.setlistFocusRevision;const auto validPosition=session.transport().editPosition;
        require(!presentation.apply(remote::Command::decode(request(session,uuid()))),"Unknown Remote region was accepted");
        auto stale=request(session,parts[0].id);put(stale,"project",remote::wireID(uuid()));
        require(!presentation.apply(remote::Command::decode(stale)) && session.setlistFocusRevision==validFocus &&
                session.transport().editPosition==validPosition,"Invalid/stale Remote request changed the selection or cursor");
        selectedAndRevealed(workspace,*rows,parts[27].id);
    });
    test("Remote region selection queues like a local click without seeking playback and still reveals the selected row",[&] {
        const auto project=fixture();const auto &parts=project.songs[0].parts;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        const auto settings=directory.getNonexistentChildFile("remote-setlist-playback",".json");
        Workspace workspace(session,auth,lighting,false,settings);workspace.setSize(1366,768);
        Appearance preferences(settings);StageState stage(preferences);remote::Presentation presentation(session,stage);
        auto *rows=dynamic_cast<SetlistRows *>(uiFeatureTests::find(workspace,"setlistRows"));require(rows,"Setlist rows missing");
        auto select=[&](const ID &id){require(presentation.apply(remote::Command::decode(request(session,id))),"Remote rejected selection during playback");};
        session.command(jaras::CommandKind::selectRegion,parts[0].id);session.command(jaras::CommandKind::play);
        uiFeatureTests::render(session,48000);session.command(jaras::CommandKind::editSeek,{},0);
        const auto before=session.audio.state();const auto editBefore=session.transport().editPosition;
        auto playbackUnchanged=[&] {
            require(session.audio.state().playing && session.transport().playing &&
                    std::abs(session.audio.state().position-before.position)<.0001 &&
                    std::abs(session.transport().position-before.position)<.0001 &&
                    session.transport().editPosition==editBefore && session.transport().regionId==parts[0].id,
                    "Remote Setlist selection stopped or sought the running audio/edit cursor");
        };
        click(*rows,rowFor(workspace,parts.back().id));
        const auto localQueue=session.transport().queuedRegionId;
        require(localQueue==parts.back().id,"Local click did not queue the destination");
        select(parts.back().id);require(!session.transport().queuedRegionId,"Remote reclick did not cancel the existing queue");
        playbackUnchanged();
        const auto cancelledSelection=get(workspace.diagnostics(),"setlist");
        require(!session.focusedRegion && strings(get(cancelledSelection,"selectedEntries")).empty() &&
                strings(get(cancelledSelection,"visibleSelectedEntries")).empty(),
                "Remote queue cancellation must clear the blue selection, unlike keyboard Enter");
        select(parts.back().id);require(session.transport().queuedRegionId==localQueue,"Remote queue differs from local selection");
        playbackUnchanged();selectedAndRevealed(workspace,*rows,parts.back().id);
        select(parts[0].id);
        require(session.transport().queuedRegionId==localQueue,"Selecting the active song discarded the armed next song");
        playbackUnchanged();selectedAndRevealed(workspace,*rows,parts[0].id);
        auto playlist=*session.project().regionSetlist;playlist.selectedId=playlist.playlists[0].id;
        session.configureSetlist(playlist);select(parts[28].id);
        require(session.transport().queuedRegionId==parts[28].id && !session.project().regionSetlist->selectedId,
                "Remote child selection outside the playlist did not arm/reveal that song");
        playbackUnchanged();selectedAndRevealed(workspace,*rows,parts[28].id,parts[26].id);
        session.command(jaras::CommandKind::stopAll);
    });
}
} // namespace catlive::remoteSetlistSelectionTests
