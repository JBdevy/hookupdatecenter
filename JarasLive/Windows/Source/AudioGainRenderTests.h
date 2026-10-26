#pragma once
#include "AudioEngine.h"

namespace catlive::audioGainRenderTests {
inline void require(bool value, const String& message) {
    if (!value) throw std::runtime_error(utf8(message));
}
inline jaras::Song inputSong() {
    jaras::Song song; song.id = uuid(); song.duration = 10;
    jaras::Track track; track.id = uuid(); track.role.id = "other";
    track.inputPatch = jaras::OutputPatch{1, 2}; track.inputMonitoring = true;
    track.outputs = std::vector<jaras::OutputPatch>{{0, 2}};
    song.tracks.push_back(track);
    return song;
}
inline void fill(AudioBuffer<float>& input) {
    for (int n = 0; n < input.getNumSamples(); ++n) {
        input.setSample(0, n, .2f + .001f * n);
        input.setSample(1, n, -.1f - .0005f * n);
    }
}
inline void staticGain(const File& directory) {
    auto engine = std::make_unique<AudioEngine>();
    engine->prepareOffline(48000); engine->instrumentAllowed = true;
    jaras::Project project; project.masterOutputs = std::vector<jaras::OutputPatch>{{1, 2}};
    auto song = inputSong();
    engine->prepareSong(song, directory, {}, &project); engine->armTrack(song.tracks[0].id, true);
    // An odd block length covers the scalar tail of the vector operation too.
    AudioBuffer<float> input(2, 47), output(2, 47); fill(input);
    for (const auto levels : {std::pair<double,double>{0,1}, {1,0}, {.6,.7}, {1,1}, {1.4,1.2}})
        for (double trackPan : {-1., -.35, 0., .4, 1.})
            for (double masterPan : {-1., 0., 1.})
                for (int phase = 0; phase < 4; ++phase)
                    for (bool mono : {false, true})
                        for (int mute = 0; mute < 4; ++mute) {
                            auto& track = song.tracks[0];
                            track.volume = levels.first; track.pan = trackPan;
                            track.phaseInverted = (phase & 1) != 0; track.mute = (mute & 1) != 0;
                            project.masterVolume = levels.second; project.masterPan = masterPan;
                            project.masterPhaseInverted = (phase & 2) != 0;
                            project.masterMute = (mute & 2) != 0; project.masterMono = mono;
                            engine->setMixer(project, song);
                            engine->render(output.getArrayOfWritePointers(), 2, 47, input.getArrayOfReadPointers(), 2);
                            for (int n = 0; n < 47; ++n) {
                                double left = input.getSample(0, n) * levels.first * (phase & 1 ? -1 : 1) * (trackPan > 0 ? 1 - trackPan : 1);
                                double right = input.getSample(1, n) * levels.first * (phase & 1 ? -1 : 1) * (trackPan < 0 ? 1 + trackPan : 1);
                                if (mono) left = right = (left + right) * .5;
                                const double gain = mute ? 0 : levels.second * (phase & 2 ? -1 : 1);
                                left *= gain * (masterPan > 0 ? 1 - masterPan : 1);
                                right *= gain * (masterPan < 0 ? 1 + masterPan : 1);
                                require(std::abs(output.getSample(0, n) - left) < .000002 &&
                                        std::abs(output.getSample(1, n) - right) < .000002,
                                        "Vectorized gain changed volume, pan, phase, mute or mono routing");
                            }
                        }
}
inline var point(double time, double value, const String& shape = "linear") {
    auto p = object(); put(p, "time", time); put(p, "value", value); put(p, "shape", shape); return p;
}
inline void automatedMaster(const File& directory) {
    auto volume = automation::envelope("volume", AutomationCurve::normalized(.25));
    put(volume, "valueScale", "linearGain");
    put(volume, "points", Array<var>{point(0, AutomationCurve::normalized(.25)), point(1, AutomationCurve::normalized(.75))});
    auto pan = automation::envelope("pan", .25);
    put(pan, "points", Array<var>{point(0, .25), point(1, .75)});
    auto mute = automation::envelope("mute", 0);
    put(mute, "points", Array<var>{point(0, 0, "square"), point(.2505, 1, "square")});
    auto settings = object(); put(settings, "mode", "read");
    put(settings, "envelopes", Array<var>{volume, pan, mute});
    jaras::Project project; project.masterOutputs = std::vector<jaras::OutputPatch>{{1, 2}};
    project.masterAutomationJSON = utf8(JSON::toString(settings, true));
    project.masterPhaseInverted = true; project.masterMono = true; project.masterVolume = 0;
    auto song = inputSong(); song.tracks[0].volume = .8; song.tracks[0].pan = -.25;
    auto engine = std::make_unique<AudioEngine>(); engine->prepareOffline(48000); engine->instrumentAllowed = true;
    engine->prepareSong(song, directory, {}, &project); engine->setMixer(project, song);
    engine->armTrack(song.tracks[0].id, true);
    AudioEngine::State state; state.playing = true; state.position = .25; engine->transport(state);
    AudioBuffer<float> input(2, 47), output(2, 47); fill(input);
    engine->render(output.getArrayOfWritePointers(), 2, 47, input.getArrayOfReadPointers(), 2);
    for (int n = 0; n < 47; ++n) {
        const double time = .25 + n / 48000.;
        const double mono = (input.getSample(0, n) * .8 + input.getSample(1, n) * .8 * .75) * .5;
        const double gain = time >= .2505 ? 0 : -(.25 + .5 * time);
        const double position = -.5 + time;
        require(std::abs(output.getSample(0, n) - mono * gain) < .000002 &&
                std::abs(output.getSample(1, n) - mono * gain * (1 + position)) < .000002,
                "Master automation lost sample timing, stereo pan, phase or mono order");
    }
}
inline void monitorOff(const File& directory) {
    auto engine = std::make_unique<AudioEngine>();
    engine->prepareOffline(48000); engine->instrumentAllowed = true;
    jaras::Project project; project.masterOutputs = std::vector<jaras::OutputPatch>{{1, 2}};
    auto song = inputSong();
    engine->prepareSong(song, directory, {}, &project);
    engine->armTrack(song.tracks[0].id, true);
    AudioBuffer<float> input(2, 128), output(2, 128); fill(input);
    for (bool monitoring : {false, true, false}) {
        song.tracks[0].inputMonitoring = monitoring;
        engine->setMixer(project, song);
        engine->render(output.getArrayOfWritePointers(), 2, 128, input.getArrayOfReadPointers(), 2);
        require(engine->trackPeak(song.tracks[0].id) > .1f, "Monitor Off hid the armed input meter");
        for (int channel = 0; channel < 2; ++channel)
            for (int sample = 0; sample < 128; ++sample)
                require(std::abs(output.getSample(channel, sample) - (monitoring ? input.getSample(channel, sample) : 0.f)) < .000002f,
                        "Monitor Off must silence the return without disabling capture input");
    }
}
inline void hardPanSilence(const File& directory) {
    const auto report=directory.getChildFile("pan-endpoints.csv");
    require(report.replaceWithText("input_channels,stage,reverb,automation,pan,silent_peak,audible_peak\n"),"Could not create pan endpoint measurements");
    // Feed distinct stereo PCM (or a duplicated mono input) through two parent
    // groups. Test the real render graph, including a stereo effect before the
    // pan stage, rather than checking the gain formula in isolation.
    for(int inputChannels:{1,2})for(int stage=0;stage<4;++stage)
        for(bool effect:{false,true})for(bool automated:{false,true})for(double position:{-1.,1.}) {
            jaras::Project project;project.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
            auto song=inputSong();auto& leaf=song.tracks.front();
            leaf.inputPatch=jaras::OutputPatch{1,inputChannels};
            jaras::Track inner,outer;inner.id=uuid();outer.id=uuid();inner.role.id="other";outer.role.id="other";
            leaf.parentTrackID=inner.id;inner.parentTrackID=outer.id;
            leaf.outputs=std::vector<jaras::OutputPatch>{{-2,2}};inner.outputs=std::vector<jaras::OutputPatch>{{-2,2}};
            outer.outputs=std::vector<jaras::OutputPatch>{{0,2}};
            const auto leafID=leaf.id;song.tracks.push_back(inner);song.tracks.push_back(outer);
            if(automated) {
                auto envelope=automation::envelope("pan",position>0?1.:0.);
                put(envelope,"points",Array<var>{point(0,position>0?1.:0.)});
                auto settings=object();put(settings,"mode","read");put(settings,"envelopes",Array<var>{envelope});
                auto& destination=stage==3?project.masterAutomationJSON:song.tracks[size_t(stage)].automationJSON;
                destination=utf8(JSON::toString(settings,true));
            } else if(stage==3)project.masterPan=position;
            else song.tracks[size_t(stage)].pan=position;
            var masterFX;
            if(effect) {
                auto settings=object();put(settings,"inserted",Array<var>{"Reverb"});
                put(settings,"reverbEnabled",true);put(settings,"reverbMix",80.);
                put(settings,"reverbDecay",2.);put(settings,"reverbRoom",1.);
                if(stage==3){masterFX=settings;project.masterFXJSON=utf8(JSON::toString(settings,true));}
                else song.tracks[size_t(stage)].fxJSON=utf8(JSON::toString(settings,true));
            }
            auto engine=std::make_unique<AudioEngine>();engine->prepareOffline(48000);engine->instrumentAllowed=true;
            engine->prepareSong(song,directory,masterFX,&project);engine->setMixer(project,song);engine->armTrack(leafID,true);
            AudioBuffer<float> input(2,127),output(2,127);fill(input);
            const int silent=position>0?0:1,audible=1-silent;
            float audiblePeak=0,silentPeak=0;
            for(int block=0;block<32;++block) {
                engine->render(output.getArrayOfWritePointers(),2,127,input.getArrayOfReadPointers(),inputChannels);
                silentPeak=std::max(silentPeak,output.getMagnitude(silent,0,127));
                require(silentPeak==0.f,
                    "Hard pan leaked PCM: stage="+String(stage)+" input="+String(inputChannels)+" fx="+String(int(effect))+" automation="+String(int(automated))+" pan="+String(position));
                audiblePeak=std::max(audiblePeak,output.getMagnitude(audible,0,127));
            }
            require(audiblePeak>.001f,"Hard-pan silence test did not route an audible source");
            report.appendText(String(inputChannels)+","+String(stage)+","+String(int(effect))+","+String(int(automated))+","+String(position)+","+String(silentPeak,9)+","+String(audiblePeak,9)+"\n");
        }
}
template <typename Register>
void registerTests(const File& directory, Register&& test) {
    test("Loopback input uses the track Monitor Off switch while keeping armed meters", [&] { monitorOff(directory); });
    test("Static track and master gains preserve stereo PCM phase mute pan and mono", [&] { staticGain(directory); });
    test("Master evaluates sample automation consistently across stereo channels", [&] { automatedMaster(directory); });
    test("Hard pan silences the opposite channel exactly for mono stereo nested groups and Master", [&] { hardPanSilence(directory); });
}
} // namespace catlive::audioGainRenderTests
