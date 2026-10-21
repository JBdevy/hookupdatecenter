#pragma once
#include "LiveItemResizeTests.h"

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
