#pragma once
#include "RegionLanes.h"
#include "TimelineRegionLabels.h"
#include "FloatingControlTests.h"

namespace catlive::regionLaneTests {
inline void require(bool okay, const char *message) {
    if (!okay) throw std::runtime_error(message);
}
inline bool closeEnough(double a, double b) { return std::abs(a-b)<.001; }
inline var findEntry(const var &entries, const ID &id) {
    for (const auto &entry : list(entries)) if (str(entry,"id")==text(id)) return entry;
    throw std::runtime_error("Region lane diagnostic entry missing: "+id);
}
inline jaras::Project fixture() {
    auto project=floatingControlTests::fixture();
    auto &song=project.songs[0];
    song.regionOwnershipInitialized=true;
    song.parts[0].id="first"; song.parts[1].id="second";
    song.markers=std::vector<jaras::TimelineMarker>{{"cue","Cue",17,0x54ff93},{"tempo","120",6,0}};
    (*song.markers)[0].regionOwnerID="second";
    (*song.markers)[1].regionOwnerID="first"; (*song.markers)[1].tempoBPM=120;
    for (size_t i=0;i<2;++i) {
        jaras::AudioClip clip; clip.id=i==0?"item-first":"item-second";
        clip.name="Owned item"; clip.startTime=i==0?1:16; clip.duration=3;
        clip.regionOwnerID=i==0?"first":"second"; clip.waveform={.1,.3,.2};
        song.tracks[i].clips={clip};
    }
    return project;
}
inline const jaras::Part &part(const jaras::Song &song, const ID &id) {
    for (const auto &value : song.parts) if (value.id==id) return value;
    throw std::runtime_error("Missing fixture region");
}
inline const jaras::TimelineMarker &marker(const jaras::Song &song, const ID &id) {
    if (song.markers) for (const auto &value : *song.markers) if (value.id==id) return value;
    throw std::runtime_error("Missing fixture marker");
}
inline const jaras::AudioClip &clip(const jaras::Song &song, const ID &id) {
    for (const auto &track : song.tracks) for (const auto &value : track.clips) if (value.id==id) return value;
    throw std::runtime_error("Missing fixture item");
}
inline MouseEvent mouse(Component &canvas, Point<float> at, Point<float> anchor, int modifiers, bool dragged=false) {
    return MouseEvent(Desktop::getInstance().getMainMouseSource(),at,ModifierKeys(modifiers),1,0,0,0,0,
                      &canvas,&canvas,Time::getCurrentTime(),anchor,Time::getCurrentTime(),1,dragged);
}

template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Marker heads stay inside regions and thin monotonically when zooming out", [&] {
        auto song=fixture().songs.front();song.parts.clear();
        jaras::Part root;root.id="root";root.startTime=10;root.endTime=20;song.parts.push_back(root);
        auto child=root;child.id="child";child.startTime=12;child.endTime=15;child.parentRegionID=root.id;song.parts.push_back(child);
        for(int kind=0;kind<4;++kind) {
            jaras::TimelineMarker marker{"marker","A long marker name",19.5,0x54ff93};
            if(kind==1)marker.tempoBPM=140;
            if(kind==2)marker.section=true;
            if(kind==3){marker.sourceRegionID=child.id;marker.unifiedRegionID=root.id;}
            const auto end=timelineRegionLabels::markerRegionEnd(song,marker);
            require(end==20,"Marker did not use its containing root region boundary");
            bool hidden=false;
            for(double scale=500;scale>=.1;scale*=.97) {
                const auto width=timelineRegionLabels::markerHeadWidth(marker.position,30,end,180,scale);
                require(width<=.5*scale+.0001,"Marker head crossed the region end at distant zoom");
                require(!hidden||width==0,"Marker head reappeared while zooming out");
                if(width==0)hidden=true;
            }
        }
        jaras::TimelineMarker outside{"outside","Outside",21,0};
        require(std::isinf(timelineRegionLabels::markerRegionEnd(song,outside)),"An outside marker was constrained to an unrelated region");
        require(timelineRegionLabels::markerHeadWidth(19,19,20,80,100)==0,"Coincident marker heads overlap");
    });
    test("Region movement preserves long audio tails, MIDI and explicit loose ownership across saves", [] {
        auto project=fixture();auto &song=project.songs[0];song.duration=31;
        auto &audio=song.tracks[1].clips[0];audio.startTime=15;audio.duration=15.153840445;
        auto midi=audio;midi.id="midi-tail";midi.audioFile.reset();midi.midi.emplace();
        song.tracks[1].clips.push_back(midi);
        const auto original=ProjectCodec::encode(project);
        song.tracks[0].clips[0].regionOwnerID.reset();
        auto restored=ProjectCodec::decode(ProjectCodec::encode(project,original));
        require(!restored.songs[0].tracks[0].clips[0].regionOwnerID,
                "Save resurrected a detached item's stale owner from the original document");
        jaras::Engine engine;engine.loadProject(restored);
        const auto before=*engine.currentSong();
        const auto preview=previewRegionEdit(before,"second",35,50,false);
        require(preview.has_value(),"Long-tail audio/MIDI region preview failed");
        engine.moveRegion("second",35);
        for(const auto &id:{"item-second","midi-tail"}) {
            require(closeEnough(clip(*preview,id).startTime,35) && closeEnough(clip(*engine.currentSong(),id).startTime,35),
                    "Audio or MIDI extending beyond the region stayed behind");
            require(closeEnough(clip(*engine.currentSong(),id).duration,15.153840445),"Region drag changed media duration");
        }
        engine.loadProject(ProjectCodec::decode(ProjectCodec::encode(engine.project())));
        engine.moveRegion("second",15);
        require(closeEnough(clip(*engine.currentSong(),"item-second").startTime,15) &&
                closeEnough(clip(*engine.currentSong(),"midi-tail").startTime,15),"Save/reopen lost region membership");
        require(closeEnough(clip(*engine.currentSong(),"item-first").startTime,1),"Move acquired a loose item");
    });
    test("Region marker repulsion uses the same zoom-aware margin and direction as Mac", [] {
        const auto song=fixture().songs[0];
        const auto &region=part(song,"second");
        RegionMarkerRepulsion repulsion(song,region,1);
        require(closeEnough(repulsion.resolve(4),3),"Leftward collision did not repel to the left edge");
        require(closeEnough(repulsion.resolve(4.8),5),"Nearest right edge not chosen");
        require(closeEnough(repulsion.resolve(10),10),"Unrelated marker changed free movement");
        require(closeEnough(repulsion.resolve(-10),0),"Region may move before project start");
    });
    test("Timeline region names and fractional BPM labels match the Mac display strings", [] {
        struct NameCase {const char *source;const char *display;};
        for (const auto &entry:std::initializer_list<NameCase>{
                {u8"Música (guia)",u8"MÚSICA (guia)"},
                {"Intro (Keys (Soft)) Final","INTRO (Keys (Soft)) FINAL"},
                {"a (b) c (d)","A (b) C (d)"},
                {"a (b c","A (b c"},
                {"a) b","A) B"},
                {"() a", "() A"},
                {"", ""}}) {
            jaras::Part region{"name",entry.source,0,10};
            require(timelineRegionLabels::displayName(region)==String::fromUTF8(entry.display),
                    "Default region display differs from Mac uppercase/parenthesis semantics");
            region.uppercaseName=true;
            require(timelineRegionLabels::displayName(region)==String::fromUTF8(entry.display),
                    "Explicit uppercase region display differs from the Mac");
            region.uppercaseName=false;
            require(timelineRegionLabels::displayName(region)==String::fromUTF8(entry.source),
                    "Disabling uppercase still changed the region's original name");
            require(region.name==entry.source,"Formatting a region modified its persisted name");
        }
        jaras::Song song;
        jaras::TimelineMarker tempo{"tempo","Tempo",0,0};
        for (const auto &entry:std::initializer_list<std::pair<double,const char *>>{
                {120,"120  4/4"},{120.25,"120.25  4/4"},{99.875,"99.875  4/4"},
                {60.123456,"60.1235  4/4"}}) {
            tempo.tempoBPM=entry.first;
            require(timelineRegionLabels::marker(song,tempo)==entry.second,
                    "Tempo label differs from the Mac %g precision or default meter");
        }
        tempo.tempoBPM=120.25;tempo.tempoBeats=7;tempo.tempoUnit=8;
        require(timelineRegionLabels::marker(song,tempo)=="120.25  7/8",
                "Fractional BPM formatting lost the marker's meter");
    });
    test("Region lanes pack adjacent roots and ignore unified children with stable equal starts", [] {
        std::vector<jaras::Part> roots{{"a","A",0,10},{"b","B",10,20}};
        RegionLanes adjacent(roots);
        require(adjacent.count==1 && adjacent.lane("a")==0 && adjacent.lane("b")==0,
                "Touching region boundaries must share one lane");
        roots.push_back({"overlap","Overlap",8,12});
        RegionLanes overlapping(roots);
        require(overlapping.count==2 && overlapping.lane("a")==overlapping.lane("b") &&
                overlapping.lane("overlap")!=overlapping.lane("a"),"Overlapping roots need separate header lanes");
        roots={{"long","Long",0,20},{"short","Short",0,10}};
        RegionLanes ties(roots);
        std::reverse(roots.begin(),roots.end());
        RegionLanes reversed(roots);
        require(ties.count==2 && ties.lane("long")!=ties.lane("short") &&
                ties.lane("long")==reversed.lane("long") && ties.lane("short")==reversed.lane("short"),
                "Equal-start roots depend on persisted insertion order");
        roots={{"family","Family",0,30},{"following","Following",30,45},
               {"child-a","Child A",0,20},{"child-b","Child B",10,30}};
        roots[2].parentRegionID="family"; roots[3].parentRegionID="family";
        RegionLanes unified(roots);
        require(unified.count==1,"Unified children must not allocate root header lanes");
        roots.push_back({"external","External",25,35});
        require(RegionLanes(roots).count==2,"Another root must overlap the entire unified parent");
        roots.push_back({"third","Third",27,28});
        require(RegionLanes(roots).count==3,"Three simultaneous roots were not detected");
    });
    test("Region preview moves only owned contents and rejects a third lane without mutating source", [] {
        auto project=fixture(); auto &song=project.songs[0];
        auto loose=song.tracks[1].clips.front();loose.id="loose";loose.regionOwnerID.reset();
        song.tracks[1].clips.push_back(loose);
        const auto moved=previewRegionEdit(song,"second",10,25,false);
        require(moved.has_value(),"Valid overlapping move rejected");
        require(closeEnough(part(*moved,"second").startTime,10) && closeEnough(part(*moved,"second").endTime,25) &&
                RegionLanes(moved->parts).count==2,"Preview region bounds or lane count wrong");
        require(closeEnough(moved->tracks[1].clips[0].startTime,11) && closeEnough(marker(*moved,"cue").position,12),
                "Owned audio item or marker did not move with region");
        require(closeEnough(moved->tracks[0].clips[0].startTime,1) && closeEnough(moved->tracks[1].clips[1].startTime,16),
                "Move captured another region's item or an explicitly unowned item");
        require(closeEnough(part(song,"second").startTime,15) && closeEnough(song.tracks[1].clips[0].startTime,16),
                "Preview changed the source project");
        const auto resized=previewRegionEdit(song,"second",10,30,true);
        require(resized && closeEnough(resized->tracks[1].clips[0].startTime,16) && closeEnough(marker(*resized,"cue").position,17),
                "Resizing boundaries moved media or markers");
        song.parts.push_back({"third","Third",10,20});
        require(!previewRegionEdit(song,"second",10,25,false),"Move requiring three root lanes was accepted");
        song.parts.back()={"child","Child",16,20}; song.parts.back().parentRegionID="second";
        song.tracks[1].clips[0].regionOwnerID="child";
        const auto family=previewRegionEdit(song,"second",10,25,false);
        require(family && closeEnough(part(*family,"child").startTime,11) && closeEnough(part(*family,"child").endTime,15) &&
                closeEnough(family->tracks[1].clips[0].startTime,11),"Unified child or its owned item did not follow parent");
        require(!previewRegionEdit(song,"second",10,30,true),"Unified family accepted unsupported independent resize");
    });
    test("Region headers retain creation IDs and unified markers show each song's live tuner value", [&] {
        ScopedValueSetter<bool> language(localization::english,false);
        auto project=floatingControlTests::fixture();auto &song=project.songs[0];
        song.duration=60;
        song.parts={{"late","Created first, played later",30,45},
                    {"early","Created second, played first",0,15},
                    {"family","Unified region",15,30},
                    {"child-a","First internal song",15,23},
                    {"child-b","Second internal song",23,30}};
        song.parts[0].pitchSemitones=-2;
        song.parts[3].parentRegionID="family";song.parts[3].pitchSemitones=3;
        song.parts[4].parentRegionID="family";
        jaras::TimelineMarker first{"child-a-marker","First internal song",15,0x54ff93};
        first.sourceRegionID="child-a";first.unifiedRegionID="family";
        jaras::TimelineMarker second{"child-b-marker","Second internal song",23,0x54ff93};
        second.sourceRegionID="child-b";second.unifiedRegionID="family";
        jaras::TimelineMarker cue{"cue","REFRAO",8,0x54ff93};cue.section=true;
        jaras::TimelineMarker tempo{"tempo","Tempo",12,0x999999};
        tempo.tempoBPM=120.25;tempo.tempoBeats=7;tempo.tempoUnit=8;
        song.markers=std::vector<jaras::TimelineMarker>{first,second,cue,tempo};
        jaras::RegionSetlist setlist;
        setlist.playlists={{"playlist","Reordered",song.id,{"family","early","late"}}};
        setlist.selectedId="playlist";project.regionSetlist=setlist;
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("region-header-labels",".json"));
        workspace.setSize(1366,768);
        auto rendered=[&] {
            const auto image=workspace.createComponentSnapshot(workspace.getLocalBounds());
            require(image.isValid(),"Could not render region identifiers");
            return get(workspace.diagnostics(),"timeline");
        };
        auto checkHeaders=[&](const var &state) {
            const auto regions=get(state,"regions");
            require(list(regions).size()==3,"Unified children created extra region header bands");
            require(str(findEntry(regions,"late"),"identifier")=="-2st  01" &&
                    str(findEntry(regions,"early"),"identifier")=="0st  02" &&
                    str(findEntry(regions,"family"),"identifier")=="Especial",
                    "Header IDs followed timeline/playlist order or lost pitch and Special label");
        };
        const auto initial=rendered();checkHeaders(initial);
        const auto initialHeads=get(initial,"markerHeads");
        require(str(findEntry(initialHeads,"tempo"),"label")=="120.25  7/8",
                "Rendered tempo marker still rounded a fractional BPM to one decimal");
        require(str(findEntry(initialHeads,"child-a-marker"),"label")=="3st  First internal song" &&
                str(findEntry(initialHeads,"child-b-marker"),"label")=="0st  Second internal song" &&
                str(findEntry(initialHeads,"cue"),"label")=="REFRAO",
                "Unified song markers did not get their own tuner prefix or an ordinary section received one");
        FileOutputStream output(directory.getChildFile("region-header-identifiers.png"));
        require(output.openedOk(),"Could not create region header screenshot");
        output.setPosition(0);output.truncate();
        require(PNGImageFormat().writeImageToStream(workspace.createComponentSnapshot(workspace.getLocalBounds()),output),
                "Could not write region header screenshot");
        session.setRegionPitch("child-a",-7,{song.tracks[0].id},{});
        const auto changed=rendered();checkHeaders(changed);
        const auto changedMarker=findEntry(get(changed,"markerHeads"),"child-a-marker");
        require(str(changedMarker,"label")=="-7st  First internal song" &&
                (double)get(changedMarker,"width")>(double)get(findEntry(initialHeads,"child-a-marker"),"width"),
                "Changing the tuner left the marker's rendered label or measured width stale");
        session.undo();
        require(str(findEntry(get(rendered(),"markerHeads"),"child-a-marker"),"label")=="3st  First internal song",
                "Undo did not restore the unified marker's tuner label");
        session.edit([&](auto &value) {auto edit=session.core;edit.moveRegion("late",45);value=edit.project();});
        checkHeaders(rendered());
        setlist.selectedId.reset();session.configureSetlist(setlist);checkHeaders(rendered());
    });
    test("Dragging overlapping regions updates header and track geometry live and commits one Undo step", [&] {
        auto project=fixture();
        auto fixed=project.songs[0].tracks[0].clips[0];
        fixed.id="collision";fixed.startTime=12;
        project.songs[0].tracks[1].clips.push_back(fixed);
        fixed.id="item-below";fixed.startTime=1;
        project.songs[0].tracks[2].clips={fixed};
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("region-lanes-drag",".json"));
        workspace.setSize(1366,768);
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");require(canvas,"Timeline canvas missing");
        auto state=[&] { return get(workspace.diagnostics(),"timeline"); };
        auto screenshot=[&](const char *name) {
            FileOutputStream output(directory.getChildFile(name));
            require(output.openedOk(),"Cannot create region overlap screenshot");
            output.setPosition(0);output.truncate();
            require(PNGImageFormat().writeImageToStream(workspace.createComponentSnapshot(workspace.getLocalBounds()),output),
                    "Cannot write region overlap screenshot");
        };
        auto checkGeometry=[&](int header,int lanes) {
            const auto diagnostics=state();
            require((int)get(diagnostics,"headerHeight")==header && (int)get(diagnostics,"regionLaneCount")==lanes,
                    "Timeline header did not follow root lane count");
            const ID itemIDs[]{"item-first","item-second","item-below"};
            for (size_t i=0;i<3;++i) {
                const auto item=findEntry(get(diagnostics,"visibleItems"),itemIDs[i]);
                auto *row=uiFeatureTests::find(workspace,"trackRow:"+text(project.songs[0].tracks[i].id));
                require(row,"Mixer track row missing");
                const auto rowBounds=workspace.getLocalArea(row,row->getLocalBounds());
                require(closeEnough((double)get(get(item,"bounds"),"y"),rowBounds.getY()+3),
                        "Timeline item and track mixer row have different vertical origins");
            }
            return diagnostics;
        };
        const auto before=checkGeometry(64,1);
        const auto firstItemBefore=get(findEntry(get(before,"visibleItems"),"item-first"),"bounds");
        const auto secondItemBefore=get(findEntry(get(before,"visibleItems"),"item-second"),"bounds");
        const auto belowBefore=get(findEntry(get(before,"visibleItems"),"item-below"),"bounds");
        const auto initialRegion=get(findEntry(get(before,"regions"),"second"),"bounds");
        const float offsetX=(float)(double)get(before,"x"),offsetY=(float)(double)get(before,"y");
        const float zoom=(float)(double)get(before,"zoom");
        const Point<float> origin{(float)(double)get(initialRegion,"x")-offsetX+5*zoom,
                                  (float)(double)get(initialRegion,"y")-offsetY+8};
        const Point<float> destination{origin.x-5*zoom,origin.y};
        const int modifiers=ModifierKeys::leftButtonModifier|ModifierKeys::shiftModifier;
        canvas->mouseDown(mouse(*canvas,origin,origin,modifiers));
        canvas->mouseDrag(mouse(*canvas,destination,origin,modifiers,true));
        const auto preview=checkGeometry(80,2);
        screenshot("region-overlap-preview.png");
        const auto previewRegion=findEntry(get(preview,"regions"),"second");
        require((int)get(previewRegion,"lane")==1 && closeEnough((double)get(previewRegion,"start"),10) && closeEnough((double)get(previewRegion,"end"),25),
                "Dragged region did not render in its overlapping lane before mouse release");
        require(str(previewRegion,"identifier")=="0st  02","Dragging a region changed its persisted header number");
        require(closeEnough((double)get(get(findEntry(get(preview,"visibleItems"),"item-first"),"bounds"),"y"),
                     (double)get(firstItemBefore,"y")+16),"Existing item did not move down with expanded header");
        require(closeEnough((double)get(get(findEntry(get(preview,"visibleItems"),"item-second"),"bounds"),"x"),
                     (double)get(secondItemBefore,"x")-5*zoom),"Region-owned item did not move in live preview");
        require((int)get(findEntry(get(preview,"visibleItems"),"collision"),"lane")==1 &&
                (double)get(get(findEntry(get(preview,"visibleItems"),"item-below"),"bounds"),"y")>
                (double)get(belowBefore,"y")+16,"Overlapping items did not create a live lane and move following tracks down");
        require(closeEnough(part(*session.song(),"second").startTime,15) && closeEnough(clip(*session.song(),"item-second").startTime,16),
                "Drag preview prematurely changed the session");
        struct CommitLayoutObserver : ComponentListener {
            std::function<void()> inspect;
            void componentMovedOrResized(Component &,bool,bool) override { inspect(); }
        } observer;
        bool collapsed=false;
        observer.inspect=[&]{ if ((int)get(state(),"headerHeight")<80) collapsed=true; };
        for(auto *child:workspace.getChildren()) child->addComponentListener(&observer);
        canvas->mouseUp(mouse(*canvas,destination,origin,ModifierKeys::shiftModifier,true));
        for(auto *child:workspace.getChildren()) child->removeComponentListener(&observer);
        require(!collapsed,"Release briefly collapsed the preview lane before committing the region");
        checkGeometry(80,2);
        screenshot("region-overlap-committed.png");
        require(closeEnough(part(*session.song(),"second").startTime,10) && closeEnough(clip(*session.song(),"item-second").startTime,11) &&
                closeEnough(marker(*session.song(),"cue").position,12),"Release did not commit the displayed region and owned contents");
        session.undo();checkGeometry(64,1);
        require(closeEnough(part(*session.song(),"second").startTime,15) && closeEnough(clip(*session.song(),"item-second").startTime,16) &&
                closeEnough(marker(*session.song(),"cue").position,17),"One Undo did not restore region, media and marker together");
        session.redo();checkGeometry(80,2);
        require(closeEnough(part(*session.song(),"second").startTime,10) && closeEnough(clip(*session.song(),"item-second").startTime,11),
                "One Redo did not restore the complete overlapping move");

        auto click=[&](Point<float> at) {
            canvas->mouseDown(mouse(*canvas,at,at,modifiers));
            canvas->mouseUp(mouse(*canvas,at,at,ModifierKeys::shiftModifier));
        };
        const auto after=state();
        const auto selected=get(findEntry(get(after,"regions"),"second"),"bounds");
        click({(float)(double)get(selected,"x")-(float)(double)get(after,"x")+2*zoom,
               (float)(double)get(selected,"y")-(float)(double)get(after,"y")+8});
        require(session.transport().regionId=="second" && closeEnough(session.transport().editPosition,10),
                "Click in second header lane selected the overlapping first region");
        // Marker, tempo and time-ruler hit targets all move down with the extra region lane.
        auto xAt=[&](double seconds) {return (float)(seconds*zoom-(double)get(state(),"horizontal"));};
        click({xAt(12)+4,37});
        require(closeEnough(session.transport().editPosition,12),"Ordinary marker hit target did not move below the region lanes");
        click({xAt(6)+4,53});
        require(closeEnough(session.transport().editPosition,6),"Tempo marker hit target did not follow the expanded header");
        click({xAt(4.2),76});
        require(closeEnough(session.transport().editPosition,4.2),"Time ruler did not seek at its shifted vertical position");
    });
}
}
