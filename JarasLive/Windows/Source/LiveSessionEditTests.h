#pragma once
#include "LiveItemResizeTests.h"
#include "NormalizationPanel.h"

namespace catlive::liveSessionEditTests {
using liveItemResizeTests::require;
inline void dispatch() {
    MSG message;
    while(PeekMessage(&message,nullptr,0,0,PM_REMOVE)) {
        TranslateMessage(&message);DispatchMessage(&message);
    }
    Thread::sleep(1);
}
struct Fixture {
    File folder;
    jaras::Project project;
    std::unique_ptr<Session> session=std::make_unique<Session>();
    AudioBuffer<float> block{2,480};
    explicit Fixture(const File &directory) : folder(directory.getNonexistentChildFile("live-session-edit","")),
                                             project(liveItemResizeTests::fixture(folder)) {
        project.songs.front().duration=600;
        auto &clip=project.songs.front().tracks.front().clips.front();clip.duration=600;clip.loopLength=1;
        liveItemResizeTests::initialise(*session,project,folder);
        session->command(jaras::CommandKind::editSeek,{},.1);
        session->command(jaras::CommandKind::play);
        session->command(jaras::CommandKind::subSeek,{},.3);
        session->command(jaras::CommandKind::subPlay);
        session->audio.render(block.getArrayOfWritePointers(),2,480);
        verify(.25f);
    }
    void verify(float left) {
        for(int n=0;n<block.getNumSamples();++n)
            require(std::abs(block.getSample(0,n)-left)<1e-5f &&
                    std::abs(block.getSample(1,n)-left*.5f)<1e-5f,
                    "Live session graph edit produced unexpected PCM or a silent gap");
    }
    void render(float left,bool playing=true) {
        const auto before=session->audio.state();
        session->audio.render(block.getArrayOfWritePointers(),2,480);
        verify(left);
        const auto after=session->audio.state();
        require(after.playing==playing && after.subPlaying==playing,
                "Live structural edit changed Play/Subplay state");
        if(before.playing==playing && before.subPlaying==playing)
            require(std::abs(after.position-before.position-(playing?.01:0))<1e-9 &&
                    std::abs(after.subPosition-before.subPosition-(playing?.01:0))<1e-9,
                    "Live structural edit reset or sought a playback head");
    }
    void wait(float oldLeft,float newLeft,bool playing=true) {
        const auto deadline=Time::getMillisecondCounterHiRes()+15000;
        while(session->preparingLiveAudio()&&Time::getMillisecondCounterHiRes()<deadline) {
            // No UI dispatch occurs inside this render; until the atomic commit,
            // the old graph must keep producing its original samples.
            render(oldLeft,playing);dispatch();
        }
        require(!session->preparingLiveAudio(),"Live session preparation did not complete");
        require(session->message.isEmpty(),"Live session graph preparation reported an error");
        render(newLeft,playing);
    }
    ID add(double volume) {
        const auto id=uuid();
        session->edit([&](auto &value) {
            auto track=value.songs.front().tracks.front();track.id=id;track.name="New live track";track.volume=volume;
            for(auto &clip:track.clips)clip.id=uuid();value.songs.front().tracks.push_back(track);
        });
        return id;
    }
};
template <typename Test> void registerTests(const File &directory,Test &test) {
    test("Recording mode and MIDI Patch changes preserve audio readers and Undo",[&] {
        Fixture fixture(directory); auto &session=*fixture.session;
        const auto graph=session.audio.preparationDiagnostics.getDynamicObject();
        session.editTrackSettings([](auto &project){auto &track=project.songs.front().tracks.front();track.recordingChannels=0;track.midiInput=6;track.midiChannel=12;});
        require(!session.preparingLiveAudio() && session.audio.preparationDiagnostics.getDynamicObject()==graph,"REC or MIDI Patch rebuilt the graph");
        require(session.song()->tracks.front().midiInput==6,"Sixth MIDI input was rejected"); fixture.render(.25f);
        session.undo();require(session.song()->tracks.front().midiInput!=6,"Undo did not restore MIDI Patch"); fixture.render(.25f);
        session.redo();require(session.song()->tracks.front().midiInput==6,"Redo lost the sixth MIDI slot");fixture.render(.25f);
    });
    test("Session structural edits and Undo/Redo prepare asynchronously while both audio heads continue",[&] {
        Fixture fixture(directory);auto &session=*fixture.session;
        fixture.add(.5);
        require(session.preparingLiveAudio()&&!session.busy,"Live structural edit blocked the workspace");
        fixture.wait(.25f,.375f);
        require(session.song()->tracks.size()==2,"Structural edit lost the inserted track");
        session.undo();require(session.preparingLiveAudio(),"Live structural Undo rebuilt synchronously");
        fixture.wait(.375f,.25f);require(session.song()->tracks.size()==1,"Undo lost the original graph");
        session.redo();fixture.wait(.25f,.375f);require(session.song()->tracks.size()==2,"Redo lost the inserted track");
        session.command(jaras::CommandKind::stopAll);
    });
    test("Track deletion and Undo retain both clocks and complete track data without JSON history",[&] {
        Fixture fixture(directory);auto &session=*fixture.session;
        const auto added=fixture.add(.5);fixture.wait(.25f,.375f);
        const auto before=session.song()->tracks.back();
        session.removeTrack(added);
        require(session.song()->tracks.size()==1 && !session.busy,"Track delete did not update immediately");
        fixture.wait(.375f,.25f);
        session.undo();fixture.wait(.25f,.375f);
        const auto &restored=session.song()->tracks.back();
        require(restored.id==before.id && restored.clips.front().id==before.clips.front().id && restored.volume==before.volume,"Undo lost deleted track data");
        session.redo();fixture.wait(.375f,.25f);
        session.command(jaras::CommandKind::stopAll);
    });
    test("Item gain and pan commit Undo and Redo preserve both heads and prepared readers",[&] {
        Fixture fixture(directory);auto &session=*fixture.session;
        const auto streams=session.audio.residentStreams();
        const auto commits=num(session.audio.streamDiagnostics(),"transportCommits");
        auto check=[&](float level) {
            require(!session.preparingLiveAudio(),"Item control edit rebuilt the audio graph");
            require(session.audio.residentStreams()==streams,"Item control edit replaced prepared readers");
            require(num(session.audio.streamDiagnostics(),"transportCommits")==commits,"Item control edit published a transport seek");
            fixture.render(level);
        };
        session.editItemControls([](auto &project) {project.songs.front().tracks.front().clips.front().gain=.5;});
        check(.125f);
        session.undo();check(.25f);
        session.redo();check(.125f);
        session.editItemControls([](auto &project) {project.songs.front().tracks.front().clips.front().pan=1;});
        session.audio.render(fixture.block.getArrayOfWritePointers(),2,480);
        require(fixture.block.getMagnitude(0,0,480)<1e-6f,"Item pan commit was not applied");
        session.undo();check(.125f);
        session.command(jaras::CommandKind::stopAll);
    });
    test("Timeline item moves and Undo Redo preserve main and Subplay clocks for audio video and text",[&] {
        const auto folder=directory.getNonexistentChildFile("live-item-moves","");
        auto project=liveItemResizeTests::fixture(folder);
        auto &song=project.songs.front();song.duration=601;
        song.tracks.front().clips.front().duration=600;song.tracks.front().clips.front().loopLength=1;
        const auto audioID=song.tracks.front().clips.front().id;
        jaras::Track video;video.id=uuid();video.role.id="video";video.name=jaras::fixedTrackName(video.role);
        jaras::AudioClip film;film.id=uuid();film.name="Video";film.startTime=10;film.duration=1;
        const auto videos=folder.getChildFile("Videos");require(videos.createDirectory().wasOk(),"Cannot create video fixture folder");
        const auto source=File(__FILE__).getParentDirectory().getSiblingFile("Tests").getChildFile("Fixtures/silent.mp4");
        require(source.copyFileTo(videos.getChildFile("silent.mp4")),"Cannot copy video fixture");
        film.audioFile=jaras::AudioFile{"Videos/silent.mp4",{}};video.clips={film};song.tracks.push_back(video);
        jaras::Track lyrics;lyrics.id=uuid();lyrics.role.id="teleprompt";lyrics.name=jaras::fixedTrackName(lyrics.role);
        jaras::AudioClip textItem;textItem.id=uuid();textItem.name="Lyrics";textItem.text="Lyrics";textItem.startTime=10;textItem.duration=1;
        lyrics.clips={textItem};song.tracks.push_back(lyrics);
        auto session=std::make_unique<Session>();liveItemResizeTests::initialise(*session,project,folder);
        session->command(jaras::CommandKind::editSeek,{},.1);session->command(jaras::CommandKind::play);
        session->command(jaras::CommandKind::subSeek,{},.3);session->command(jaras::CommandKind::subPlay);
        AudioBuffer<float> block(2,480);session->audio.render(block.getArrayOfWritePointers(),2,480);
        const auto repositions=num(session->audio.streamDiagnostics(),"transportRepositions");
        const auto commits=num(session->audio.streamDiagnostics(),"transportCommits");
        auto check=[&](const std::function<void()> &edit) {
            const auto before=session->audio.state();edit();
            require(!session->preparingLiveAudio(),"Moving an existing item rebuilt unrelated readers");
            require(num(session->audio.streamDiagnostics(),"transportRepositions")==repositions &&
                    num(session->audio.streamDiagnostics(),"transportCommits")==commits,
                    "Releasing an item resent a transport position instead of preserving the running clocks");
            liveItemResizeTests::assertClocks(before,session->audio.state());
            session->audio.render(block.getArrayOfWritePointers(),2,480);
            const auto after=session->audio.state();
            require(after.playing && after.subPlaying && std::abs(after.position-before.position-.01)<1e-9 &&
                    std::abs(after.subPosition-before.subPosition-.01)<1e-9,"Moving an item rewound a playing head");
            for(int frame=0;frame<480;++frame)
                require(std::abs(block.getSample(0,frame)-.25f)<1e-5f && std::abs(block.getSample(1,frame)-.125f)<1e-5f,
                        "An unrelated item edit interrupted the playing audio");
        };
        for(const auto &id:{audioID,film.id,textItem.id}) {
            check([&]{session->editTimeline([&](auto &value){
                for(auto &track:value.songs.front().tracks)for(auto &clip:track.clips)if(clip.id==id)clip.startTime+=.02;
            });});
            check([&]{session->undo();});check([&]{session->redo();});
        }
        session->command(jaras::CommandKind::stopAll);
    });
    test("Playlist switches removals Stop and Auto policies preserve both running audio heads through Undo Redo",[&] {
        Fixture fixture(directory);auto &session=*fixture.session;
        session.command(jaras::CommandKind::stopAll);
        const ID first=uuid(),second=uuid(),listA=uuid(),listB=uuid();
        session.editTimeline([&](auto &project){
            auto &song=project.songs.front();song.parts={{first,"First",0,300},{second,"Second",300,600}};
            jaras::RegionSetlist state;
            state.playlists={{listA,"A",song.id,{first,second}},{listB,"B",song.id,{second,first}}};
            state.selectedId=listA;project.regionSetlist=state;
        });
        session.command(jaras::CommandKind::editSeek,{},.1);session.command(jaras::CommandKind::play);
        session.command(jaras::CommandKind::subSeek,{},.3);session.command(jaras::CommandKind::subPlay);
        session.audio.render(fixture.block.getArrayOfWritePointers(),2,480);fixture.verify(.25f);
        const auto repositions=num(session.audio.streamDiagnostics(),"transportRepositions");
        const auto commits=num(session.audio.streamDiagnostics(),"transportCommits");
        auto check=[&](const std::function<void()> &change) {
            const auto before=session.audio.state();change();
            require(!session.preparingLiveAudio(),"Playlist policy rebuilt the playing graph");
            require(num(session.audio.streamDiagnostics(),"transportRepositions")==repositions &&
                    num(session.audio.streamDiagnostics(),"transportCommits")==commits,
                    "Playlist edit or Undo replayed a sampled transport position");
            liveItemResizeTests::assertClocks(before,session.audio.state());fixture.render(.25f);
        };
        check([&]{auto state=*session.project().regionSetlist;state.selectedId=listB;session.configureSetlist(state);});
        check([&]{session.undo();});check([&]{session.redo();});
        check([&]{auto state=*session.project().regionSetlist;state.playlists[1].regionIds.erase(state.playlists[1].regionIds.begin());session.configureSetlist(state);});
        check([&]{session.undo();});check([&]{session.redo();});
        for(bool enabled:{true,false}) {
            check([&]{auto state=*session.project().regionSetlist;state.stopAtRegionEnd=enabled;session.configureSetlist(state);});
            check([&]{session.undo();});check([&]{session.redo();});
        }
        check([&]{auto state=*session.project().regionSetlist;state.autoAdvance=true;session.configureSetlist(state);});
        check([&]{session.undo();});check([&]{session.redo();});
        session.command(jaras::CommandKind::stopAll);
    });
    test("Normalization panel applies measured PCM gain immediately and Undo Redo retain both transport clocks",[&] {
        const auto folder=directory.getNonexistentChildFile("normalization-live-controls","");
        auto project=liveItemResizeTests::fixture(folder);auto &clip=project.songs.front().tracks.front().clips.front();
        clip.gain=.5;const auto id=clip.id;
        auto session=std::make_unique<Session>();liveItemResizeTests::initialise(*session,project,folder);
        session->command(jaras::CommandKind::editSeek,{},.1);session->command(jaras::CommandKind::play);
        session->command(jaras::CommandKind::subSeek,{},.3);session->command(jaras::CommandKind::subPlay);
        AudioBuffer<float> block(2,480);session->audio.render(block.getArrayOfWritePointers(),2,480);
        const auto repositions=num(session->audio.streamDiagnostics(),"transportRepositions");
        const auto commits=num(session->audio.streamDiagnostics(),"transportCommits");
        const auto streams=session->audio.residentStreams();
        Appearance appearance(folder.getChildFile("appearance.json"));
        NormalizationPanel panel(*session,appearance,id);panel.setSize(360,250);
        auto *level=dynamic_cast<TextEditor*>(panel.findChildWithID("normalizationTarget"));
        auto *apply=dynamic_cast<Button*>(panel.findChildWithID("normalizationApply"));
        require(level && apply && apply->onClick,"Normalization controls are inaccessible");
        level->setText("-12");const auto before=session->audio.state();apply->onClick();
        const auto deadline=Time::getMillisecondCounterHiRes()+10000;
        while(!session->song()->tracks.front().clips.front().normalizationGain && Time::getMillisecondCounterHiRes()<deadline)dispatch();
        const auto expected=std::pow(10.,-12./20.)/.125;
        const auto gain=session->song()->tracks.front().clips.front().normalizationGain.value_or(1);
        require(std::abs(gain-expected)<1e-5,"Analysis finished without applying the measured normalization gain");
        require(std::abs((double)appearance.value("jaras.normalization.target.Peak",0)+12)<1e-9,"Normalization target was not saved");
        liveItemResizeTests::assertClocks(before,session->audio.state());
        auto render=[&](double expectedGain) {
            require(!session->preparingLiveAudio() && session->audio.residentStreams()==streams,
                    "Normalization replaced live readers instead of updating gain");
            require(num(session->audio.streamDiagnostics(),"transportRepositions")==repositions &&
                    num(session->audio.streamDiagnostics(),"transportCommits")==commits,"Normalization sought a transport head");
            session->audio.render(block.getArrayOfWritePointers(),2,480);
            for(int n=0;n<480;++n)require(std::abs(block.getSample(0,n)-.125*expectedGain)<1e-5 &&
                    std::abs(block.getSample(1,n)-.0625*expectedGain)<1e-5,"Normalization model gain did not reach the actual audio");
        };
        render(expected);session->undo();render(1);session->redo();render(expected);
        const auto restored=ProjectCodec::decode(session->snapshot());
        require(std::abs(restored.songs.front().tracks.front().clips.front().normalizationGain.value_or(1)-expected)<1e-5,
                "Normalized gain was lost from the saved document");
        session->command(jaras::CommandKind::stopAll);
    });
    test("Normalization processes the entire selected batch with visible progress and one Undo",[&] {
        const auto folder=directory.getNonexistentChildFile("normalization-selection","");
        auto project=liveItemResizeTests::fixture(folder);
        project.songs.front().duration=11;
        auto &track=project.songs.front().tracks.front();
        auto second=track.clips.front();second.id=uuid();second.startTime=5;
        auto third=second;third.id=uuid();third.startTime=10;
        track.clips.push_back(second);track.clips.push_back(third);
        const auto first=track.clips.front().id;
        auto session=std::make_unique<Session>();liveItemResizeTests::initialise(*session,project,folder);
        Appearance appearance(folder.getChildFile("appearance.json"));
        NormalizationPanel panel(*session,appearance,std::set<ID>{first,second.id});panel.setSize(380,260);
        auto *level=dynamic_cast<TextEditor*>(panel.findChildWithID("normalizationTarget"));
        auto *apply=dynamic_cast<Button*>(panel.findChildWithID("normalizationApply"));
        auto *progress=panel.findChildWithID("normalizationProgress");
        require(level&&apply&&progress,"Batch normalization controls are missing");
        level->setText("-6");apply->onClick();
        require(progress->isVisible()&&!apply->isEnabled(),"Normalization has no progress feedback while analysing");
        const auto deadline=Time::getMillisecondCounterHiRes()+10000;
        while(!session->song()->tracks.front().clips[1].normalizationGain&&Time::getMillisecondCounterHiRes()<deadline)dispatch();
        const auto expected=std::pow(10.,-6./20.)/.125;
        const auto verify=[&](bool normalized){
            const auto &items=session->song()->tracks.front().clips;
            for(int i=0;i<2;++i)require(std::abs(items[i].normalizationGain.value_or(1)-(normalized?expected:1))<1e-5,"Batch normalization skipped a selected item");
            require(!items[2].normalizationGain,"Batch normalization changed an unselected item");
        };
        verify(true);session->undo();verify(false);session->redo();verify(true);
    });
    test("Coalesced Session edits publish only the latest graph without stopping either transport",[&] {
        Fixture fixture(directory);auto &session=*fixture.session;
        fixture.add(.5);fixture.add(.25);
        require(session.song()->tracks.size()==3&&session.preparingLiveAudio(),"Consecutive live edits were discarded");
        fixture.wait(.25f,.4375f);
        for(int i=0;i<12;++i){dispatch();fixture.render(.4375f);}
        require(session.song()->tracks.size()==3,"An obsolete preparation replaced the latest project");
        session.command(jaras::CommandKind::stopAll);
    });
    test("Stop during Session graph preparation stays stopped when the prepared graph commits",[&] {
        Fixture fixture(directory);auto &session=*fixture.session;
        fixture.add(.5);session.command(jaras::CommandKind::stopAll);
        fixture.render(0,false);
        const auto stopped=session.audio.state();
        fixture.wait(0,0,false);
        liveItemResizeTests::assertClocks(stopped,session.audio.state());
        require(!session.transport().playing&&!session.transport().subPlay.playing,
                "Prepared structural graph restarted a stopped transport");
    });
    test("Replacing a project cancels a pending live graph and cannot restore its obsolete audio",[&] {
        Fixture fixture(directory);auto &session=*fixture.session;
        fixture.add(.5);
        auto replacement=fixture.project;replacement.id=uuid();replacement.name="Replacement";
        replacement.songs.front().id=uuid();replacement.songs.front().tracks.clear();
        const auto file=fixture.folder.getChildFile("Replacement.jl");
        ProjectCodec::write(file,ProjectCodec::encode(replacement));
        bool completed=false;String error;
        session.loadAsync(file,{}, {},[&](String value){error=value;completed=true;});
        const auto deadline=Time::getMillisecondCounterHiRes()+15000;
        while(!completed&&Time::getMillisecondCounterHiRes()<deadline) {
            // Replacement prepares on the same queue. Its completion guarantees
            // older live preparation jobs have reached their commit/cancel path.
            session.audio.render(fixture.block.getArrayOfWritePointers(),2,480);dispatch();
        }
        require(completed&&error.isEmpty()&&!session.busy&&!session.preparingLiveAudio(),
                "Project replacement did not finish or left an obsolete live graph pending");
        require(session.project().id==replacement.id&&session.song()->tracks.empty(),
                "Stale live preparation replaced the new project");
        fixture.render(0,false);
        session.command(jaras::CommandKind::play);
        for(int i=0;i<12;++i){dispatch();session.audio.render(fixture.block.getArrayOfWritePointers(),2,480);fixture.verify(0);}
        require(session.project().id==replacement.id&&session.audio.state().playing,
                "Obsolete prepared audio reappeared after a replacement project started");
        session.command(jaras::CommandKind::stopAll);
    });
}
} // namespace catlive::liveSessionEditTests
