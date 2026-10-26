#pragma once
#include "Workspace.h"
#include "MIDIItemExport.h"
#include "FloatingControlTests.h"
#include "ProjectDeletionPanel.h"
#include "ProjectOpenConfirmationPanel.h"
#include "SetlistRows.h"
namespace catlive {
struct WorkspaceLayoutTests {
    static void projectReplacement(const File &directory) {
        using floatingControlTests::require;
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(Session::makeEmptyProject("Original"))); session.audio.setOffline(true);
        const auto file=directory.getNonexistentChildFile("replace-current", "").getChildFile("Original.jl");
        session.save(file);
        Auth auth; Lighting lighting(session); Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("replacement-ui",".json"));
        w.setSize(1200,800); w.projectOpened(false);
        session.edit([](jaras::Project &p){p.name="Preserved edit";},false);
        bool applied=false, cancelled=false;
        auto find=[&]() -> ProjectOpenConfirmationPanel * {
            for(auto *child:w.getChildren())if(auto *sheet=dynamic_cast<ModalSheet*>(child))
                for(auto *content:sheet->getChildren())if(auto *panel=dynamic_cast<ProjectOpenConfirmationPanel*>(content))return panel;
            return nullptr;
        };
        w.confirmProjectReplacement("Next",[&]{applied=true;},[&]{cancelled=true;});
        auto *panel=find();require(panel!=nullptr,"Replacement used a system alert instead of the rounded panel");
        panel->keyPressed(KeyPress(KeyPress::escapeKey));floatingControlTests::pump();
        require(cancelled&&!applied&&session.dirty&&session.project().name=="Preserved edit","Cancel modified the outgoing project");
        w.confirmProjectReplacement("Next",[&]{applied=true;});panel=find();require(panel!=nullptr,"Second confirmation missing");
        panel->keyPressed(KeyPress(KeyPress::returnKey));
        const auto deadline=Time::getMillisecondCounterHiRes()+15000;
        while(!applied&&Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
        require(applied&&!session.dirty,"Replacement ran before saving or never continued");
        Session reopened;reopened.inspection=true;reopened.audio.prepareOffline(48000);reopened.audio.setOffline(true);reopened.load(file);
        require(reopened.project().name=="Preserved edit","Replacement discarded unsaved edits");
        floatingControlTests::pump();
        session.edit([](jaras::Project &p){p.name="Remote preserved edit";},false);applied=false;
        w.confirmProjectReplacement("Remote next",[&]{applied=true;},{},true);
        require(find()==nullptr,"Remote confirmation was repeated on the desktop");
        const auto remoteDeadline=Time::getMillisecondCounterHiRes()+15000;
        while(!applied&&Time::getMillisecondCounterHiRes()<remoteDeadline)floatingControlTests::pump();
        require(applied&&!session.dirty,"Remote replacement did not save before continuing");
        reopened.load(file);require(reopened.project().name=="Remote preserved edit","Remote replacement lost edits");
    }
    static void liveRecordingWaveform(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();
        auto &track=project.songs.front().tracks.front();track.clips.clear();track.heightScale=.1;track.color=0x555555;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Session::RecordingItem item;item.track=track.id;item.clip.id=uuid();item.clip.name="Live";item.clip.startTime=0;item.clip.duration=100;item.clip.recordingLane=0;
        item.preview=std::make_shared<RecordingPreview>(48000,2);item.preview->frames=48000;
        session.recordingItems.push_back(item);++session.revision;
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getChildFile("recording-preview.json"));
        w.setSize(1600,900);w.projectOpened(false);w.partsLeftVisible=false;w.partsRightVisible=false;w.setlistVisible=false;
        w.pixelsPerSecond=240;w.rebuild();
        auto silent=w.createComponentSnapshot(w.getLocalBounds());
        AudioBuffer<float> samples(2,48000);for(int c=0;c<2;++c)for(int i=0;i<48000;++i)samples.setSample(c,i,(c?-.6f:.8f));
        item.preview->append(samples.getArrayOfReadPointers(),48000);item.preview->drain();
        // Invalidate the cached canvas without rebuilding or stopping capture.
        std::function<void(Component &)> invalidate=[&](Component &c){c.repaint();for(auto *child:c.getChildren())invalidate(*child);};
        invalidate(w);
        auto recorded=w.createComponentSnapshot(w.getLocalBounds());
        int changed=0;for(int y=0;y<silent.getHeight();++y)for(int x=0;x<silent.getWidth();++x)
            if(silent.getPixelAt(x,y)!=recorded.getPixelAt(x,y))++changed;
        require(changed>50,"Compact live item has no visible waveform before Stop");
    }
    static void dividerMargins(const File &directory) {
        using floatingControlTests::require;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("divider-margins",".json"));
        w.setSize(1600,900);w.projectOpened(false);w.partsLeftVisible=false;w.partsRightVisible=false;
        w.mixerWidth=350;w.setlistWidth=300;
        for(bool mixer:{false,true})for(bool setlist:{false,true})for(bool leading:{false,true}) {
            w.mixerVisible=mixer;w.setlistVisible=setlist;
            w.setlistPlacement=leading?Workspace::SetlistPlacement::left:Workspace::SetlistPlacement::right;w.resized();
            const auto state=get(w.diagnostics(),"timeline");
            require(num(state,"x")==w.tracksViewport.getRight()+(mixer?20:0),"Mixer divider lost its reserved Mac margin");
            require(w.mixerDivider.getWidth()==(mixer?20:0)&&w.setlistDivider.getWidth()==(setlist?14:0),"Hidden divider retained a margin or visible rail collapsed");
            require(w.tracksViewport.getWidth()==(mixer?350:0),"Divider margin reduced mixer controls");
            if(setlist&&!leading)require(num(state,"x")+num(state,"width")==w.setlistDivider.getX(),"Setlist rail overlaps the grid");
            if(setlist&&leading)require(w.setlistDivider.getRight()==w.tracksViewport.getX(),"Leading setlist gap was not reserved");
        }
    }
    static void trackIconWidth(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();
        auto &tracks=project.songs.front().tracks;
        tracks[1].parentTrackID=tracks[0].id;
        const auto target=tracks[0].id;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getChildFile("track-icon-width-layout.json"));
        w.setSize(1600,900);w.projectOpened(false);w.mixerVisible=true;
        w.partsLeftVisible=false;w.partsRightVisible=false;w.setlistVisible=false;
        std::function<Component *(Component &,const String &)> find=[&](Component &parent,const String &id)->Component * {
            if(parent.getComponentID()==id)return &parent;
            for(auto *child:parent.getChildren())if(auto *result=find(*child,id))return result;
            return nullptr;
        };
        const auto frames=[&] {
            std::vector<juce::Rectangle<int>> result;
            for(const auto &track:session.song()->tracks) {
                auto *row=find(w,"trackRow:"+text(track.id));require(row!=nullptr,"Missing track row");
                for(auto *child:row->getChildren())if(child->isVisible())result.push_back(child->getBounds());
            }
            return result;
        };
        for(int width:{281,350,480}) {
            w.mixerWidth=width;w.rebuild();
            const auto before=frames();const int viewport=w.tracksViewport.getWidth();
            const auto toolbar=w.addTrack.getBounds();
            session.setTrackInstrumentIcon({target},std::string("drums"));w.rebuild();
            require(w.tracksViewport.getWidth()==viewport+40&&w.mixerWidth==width,
                    "Track icon column consumed the saved control width");
            require(frames()==before&&w.addTrack.getBounds()==toolbar,
                    "Track icons moved group/child controls or the toolbar");
            w.mixerVisible=false;w.resized();
            require(w.tracksViewport.getWidth()==0&&!w.tracksViewport.isVisible(),"Hidden mixer retained its icon column");
            w.mixerVisible=true;w.resized();
            require(w.tracksViewport.getWidth()==viewport+40&&frames()==before,"Restoring mixer changed its control width");
            session.setTrackInstrumentIcon({target},std::nullopt);w.rebuild();
            require(w.tracksViewport.getWidth()==viewport&&frames()==before,"Removing the last icon changed the saved body width");
        }
    }
    static void deleteRecentWhilePlaying(const File &directory) {
        using floatingControlTests::require;
        struct RestoreRecents { StringArray saved=RecentProjects::read(); ~RestoreRecents(){RecentProjects::write(saved);} } recents;
        const auto folder=directory.getNonexistentChildFile("live-recent-deletion","");
        const auto currentFile=folder.getChildFile("current/Current.jl"), otherFile=folder.getChildFile("other/Other.jl");
        otherFile.getParentDirectory().createDirectory();
        ProjectCodec::write(otherFile,ProjectCodec::encode(floatingControlTests::fixture()));
        auto session=std::make_unique<Session>();session->inspection=true;session->audio.prepareOffline(48000);
        session->restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));session->audio.setOffline(true);
        session->save(currentFile);
        Auth auth;Lighting lighting(*session);Workspace w(*session,auth,lighting,false,folder.getChildFile("layout.json"));
        w.setSize(1366,900);w.projectOpened(false);
        session->edit([](auto &project){project.name="Unsaved active show";},false);
        session->command(jaras::CommandKind::play);
        AudioBuffer<float> pcm(2,128);session->audio.render(pcm.getArrayOfWritePointers(),2,128);
        const auto projectID=session->project().id;
        w.deleteRecentProject(otherFile);
        ProjectDeletionPanel *panel=nullptr;
        std::function<void(Component &)> find=[&](Component &component){
            if(auto *candidate=dynamic_cast<ProjectDeletionPanel*>(&component))panel=candidate;
            for(auto *child:component.getChildren())find(*child);
        };
        find(w);require(panel!=nullptr,"Playback prevented the recent-project deletion confirmation");
        TextButton *remove=nullptr;
        for(auto *child:panel->getChildren())if(auto *button=dynamic_cast<TextButton*>(child))
            if(button->getButtonText()!=localization::translate("Cancel"))remove=button;
        require(remove && !remove->isEnabled(),"Deletion confirmation skipped its countdown");
        const auto deadline=Time::getMillisecondCounterHiRes()+4500;
        while(!remove->isEnabled()&&Time::getMillisecondCounterHiRes()<deadline) {
            floatingControlTests::pump();session->audio.render(pcm.getArrayOfWritePointers(),2,128);
        }
        require(remove->isEnabled()&&session->transport().playing&&otherFile.existsAsFile(),
                "Opening or waiting for deletion stopped playback or deleted without confirmation");
        const auto clock=session->audio.state();
        remove->onClick();floatingControlTests::pump();
        require(!otherFile.existsAsFile()&&currentFile.existsAsFile(),"Deletion removed the wrong project");
        require(session->project().id==projectID&&session->document==currentFile&&w.projectReady,
                "Deleting another recent project cleared the active session");
        require(session->transport().playing&&session->audio.state().playing&&session->audio.state().position==clock.position,
                "Deleting another recent project stopped or reset the audio clock");
        require(ProjectCodec::decode(ProjectCodec::read(currentFile)).name=="Unsaved active show",
                "Deleting another project lost the active project's unsaved shared-media protection");
        session->command(jaras::CommandKind::stopAll);
    }
    static void unifyItems(const File &directory) {
        using floatingControlTests::require;
        for(bool midi:{false,true}) {
            const auto folder=directory.getNonexistentChildFile("unify-selection","");folder.createDirectory();
            mediaImportTests::source(folder,"source.wav",48000);
            auto project=floatingControlTests::fixture();project.songs.front().parts.clear();
            std::set<ID> selected;ID clicked,unselected;
            for(int ti=0;ti<2;++ti) for(int ci=0;ci<3;++ci) {
                jaras::AudioClip clip;clip.id=uuid();clip.name="Item";clip.startTime=ci*2;clip.duration=1;
                if(midi){clip.midi.emplace();clip.midi->sourceBPM=120;clip.midi->notes.push_back({uuid(),0,1,60+ci,100,1});}
                else clip.audioFile=jaras::AudioFile{"source.wav",{}};
                project.songs.front().tracks[(size_t)ti].clips.push_back(clip);
                if(ci<2){selected.insert(clip.id);clicked=clip.id;}else unselected=clip.id;
            }
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.mediaDirectory=folder;session.document=folder.getChildFile("Show.jl");
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,folder.getChildFile("layout.json"));
            w.setSize(1366,900);w.projectOpened(false);
            const auto before=JSON::toString(session.snapshot());w.selectedClips=selected;w.selectedClip=clicked;
            const auto choose=[&](const ID &id,int action){
                // Invoke the exact callback passed to the popup, including the
                // selection snapshot captured when that menu opens.
                const auto handler=w.clipMenuAction(id);
                handler(action);floatingControlTests::pump();mediaImportTests::wait(session,60000);floatingControlTests::pump();
                mediaImportTests::require(session.message.isEmpty(),"Item menu action failed: "+session.message);
            };
            if(!midi){
                choose(clicked,24);
                for(const auto &track:session.song()->tracks)for(const auto &clip:track.clips)require(clip.channelMode.value_or(0)==(selected.count(clip.id)?4:0),"Swap LR did not apply exactly to the selection");
                session.undo();require(JSON::toString(session.snapshot())==before,"Swap LR Undo changed other item data");
            }
            choose(clicked,14);
            require(w.selectedClips.size()==2,"Unify did not select one resulting item per track");
            for(int ti=0;ti<2;++ti){const auto &track=session.song()->tracks[(size_t)ti];require(track.clips.size()==2,"Unify processed only the right-clicked item or removed unrelated items");
                const auto &clip=track.clips.front();require(clip.startTime==0&&clip.duration==3&&w.selectedClips.count(clip.id),"Unified range or result selection is wrong");
                require(selected.count(track.clips.back().id)==0&&track.clips.back().startTime==4,"Unselected item changed");
                if(midi)require(clip.midi&&clip.midi->notes.size()==2,"Unify lost MIDI notes");
                else require(clip.audioFile&&!clip.waveform.empty()&&folder.getChildFile(text(clip.audioFile->path)).existsAsFile(),"Unify produced no audio or peaks");
            }
            session.undo();require(JSON::toString(session.snapshot())==before,"Single Undo did not restore selected originals");
            session.redo();require(session.song()->tracks.front().clips.size()==2,"Redo did not restore unified item");
            // Right-click outside the selection must affect that item alone.
            session.undo();w.selectedClips=selected;w.selectedClip=clicked;choose(unselected,14);
            require(session.song()->tracks.front().clips.size()==3&&session.song()->tracks[1].clips.size()==3,"Unify outside selection modified selected items");
        }
    }
    static void generatedItems(const File &directory) {
        using floatingControlTests::require;
        for (bool playing : {false,true}) {
            auto project=floatingControlTests::fixture();
            auto &tracks=project.songs.front().tracks;
            tracks[1].role.id="teleprompt";tracks[1].name=jaras::fixedTrackName(tracks[1].role);
            tracks[2].role.id="chords";tracks[2].name=jaras::fixedTrackName(tracks[2].role);
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            Auth auth;Lighting lighting(session);
            Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("generated-items",".json"));w.setSize(1366,900);w.projectOpened(false);
            session.command(jaras::CommandKind::editSeek,{},3);
            if(playing)session.command(jaras::CommandKind::play);
            for(size_t index=0;index<3;++index) {
                // Windows MIDI creation is a structural edit and requires Stop;
                // text creation also supports an already-running transport.
                if (playing && index==0) continue;
                const auto id=tracks[index].id;
                if(index==0)w.addMIDIItem(id,5);else w.addTextItem(id,5);
                const auto findTrack=[&]() -> const jaras::Track& { return *std::find_if(session.song()->tracks.begin(),session.song()->tracks.end(),[&](const auto &t){return t.id==id;}); };
                require(!findTrack().clips.empty(),"Generated item was not inserted");
                const auto &clip=findTrack().clips.back();
                const auto end=clip.startTime+clip.duration;
                require(session.transport().editPosition==end,"Generated item did not advance edit cursor to its actual end");
                require(session.transport().playing==playing&&session.transport().position==(playing?3:end),"Generated item disrupted playback");
                if(index>0) {
                    w.floatingWindows.at("Editor de texto")->closeButtonPressed();
                    w.addTextItem(id,session.transport().editPosition);
                    require(findTrack().clips.back().startTime==end,"Consecutive text items do not start at the previous end");
                    w.floatingWindows.at("Editor de texto")->closeButtonPressed();
                }
            }
            session.command(jaras::CommandKind::stopAll);
        }
    }
    static void trackTail(const File &directory) {
        using floatingControlTests::require;
        auto project=floatingControlTests::fixture();auto &tracks=project.songs.front().tracks;
        while(tracks.size()<30){auto track=tracks.front();track.id=uuid();track.name="Track "+std::to_string(tracks.size());tracks.push_back(track);}
        jaras::AudioClip clip;clip.id=uuid();clip.name="Retained grid selection";clip.duration=3;
        tracks.front().clips.push_back(clip);
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("track-tail",".json"));w.setSize(1366,900);w.projectOpened(false);
        require(w.tracksContent.getHeight()-w.rowTop((int)tracks.size())==w.trackHeight*2,"Empty track tail differs from Mac's two rows");
        w.selectMixerTrack(tracks[0].id,ModifierKeys{});
        w.selectMixerTrack(tracks[1].id,ModifierKeys(ModifierKeys::ctrlModifier));
        const auto event=[&](Component &target,Point<float> at,int flags=ModifierKeys::leftButtonModifier){
            return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(flags),1,0,0,0,0,
                              &target,&target,Time::getCurrentTime(),at,Time::getCurrentTime(),1,false);
        };
        const auto selected=w.selectedTracks;
        const Point<float> blank{20.0f,(float)w.rowTop((int)tracks.size())+10.0f};
        w.mouseDown(event(w.tracksContent,blank,ModifierKeys::rightButtonModifier));
        require(w.selectedTracks==selected,"Context click cleared track selection");
        w.mouseDown(event(w.tracksContent,{20,10}));
        require(w.selectedTracks==selected,"Blank-tail handler consumed a track row click");
        w.mouseDown(event(w.addTrack,{5,5}));
        require(w.selectedTracks==selected,"A mixer control cleared the selected tracks");
        w.selectedClip=clip.id;w.selectedClips={w.selectedClip};
        w.mouseDown(event(w.tracksContent,blank));
        require(w.selectedTracks.empty()&&w.selectedTrack.empty()&&w.trackSelectionAnchor.empty(),
                "Clicking empty mixer space did not clear tracks and the Shift-selection anchor");
        require(w.selectionAreas.activeScope()=="tracks"&&w.selectedClip==clip.id,
                "Empty mixer click changed another panel's selection or lost Delete ownership");
        const auto count=session.song()->tracks.size();
        w.keyPressed(KeyPress(KeyPress::deleteKey));
        require(session.song()->tracks.size()==count,"Delete after deselection removed a stale track");
        require(session.song()->tracks.front().clips.size()==1,"Delete after a blank mixer click leaked into the grid selection");
        const int offset=w.tracksContent.getHeight()-w.tracksViewport.getViewHeight();
        w.verticalOffset=offset;w.tracksViewport.setViewPosition(0,offset);
        w.addStandardTrackAtEnd();w.rebuild();
        require(session.song()->tracks.size()==31,"Double-click track command did not append a track");
        require(w.verticalOffset==offset&&w.tracksViewport.getViewPositionY()==offset,"Appending a track jumped to the top");
    }
    static void setlistBlockDeletion(const File &directory) {
        using floatingControlTests::require;
        auto project = floatingControlTests::fixture();
        auto &song = project.songs.front();
        jaras::AudioClip clip; clip.id = uuid(); clip.name = "Retained item"; clip.duration = 5;
        song.tracks.front().clips = {clip};
        song.markers = std::vector<jaras::TimelineMarker>{{uuid(), "Verse", 2, 0x54ff93}};
        jaras::RegionSetlist state; const ID playlist = uuid(), other = uuid(), block = uuid(), otherBlock = uuid();
        state.selectedId = playlist;
        state.playlists = {{playlist, "Show", song.id, {song.parts[0].id, song.parts[1].id}},
                           {other, "Other", song.id, {song.parts[1].id}}};
        state.blocks = std::vector<jaras::SetlistBlock>{{block, song.id, playlist, "Opening", 0x54ff93, song.parts[0].id},
                                                       {otherBlock, song.id, other, "Other", 0x54ff93, song.parts[1].id}};
        project.regionSetlist = state;
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace w(session, auth, lighting, false, directory.getNonexistentChildFile("setlist-block-delete", ".json"));
        w.setSize(1366, 900); w.projectOpened(false);
        auto *panel = uiFeatureTests::find(w, "setlistPanel"); require(panel, "Setlist panel is missing");
        auto *rows = dynamic_cast<SetlistRows *>(uiFeatureTests::find(w, "setlistRows"));
        require(rows && rows->getModel() && rows->getModel()->getNumRows() == 3, "Playlist fixture must contain a block and two songs");
        rows->selectRow(0);
        const auto payload = rows->getModel()->getDragSourceDescription(rows->getSelectedRows());
        require(list(get(payload, "ids")).size() == 1 && list(get(payload, "ids"))[0].toString() == text(block),
                "Block row is excluded from its drag payload");
        require(rows->createDragPreview().getImage().getHeight() == 34, "Block drag must use the same compact title strip as songs");
        auto *target = dynamic_cast<DragAndDropTarget *>(panel); require(target, "Setlist drop target is missing");
        const auto priorDrag = JSON::toString(session.snapshot());
        const auto end = panel->getLocalPoint(rows, Point<int>(20, rows->rowTop(3) + 6));
        DragAndDropTarget::SourceDetails drop(payload, rows, end);
        require(target->isInterestedInDragSource(drop), "Setlist rejects dragging its own block");
        target->itemDropped(drop);
        require(!session.project().regionSetlist->blocks->front().beforeRegionId &&
                session.project().regionSetlist->playlists.front().regionIds == state.playlists.front().regionIds,
                "Dropping a block at the end moved its songs or failed to move the block");
        session.undo(); w.rebuild();
        require(JSON::toString(session.snapshot()) == priorDrag, "Undo did not restore block drag order");
        w.selectMixerTrack(song.tracks[0].id, ModifierKeys{});
        w.selectedClip = clip.id; w.selectedClips = {clip.id};
        rows->selectRow(0); w.selectionAreas.activate(*panel);
        const auto before = JSON::toString(session.snapshot());
        const auto songsBefore = JSON::toString(get(session.snapshot(), "songs"));
        const auto request = [&] {
            w.keyPressed(KeyPress(KeyPress::deleteKey)); floatingControlTests::pump();
            auto *alert = dynamic_cast<AlertWindow *>(Component::getCurrentlyModalComponent());
            require(alert && alert->getName() == localization::translate("Delete selected blocks?"),
                    "Delete did not target the selected block or showed the region deletion warning");
            return alert;
        };
        request()->exitModalState(0); floatingControlTests::pump();
        require(JSON::toString(session.snapshot()) == before && rows->getSelectedRows().contains(0), "Cancel removed the block or cleared its selection");
        request()->exitModalState(1); floatingControlTests::pump();
        require(session.project().regionSetlist->blocks->size() == 1 &&
                session.project().regionSetlist->blocks->front().id == otherBlock, "Delete did not remove only the selected block");
        require(JSON::toString(get(session.snapshot(), "songs")) == songsBefore &&
                session.project().regionSetlist->playlists.front().regionIds == state.playlists.front().regionIds,
                "Deleting a block removed songs, audio, markers or a stale track/grid selection");
        w.keyPressed(KeyPress(KeyPress::spaceKey));
        require(session.transport().playing, "A deleted block left Play blocked");
        session.command(jaras::CommandKind::stopAll);
        session.undo(); w.rebuild();
        require(JSON::toString(session.snapshot()) == before, "One Undo did not restore the complete block metadata");
        rows->selectRow(0); w.selectionAreas.activate(*panel);
        auto *pending = request();
        auto changed = *session.project().regionSetlist; changed.selectedId = other;
        session.configureSetlist(changed); pending->exitModalState(1); floatingControlTests::pump();
        require(session.project().regionSetlist->blocks->size() == 2, "A stale confirmation deleted a block after switching playlists");
    }
    static void setlistBlockMIDI(const File &directory) {
        using floatingControlTests::require;
        auto project = floatingControlTests::fixture();
        const auto song = project.songs.front();
        const ID a = song.parts[0].id, b = song.parts[1].id, playlist = uuid(), other = uuid();
        const ID first = uuid(), second = uuid(), consecutive = uuid(), tail = uuid();
        jaras::RegionSetlist state; state.selectedId = playlist;
        state.playlists = {{playlist,"First playlist",song.id,{a,b}}, {other,"Second playlist",song.id,{b,a}}};
        // Persisted metadata order and names intentionally disagree with the visible block order.
        state.blocks = std::vector<jaras::SetlistBlock>{{second,song.id,playlist,"Bloco 01",0x54ff93,b},
            {first,song.id,playlist,"Renamed 99",0x54ff93,a},
            {consecutive,song.id,playlist,"Empty consecutive block",0x54ff93,a},
            {tail,song.id,playlist,"Tail",0x54ff93,std::nullopt},
            {uuid(),song.id,other,"Different project-style name",0x54ff93,b}};
        project.regionSetlist = state;
        Session session; session.inspection = true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("setlist-block-midi-workspace",".json"));
        w.setSize(1366,900); w.projectOpened(false);
        auto midi = object(); put(midi,"status",0xb0);put(midi,"number",48);put(midi,"channel",4);
        require(w.actions.assign("setlistBlock:1","midi",midi),"Could not map the first block");
        auto trigger = [&] {
            ActionBindingsTestAccess::receive(w.actions,MidiMessage::controllerEvent(4,48,0));
            ActionBindingsTestAccess::receive(w.actions,MidiMessage::controllerEvent(4,48,127));
        };
        session.command(jaras::CommandKind::selectRegion,b);
        const auto songData = JSON::toString(get(session.snapshot(),"songs"));
        trigger();
        require(session.transport().regionId == a && !session.transport().playing && session.transport().editPosition == 0,
                "Block MIDI used its name/metadata index instead of the visible ordinal, or started playback");
        require(w.selectionAreas.activeScope() == "setlist", "Block MIDI did not select the same area as a song click");
        w.performAction("setlistBlock:3",1,0);
        require(session.transport().regionId == b && !session.transport().playing,"Third block did not select its first song");
        w.performAction("setlistBlock:1",1,0);
        require(session.transport().regionId == a,"Consecutive empty block prevented selecting the first song below");
        w.performAction("setlistBlock:4",1,0); w.performAction("setlistBlock:1000",1,0);
        require(session.transport().regionId == a && !session.transport().playing,"Trailing or missing block changed the selection");
        session.command(jaras::CommandKind::play);
        w.performAction("setlistBlock:3",1,0);
        require(session.transport().playing && session.transport().regionId == a && session.transport().queuedRegionId == b,
                "During playback block MIDI did not use the normal song queue");
        session.command(jaras::CommandKind::stopAll);
        auto changed = *session.project().regionSetlist; changed.selectedId = other;
        session.configureSetlist(changed); w.rebuild(); trigger();
        require(session.transport().regionId == b && !session.transport().playing,"Global mapping kept a block UUID from the previous playlist");
        changed = *session.project().regionSetlist; changed.selectedId = playlist;
        require(playlistOccurrences::moveEntries(changed,song.id,playlist,{first,consecutive},std::nullopt),"Could not reorder block test fixture");
        session.configureSetlist(changed); w.rebuild(); trigger();
        require(session.transport().regionId == b && !session.transport().playing,"MIDI ordinal did not follow reordered blocks");
        require(JSON::toString(get(session.snapshot(),"songs")) == songData,"Learning or triggering a block modified project media");
        auto otherProject = floatingControlTests::fixture();
        const auto otherSong = otherProject.songs.front(); const ID otherPlaylist = uuid();
        jaras::RegionSetlist fresh; fresh.selectedId = otherPlaylist;
        fresh.playlists = {{otherPlaylist,"Another project",otherSong.id,{otherSong.parts[0].id,otherSong.parts[1].id}}};
        fresh.blocks = std::vector<jaras::SetlistBlock>{{uuid(),otherSong.id,otherPlaylist,"Fresh block",0x54ff93,otherSong.parts[1].id}};
        otherProject.regionSetlist = fresh;
        session.restoreSnapshot(ProjectCodec::encode(otherProject)); w.projectOpened(false); trigger();
        require(session.transport().regionId == otherSong.parts[1].id && !session.transport().playing,
                "Global block mapping did not resolve the current project's first block");
    }
    static void textEditor(const File &directory) {
        using floatingControlTests::require;
        for (const auto *role : {"teleprompt", "chords"}) {
            auto project=floatingControlTests::fixture();
            auto &track=project.songs.front().tracks.front();
            track.role.id=role;track.name=jaras::fixedTrackName(track.role);
            jaras::AudioClip clip;clip.id=uuid();clip.name="Text";clip.duration=10;clip.text="Original";
            track.clips={clip};
            Session session;session.inspection=true;session.audio.prepareOffline(48000);
            session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
            Auth auth;Lighting lighting(session);
            Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("text-window",".json"));
            struct Host : DocumentWindow {
                Host():DocumentWindow("CatLive",theme::background,allButtons){}
                void closeButtonPressed() override {}
            } host;
            host.setContentNonOwned(&w,false);host.setBounds(40,40,1100,750);host.setVisible(true);w.projectOpened(false);
            w.showTeleprompter(1);w.updateState();floatingControlTests::pump();
            auto *projection=w.floatingWindows.at("Teleprompter 1").get();
            const auto handle=static_cast<HWND>(projection->getPeer()->getNativeHandle());
            const auto owner=GetWindowLongPtrW(handle,GWLP_HWNDPARENT);
            w.editTextItem(clip.id);w.updateState();floatingControlTests::pump();
            auto *editor=w.floatingWindows.at("Editor de texto").get();
            require(editor->isVisible()&&projection->isVisible()&&Component::getCurrentlyModalComponent()==nullptr,
                    "Text editor hid the projection or became a workspace-blocking modal");
            require(owner!=0&&GetWindowLongPtrW(handle,GWLP_HWNDPARENT)==owner,
                    "Text editor removed projection ownership and sent it behind the workspace");
            TextEditor *input=nullptr;Button *apply=nullptr,*cancel=nullptr;
            for(auto *child:editor->getContentComponent()->getChildren()) {
                if(auto *text=dynamic_cast<TextEditor*>(child))input=text;
                if(auto *button=dynamic_cast<Button*>(child)) {
                    if(button->getButtonText()=="Aplicar")apply=button;
                    if(button->getButtonText()=="Cancelar")cancel=button;
                }
            }
            require(input&&apply&&cancel,"Text editing controls missing");
            input->setText("Updated\nAm G");floatingControlTests::pump();
            require(*session.song()->tracks.front().clips.front().text=="Original","Typing changed the item before Apply");
            w.editTextItem(clip.id);require(w.floatingWindows.at("Editor de texto").get()==editor&&input->getText()=="Updated\nAm G","Reopening replaced the unfinished draft");
            apply->onClick();floatingControlTests::pump();
            require(!editor->isVisible()&&projection->isVisible()&&*session.song()->tracks.front().clips.front().text=="Updated\nAm G","Apply failed to commit and close only the text editor");
            session.undo();require(*session.song()->tracks.front().clips.front().text=="Original","Text edit could not be undone");
            w.editTextItem(clip.id);editor=w.floatingWindows.at("Editor de texto").get();
            editor->closeButtonPressed();require(projection->isVisible(),"Cancel closed the projection");
            host.clearContentComponent();
        }
    }
    static void run(const File &directory) {
        using floatingControlTests::require;
        const auto preferences=directory.getNonexistentChildFile("global-workspace-layout",".json");
        auto project=floatingControlTests::fixture();
        Session first; first.inspection=true; first.audio.prepareOffline(48000);
        first.restoreSnapshot(ProjectCodec::encode(project)); first.audio.setOffline(true);
        Auth auth; Lighting lighting(first);
        Workspace a(first,auth,lighting,false,preferences);a.setSize(1366,900);a.projectOpened(false);
        const auto before=JSON::toString(first.snapshot());
        a.mixerVisible=false;a.mixerWidth=410;a.setlistWidth=370;a.partsLeftWidth=290;
        a.mixerHeightSetting=410;a.partsRightVisible=true;
        a.setSetlistPlacement(Workspace::SetlistPlacement::detached);
        a.detachLeftParts();a.showDetachedMixer();
        const juce::Rectangle<int> frame(30,40,680,430);
        a.floatingWindows.at("Mixer")->setBounds(frame);
        a.floatingWindows.at("Parts")->setBounds(frame.withX(80));
        a.setlistWindow->setBounds(frame.withX(130));
        a.saveWorkspaceLayout();a.deactivateProjectTab();
        require(!a.floatingWindows.at("Mixer")->isVisible()&&!a.floatingWindows.at("Parts")->isVisible()&&!a.setlistWindow->isVisible(),"Background project left its floating panels visible");
        Session second;second.inspection=true;second.audio.prepareOffline(48000);
        project.id=uuid();second.restoreSnapshot(ProjectCodec::encode(project));second.audio.setOffline(true);
        Lighting otherLighting(second);Workspace b(second,auth,otherLighting,false,preferences);
        b.setSize(1366,900);b.projectOpened(false);
        require(!b.mixerVisible&&b.mixerWidth==410&&b.partsLeftWidth==290&&b.mixerHeightSetting==410,"Panel dimensions and visibility did not transfer to another project");
        require(b.mixerDetached&&b.partsLeftDetached&&b.setlistPlacement==Workspace::SetlistPlacement::detached,"Docking belongs to the project instead of global preferences");
        require(b.floatingWindows.at("Mixer")->getBounds()==frame&&b.floatingWindows.at("Parts")->getBounds()==frame.withX(80)&&b.setlistWindow->getBounds()==frame.withX(130),"Detached window frames were not restored");
        b.openVideo();require(b.floatingWindows.at("Video")->isVisible(),"Video did not open");
        b.openVideo();require(!b.floatingWindows.at("Video")->isVisible(),"Video toolbar failed to toggle closed");
        b.navigation->setVisible(true);b.resized();
        require(b.navigation->getBounds()==b.workspaceBounds,"Navigation covers the transport or extends beyond the Track-Mixer area");
        b.navigation->setVisible(false);
        b.mixerVisible=true;b.mixerWidth=480;b.floatingWindows.at("Mixer")->setBounds(frame.withWidth(760));
        b.saveWorkspaceLayout();b.deactivateProjectTab();a.activateProjectTab();
        require(a.mixerVisible&&a.mixerWidth==480&&a.floatingWindows.at("Mixer")->getWidth()==760,"Returning to an existing tab restored its stale project layout");
        require(JSON::toString(first.snapshot())==before,"Global panel preferences modified the project");
    }
};
namespace workspaceLayoutTests {
template<class Test> void registerTests(const File &directory,Test &test) {
    test("Project replacement saves edits before continuing and Cancel preserves them",[&]{WorkspaceLayoutTests::projectReplacement(directory);});
    test("Recording live waveform is visible in compact tracks before Stop",[&]{WorkspaceLayoutTests::liveRecordingWaveform(directory);});
    test("MIDI item export preserves trimmed notes and channels while muted",[&]{
        using floatingControlTests::require;
        jaras::AudioClip clip;clip.id=uuid();clip.name="Keys";clip.startTime=10;clip.duration=1.5;clip.sourceOffset=1;clip.playbackRate=2;clip.muted=true;clip.gain=0;
        clip.midi.emplace();clip.midi->sourceBPM=120;
        jaras::MIDINote a;a.id=uuid();a.start=0;a.length=4;a.pitch=60;a.velocity=80;a.channel=3;
        auto b=a;b.id=uuid();b.start=4;b.pitch=64;b.channel=16;b.velocity=100;clip.midi->notes={a,b};
        auto file=directory.getNonexistentChildFile("export-item",".mid");exportMIDIItem(clip,file);
        FileInputStream input(file);MidiFile parsed;require(parsed.readFrom(input),"Unreadable MIDI file");parsed.convertTimestampTicksToSeconds();
        std::vector<MidiMessage> notes;for(int t=0;t<parsed.getNumTracks();++t)for(int i=0;i<parsed.getTrack(t)->getNumEvents();++i){auto m=parsed.getTrack(t)->getEventPointer(i)->message;if(m.isNoteOn()||m.isNoteOff())notes.push_back(m);}
        require(notes.size()==4,"MIDI notes were lost");require(notes[0].getChannel()==3&&notes[2].getChannel()==16,"MIDI channels changed");
        require(std::abs(notes.front().getTimeStamp())<.001&&std::abs(notes.back().getTimeStamp()-1.5)<.001,"MIDI trim or rate changed");
        file.deleteFile();
    });
    test("Workspace divider margins match Mac without shrinking track controls",[&]{WorkspaceLayoutTests::dividerMargins(directory);});
    test("Track icon column extends the mixer without moving group or child controls; hiding and removal restore width",[&]{WorkspaceLayoutTests::trackIconWidth(directory);});
    test("Deleting another recent project during playback preserves the current dirty project and audio clock",[&]{WorkspaceLayoutTests::deleteRecentWhilePlaying(directory);});
    test("Item context unifies the full selection per track with audio, MIDI, result selection and Undo; LR swap preserves unselected items",[&]{WorkspaceLayoutTests::unifyItems(directory);});
    test("Generated MIDI and text items advance edit cursor without seeking playback",[&]{WorkspaceLayoutTests::generatedItems(directory);});
    test("Empty track tail matches Mac and appending preserves vertical scroll",[&]{WorkspaceLayoutTests::trackTail(directory);});
    test("Setlist block Delete and drag follow last area, keep songs and media, support cancel and Undo, and reject stale confirmations",[&]{WorkspaceLayoutTests::setlistBlockDeletion(directory);});
    test("Setlist block MIDI follows the current playlist ordinal and normal song selection or queue",[&]{WorkspaceLayoutTests::setlistBlockMIDI(directory);});
    test("Lyrics and chord editors retain visible projections, drafts and undo",[&]{WorkspaceLayoutTests::textEditor(directory);});
    test("Panel layout survives new workspaces and tab switches without changing projects; navigation and Video toggle stay independent",[&]{WorkspaceLayoutTests::run(directory);});
}
}
}
