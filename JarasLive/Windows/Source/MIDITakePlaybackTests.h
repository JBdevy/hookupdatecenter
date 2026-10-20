#pragma once
#include "MIDIPlayback.h"
#include "Automation.h"

namespace catlive::midiTakePlaybackTests {
inline void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
inline jaras::AudioClip item(int pitch) {
    jaras::AudioClip clip;
    clip.id=uuid();clip.name="MIDI take";clip.startTime=2;clip.duration=4;
    clip.midi.emplace();clip.midi->sourceBPM=120;
    clip.midi->notes={{uuid(),1,2,pitch,100,1}};
    return clip;
}
inline std::string instrumentFX() {
    return R"({"inserted":["External:take"],"externalPlugins":[{"id":"take","category":"Instrument|Synth","bypassed":false}]})";
}
inline int noteOns(const MidiBuffer &messages, int pitch=-1) {
    int count=0;
    for(const auto event:messages)
        if(event.getMessage().isNoteOn()&&(pitch<0||event.getMessage().getNoteNumber()==pitch))++count;
    return count;
}
template <typename Test> void registerTests(Test &test) {
    test("Virtual Keyboard routes Omni and fixed channels only to armed tracks and releases original voices", [] {
        VirtualKeyboardRoute a,b,c;
        MidiBuffer source,first,second,third;
        source.addEvent(MidiMessage::noteOn(1,60,(uint8)100),3);
        a.append(first,source,16,true,0,2); b.append(second,source,16,true,0,16); c.append(third,source,16,false,0,0);
        require(first.getNumEvents()==1 && second.getNumEvents()==1 && third.isEmpty(),"Omni duplicated or reached an unarmed track");
        require((*first.begin()).getMessage().getChannel()==2 && (*second.begin()).getMessage().getChannel()==16,"Omni ignored target channels");
        source.clear();first.clear();second.clear();
        source.addEvent(MidiMessage::noteOff(1,60),4);
        a.append(first,source,16,false,5,7);b.append(second,source,16,false,5,7);
        require(first.getNumEvents()==1 && (*first.begin()).getMessage().getChannel()==2 && second.getNumEvents()==1 && (*second.begin()).getMessage().getChannel()==16,"Changing arm/channel stranded original notes");
        first.clear();second.clear();source.clear();
        source.addEvent(MidiMessage::noteOn(5,62,(uint8)100),0);
        a.append(first,source,16,true,5,2); b.append(second,source,16,true,5,0);
        require(first.isEmpty() && second.getNumEvents()==1 && (*second.begin()).getMessage().getChannel()==5,"Fixed channel ignored track filter");
        source.clear();second.clear();source.addEvent(MidiMessage::allNotesOff(5),0);
        b.append(second,source,16,false,0,0);
        require(second.getNumEvents()==1 && (*second.begin()).getMessage().isNoteOff(),"All-notes-off left a virtual note held");
    });

    test("MIDI takes own their notes without duplicating the shared track instrument", [] {
        jaras::Song song; song.bpm=120;
        jaras::Track track;track.id=uuid();track.role.id="keys";
        auto take=item(60),shared=item(64),effectOnly=item(67),frozen=item(72);
        take.fxJSON=instrumentFX();
        effectOnly.fxJSON=R"({"inserted":["External:fx"],"externalPlugins":[{"id":"fx","category":"Fx"}]})";
        frozen.frozenMIDI=true;
        track.clips={take,shared,effectOnly,frozen};
        const auto notes=playbackNotes(track,&song,false,true);
        require(notes.size()==2&&notes[0].pitch==64&&notes[1].pitch==67,
                "Take or frozen notes leaked into the track, or an ordinary MIDI item was lost");
        const auto owned=takePlaybackNotes(track,take,song,true);
        require(owned.size()==1&&owned[0].pitch==60,"Take received another item's notes");
        track.clips[0].fxBypassed=true;
        require(playbackNotes(track,&song,false,true).size()==3,"Take bypass did not restore shared-track playback");
        track.clips[0].fxBypassed=false;
        auto fx=JSON::parse(text(*track.clips[0].fxJSON));
        auto plugins=list(get(fx,"externalPlugins"));put(plugins.getReference(0),"bypassed",true);
        put(fx,"externalPlugins",plugins);track.clips[0].fxJSON=utf8(JSON::toString(fx));
        require(playbackNotes(track,&song,false,true).size()==3,"Plugin bypass did not restore shared-track playback");
        put(plugins.getReference(0),"bypassed",false);put(fx,"externalPlugins",plugins);
        put(fx,"inserted",Array<var>{});track.clips[0].fxJSON=utf8(JSON::toString(fx));
        require(!hasTakeInstrument(track.clips[0]),"Retained but uninserted plugin captured the take");
    });
    test("MIDI take gain and fades do not scale its instrument velocity twice", [] {
        jaras::Song song;song.bpm=120;
        jaras::Track track;track.id=uuid();track.role.id="keys";
        auto clip=item(60);clip.fxJSON=instrumentFX();clip.gain=.25;clip.fadeIn=1;
        track.clips={clip};
        const auto owned=takePlaybackNotes(track,clip,song,true);
        const auto shared=takePlaybackNotes(track,clip,song,false);
        require(owned.size()==1&&owned[0].velocity==100,"Take fader/fade changed MIDI velocity before audio automation");
        require(shared.size()==1&&shared[0].velocity<owned[0].velocity,"Existing shared-instrument velocity behavior changed");
        clip.muted=true;
        require(takePlaybackNotes(track,clip,song,true)[0].velocity==100,
                "Muting destroyed the take sequence needed when its audio is unmuted");
        require(takePlaybackNotes(track,clip,song,false)[0].velocity==0,
                "Muted shared-track notes remained audible");
    });
    test("MIDI take clocks chase, loop, scope and release independently", [] {
        const auto a=MIDIPlayback::sequence({{1,2,60,100,1,0.}});
        const auto b=MIDIPlayback::sequence({{1.5,2.5,67,90,2,1.}});
        MidiBuffer first,second;
        double expectedA=-1,expectedB=-1;
        jaras::PlaybackScope scopeA,scopeB;
        MIDIPlayback::appendExternal(a,first,expectedA,scopeA,1.25,100,1000);
        MIDIPlayback::appendExternal(b,second,expectedB,scopeB,1.25,100,1000);
        require(noteOns(first,60)==1&&noteOns(second)==0,"Seeking chased another take's held notes");
        first.clear();
        MIDIPlayback::appendExternal(a,first,expectedA,scopeA,1.35,100,1000);
        require(first.isEmpty(),"Contiguous block retriggered a held note");
        second.clear();
        MIDIPlayback::appendExternal(b,second,expectedB,scopeB,1.45,100,1000);
        bool offset=false;
        for(const auto event:second)if(event.getMessage().isNoteOn())offset=event.samplePosition==50;
        require(offset&&noteOns(second,67)==1,"Take note-on lost its sample offset");
        first.clear();
        MIDIPlayback::appendExternal(a,first,expectedA,scopeA,1.25,100,1000);
        require(noteOns(first,60)==1,"Loop/seek did not re-chase the take");
        first.clear();
        MIDIPlayback::appendExternal(a,first,expectedA,scopeA,1.95,100,1000);
        bool released=false;
        for(const auto event:first)if(event.getMessage().isNoteOff())
            released=event.getMessage().getNoteNumber()==60&&event.samplePosition==50;
        require(released,"Take note-off lost its exact end inside the render block");
        first.clear();
        MIDIPlayback::appendExternal(a,first,expectedA,scopeA,1.35,100,1000,{.5,3});
        require(noteOns(first)==0&&!first.isEmpty(),"Scope change kept an excluded take sounding");
        second.clear();
        MIDIPlayback::appendExternal(b,second,expectedB,scopeB,1.55,100,1000,{},false);
        require(second.getNumEvents()==16&&expectedB==-1,"Stopping did not release the take's channels");
        second.clear();
        MIDIPlayback::appendExternal(b,second,expectedB,scopeB,1.55,100,1000,{},false);
        require(second.isEmpty(),"Stopped take repeatedly sent MIDI resets");
        expectedB=-2;
        MIDIPlayback::appendExternal(b,second,expectedB,scopeB,1.55,100,1000,{},false);
        require(second.getNumEvents()==16,"Muting a freshly edited sequence left held notes");
    });
    test("MIDI take automation follows its own source offset and tempo clock", [] {
        jaras::Song song;song.bpm=120;
        auto a=item(60),b=item(67);
        a.sourceOffset=3;a.playbackRate=2;
        b.sourceOffset=0;b.playbackRate=1;
        ClipTempo clockA(a,&song),clockB(b,&song);
        AutomationProgram automation;
        automation.prepare(JSON::parse(R"({"enabled":true,"envelopes":[{"target":{"kind":"pan"},"points":[{"time":0,"value":0},{"time":4,"value":1}]}]})"),true);
        const auto first=automation.evaluate(clockA.sourceAt(2.5),1,0);
        const auto second=automation.evaluate(clockB.sourceAt(2.5),1,0);
        require(std::abs(first.pan-1)<1e-9&&std::abs(second.pan+.75)<1e-9,
                "Overlapping takes shared an automation clock");
    });
    test("Live MIDI keeps its existing track arm and note-release behavior", [] {
        MidiBuffer live,routed;
        live.addEvent(MidiMessage::noteOn(1,60,(uint8)100),3);
        live.addEvent(MidiMessage::noteOff(1,60),8);
        appendLiveTrackMIDI(routed,live,16,false);
        require(noteOns(routed)==0&&routed.getNumEvents()==1,"Disarmed track blocked releases or accepted new notes");
        routed.clear();appendLiveTrackMIDI(routed,live,16,true);
        require(noteOns(routed)==1&&routed.getNumEvents()==2,"Take routing changed the live track MIDI path");
    });
}
} // namespace catlive::midiTakePlaybackTests
