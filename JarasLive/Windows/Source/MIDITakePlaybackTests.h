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

    test("Virtual Keyboard overflow releases sustain on the original mapped channels", [] {
        VirtualKeyboardRoute route;
        MidiBuffer source,output;
        source.addEvent(MidiMessage::noteOn(1,60,(uint8)100),0);
        route.append(output,source,16,true,0,2);
        source.clear();output.clear();
        source.addEvent(MidiMessage::noteOn(1,64,(uint8)100),0);
        route.append(output,source,16,true,0,16);
        source.clear();output.clear();
        source.addEvent(MidiMessage::controllerEvent(1,64,0),0);
        source.addEvent(MidiMessage::allSoundOff(1),0);
        source.addEvent(MidiMessage::allNotesOff(1),0);
        route.append(output,source,16,false,5,7);
        unsigned pedals=0,panics=0;
        for(const auto event:output) {
            const auto message=event.getMessage();
            const unsigned channel=1u<<(message.getChannel()-1);
            if(message.isController() && message.getControllerNumber()==64 && message.getControllerValue()==0)pedals|=channel;
            if(message.isAllSoundOff())panics|=channel;
        }
        const unsigned expected=(1u<<1)|(1u<<15);
        require(pedals==expected && panics==expected,
                "Overflow recovery ignored sustain or sent panic to the current channel instead of original targets");
        require(output.getNumEvents()==4,"Overflow recovery duplicated its mapped controllers");
        source.clear();output.clear();
        source.addEvent(MidiMessage::noteOff(1,60),0);
        source.addEvent(MidiMessage::noteOff(1,64),0);
        route.append(output,source,16,false,5,7);
        require(output.isEmpty(),"Overflow recovery retained stale keyboard routes");
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
        BoundedMIDIBuffer first,second;
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
    test("Oversized MIDI blocks panic once and recover fresh notes without growing storage", [] {
        std::vector<PlaybackNote> notes{{0,10,40,100,1}};
        for(size_t i=0;i<BoundedMIDIBuffer::maximumEvents+100;++i)
            notes.push_back({.1,.12,int(i%128),100,1});
        notes.push_back({.25,.275,70,100,2});
        const auto sequence=MIDIPlayback::sequence(std::move(notes));
        BoundedMIDIBuffer messages;
        const auto* storage=messages.buffer().data.begin();
        double expected=-1;jaras::PlaybackScope scope;
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,0,100,1000);
        require(noteOns(messages,40)==1,"Ordinary note before overflow was changed");
        messages.clear();
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.1,100,1000);
        require(messages.overflowed()&&messages.overflows()==1&&messages.getNumEvents()==48,"Dense MIDI did not emit one complete panic");
        std::array<unsigned,16> controls{};
        for(const auto event:messages) {
            const auto message=event.getMessage();
            require(message.isController()&&event.samplePosition==0&&message.getControllerValue()==0,"Panic retained a queued note or late controller");
            const auto control=message.getControllerNumber();
            controls[size_t(message.getChannel()-1)] |= control==64?1u:control==120?2u:control==123?4u:0u;
        }
        require(std::all_of(controls.begin(),controls.end(),[](unsigned value){return value==7;}),"Panic left a channel's voices or sustain active");
        require(!messages.addEvent(MidiMessage::noteOn(1,64,(uint8)100),99)&&messages.getNumEvents()==48,
                "A later append resurrected a note after panic");
        messages.clear();
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.2,100,1000);
        require(!messages.overflowed()&&messages.overflows()==1&&messages.getNumEvents()==2&&noteOns(messages,70)==1,
                "Overflow retried stale held notes or blocked fresh notes");
        bool released=false;
        for(const auto event:messages)if(event.getMessage().isNoteOff())
            released=event.getMessage().getNoteNumber()==70&&event.samplePosition==75;
        require(released,"Recovered note lost its note-off/sample offset");
        require(messages.buffer().data.begin()==storage,"Realtime MIDI changed its prepared storage");
    });
    test("Merging playback heads preserves note-offs or replaces the entire block with panic", [] {
        BoundedMIDIBuffer first,second;
        for(size_t i=0;i<BoundedMIDIBuffer::maximumEvents/2+1;++i) {
            first.addEvent(MidiMessage::noteOn(1,int(i%128),(uint8)100),0);
            second.addEvent(MidiMessage::noteOff(1,int(i%128)),8);
        }
        first.addEvents(second,0,16,0);
        require(first.overflowed()&&first.getNumEvents()==48&&noteOns(first)==0,"Head merge silently truncated releases");
        first.clear();second.clear();
        first.addEvent(MidiMessage::noteOn(1,60,(uint8)100),2);
        second.addEvent(MidiMessage::noteOff(1,60),9);
        first.addEvents(second,0,16,0);
        require(first.getNumEvents()==2&&first.overflows()==1,"Head merge did not recover after overflow");
        second.panic();first.addEvents(second,0,16,0);
        require(first.overflowed()&&first.getNumEvents()==48&&noteOns(first)==0,"A source panic left other-head notes queued");
    });
    test("MIDI replacement and scope changes recover after overflow without stale notes", [] {
        std::vector<PlaybackNote> notes(BoundedMIDIBuffer::maximumEvents+1,PlaybackNote{0,10,40,100,1,0.});
        auto sequence=MIDIPlayback::sequence(std::move(notes));
        BoundedMIDIBuffer messages;double expected=-1;jaras::PlaybackScope scope;
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.1,100,1000);
        require(messages.overflowed(),"Dense held-note chase did not overflow");

        auto replacement=MIDIPlayback::sequence({{0,1,74,120,3,0.},{.4,.45,75,100,3,0.}});
        std::swap(sequence,replacement);expected=-2;messages.clear();
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.2,100,1000,{1,2});
        require(!messages.overflowed()&&messages.getNumEvents()==16&&noteOns(messages)==0,
                "Replacement revived an old or scope-excluded held note");
        messages.clear();
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.3,100,1000);
        require(noteOns(messages,74)==1&&noteOns(messages,40)==0,"Scope re-entry did not chase only the replacement's held note");
        messages.clear();
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.4,100,1000);
        require(noteOns(messages,74)==0&&noteOns(messages,75)==1&&messages.getNumEvents()==2,
                "Contiguous playback retriggered a sustained note or lost the replacement onset");
        bool released=false;
        for(const auto event:messages)if(event.getMessage().isNoteOff())
            released=event.getMessage().getNoteNumber()==75&&event.samplePosition==50;
        require(released,"Replacement's ordinary note-off was lost");
        messages.clear();
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.5,600,1000);
        require(messages.getNumEvents()==1&&(*messages.begin()).getMessage().isNoteOff()&&
                (*messages.begin()).getMessage().getNoteNumber()==74&&(*messages.begin()).samplePosition==500,
                "Replacement's chased sustained note was left sounding");
        require(messages.overflows()==1,"Sequence replacement repeatedly retried the discarded overflow");
    });
    test("Zero-frame MIDI blocks preserve panic, clock and pending reset until audio resumes", [] {
        const auto sequence=MIDIPlayback::sequence({{0,1,60,100,1,0.}});
        BoundedMIDIBuffer messages;double expected=-2;jaras::PlaybackScope scope;
        const auto originalScope=scope;
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.25,0,1000,{1,2});
        require(messages.isEmpty()&&expected==-2&&scope==originalScope,"Zero frames consumed a pending sequence reset");
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.25,100,1000);
        require(noteOns(messages,60)==1,"Audio resumed without chasing the pending held note");
        messages.panic();const auto clock=expected;
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,9,0,1000,{1,2},false);
        require(messages.overflowed()&&messages.getNumEvents()==48&&messages.overflows()==1&&
                expected==clock&&scope==originalScope,"Zero-frame stop consumed panic or altered playback state");
        messages.clear();
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.35,100,1000);
        require(messages.isEmpty(),"Post-panic zero-frame callback caused a stale held-note chase");
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.45,100,1000,{},false);
        require(messages.getNumEvents()==16&&expected==-1,"Real stop after a zero-frame block lost its release");
        messages.clear();
        MIDIPlayback::appendExternal(sequence,messages,expected,scope,.55,100,1000);
        require(noteOns(messages,60)==1,"Explicit restart failed to restore a valid sustained note");
    });
    test("MIDI seek index skips old sparse history and bounds excluded dense events", [] {
        std::vector<PlaybackNote> notes;
        for(size_t i=0;i<BoundedMIDIBuffer::maximumVisits+100;++i)
            notes.push_back({double(i)*2,double(i)*2+1,60,100,1});
        const auto sparse=MIDIPlayback::sequence(std::move(notes));
        BoundedMIDIBuffer messages;double expected=-1;jaras::PlaybackScope scope;
        const double at=sparse.notes.back().start+.5;
        MIDIPlayback::appendExternal(sparse,messages,expected,scope,at,100,1000);
        require(!messages.overflowed()&&noteOns(messages)==1,"Long sparse score exhausted the seek budget");
        notes.assign(BoundedMIDIBuffer::maximumVisits+100,PlaybackNote{0,1,60,100,1,0.});
        const auto dense=MIDIPlayback::sequence(std::move(notes));
        messages.clear();expected=-1;
        MIDIPlayback::appendExternal(dense,messages,expected,scope,0,100,1000,{2,3});
        require(messages.overflowed()&&messages.getNumEvents()==48,"Scope-filtered score bypassed the work bound");
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
