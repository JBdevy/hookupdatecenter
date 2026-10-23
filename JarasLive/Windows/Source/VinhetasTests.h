#pragma once
#include "VinhetasAudio.h"
#include "RecordingCaptureTests.h"
#include "VinhetasPanel.h"
namespace catlive {
struct VinhetasPanelProbe {
    static void run(const File &directory) {
        const ScopedValueSetter<var> restore(VinhetasPanel::globalState,var{});
        Appearance preferences(directory.getNonexistentChildFile("pads-midi",".json"));
        VinhetasAudio audio; audio.setOutputAvailable(true);
        auto sample=std::make_shared<VinhetasAudio::Sample>();sample->pcm.setSize(2,44100);
        for(int ch=0;ch<2;ch++)FloatVectorOperations::fill(sample->pcm.getWritePointer(ch),.025f,44100);
        auto *pcm=audio.retain(sample);VinhetasPanel panel(audio,preferences);
        for(auto &preset:panel.presets)preset.pads[0].sample=pcm;
        AudioBuffer<float> output(2,512);
        auto level=[&](float expected) { output.clear();audio.render(output,512,44100);recordingCaptureTests::require(std::abs(output.getSample(0,256)-expected)<.00001f,"MIDI pad playback or release used the wrong preset"); };
        panel.learning=0;panel.learningPreset=false;panel.midi(0xb0,20,127,1);
        panel.midi(0xb0,20,0,1);panel.midi(0xb0,20,127,1);level(.025f);
        panel.select(1);panel.midi(0xb0,20,0,1);panel.midi(0xb0,20,127,1);level(.05f);
        panel.midi(0xb0,20,64,1);level(.05f);
        audio.enqueue({VinhetasAudio::Kind::stop,1});audio.enqueue({VinhetasAudio::Kind::stop,2});level(0);
        panel.learning=0;panel.midi(0x90,60,100,1);panel.midi(0x90,60,0,1);
        panel.midi(0x90,60,100,1);level(.025f);panel.select(0);
        panel.midi(0x80,60,64,1);level(0);
        recordingCaptureTests::require(audio.handlesMIDI(MidiMessage::noteOn(1,60,(uint8)100)) && audio.handlesMIDI(MidiMessage::noteOff(1,60)),"Mapped note must be reserved for the pad on press and release");
        recordingCaptureTests::require(audio.handlesMIDI(MidiMessage::noteOn(2,60,(uint8)100)) && !audio.handlesMIDI(MidiMessage::noteOn(1,61,(uint8)100)),"Unmapped MIDI must still reach track instruments");
        panel.channel=10;panel.save();
        recordingCaptureTests::require(!panel.midi(0x90,60,100,1) && !audio.handlesMIDI(MidiMessage::noteOn(1,60,(uint8)100)),"Other channels must remain available for track MIDI");
        panel.midi(0x90,60,100,10);level(.025f);
        recordingCaptureTests::require(audio.handlesMIDI(MidiMessage::noteOn(10,60,(uint8)100)),"Channel change must keep the learned pad without relearning");
        panel.channel=2;panel.save();panel.midi(0x80,60,0,10);level(0);
        panel.channel=0;panel.save();
        panel.learning=3;panel.learningPreset=true;panel.midi(0xb0,32,127,1);
        panel.midi(0xb0,32,0,1);panel.midi(0xb0,32,127,1);
        recordingCaptureTests::require(panel.selected==3,"Preset MIDI learn did not select the preset");
        panel.select(0);panel.current(0).gate=false;
        auto &pad=panel.pads[0];const Point<float> point{10,10};const auto now=Time::getCurrentTime();
        MouseEvent down(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys(ModifierKeys::leftButtonModifier),1,0,0,0,0,&pad,&pad,now,point,now,1,false);
        MouseEvent up(Desktop::getInstance().getMainMouseSource(),point,ModifierKeys{},1,0,0,0,0,&pad,&pad,now,point,now,1,false);
        pad.mouseDown(down);pad.mouseUp(up);
        recordingCaptureTests::require(pad.isLit(),"Gate Off pad blanked before the callback received its trigger");
        level(.025f);panel.timerCallback();
        recordingCaptureTests::require(pad.isLit(),"Gate Off mouse release removed the sounding highlight");
        pad.mouseDown(down);pad.mouseUp(up);level(.05f);
        panel.gates[0].onClick();level(0);
        recordingCaptureTests::require(!pad.isLit(),"Enabling Gate did not stop all voices of that pad");
        panel.gates[0].onClick();pad.mouseDown(down);pad.mouseUp(up);level(.025f);
        for(int i=0;i<90;i++){output.clear();audio.render(output,512,44100);}
        recordingCaptureTests::require(!pad.isLit(),"Pad remained highlighted after its sample ended");
        pad.mouseDown(down);pad.mouseUp(up);level(.025f);panel.panic.onClick();level(0);
        recordingCaptureTests::require(!pad.isLit(),"Panic did not clear the sounding highlight");
        const auto stored=preferences.value("jaras.vinhetas");const auto mappings=get(stored,"padMappings");
        recordingCaptureTests::require(mappings.isArray()&&mappings.size()==16,"Pad mappings were duplicated per preset");
    }
};
}
namespace catlive::vinhetasTests {
template<class Test> void run(const File &directory, Test &&test) {
    test("Vinhetas has sixteen shared MIDI mappings, preset learn and note release after preset change",[&]{VinhetasPanelProbe::run(directory);});
    test("Vinhetas reaches its FX track with stopped transport and obeys fader and mute",[&] {
        jaras::Project project;jaras::Song song;song.id=uuid();song.duration=60;song.bpm=120;
        jaras::Track track;track.id=uuid();track.name="VINHETAS-FX";track.role.id="vinhetas";track.volume=.5;
        song.tracks.push_back(track);project.songs.push_back(song);
        AudioEngine audio;audio.prepareOffline(48000);audio.prepareSong(song,directory);audio.setMixer(project,song);
        auto sample=std::make_shared<VinhetasAudio::Sample>();sample->pcm.setSize(2,44100);
        for(int ch=0;ch<2;ch++)FloatVectorOperations::fill(sample->pcm.getWritePointer(ch),.025f,44100);
        auto *pcm=audio.vinhetas.retain(sample);audio.vinhetas.enqueue({VinhetasAudio::Kind::start,1,0,0,1,pcm});
        AudioBuffer<float> output(2,512);
        auto level=[&](float expected){for(int i=0;i<8;i++)audio.render(output.getArrayOfWritePointers(),2,512);recordingCaptureTests::require(std::abs(output.getSample(0,256)-expected)<.0001f,"Vinhetas routing/fader/mute differs from actual PCM");};
        level(.0125f);
        recordingCaptureTests::require(audio.meterLevels(track.id)[0]>.01f && audio.meterLevels(track.id)[1]>.01f,"VINHETAS-FX meters did not receive pad audio with stopped transport");
        song.tracks[0].mute=true;audio.setMixer(project,song);level(0);
        recordingCaptureTests::require(!audio.state().playing,"A pad started the transport");
        song.tracks.clear();audio.prepareSong(song,directory);audio.setMixer(project,song);level(0);
        recordingCaptureTests::require(!audio.vinhetas.active(0,0),"Deleting VINHETAS-FX left a sounding voice");
        recordingCaptureTests::require(!audio.vinhetas.enqueue({VinhetasAudio::Kind::start,2,0,0,1,pcm}),"Missing VINHETAS-FX accepted an audible trigger");level(0);
        song.tracks.push_back(track);audio.prepareSong(song,directory);audio.setMixer(project,song);level(0);
        recordingCaptureTests::require(audio.vinhetas.enqueue({VinhetasAudio::Kind::start,3,0,0,1,pcm}),"Existing VINHETAS-FX rejected a trigger");level(.0125f);

    });
    test("Vinhetas overlaps voices, gates independently and changes gain without restarting", [] {
        VinhetasAudio audio; audio.setOutputAvailable(true);
        auto sample=std::make_shared<VinhetasAudio::Sample>();sample->rate=44100;
        sample->pcm.setSize(2,44100);
        for(int ch=0;ch<2;ch++)FloatVectorOperations::fill(sample->pcm.getWritePointer(ch),.025f,44100);
        const auto *pcm=audio.retain(sample);AudioBuffer<float> output(2,512);
        auto level=[&](float wanted) {output.clear();audio.render(output,512,48000);recordingCaptureTests::require(std::abs(output.getSample(0,256)-wanted)<.00001f,"Vinhetas voice PCM changed");};
        audio.enqueue({VinhetasAudio::Kind::start,1,0,0,1,pcm});level(.025f);
        audio.enqueue({VinhetasAudio::Kind::start,2,0,0,1,pcm});level(.05f);
        audio.enqueue({VinhetasAudio::Kind::stop,2});level(.025f);
        audio.enqueue({VinhetasAudio::Kind::volume,0,0,0,.5f});level(.0125f);
        audio.enqueue({VinhetasAudio::Kind::stop,1});level(0);
        recordingCaptureTests::require(!audio.active(0,0),"Pad remains highlighted after Gate release");
    });
    test("Track output recording picks one stage without duplicating samples or gain", [&] {
        std::vector<TrackCapture::Target> targets;
        const auto id=uuid();
        for(int stage=0;stage<4;stage++) {
            TrackCapture::Target target;target.track=id;target.bus=true;target.output=true;
            target.outputPostFX=stage>=2;target.outputPostFader=stage%2==1;
            target.postFX=false;target.postFader=false;target.gain=.2f;
            target.file=directory.getNonexistentChildFile("vinhetas-output-"+String(stage),".wav");
            targets.push_back(target);
        }
        TrackCapture capture(targets,48000,24,120);
        AudioBuffer<float> block(2,512);
        for(int pass=0;pass<8;pass++) {
            for(int stage=0;stage<4;stage++) {
                for(int ch=0;ch<2;ch++)FloatVectorOperations::fill(block.getWritePointer(ch),.1f*(stage+1),512);
                capture.bus(id,block,512,true,stage>=2,stage%2==1);
            }
            capture.advance(512);
        }
        auto takes=capture.finish();recordingCaptureTests::require(takes.size()==4,"Missing output capture stages");
        for(int stage=0;stage<4;stage++) {
            auto reader=recordingCaptureTests::read(takes[(size_t)stage].file);
            recordingCaptureTests::require(reader->lengthInSamples==4096,"Output capture duplicated heads or stages");
            reader->read(&block,0,512,1024,true,true);
            recordingCaptureTests::require(std::abs(block.getSample(0,0)-.1f*(stage+1))<.00001f,"Output applied a second fader or wrong stage");
        }
    });
}
}
