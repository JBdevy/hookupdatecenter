#pragma once
#include "FrontendBridge.h"
#include "FloatingControlTests.h"

namespace catlive::frontendBridgeTests {
template<class Test, class Require>
void run(Test test, Require require, const File &directory) {
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
