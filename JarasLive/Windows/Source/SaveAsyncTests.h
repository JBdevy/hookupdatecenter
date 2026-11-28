#pragma once
#include "FloatingControlTests.h"
#include "ProjectBackups.h"
#include "MediaImportTests.h"
namespace catlive::saveAsyncTests {
using floatingControlTests::require;
inline void finish(Session &session) {
    const auto deadline = Time::getMillisecondCounterHiRes() + 20000;
    while (session.isSaving() && Time::getMillisecondCounterHiRes() < deadline)
        floatingControlTests::pump();
    require(!session.isSaving(), "Asynchronous project save did not finish");
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Project backups retain ten encrypted snapshots and preserve other documents", [&] {
        const auto root=directory.getNonexistentChildFile("project-backups", "");
        const auto target=root.getChildFile(String::fromUTF8("Canção.jl"));
        auto project=floatingControlTests::fixture();
        const auto other=root.getChildFile("backups/Other - 03-11-2026 - 12-00.bkjl");
        other.getParentDirectory().createDirectory();require(other.replaceWithText("unrelated"),"Could not write unrelated backup");
        for (int version=1;version<=13;++version) {
            project.name="Save "+std::to_string(version);
            ProjectCodec::saveWithBackup(target,ProjectCodec::encode(project));
            const auto backups=projectBackups::files(target);
            require(backups.size()==size_t(std::min(version,10)),"Save omitted a backup or exceeded retention");
            MemoryBlock snapshot,document;
            require(backups.back().loadFileAsData(snapshot)&&target.loadFileAsData(document)&&snapshot==document,
                    "Backup is not the exact encrypted document that was saved");
            require(!JSON::parse(target.loadFileAsString()).isObject(),"Backup document is unencrypted");
        }
        const auto backups=projectBackups::files(target);
        for(size_t i=0;i<backups.size();++i)
            require(ProjectCodec::decode(ProjectCodec::read(backups[i])).name=="Save "+std::to_string(i+4),
                    "Retention removed a recent snapshot or reordered same-minute saves");
        require(other.loadFileAsString()=="unrelated","Saving pruned another document's backup");
        require(projectBackups::belongsTo(root.getChildFile(String::fromUTF8("Canção - 001.bkjl")),target)&&
                projectBackups::belongsTo(root.getChildFile(String::fromUTF8("Canção--00001793700000000000.bkjl")),target),
                "Legacy Mac backup names were not recognized");
    });
    test("Project backups roll back failed saves and preserve the previous document", [&] {
        const auto root=directory.getNonexistentChildFile("project-backup-failure", "");
        const auto target=root.getChildFile("Show.jl");
        auto project=floatingControlTests::fixture();
        ProjectCodec::saveWithBackup(target,ProjectCodec::encode(project));
        MemoryBlock original;require(target.loadFileAsData(original),"Could not read saved fixture");
        const auto previous=projectBackups::files(target);
        HANDLE locked=CreateFileW(target.getFullPathName().toWideCharPointer(),GENERIC_READ,FILE_SHARE_READ,
                                  nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
        require(locked!=INVALID_HANDLE_VALUE,"Could not lock destination fixture");
        bool failed=false;project.name="Failed replacement";
        try {ProjectCodec::saveWithBackup(target,ProjectCodec::encode(project));}catch(const std::exception &){failed=true;}
        CloseHandle(locked);
        MemoryBlock remaining;target.loadFileAsData(remaining);
        require(failed&&remaining==original&&projectBackups::files(target)==previous,
                "Failed replacement changed the document or left a false successful backup");
        const auto blockedRoot=directory.getNonexistentChildFile("project-backup-blocked", "");
        const auto blocked=blockedRoot.getChildFile("Show.jl");
        ProjectCodec::write(blocked,ProjectCodec::encode(project));
        const auto blocker=blockedRoot.getChildFile("backups");require(blocker.replaceWithText("keep"),"Could not block backup folder");
        MemoryBlock before;blocked.loadFileAsData(before);failed=false;project.name="Not saved";
        try {ProjectCodec::saveWithBackup(blocked,ProjectCodec::encode(project));}catch(const std::exception &){failed=true;}
        remaining.reset();blocked.loadFileAsData(remaining);
        require(failed&&remaining==before&&blocker.loadFileAsString()=="keep","A failed backup still overwrote the project");
    });
    test("Project backups are cleared by Advanced cleanup and restart on the next Save", [&] {
        const auto root=directory.getNonexistentChildFile("project-backup-cleanup", "");
        const auto target=root.getChildFile("Show.jl");
        auto project=floatingControlTests::fixture();
        const auto discarded=mediaImportTests::source(root.getChildFile("Stems"),"discarded.wav",4800);
        jaras::AudioClip clip;clip.id=uuid();clip.name="Discarded";clip.duration=.1;
        clip.audioFile=jaras::AudioFile{"Stems/discarded.wav",{}};
        project.songs[0].tracks[0].clips={clip};
        ProjectCodec::saveWithBackup(target,ProjectCodec::encode(project));
        project.songs[0].tracks[0].clips.clear();
        ProjectCodec::saveWithBackup(target,ProjectCodec::encode(project));
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.audio.setOffline(true);
        session.load(target);
        bool completed=false;String error;
        session.cleanTimelineMedia([&](String failure, bool){error=failure;completed=true;});
        const auto deadline=Time::getMillisecondCounterHiRes()+20000;
        while(session.busy&&Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
        require(completed&&error.isEmpty()&&projectBackups::files(target).empty()&&!discarded.exists(),
                "Advanced cleanup left backups or their discarded media behind");
        session.save(target);
        const auto backups=projectBackups::files(target);
        require(backups.size()==1&&ProjectCodec::decode(ProjectCodec::read(backups.front())).songs[0].tracks[0].clips.empty(),
                "The next Save did not start clean backup history after Advanced cleanup");
    });
    test("Project backups reopen with independent media and save without overwriting history", [&] {
        const auto root=directory.getNonexistentChildFile("project-backup-restore", "");
        const auto target=root.getChildFile("Show.jl");
        auto project=floatingControlTests::fixture();
        const auto media=mediaImportTests::source(root.getChildFile("Stems"),"take.wav",4800);
        jaras::AudioClip clip;clip.id=uuid();clip.name="Take";clip.duration=.1;clip.audioFile=jaras::AudioFile{"Stems/take.wav",{}};
        project.songs[0].tracks[0].clips={clip};
        ProjectCodec::saveWithBackup(target,ProjectCodec::encode(project));
        const auto backup=projectBackups::files(target).back();
        MemoryBlock original;target.loadFileAsData(original);
        Session session;session.inspection=true;session.audio.prepareOffline(48000);session.audio.setOffline(true);
        String error;bool completed=false,missing=false;
        session.loadAsync(backup,{}, {},[&](String failure){error=failure;completed=true;},[&](StringArray){missing=true;});
        const auto deadline=Time::getMillisecondCounterHiRes()+20000;
        while(session.busy&&Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
        require(!missing&&completed&&error.isEmpty()&&session.document.hasFileExtension("jl")&&
                    session.mediaDirectory!=root&&session.mediaDirectory.getParentDirectory()==root.getParentDirectory(),
                "Opening a backup did not create a separate recovered project");
        require(session.mediaDirectory.getChildFile("Stems/take.wav").hasIdenticalContentTo(media),"Recovered media was missing or changed");
        session.save(session.document);
        MemoryBlock after;target.loadFileAsData(after);
        require(original==after&&backup.existsAsFile()&&projectBackups::files(session.document).size()==1,
                "Saving the recovery overwrote the original document or backup history");
    });
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
        const auto backups=projectBackups::files(target);
        require(backups.size()==3&&ProjectCodec::decode(ProjectCodec::read(backups[1])).name=="Snapshot being saved"&&
                    ProjectCodec::decode(ProjectCodec::read(backups[2])).name=="Edited while saving",
                "Async Save backups lost snapshot isolation or duplicated coalesced saves");
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
    test("Untitled Save As preserves original stem names, colliding sources and completed progress", [&] {
        const auto folder = directory.getNonexistentChildFile("untitled-save", "");
        const auto name = String::fromUTF8("Percussão ao vivo.WAV");
        const auto first = mediaImportTests::source(folder.getChildFile("one"), name, 800);
        const auto second = mediaImportTests::source(folder.getChildFile("two"), name, 1600);
        Session session;
        session.temporarySession = std::make_unique<TemporaryProjectSession>(folder);
        const auto scratch = session.temporarySession->directory;
        mediaImportTests::initialise(session, scratch);
        session.save(scratch.getChildFile("Temporary.jl"));
        require(session.suggestedSaveName() == "Untitled", "A temporary folder supplied the suggested project name");
        session.importAudio({first, second}, 0);
        mediaImportTests::wait(session);
        require(session.song()->tracks.size() == 2, "Two input files were not imported");
        require(session.song()->tracks[0].clips[0].name == utf8(first.getFileNameWithoutExtension()) &&
                session.song()->tracks[1].clips[0].name == utf8(first.getFileNameWithoutExtension() + " 001"),
                "Dragging duplicate filenames did not number the grid items");
        const auto path1 = session.song()->tracks[0].clips[0].audioFile->path;
        const auto path2 = session.song()->tracks[1].clips[0].audioFile->path;
        require(path1 == utf8("Stems/" + name) && path2 != path1 &&
                text(path2).startsWith("Stems/" + second.getFileNameWithoutExtension()) && text(path2).endsWith(".WAV"),
                "Original media names, extensions or collision suffixes were lost");
        const auto target = folder.getChildFile("saved/Untitled.jl");
        String error = "pending";
        session.saveAsync(target, [&](String failure) { error = failure; });
        require(session.saveProgress().has_value(), "Save did not expose progress when started");
        finish(session);
        require(error.isEmpty() && !session.saveProgress() && session.document == target, "Save completion was published incorrectly");
        session.load(target);
        require(session.project().name == "Untitled" && session.song()->tracks.size() == 2, "Saved project did not reopen");
        for (int i = 0; i < 2; ++i) {
            const auto &path = session.song()->tracks[size_t(i)].clips[0].audioFile->path;
            require(path == (i == 0 ? path1 : path2), "Reopen changed a saved media path");
            mediaImportTests::unchangedMedia(i == 0 ? first : second, ProjectCodec::resolveMedia(target.getParentDirectory(), path));
        }
    });
    test("Async Save shows byte progress and recovers legacy temporary stem filenames", [&] {
        Session session; const auto root=directory.getNonexistentChildFile("legacy-progress", "");
        session.temporarySession=std::make_unique<TemporaryProjectSession>(root);
        const auto scratch=session.temporarySession->directory;
        mediaImportTests::initialise(session,scratch);
        session.save(scratch.getChildFile("Temporary.jl"));
        const auto id=uuid();
        const auto source=scratch.getChildFile("Stems/"+text(id)+".wav");
        source.getParentDirectory().createDirectory();
        {
            FileOutputStream stream(source);
            require(stream.openedOk() && stream.setPosition(48*1024*1024) && stream.writeByte(5), "Could not create copy fixture");
        }
        session.edit([&](jaras::Project &p) {
            jaras::Track track; track.id=uuid(); track.role.id="other";
            jaras::AudioClip clip; clip.id=id; clip.name="Guitarra base"; clip.duration=1;
            clip.audioFile=jaras::AudioFile{utf8("Stems/"+text(id)+".wav"),{}};
            track.clips={clip};p.songs[0].tracks={track};
        },false);
        const auto doc=root.getChildFile("Saved/Show.jl");
        Auth auth; Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,root.getChildFile("layout.json"));
        workspace.setSize(1280,800);workspace.projectOpened(false);
        String error="pending"; session.saveAsync(doc,[&](String failure){error=failure;});
        auto *indicator=workspace.findChildWithID("project-save-progress");
        auto* saveButton=uiFeatureTests::find(workspace,"save");
        require(indicator && saveButton && indicator->isVisible() && indicator->getWidth()>80 &&
                indicator->getHeight() <= 5 && indicator->getY() >= saveButton->getBottom() &&
                indicator->getY() < saveButton->getBottom()+16 && !indicator->isOnDesktop() &&
                !indicator->hitTest(1,1) && !indicator->getWantsKeyboardFocus(),
                "Saving must use the transport rail below the buttons without a floating panel");
        double last=0; bool advanced=false;
        const auto deadline=Time::getMillisecondCounterHiRes()+15000;
        while(Time::getMillisecondCounterHiRes()<deadline) {
            const auto state=session.saveProgress(); if(!state || state->phase==Session::SaveProgress::Phase::writing) break;
            if(state->phase==Session::SaveProgress::Phase::copying) {
                require(state->filename=="Guitarra base.wav" && state->fileIndex==1 && state->fileCount==1 &&
                        state->fraction>=last && state->fraction<1,"File copy showed invalid progress");
                advanced|=state->fraction>0;
                last=state->fraction;
            }
            Thread::yield();
        }
        finish(session);
        require(advanced && error.isEmpty() && !workspace.findChildWithID("project-save-progress"),"The save bar failed to advance or dismiss");
        const auto disk=ProjectCodec::decode(ProjectCodec::read(doc));
        require(session.song()->tracks[0].clips[0].audioFile->path=="Stems/Guitarra base.wav" &&
                disk.songs[0].tracks[0].clips[0].audioFile->path=="Stems/Guitarra base.wav" &&
                doc.getSiblingFile("Stems/Guitarra base.wav").getSize()==source.getSize(),"Legacy stem did not survive promotion");
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
