#pragma once
#include "FloatingControlTests.h"
namespace catlive::saveAsyncTests {
using floatingControlTests::require;
inline void finish(Session &session) {
    const auto deadline = Time::getMillisecondCounterHiRes() + 20000;
    while (session.isSaving() && Time::getMillisecondCounterHiRes() < deadline)
        floatingControlTests::pump();
    require(!session.isSaving(), "Asynchronous project save did not finish");
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Async Save preserves edits made during persistence and coalesces repeated Save", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));
        session.audio.setOffline(true);
        const auto target=directory.getNonexistentChildFile("async-save", "").getChildFile("Show.jl");
        session.save(target);
        session.editTimeline([](jaras::Project &p){p.name="Snapshot being saved";});
        int completions=0; String error; bool onMessageThread=true;
        auto completed=[&](String failure) {
            error=failure; ++completions;
            onMessageThread=onMessageThread && MessageManager::getInstance()->isThisTheMessageThread();
        };
        int statusUpdates=0, fullRefreshes=0;
        session.tick=[&]{++statusUpdates;}; session.changed=[&]{++fullRefreshes;};
        const auto beforeSaveRevision=session.revision;
        session.saveAsync(target, completed);
        require(session.isSaving() && !session.busy && completions==0 &&
                    session.revision==beforeSaveRevision && statusUpdates>0 && fullRefreshes==0,
                "Regular Save blocked editing, rebuilt the workspace or completed synchronously on the UI thread");
        session.saveAsync(target, completed);
        session.waitForSave(completed);
        session.editTimeline([](jaras::Project &p){p.name="Edited while saving";});
        finish(session);
        require(error.isEmpty() && completions==3 && onMessageThread,
                "Duplicate Save or close-wait completion was lost or called off the UI thread");
        require(ProjectCodec::decode(ProjectCodec::read(target)).name=="Snapshot being saved" &&
                    session.project().name=="Edited while saving" && session.dirty,
                "Save completion overwrote a newer edit or incorrectly cleared its dirty state");
        const auto beforeSecondRevision=session.revision; const auto beforeRefreshes=fullRefreshes;
        session.saveAsync(target, completed); finish(session);
        require(error.isEmpty() && completions==4 && !session.dirty && session.revision==beforeSecondRevision &&
                    fullRefreshes==beforeRefreshes && ProjectCodec::decode(ProjectCodec::read(target)).name=="Edited while saving",
                "The next Save did not persist the edit, clear the indicator or avoid a workspace rebuild");
        session.tick={}; session.changed={};
    });
    test("Async Save As allows transport and mixer while keeping media edits locked", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture())); session.audio.setOffline(true);
        const auto source=directory.getNonexistentChildFile("async-save-controls-source", "").getChildFile("Show.jl");
        const auto target=directory.getNonexistentChildFile("async-save-controls-target", "").getChildFile("Copy.jl");
        session.save(source);
        const auto track=session.song()->tracks[0].id;
        session.command(jaras::CommandKind::play); require(session.transport().playing,"Transport fixture did not start");
        String error; session.saveAsync(target,[&](String failure){error=failure;});
        require(session.busy && session.isSaving(),"Save As fixture was not pending");
        session.command(jaras::CommandKind::pause); require(!session.transport().playing,"Save As blocked Pause");
        session.command(jaras::CommandKind::play); require(session.transport().playing,"Save As blocked Play");
        session.mixerCommand(jaras::CommandKind::mute,track,{});
        session.command(jaras::CommandKind::volume,track,.4);
        session.command(jaras::CommandKind::stopAll);
        const auto name=session.project().name;
        session.editTimeline([](auto &project){project.name="Forbidden media edit";});
        require(!session.transport().playing && session.song()->tracks[0].mute &&
                    std::abs(session.song()->tracks[0].volume-.4)<1e-9 && session.project().name==name,
                "Save As blocked Stop/Mute/fader or allowed a structural edit during copying");
        finish(session);
        const auto saved=ProjectCodec::decode(ProjectCodec::read(target));
        require(error.isEmpty() && session.dirty && session.song()->tracks[0].mute && !saved.songs[0].tracks[0].mute,
                "Save As completion overwrote newer mixer controls or cleared their dirty flag");
        session.busy=true;
        session.command(jaras::CommandKind::mute,track);
        session.mixerCommand(jaras::CommandKind::mute,track,{});
        require(session.song()->tracks[0].mute,"The save exception incorrectly bypassed another busy operation");
        session.busy=false;
    });
    test("Async Save waits before reopening the same document", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture())); session.audio.setOffline(true);
        const auto target=directory.getNonexistentChildFile("async-save-reopen", "").getChildFile("Show.jl");
        session.save(target);
        session.editTimeline([](auto &project){project.name="Newest persisted version";});
        String saveError, loadError; bool loaded=false;
        session.saveAsync(target,[&](String error){saveError=error;});
        session.loadAsync(target,{}, {},[&](String error){loadError=error;loaded=true;});
        require(session.isSaving() && !loaded,"Reopen did not wait for the pending Save");
        const auto deadline=Time::getMillisecondCounterHiRes()+20000;
        while(!loaded && Time::getMillisecondCounterHiRes()<deadline) floatingControlTests::pump();
        require(loaded && saveError.isEmpty() && loadError.isEmpty() && !session.dirty &&
                    session.project().name=="Newest persisted version" && session.document==target,
                "Reopening the pending Save loaded stale contents or failed to finish");
    });
    test("Async Save As copies media and retains the original document after destination failure", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(floatingControlTests::fixture()));
        session.audio.setOffline(true);
        const auto source=directory.getNonexistentChildFile("async-save-as-source", "").getChildFile("Show.jl");
        session.save(source);
        const auto audio=source.getParentDirectory().getChildFile("Audio/take.wav");
        audio.getParentDirectory().createDirectory(); require(audio.replaceWithText("media copy fixture"), "Could not write media fixture");
        session.edit([](jaras::Project &p){
            jaras::AudioClip clip; clip.id=uuid(); clip.name="Take"; clip.duration=1;
            clip.audioFile=jaras::AudioFile{"Audio/take.wav",{}};
            p.songs[0].tracks[0].clips={clip};
        },false);
        const auto destination=directory.getNonexistentChildFile("async-save-as-target", "").getChildFile("Copy.jl");
        destination.getParentDirectory().createDirectory();
        const auto occupied=destination.getSiblingFile("Other.jl");
        ProjectCodec::write(occupied,ProjectCodec::encode(floatingControlTests::fixture()));
        String error; int completed=0;
        session.saveAsync(destination,[&](String failure){error=failure;++completed;});
        require(session.busy && session.document==source, "Save As changed the media root before the copy finished");
        finish(session);
        require(error.isNotEmpty() && completed==1 && !session.busy && session.dirty && session.document==source &&
                    !destination.existsAsFile() && occupied.existsAsFile(),
                "Failed Save As discarded edits or replaced an unrelated project");
        require(occupied.deleteFile(), "Could not reset Save As fixture");
        session.saveAsync(destination,[&](String failure){error=failure;++completed;}); finish(session);
        require(error.isEmpty() && completed==2 && !session.busy && !session.dirty && session.document==destination &&
                    session.mediaDirectory==destination.getParentDirectory() && source.existsAsFile() &&
                    destination.getParentDirectory().getChildFile("Audio/take.wav").loadFileAsString()==audio.loadFileAsString(),
                "Save As did not copy media, preserve the source and commit the new document together");
    });
}
}
