#pragma once
#include "FrontendBridge.h"
#include "FloatingControlTests.h"
#include "FrontendPresentation.h"
#include "FXSchema.h"

namespace catlive::frontendBridgeTests {
template<class Test, class Require>
void run(Test test, Require require, const File &directory) {
    test("Native frontend display projection excludes plugin state and bounds MIDI previews", [&] {
        auto project=Session::makeEmptyProject("Projection");
        jaras::Track track;track.id="projection-track";track.name="Audio";track.fxJSON=std::string(1000000,'x');
        jaras::AudioClip item;item.id="projection-item";item.name="MIDI";item.duration=10;item.fxJSON=track.fxJSON;
        item.waveform.resize(100000,1);item.midi.emplace();
        for(int i=0;i<5000;++i){jaras::MIDINote note;note.start=i*.1;item.midi->notes.push_back(note);}
        track.clips.push_back(item);project.songs.front().tracks.push_back(track);project.masterFXJSON=track.fxJSON;
        const auto rendered=frontendPresentation::song(project.songs.front());
        const auto shown=get(list(get(rendered,"tracks"))[0],"clips");
        const auto visible=list(shown)[0];
        require(get(visible,"fx").isVoid()&&get(visible,"waveform").isVoid(),"Display projection copied plugin state or source peaks");
        require(list(get(get(visible,"midi"),"notes")).size()<=512,"Dense MIDI preview was unbounded");
        require(JSON::toString(rendered).length()<100000,"Display projection retained unrelated document payload");
        require(get(frontendPresentation::project(project),"masterFX").isVoid(),"Master plugin state leaked into presentation snapshots");
        require(project.songs.front().tracks.front().clips.front().midi->notes.size()==5000,"Presentation modified the saved MIDI data");
    });
    test("Native frontend edits the existing session and rejects stale or invalid requests", [&] {
        Session session; session.audio.prepareOffline(48000);
        session.mediaDirectory=directory.getNonexistentChildFile("bridge-project","");
        require(session.mediaDirectory.createDirectory().wasOk(),"Cannot create bridge project fixture");
        session.addTrack("First"); session.addTrack("Second");
        Auth auth(directory.getNonexistentChildFile("bridge-auth", ""));
        Array<var> messages;
        session.audio.instrumentAllowed = true;
        FrontendBridge bridge(session, auth, [&](const String &json) { messages.add(JSON::parse(json)); });
        require(!session.audio.instrumentAllowed.load(),"New frontend left MIDI instruments enabled without access");
        bridge.publishSnapshot();
        const auto first = session.song()->tracks[0].id, second = session.song()->tracks[1].id;
        int serial = 0;
        auto request = [&](const String &action, var payload) {
            messages.clear(); auto input = object(); put(input, "id", ++serial); put(input, "action", action); put(input, "payload", payload);
            bridge.receive(JSON::toString(input));
            for (const auto &message : messages) if (str(message, "type") == "reply" && (int)get(message, "id") == serial) return message;
            throw std::runtime_error("Native request did not reply");
        };
        auto payload = object(); put(payload, "kind", "volume"); put(payload, "trackID", text(first)); put(payload, "value", .5);
        put(payload, "targets", Array<var>{text(first), text(second)}); put(payload, "phase", "begin");
        require(flag(request("mixer", payload), "ok"), "Live mixer gesture failed");
        require(std::none_of(messages.begin(),messages.end(),[](const var &m){return str(m,"type")=="snapshot";}),"Mixer drag encoded the whole project before the coalesced UI tick");
        require(std::abs(session.song()->tracks[0].volume-.5)<1e-9 && std::abs(session.song()->tracks[1].volume-.5)<1e-9, "Frontend used a shadow mixer instead of Session");
        put(payload, "value", .25); put(payload, "phase", "end"); request("mixer", payload);
        require(std::abs(session.song()->tracks[1].volume-.25)<1e-9, "Group fader gesture compounded relative gain");
        put(payload, "kind", "mute"); put(payload, "value", true); put(payload, "phase", "");
        request("mixer", payload); request("mixer", payload);
        require(session.song()->tracks[0].mute && session.song()->tracks[1].mute, "Explicit mute was toggled twice");
        put(payload, "kind", "pan"); put(payload, "value", .4); request("mixer", payload);
        require(std::abs(session.song()->tracks[0].pan-.4)<1e-9, "Pan did not reach the real mixer");
        put(payload, "projectID", "old-project"); put(payload, "value", -.4);
        require(!flag(request("mixer", payload), "ok") && session.song()->tracks[0].pan>.39, "A stale UI edited another project");
        put(payload, "projectID", text(session.project().id)); put(payload, "value", "invalid");
        require(!flag(request("mixer", payload), "ok"), "Non-numeric mixer value was accepted");
        payload = object(); put(payload, "seconds", 4.5); require(flag(request("seek", payload), "ok") && session.transport().position==4.5, "Seek did not update Session");
        require(!flag(request("play", object()), "ok") && !session.transport().playing, "New frontend bypassed access control");
        const auto before = session.song()->tracks.size(); payload = object(); put(payload, "name", "Third"); request("addTrack", payload);
        require(session.song()->tracks.size()==before+1, "AddTrack did not use Session");
        request("undo", object()); require(session.song()->tracks.size()==before, "Undo did not use Session history");
        request("redo", object()); require(session.song()->tracks.size()==before+1, "Redo did not use Session history");
        payload=object();put(payload,"trackID",text(first));
        auto fxReply=request("effectsGet",payload);
        auto settings=get(get(fxReply,"result"),"settings");
        require(flag(fxReply,"ok") && settings.isObject(),"Native FX settings were not exposed");
        put(settings,"inserted",Array<var>{"EQ"});put(settings,"eqEnabled",true);put(payload,"settings",settings);
        require(flag(request("effectsCommit",payload),"ok") && session.song()->tracks[0].fxJSON.has_value(),"FX commit did not use Session");
        put(payload,"key","EQ");put(payload,"kind","EQ");
        auto edited=settings.clone();auto bands=list(get(edited,"bands"));
        put(bands.getReference(2),"gain",6.);put(payload,"settings",edited);put(payload,"chainSettings",edited);
        require(flag(request("effectsPreview",payload),"ok"),"Live FX preview did not reach its inserted instance");
        const auto saved=JSON::parse(text(*session.song()->tracks[0].fxJSON));
        require(num(list(get(saved,"bands"))[2],"gain")==0,"Preview committed history before mouse-up");
        put(payload,"enabled",true);auto spectrum=get(request("effectsRTA",payload),"result");
        require(list(get(spectrum,"input")).size()==384 && list(get(spectrum,"output")).size()==384,"RTA response omitted its fixed log bins");
        put(payload,"enabled",false);require(flag(request("effectsRTA",payload),"ok"),"RTA did not unsubscribe");
        auto inserted=list(get(settings,"inserted"));inserted.add("CatLive Trigger");put(settings,"inserted",inserted);put(settings,"triggerEnabled",true);
        put(payload,"settings",settings);require(flag(request("effectsCommit",payload),"ok"),"Trigger insertion failed");
        const auto sample=directory.getChildFile("bridge-trigger.wav");
        WavAudioFormat wav;auto stream=sample.createOutputStream();
        std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),48000,1,16,{},0));require(writer!=nullptr,"Cannot create bridge sample");stream.release();
        AudioBuffer<float> pcm(1,128);pcm.clear();pcm.setSample(0,0,.5f);require(writer->writeFromAudioSampleBuffer(pcm,0,128),"Cannot write bridge sample");writer.reset();
        put(payload,"key","CatLive Trigger");put(payload,"path",sample.getFullPathName());
        const auto sampleReply=request("effectsChooseSample",payload);
        const auto portable=str(get(get(get(sampleReply,"result"),"settings"),"trigger"),"samplePath");
        require(flag(sampleReply,"ok") && portable.startsWith("Stems/") && session.mediaDirectory.getChildFile(portable).existsAsFile(),"Trigger chooser did not use the portable sample importer");
        bridge.publishSnapshot();
        var snapshot; for (const auto &message : messages) if (str(message,"type")=="snapshot") snapshot=message;
        require(str(get(snapshot,"project"),"id")==text(session.project().id) && str(get(snapshot,"song"),"id")==text(session.song()->id), "Codec snapshot omitted current project/song");
        require(flag(snapshot,"canUndo") && flag(snapshot,"dirty"), "Frontend history/dirty state is incomplete");
        payload=object();put(payload,"trackIDs",Array<var>{text(first)});request("viewport",payload);
        var telemetry;
        for(int n=0;n<100 && telemetry.isVoid();++n) {
            floatingControlTests::pump();
            for(const auto &message:messages)if(str(message,"type")=="telemetry")telemetry=message;
        }
        const auto meters=list(get(telemetry,"meters"));
        require(meters.size()==2 && str(meters[0],"trackID").isEmpty() && str(meters[1],"trackID")==text(first),"Telemetry polled hidden tracks instead of the reported viewport");
    });
    test("Native frontend item edits use session history and preserve the playing cursor", [&] {
        Session session; session.audio.prepareOffline(48000); session.addTrack("Audio");
        session.editTimeline([](jaras::Project &project) {
            jaras::AudioClip a; a.id="bridge-a"; a.name="First"; a.startTime=1; a.duration=4;
            auto b=a; b.id="bridge-b"; b.name="Second"; b.startTime=6;
            project.songs.front().tracks.front().clips={a,b}; project.songs.front().duration=20;
        });
        Auth auth(directory.getNonexistentChildFile("bridge-edit-auth", ""));
        var reply; int serial=0;
        FrontendBridge bridge(session,auth,[&](const String &json){const auto message=JSON::parse(json);if(str(message,"type")=="reply")reply=message;});
        auto request=[&](const String &action,var payload){auto input=object();put(input,"id",++serial);put(input,"action",action);put(input,"payload",payload);reply=var();bridge.receive(JSON::toString(input));return flag(reply,"ok");};
        auto payload=object();put(payload,"itemIDs",Array<var>{"bridge-a","bridge-b"});put(payload,"delta",2.);
        require(request("moveItems",payload),"Multi-item move failed");
        const auto &moved=session.song()->tracks.front().clips;
        require(std::any_of(moved.begin(),moved.end(),[](const auto &clip){return clip.id=="bridge-a"&&clip.startTime==3;}),"Move edited a shadow project");
        require(request("undo",object())&&session.song()->tracks.front().clips.front().startTime==1,"Move was not undoable");
        put(payload,"gain",.4);put(payload,"pan",-.8);put(payload,"muted",true);
        require(request("itemControls",payload),"Multi-item controls failed");
        for(const auto &clip:session.song()->tracks.front().clips)
            require(clip.gain.value_or(1)==.4&&clip.pan.value_or(0)==-.8&&clip.muted,"A selected item did not receive controls");
        put(payload,"pan",1.1);require(!request("itemControls",payload),"Invalid pan was accepted");
        put(payload,"itemIDs",Array<var>{"bridge-a","missing"});require(!request("removeItems",payload)&&session.song()->tracks.front().clips.size()==2,"Partially invalid deletion changed the document");
        session.editTimeline([](jaras::Project &project){project.timelineMovementLocked=true;});
        put(payload,"itemIDs",Array<var>{"bridge-a"});require(!request("moveItems",payload),"Locked timeline allowed movement");
        session.core.execute({jaras::CommandKind::play});
        const double previousPosition=session.transport().position;
        payload=object();put(payload,"kind","editSeek");put(payload,"value",12.);
        require(request("transport",payload)&&session.transport().playing&&session.transport().editPosition==12.&&session.transport().position==previousPosition,"Editing cursor sought or stopped playback");
        session.core.execute({jaras::CommandKind::stop});
        require(!request("record",object())&&!session.audio.isRecording(),"Recording bypassed authorization");
    });
    test("Native timeline clipboard preserves shipping paste, cut, history and document scope", [&] {
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.addTrack("Clipboard A");session.addTrack("Clipboard B");
        session.editTimeline([](jaras::Project &project) {
            auto &song=project.songs.front();song.duration=120;
            jaras::AudioClip a;a.id="clipboard-a";a.name="First";a.startTime=1;a.duration=4;
            a.gain=.7;a.pan=-.3;a.fadeIn=.2;a.fadeInCurve=.4;a.loopStart=1;a.loopLength=2;
            a.fxJSON=utf8(JSON::toString(fxschema::complete(JSON::parse(R"({"inserted":[]})")),true,17));a.separatedStemTracks={"derived-owner"};
            auto b=a;b.id="clipboard-b";b.name="MIDI";b.startTime=9;b.midi.emplace();
            b.midi->notes.push_back({"clipboard-note",0,1,60,100,1});
            song.tracks[0].clips={a};song.tracks[1].clips={b};
        });
        const auto firstTrack=session.song()->tracks[0].id,secondTrack=session.song()->tracks[1].id;
        const auto original=session.song()->tracks[0].clips[0];
        Auth auth(directory.getNonexistentChildFile("bridge-clipboard-auth",""));
        var lastReply,lastSnapshot;int serial=0;
        FrontendBridge bridge(session,auth,[&](const String &json) {
            const auto message=JSON::parse(json);
            if(str(message,"type")=="reply")lastReply=message;
            if(str(message,"type")=="snapshot")lastSnapshot=message;
        },true);
        bridge.publishSnapshot();
        auto scoped=[&] {auto payload=object();put(payload,"projectID",text(session.project().id));put(payload,"songID",text(session.song()->id));return payload;};
        auto selected=[&] {auto payload=scoped();put(payload,"itemIDs",Array<var>{"clipboard-a","clipboard-b"});return payload;};
        auto request=[&](const String &action,var payload) {
            auto input=object();put(input,"id",++serial);put(input,"action",action);put(input,"payload",payload);
            lastReply=var();bridge.receive(JSON::toString(input));return flag(lastReply,"ok");
        };
        auto clip=[&](const ID &id)->const jaras::AudioClip& {
            for(const auto &track:session.song()->tracks)for(const auto &item:track.clips)if(item.id==id)return item;
            throw std::runtime_error("Clipboard fixture item missing");
        };
        auto clipboard=[&] {bridge.publishSnapshot();return get(lastSnapshot,"clipboard");};
        auto payload=selected();const auto beforeCopy=session.revision;
        require(request("copyItems",payload),"Copy failed");
        require(session.revision==beforeCopy && flag(clipboard(),"available")&&!flag(clipboard(),"moving"),"Copy modified the project or omitted clipboard state");
        payload=scoped();put(payload,"seconds",30.);require(request("pasteItems",payload),"Copy paste failed");
        require(session.song()->tracks[0].clips.size()==2&&session.song()->tracks[1].clips.size()==2,"Paste lost a selected track");
        const auto copied=session.song()->tracks[0].clips.back(),copiedMIDI=session.song()->tracks[1].clips.back();
        require(copied.id!=original.id&&copied.startTime==30&&copiedMIDI.startTime==38,"Paste lost new identity or relative timing");
        require(copied.gain==original.gain&&copied.pan==original.pan&&copied.fadeInCurve==original.fadeInCurve&&copied.loopLength==original.loopLength&&copied.fxJSON==original.fxJSON&&copied.separatedStemTracks.empty(),"Paste changed full item state or retained derived-track ownership");
        require(copiedMIDI.midi&&copiedMIDI.midi->notes[0].pitch==60,"MIDI clipboard payload was lost");
        const auto shown=get(lastSnapshot,"selection");
        require(list(get(shown,"itemIDs")).contains(text(copied.id))&&list(get(shown,"itemIDs")).contains(text(copiedMIDI.id))&&list(get(shown,"trackIDs")).contains(text(firstTrack))&&list(get(shown,"trackIDs")).contains(text(secondTrack)),"Pasted items were not selected on their original tracks");
        require(request("undo",object())&&session.song()->tracks[0].clips.size()==1&&session.song()->tracks[1].clips.size()==1,"One undo did not remove the whole paste");
        require(request("redo",object())&&clip(copied.id).startTime==30,"Redo did not restore exact pasted IDs");
        require(request("undo",object()),"Cannot reset clipboard fixture");
        require(request("cutItems",selected())&&clip("clipboard-a").startTime==1&&flag(clipboard(),"moving"),"Cut removed or moved source items prematurely");
        payload=scoped();put(payload,"seconds",-1.);
        require(!request("pasteItems",payload)&&flag(clipboard(),"moving")&&clip("clipboard-a").startTime==1,"Failed paste cleared pending cut or changed source");
        session.editItemControls([](jaras::Project &project){project.songs.front().tracks[0].clips[0].gain=.25;});
        payload=scoped();put(payload,"seconds",50.);require(request("pasteItems",payload),"Cut paste failed");
        require(session.song()->tracks[0].clips.size()==1&&session.song()->tracks[1].clips.size()==1&&clip("clipboard-a").startTime==50&&clip("clipboard-b").startTime==58&&clip("clipboard-a").gain==.25,"Cut duplicated IDs or restored stale item controls");
        require(flag(clipboard(),"available")&&!flag(clipboard(),"moving")&&list(get(clipboard(),"cutItemIDs")).isEmpty(),"Successful cut paste did not become an ordinary copy");
        require(request("undo",object())&&clip("clipboard-a").startTime==1&&clip("clipboard-a").gain==.25,"Cut paste was not one undoable transaction");
        require(request("cutItems",selected()),"Second cut failed");
        session.removeClips({"clipboard-a"});payload=scoped();put(payload,"seconds",70.);
        require(!request("pasteItems",payload)&&clip("clipboard-b").startTime==9&&flag(clipboard(),"moving"),"Missing cut source allowed a partial move");
        session.undo();require(request("cancelItemCut",scoped())&&!flag(clipboard(),"available"),"Escape did not cancel the pending cut");
        session.editTimeline([](jaras::Project &project){project.timelineMovementLocked=true;});
        require(!request("cutItems",selected()),"Movement lock allowed cutting");
        require(request("copyItems",selected()),"Movement lock blocked harmless copying");
        session.editTimeline([](jaras::Project &project){project.timelineMovementLocked=false;});
        payload=selected();put(payload,"itemIDs",Array<var>{"clipboard-a","missing"});
        require(!request("cutItems",payload)&&!flag(clipboard(),"moving"),"Invalid selection partially replaced the clipboard");
        payload=scoped();put(payload,"songID","stale-song");put(payload,"seconds",80.);
        require(!request("pasteItems",payload)&&clip("clipboard-a").startTime==1,"Stale song scope edited the current grid");
        session.editTimeline([](jaras::Project &project) {
            jaras::Track track;track.id="clipboard-chords";track.role.id="chords";track.name="Chords";
            jaras::AudioClip source;source.id="clipboard-chord";source.name="C";source.text="C";source.startTime=2;source.duration=2;
            auto occupied=source;occupied.id="clipboard-occupied";occupied.startTime=20;
            track.clips={source,occupied};project.songs.front().tracks.push_back(track);
        });
        payload=scoped();put(payload,"itemIDs",Array<var>{"clipboard-a","clipboard-chord"});require(request("cutItems",payload),"Cannot stage occupied-destination fixture");
        const auto beforeRejection=session.revision;const auto selectionBefore=JSON::toString(get(lastSnapshot,"selection"));
        payload=scoped();put(payload,"seconds",19.);
        require(!request("pasteItems",payload)&&session.revision==beforeRejection&&clip("clipboard-a").startTime==1&&clip("clipboard-chord").startTime==2&&flag(clipboard(),"moving"),"Core overlap rejection partially pasted or cleared the cut");
        require(JSON::toString(get(lastSnapshot,"selection"))==selectionBefore,"Failed paste changed item selection");
        require(request("cancelItemCut",scoped())&&request("undo",object())&&session.song()->tracks.size()==2,"Failed paste added an undo entry");
        require(request("copyItems",selected()),"Cannot stage same-document reload fixture");
        const auto reload=directory.getNonexistentChildFile("bridge-clipboard-reload","").getChildFile("Clipboard.jl");
        ProjectCodec::write(reload,ProjectCodec::encode(session.project()));session.dirty=false;
        bridge.openProject(reload);
        for(int n=0;n<150&&(session.busy||session.document!=reload);++n)floatingControlTests::pump();
        require(!session.busy&&session.document==reload&&!flag(clipboard(),"available"),"Opening the same project UUID retained stale copied items");
        require(request("copyItems",selected()),"Cannot stage replacement-project fixture");
        const auto oldScope=scoped();session.newProject("Replacement");
        require(!request("pasteItems",oldScope)&&!flag(clipboard(),"available"),"Clipboard crossed a project boundary");
    });
    test("Native frontend media import preserves batch layout undo and document scope", [&] {
        Session session;session.audio.prepareOffline(48000);session.addTrack("Destination");
        session.mediaDirectory=directory.getNonexistentChildFile("bridge-import-media","");
        require(session.mediaDirectory.createDirectory().wasOk(),"Cannot create media directory");
        Auth auth(directory.getNonexistentChildFile("bridge-import-auth",""));
        Array<var> messages;FrontendBridge bridge(session,auth,[&](const String& json){messages.add(JSON::parse(json));},true);
        const auto source=directory.getNonexistentChildFile("bridge-import-sources","");require(source.createDirectory().wasOk(),"Cannot create sources");
        const auto first=source.getChildFile(String::fromUTF8("Canção.wav")),second=source.getChildFile("Second.wav");
        for(const auto& file:{first,second}) {
            WavAudioFormat format;auto stream=file.createOutputStream();
            std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(),48000,1,16,{},0));
            require(writer!=nullptr,"Cannot create import source");stream.release();
            AudioBuffer<float> pcm(1,4800);pcm.clear();pcm.setSample(0,0,.5f);require(writer->writeFromAudioSampleBuffer(pcm,0,4800),"Cannot write import source");
        }
        int serial=0;
        auto request=[&](var payload) {
            messages.clear();auto input=object();put(input,"id",++serial);put(input,"action","importMedia");put(input,"payload",payload);bridge.receive(JSON::toString(input));
            for(int n=0;n<1000;++n) {
                for(const auto& message:messages)if(str(message,"type")=="reply"&&(int)get(message,"id")==serial)return flag(message,"ok");
                floatingControlTests::pump();
            }
            throw std::runtime_error("Media import did not complete");
        };
        auto payload=object();put(payload,"projectID",text(session.project().id));put(payload,"songID",text(session.song()->id));
        put(payload,"trackID",text(session.song()->tracks.front().id));put(payload,"seconds",2.);put(payload,"gap",.25);put(payload,"layout","sameTrack");
        put(payload,"paths",Array<var>{first.getFullPathName(),second.getFullPathName(),first.getFullPathName()});
        require(request(payload),"Sequential batch import failed");
        require(session.song()->tracks.size()==1&&session.song()->tracks.front().clips.size()==2,"Batch duplicated source or changed target track");
        const auto imported=session.song()->tracks.front().clips;
        require(imported[0].name==utf8(first.getFileNameWithoutExtension())&&std::abs(imported[0].startTime-2)<1e-6&&std::abs(imported[1].startTime-2.35)<1e-6,"Unicode name or sequential placement changed");
        require(imported[0].audioFile&&session.mediaDirectory.getChildFile(text(imported[0].audioFile->path)).existsAsFile(),"Import omitted project media");
        session.undo();require(session.song()->tracks.front().clips.empty(),"Import was not one undoable edit");
        put(payload,"layout","stacked");put(payload,"gap",0.);require(request(payload),"Stacked batch import failed");
        require(session.song()->tracks.front().clips.size()==2&&session.song()->tracks.front().clips[0].startTime==session.song()->tracks.front().clips[1].startTime,"Stacked media was offset");
        const auto revision=session.revision;
        put(payload,"songID","stale-song");require(!request(payload)&&session.revision==revision,"Stale drop imported into another timeline");
        put(payload,"songID",text(session.song()->id));put(payload,"paths",Array<var>{first.getFullPathName(),source.getChildFile("missing.wav").getFullPathName()});
        // Busy/status notifications advance the presentation revision even on
        // failure. Assert the authoritative document, not that UI counter.
        const auto beforeInvalidBatch=JSON::toString(ProjectCodec::encode(session.project()));
        require(!request(payload)&&JSON::toString(ProjectCodec::encode(session.project()))==beforeInvalidBatch&&!session.busy,"Partly invalid batch changed the project or remained busy");
        put(payload,"paths",Array<var>{"relative.wav"});require(!request(payload),"Relative drop path was accepted");
    });
    test("Native frontend confirms playback and unsaved changes before closing", [&] {
        Session session; session.audio.prepareOffline(48000); session.addTrack("Unsaved");
        Auth auth(directory.getNonexistentChildFile("bridge-close-auth", ""));
        Array<var> messages; bool closed = false;
        FrontendBridge bridge(session, auth, [&](const String &json) { messages.add(JSON::parse(json)); });
        bridge.onCloseApproved = [&] { closed = true; };
        auto confirmation = [&] {
            for(int i=messages.size();--i>=0;)if(str(messages[i],"type")=="confirm")return messages[i];
            throw std::runtime_error("Missing native frontend confirmation");
        };
        auto answer = [&](const String &choice) {
            auto payload=object(),request=object();put(payload,"token",get(confirmation(),"token"));put(payload,"choice",choice);
            put(request,"id",1);put(request,"action","confirm");put(request,"payload",payload);bridge.receive(JSON::toString(request));
        };
        bridge.requestClose(); require(str(confirmation(),"kind")=="unsaved" && !closed,"Dirty project closed without confirmation");
        answer("cancel"); require(!closed && session.dirty,"Cancel changed the project");
        session.core.execute({jaras::CommandKind::play}); messages.clear(); bridge.requestClose();
        require(str(confirmation(),"kind")=="playing" && !closed,"Playing project skipped its confirmation");
        answer("stop"); require(!session.transport().playing && str(confirmation(),"kind")=="unsaved" && !closed,"Playback confirmation skipped unsaved changes");
        answer("discard"); require(closed,"Confirmed close was not delivered to the host");
    });
}
}
