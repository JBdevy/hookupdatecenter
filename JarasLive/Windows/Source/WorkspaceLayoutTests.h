#pragma once
#include "Workspace.h"
#include "FloatingControlTests.h"
#include "ProjectDeletionPanel.h"
namespace catlive {
struct WorkspaceLayoutTests {
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
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        Auth auth;Lighting lighting(session);Workspace w(session,auth,lighting,false,directory.getNonexistentChildFile("track-tail",".json"));w.setSize(1366,900);w.projectOpened(false);
        require(w.tracksContent.getHeight()-w.rowTop((int)tracks.size())==w.trackHeight*2,"Empty track tail differs from Mac's two rows");
        const int offset=w.tracksContent.getHeight()-w.tracksViewport.getViewHeight();
        w.verticalOffset=offset;w.tracksViewport.setViewPosition(0,offset);
        w.addStandardTrackAtEnd();w.rebuild();
        require(session.song()->tracks.size()==31,"Double-click track command did not append a track");
        require(w.verticalOffset==offset&&w.tracksViewport.getViewPositionY()==offset,"Appending a track jumped to the top");
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
    test("Deleting another recent project during playback preserves the current dirty project and audio clock",[&]{WorkspaceLayoutTests::deleteRecentWhilePlaying(directory);});
    test("Item context unifies the full selection per track with audio, MIDI, result selection and Undo; LR swap preserves unselected items",[&]{WorkspaceLayoutTests::unifyItems(directory);});
    test("Generated MIDI and text items advance edit cursor without seeking playback",[&]{WorkspaceLayoutTests::generatedItems(directory);});
    test("Empty track tail matches Mac and appending preserves vertical scroll",[&]{WorkspaceLayoutTests::trackTail(directory);});
    test("Lyrics and chord editors retain visible projections, drafts and undo",[&]{WorkspaceLayoutTests::textEditor(directory);});
    test("Panel layout survives new workspaces and tab switches without changing projects; navigation and Video toggle stay independent",[&]{WorkspaceLayoutTests::run(directory);});
}
}
}
