#pragma once
#include "AudioExport.h"
#include "FXSchema.h"

namespace catlive::stemGraphTests {
inline constexpr int rate = 44100, frames = 16384, delay = 66150;
inline void require(bool condition, const String &message) {
    if (!condition) throw std::runtime_error(utf8(message));
}
inline var settings() {
    auto fx = fxschema::defaults(), mix = object();
    Array<var> sources;
    for (int i = 0; i < 5; ++i) {
        auto source = object();
        put(source, "gain", 1.); put(source, "mute", i == 0); put(source, "solo", false);
        sources.add(source);
    }
    // The identity worker returns half Vocal and half Other. Muting Vocal
    // proves that a passing graph used the worker, rather than dry fallback.
    put(mix, "sources", sources); put(fx, "stemMix", mix);
    put(fx, "stemSeparatorEnabled", true);
    put(fx, "inserted", Array<var>{String(native::stem::effectName)});
    return fx;
}
inline float sample(int frame, int channel) {
    const float value = frame == 2048 ? .125f : frame == frames - 1 ? .25f : 0;
    return channel == 0 ? value : value * .5f;
}
inline File writeSource(const File &directory) {
    const auto folder = directory.getChildFile("stem-graph-" + text(uuid()));
    require(folder.createDirectory().wasOk(), "Cannot create isolated stem graph fixture");
    WavAudioFormat format; auto stream = folder.getChildFile("impulses.wav").createOutputStream();
    require(stream != nullptr, "Cannot open stem graph fixture");
    std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(), rate, 2, 24, {}, 0));
    require(writer != nullptr, "Cannot create stem graph WAV writer"); stream.release();
    AudioBuffer<float> pcm(2, frames);
    for (int ch = 0; ch < 2; ++ch)
        for (int n = 0; n < frames; ++n) pcm.setSample(ch, n, sample(n, ch));
    require(writer->writeFromAudioSampleBuffer(pcm, 0, frames), "Cannot write stem graph PCM");
    return folder;
}
inline jaras::Track track(const char *name) {
    jaras::Track result; result.id = uuid(); result.name = name;
    jaras::AudioClip clip; clip.id = uuid(); clip.name = "Impulses";
    clip.duration = frames / double(rate); clip.audioFile = jaras::AudioFile{"impulses.wav", {}};
    result.clips.push_back(clip);
    return result;
}
inline jaras::Project project(std::vector<jaras::Track> tracks) {
    jaras::Project result; result.id = uuid(); result.name = "CatStem graph fixture";
    jaras::Song song; song.id = uuid(); song.name = "Impulses";
    song.duration = frames / double(rate); song.tracks = std::move(tracks);
    result.songs.push_back(std::move(song)); return result;
}
using Expected = std::function<float(int, int)>;
inline void checkPCM(const AudioBuffer<float> &pcm, const Expected &expected, const String &label) {
    for (int ch = 0; ch < pcm.getNumChannels(); ++ch)
        for (int n = 0; n < pcm.getNumSamples(); ++n) {
            const float actual = pcm.getSample(ch, n), wanted = expected(n, ch);
            if (!std::isfinite(actual) || std::abs(actual - wanted) > .00002f)
                throw std::runtime_error(utf8(label + " channel=" + String(ch + 1) +
                    " frame=" + String(n) + " actual=" + String(actual, 8) + " expected=" + String(wanted, 8)));
        }
}
inline void render(const jaras::Project &p, const File &media, int channels,
                   int sourceFrames, const Expected &expected, bool naturalEnd = false,
                   int subStart = -1, const ID &capture = {}, bool captureTrack = false) {
    AudioEngine engine; engine.prepareOffline(rate);
    const auto master = p.masterFXJSON ? JSON::parse(text(*p.masterFXJSON)) : var();
    engine.prepareSong(p.songs[0], media, master, &p);
    engine.setOffline(true); engine.setMixer(p, p.songs[0]);
    if (captureTrack) engine.setExportCapture(capture);
    if (!naturalEnd) engine.extendOfflineDuration((sourceFrames + delay + 1024) / double(rate));
    engine.waitForStems();
    require(engine.missingFiles.isEmpty() && engine.unsupported.isEmpty(), "Stem graph preparation rejected a valid fixture");
    AudioEngine::State state; state.playing = true;
    state.subPlaying = subStart >= 0; state.subPosition = std::max(0, subStart) / double(rate);
    engine.transport(state);
    // Odd buffer sizes cross both host and CST1 block boundaries.
    AudioBuffer<float> output(channels, sourceFrames + delay + 1024);
    for (int offset = 0; offset < output.getNumSamples();) {
        const int count = std::min(257, output.getNumSamples() - offset);
        std::array<float *, 4> pointers{};
        for (int ch = 0; ch < channels; ++ch) pointers[size_t(ch)] = output.getWritePointer(ch, offset);
        engine.render(pointers.data(), channels, count); engine.checkStemErrors(); offset += count;
        if (naturalEnd) {
            const auto audible = engine.presentationState();
            require(audible.playing == (offset < sourceFrames + delay),
                    "Natural-end presentation stopped before the delayed audio drained, or remained active afterwards");
            require(std::abs(audible.position - jlimit(0, sourceFrames, offset - delay) / double(rate)) < 1.5 / rate,
                    "Natural-end presentation cursor does not follow the delayed output");
        }
    }
    checkPCM(output, [&](int n, int ch) { return expected(n - delay, ch); }, "CatStem graph PDC");
}
template <typename Test>
void registerTests(const File &directory, Test &test, StringArray &skipped) {
    test("Legacy offline-only CatStem settings preserve dry audio without a worker", [&] {
        auto configuration=settings(); configuration.getDynamicObject()->removeProperty("stemMix");
        const auto saved=JSON::toString(configuration);
        for(bool offline : {false,true}) {
            NativeFX effects; effects.prepare(configuration,rate,nullptr,offline);
            AudioBuffer<float> pcm(2,128);
            for(int ch=0;ch<2;++ch)for(int n=0;n<128;++n)pcm.setSample(ch,n,(ch?-.25f:.5f)*n/128.f);
            AudioBuffer<float> original;original.makeCopyOf(pcm);
            effects.process(pcm,128);effects.checkStemErrors();
            require(!effects.hasActiveStem() && effects.latencyFrames()==0 && effects.unsupported.isEmpty(),
                    "Unavailable CatStem must not start a worker, delay audio or report an unsupported effect");
            for(int ch=0;ch<2;++ch)for(int n=0;n<128;++n)
                require(pcm.getSample(ch,n)==original.getSample(ch,n),"Legacy settings changed dry audio");
            require(JSON::toString(configuration)==saved,"Legacy settings changed the saved Mac-compatible settings");
        }
    });
    // runTests is only called by Main's --self-test branch. The environment
    // gate is additional; the ordinary installed application never uses this.
    if (SystemStats::getEnvironmentVariable("CATLIVE_STEM_IDENTITY_TEST", {}) != "1") {
        skipped.add("CatStem graph identity worker (CATLIVE_STEM_IDENTITY_TEST=1)"); return;
    }
    bool fixtureReady = false;
    test("CatStem graph fixture is isolated from the production model worker", [&] {
        const auto paths = native::stem::Paths::bundled();
        require(paths.available(), "Isolated StemSeparationRuntime is incomplete");
        const File worker(String(paths.worker.wstring().c_str()));
        require(worker.loadFileAsString().contains("Deterministic CST1 fixture"),
                "Refusing graph identity tests with the production worker: use an isolated executable/runtime copy");
        fixtureReady = true;
    });
    if (!fixtureReady) return;
    for(int location=0;location<4;++location) {
        const StringArray names{"track","item","group","Master"};
        test("CatStem live "+names[location]+" insertion admits without Stop and preserves both heads",[&,location]{
            auto wet=track("Live wet"),dry=track("Live dry");
            jaras::Track group;group.id=uuid();group.name="Live group";group.role.id="group";
            if(location==2)wet.parentTrackID=group.id;
            const auto p=project(location==2?std::vector<jaras::Track>{group,wet,dry}:std::vector<jaras::Track>{wet,dry});
            const ID target=location==0?wet.id:location==1?wet.clips[0].id:location==2?group.id:ID{};
            const auto media=writeSource(directory);
            AudioEngine engine(rate);engine.prepareSong(p.songs[0],media,{},&p);
            engine.setOffline(true);engine.setMixer(p,p.songs[0]); // deterministic readers; DSP remains realtime
            constexpr int loopFrames=8192,firstFrames=512,subOffset=4096;
            AudioEngine::State state;state.playing=true;state.subPlaying=true;state.subPosition=subOffset/double(rate);
            state.loop=true;state.loopEnd=loopFrames/double(rate);engine.transport(state);
            AudioBuffer<float> first(2,firstFrames);engine.render(first.getArrayOfWritePointers(),2,firstFrames);
            checkPCM(first,[=](int n,int ch){return 2.f*(sample(n,ch)+sample(n+subOffset,ch));},"Before live insertion");
            const auto before=engine.presentationState();
            engine.setEffects(target,settings());
            const auto deadline=Time::getMillisecondCounterHiRes()+30000;
            for(;;) {
                const auto status=engine.stemStatus(target,native::stem::effectName);
                require(status.state!="fault","Live CatStem preparation failed: "+text(status.error));
                if(status.ready)break;
                require(Time::getMillisecondCounterHiRes()<deadline,"Live CatStem worker did not prepare");
                Thread::sleep(10);
            }
            engine.refreshStemLatency();
            require(engine.presentationLatencyFrames()==delay,"Ready CatStem still requires Stop to admit compensation");
            auto admitted=engine.presentationState();
            require(admitted.playing&&admitted.subPlaying&&engine.state().playing&&engine.state().subPlaying,
                    "Live admission manufactured a transport Stop");
            require(std::abs(admitted.position-before.position)<1.5/rate&&
                    std::abs(admitted.subPosition-before.subPosition)<1.5/rate,
                    "Live admission jumped either audible cursor");
            auto pacedRender=[&](AudioBuffer<float> &output,const std::function<void(int)> &check={}) {
                for(int offset=0;offset<output.getNumSamples();) {
                    const int count=std::min(257,output.getNumSamples()-offset);
                    float *pointers[]{output.getWritePointer(0,offset),output.getWritePointer(1,offset)};
                    engine.render(pointers,2,count);engine.checkStemErrors();offset+=count;
                    if(check)check(offset);
                    // This is the realtime worker path, so let the isolated IPC
                    // worker run instead of overrunning it with offline bursts.
                    Thread::sleep(int(std::ceil(count*1000./rate))+1);
                }
            };
            AudioBuffer<float> output(2,delay+frames);
            pacedRender(output,[&](int count){
                const auto audible=engine.presentationState();const int consumed=std::max(0,count-delay);
                const double main=consumed==0?firstFrames/double(rate):((firstFrames+consumed-1)%loopFrames+1)/double(rate);
                require(audible.playing&&audible.subPlaying&&std::abs(audible.position-main)<1.5/rate&&
                        std::abs(audible.subPosition-(firstFrames+subOffset+consumed)/double(rate))<1.5/rate,
                        "Live admission lost the loop or Subplay presentation history");
            });
            checkPCM(output,[=](int n,int ch){
                if(n<delay)return 0.f;
                const int source=n-delay+firstFrames;
                return (location==3?1.f:1.5f)*(sample(source%loopFrames,ch)+sample(source+subOffset,ch));
            },"Live insertion compensated PCM");
            if(location==0) {
                // Each block starts at the same loop phase. The impulse is
                // 1536 frames later, beyond the documented 3 ms gain smoothing.
                auto verifyControl=[&](const var &fx,float gain,const String &label){
                    const auto previous=engine.presentationState();
                    engine.setEffects(target,fx);engine.refreshStemLatency();
                    const auto next=engine.presentationState();
                    require(engine.presentationLatencyFrames()==delay&&next.playing&&next.subPlaying&&
                            std::abs(next.position-previous.position)<1.5/rate,
                            label+" reset active delay history");
                    const int sourceStart=int(std::llround(previous.position*rate));
                    const int subStart=int(std::llround(previous.subPosition*rate));
                    AudioBuffer<float> changed(2,loopFrames);pacedRender(changed);
                    checkPCM(changed,[&](int n,int ch){return gain*(sample((sourceStart+n)%loopFrames,ch)+sample(subStart+n,ch));},label);
                };
                auto quieter=settings();auto quietSources=list(get(get(quieter,"stemMix"),"sources"));put(quietSources[4],"gain",.5);
                verifyControl(quieter,1.25f,"Live CatStem gain");
                auto bypassed=settings();put(bypassed,"stemSeparatorEnabled",false);
                verifyControl(bypassed,2.f,"Live CatStem bypass");
                verifyControl(settings(),1.5f,"Live CatStem reenable");
                verifyControl(fxschema::defaults(),2.f,"Live CatStem removal retains dry compensation");
                state.playing=false;state.subPlaying=false;state.position=.125;state.subPosition=.25;
                engine.transport(state);engine.render(first.getArrayOfWritePointers(),2,257);engine.refreshStemLatency();
                require(engine.presentationLatencyFrames()==0&&!engine.presentationState().playing,
                        "Stopped graph retained a removed CatStem delay");
                require(first.getMagnitude(0,257)<.00002f,"Stop leaked the retired CatStem epoch");
            } else {
                state.position=4096./rate;state.subPosition=7680./rate;engine.transport(state);
                AudioBuffer<float> sought(2,delay+12288);pacedRender(sought);
                checkPCM(sought,[=](int n,int ch){
                    if(n<delay)return 0.f;
                    const int source=n-delay;
                    return (location==3?1.f:1.5f)*(sample((4096+source)%loopFrames,ch)+sample(7680+source,ch));
                },"Seek clears pre-insertion CatStem history");
            }
        });
    }
    test("CatStem track and dry track stay sample aligned", [&] {
        auto wet = track("Wet"), dry = track("Dry"); wet.fxJSON = utf8(JSON::toString(settings()));
        render(project({wet, dry}), writeSource(directory), 2, frames,
               [](int n, int ch) { return 1.5f * sample(n, ch); });
    });
    test("CatStem nested groups compensate dry children and independent tracks", [&] {
        auto wet = track("Wet"), child = track("Dry child"), dry = track("Dry master");
        jaras::Track group; group.id = uuid(); group.name = "Group"; group.role.id = "group"; group.volume = .5;
        jaras::Track nested; nested.id = uuid(); nested.name = "Nested"; nested.role.id = "group";
        nested.parentTrackID = group.id; wet.parentTrackID = nested.id; child.parentTrackID = nested.id;
        wet.fxJSON = utf8(JSON::toString(settings()));
        render(project({group, nested, wet, child, dry}), writeSource(directory), 2, frames,
               [](int n, int ch) { return 1.75f * sample(n, ch); });
    });
    test("CatStem sends align with destination clips without duplicate routes", [&] {
        auto wet = track("Send"), receive = track("Receive"), dry = track("Dry");
        wet.fxJSON = utf8(JSON::toString(settings())); wet.outputs = std::vector<jaras::OutputPatch>{{-1, 2}};
        wet.routing = jaras::TrackRouting{{}, {receive.id}};
        receive.routing = jaras::TrackRouting{{wet.id}, {}}; receive.volume = .5;
        render(project({receive, dry, wet}), writeSource(directory), 2, frames,
               [](int n, int ch) { return 1.75f * sample(n, ch); });
    });
    test("CatStem direct hardware output aligns with dry Master and bypasses its fader", [&] {
        auto wet = track("Direct 3-4"), dry = track("Master");
        wet.fxJSON = utf8(JSON::toString(settings())); wet.outputs = std::vector<jaras::OutputPatch>{{3, 2}};
        auto p = project({wet, dry}); p.masterVolume = .25;
        render(p, writeSource(directory), 4, frames,
               [](int n, int ch) { return sample(n, ch % 2) * (ch < 2 ? .25f : .5f); });
    });
    test("CatStem Master aligns dry hardware routes with the processed sum", [&] {
        auto first = track("Master A"), second = track("Master B"), direct = track("Direct");
        direct.outputs = std::vector<jaras::OutputPatch>{{3, 2}};
        auto p = project({first, second, direct}); p.masterFXJSON = utf8(JSON::toString(settings()));
        render(p, writeSource(directory), 4, frames,
               [](int n, int ch) { return sample(n, ch % 2); });
    });
    test("CatStem item aligns later dry items on its track and parallel dry audio", [&] {
        auto wet = track("Item FX"), dry = track("Reference");
        const int offset = frames + 1024;
        auto nextWet = wet.clips[0]; nextWet.id = uuid(); nextWet.startTime = offset / double(rate);
        auto nextDry = dry.clips[0]; nextDry.id = uuid(); nextDry.startTime = nextWet.startTime;
        wet.clips[0].fxJSON = utf8(JSON::toString(settings()));
        wet.clips.push_back(nextWet); dry.clips.push_back(nextDry);
        auto p = project({wet, dry}); p.songs[0].duration = (offset + frames) / double(rate);
        render(p, writeSource(directory), 2, offset + frames,
               [offset](int n, int ch) { return 1.5f * sample(n, ch) + 2.f * sample(n - offset, ch); });
    });
    test("CatStem drains the last source frame after the timeline reaches its natural end", [&] {
        auto wet = track("Tail"), dry = track("Dry"); wet.fxJSON = utf8(JSON::toString(settings()));
        render(project({wet, dry}), writeSource(directory), 2, frames,
               [](int n, int ch) { return 1.5f * sample(n, ch); }, true);
    });
    for (bool item : {false, true}) test(String("CatStem ") + (item ? "item" : "track") + " processes main and Sub Play in one aligned stream", [&, item] {
        auto wet = track("Both heads"), dry = track("Dry");
        (item ? wet.clips[0].fxJSON : wet.fxJSON) = utf8(JSON::toString(settings()));
        render(project({wet, dry}), writeSource(directory), 2, frames,
               [](int n, int ch) { return 1.5f * (sample(n, ch) + (n >= 0 ? sample(n + 4096, ch) : 0)); }, false, 4096);
    });
    test("CatStem short loops retain PCM and audible cursor history across wraps and clear on Stop", [&] {
        auto wet = track("Loop"), dry = track("Dry"); wet.fxJSON = utf8(JSON::toString(settings()));
        const auto p = project({wet, dry}); const auto media = writeSource(directory);
        AudioEngine engine; engine.prepareOffline(rate); engine.prepareSong(p.songs[0], media, {}, &p);
        engine.setOffline(true); engine.setMixer(p, p.songs[0]); engine.waitForStems();
        constexpr int loopFrames = 8192;
        AudioEngine::State state; state.playing = true; state.loop = true; state.loopEnd = loopFrames / double(rate);
        engine.transport(state);
        AudioBuffer<float> output(2, delay + 3 * loopFrames + 1024);
        for (int offset = 0; offset < output.getNumSamples();) {
            const int count = std::min(257, output.getNumSamples() - offset);
            float *pointers[]{output.getWritePointer(0, offset), output.getWritePointer(1, offset)};
            engine.render(pointers, 2, count); engine.checkStemErrors(); offset += count;
            const auto audible = engine.presentationState();
            const double position = offset <= delay ? 0 : ((offset - delay - 1) % loopFrames + 1) / double(rate);
            require(audible.playing && std::abs(audible.position - position) < 1.5 / rate,
                    "Audible loop cursor reset early or followed the future render cursor");
        }
        checkPCM(output, [loopFrames](int n, int ch) {
            return n < delay ? 0.f : 1.5f * sample((n - delay) % loopFrames, ch);
        }, "CatStem short-loop PCM");
        state.playing = false; state.position = .125; engine.transport(state);
        engine.render(output.getArrayOfWritePointers(), 2, 257);
        require(output.getMagnitude(0, 257) < .00002f, "Stop leaked buffered loop audio");
        const auto audible = engine.presentationState();
        require(!audible.playing && std::abs(audible.position - .125) < 1.5 / rate,
                "Stop left stale presentation history");
    });
    const StringArray controlNames{"dry volume", "wet volume", "dry mute", "wet mute", "wet solo", "dry phase", "dry pan", "dry Fadeout"};
    for(int control=0;control<controlNames.size();++control)test("CatStem PDC responds immediately to "+controlNames[control]+" and preserves queued audio",[&,control]{
        auto wet=track("Wet control"),dry=track("Dry control");wet.fxJSON=utf8(JSON::toString(settings()));
        auto p=project({wet,dry});const auto media=writeSource(directory);
        AudioEngine engine;engine.prepareOffline(rate);engine.prepareSong(p.songs[0],media,{},&p);
        engine.setOffline(true);engine.setMixer(p,p.songs[0]);engine.waitForStems();
        engine.extendOfflineDuration((frames+delay+2048)/double(rate));
        AudioEngine::State state;state.playing=true;engine.transport(state);
        AudioBuffer<float> output(2,frames+delay+1024);bool changed=false,restored=false;
        int controlStartFrame=0;
        auto controlState=[&](bool on){
            auto &wetTrack=p.songs[0].tracks[0],&dryTrack=p.songs[0].tracks[1];
            if(control==0)dryTrack.volume=on?.25:1;
            if(control==1)wetTrack.volume=on?.25:1;
            if(control==2)dryTrack.mute=on;
            if(control==3)wetTrack.mute=on;
            if(control==4)wetTrack.solo=on;
            if(control==5)dryTrack.phaseInverted=on;
            if(control==6)dryTrack.pan=on?1:0;
            if(control==7){if(on)engine.startTrackFadeout({dryTrack.id},1);else engine.cancelTrackFadeout();}
            engine.setMixer(p,p.songs[0]);
        };
        for(int offset=0;offset<output.getNumSamples();) {
            if(!changed&&offset>=4096){changed=true;controlStartFrame=offset;controlState(true);}
            if(!restored&&offset>=delay+4096){restored=true;controlState(false);}
            const int count=std::min(257,output.getNumSamples()-offset);
            float *pointers[]{output.getWritePointer(0,offset),output.getWritePointer(1,offset)};
            engine.render(pointers,2,count);engine.checkStemErrors();offset+=count;
        }
        checkPCM(output,[control,controlStartFrame](int frame,int ch){
            const int source=frame-delay;float gain=1.5f;
            if(source==2048){
                if(control==0)gain=.75f;else if(control==1)gain=1.125f;
                else if(control==2||control==4)gain=.5f;
                // A one-second fade is still in progress when the shorter
                // CatStem latency delivers this impulse. Validate its audible
                // position on the ramp, not an assumed already-muted output.
                else if(control==7)gain=.5f+std::clamp(1.f-float(frame-controlStartFrame)/float(rate-1),0.f,1.f);
                else if(control==3)gain=1;else if(control==5)gain=-.5f;
                else if(control==6)gain=ch==0?.5f:1.5f;
            }
            return gain*sample(source,ch);
        },"PDC live control");
    });
    test("CatStem scheduled Part jump preserves queued PCM and its audible timeline",[&]{
        auto wet=track("Part wet"),dry=track("Part dry");wet.fxJSON=utf8(JSON::toString(settings()));
        auto p=project({wet,dry});const auto media=writeSource(directory);
        AudioEngine engine;engine.prepareOffline(rate);engine.prepareSong(p.songs[0],media,{},&p);
        engine.setOffline(true);engine.setMixer(p,p.songs[0]);engine.waitForStems();
        engine.extendOfflineDuration((frames+delay+8192)/double(rate));
        AudioEngine::State state;state.playing=true;engine.transport(state);
        AudioBuffer<float> output(2,frames+delay+1024);bool jumped=false;
        for(int offset=0;offset<output.getNumSamples();) {
            if(!jumped&&offset==4096){jumped=true;state.position=8192./rate;state.preserveLatency=true;engine.transport(state);}
            const int count=std::min({257,output.getNumSamples()-offset,jumped?257:4096-offset});
            float *pointers[]{output.getWritePointer(0,offset),output.getWritePointer(1,offset)};
            engine.render(pointers,2,count);engine.checkStemErrors();offset+=count;
            const int audible=std::max(0,offset-delay);
            const double expected=(audible+(audible>4096?4096:0))/double(rate);
            require(std::abs(engine.presentationState().position-expected)<1.5/rate,"Scheduled Part jump exposed the future cursor or cleared presentation history");
        }
        checkPCM(output,[](int frame,int ch){const int source=frame-delay;return 1.5f*sample(source+(source>=4096?4096:0),ch);},"Scheduled Part jump queued PCM");
    });
    test("CatStem selected-track export capture keeps the track latency independent of Master", [&] {
        auto wet = track("Track capture"), dry = track("Dry"); wet.fxJSON = utf8(JSON::toString(settings()));
        auto p = project({wet, dry}); p.masterVolume = .25;
        render(p, writeSource(directory), 2, frames,
               [](int n, int ch) { return .5f * sample(n, ch); }, false, -1, wet.id, true);
    });
    test("CatStem WAV export removes preroll latency and preserves the final item sample", [&] {
        auto wet = track("Export"), dry = track("Dry"); wet.fxJSON = utf8(JSON::toString(settings()));
        auto p = project({wet, dry}); const auto media = writeSource(directory);
        ExportRequest request; request.directory = media.getChildFile("export"); request.encodings[0].rate = rate;
        ExportJob job; job.name = "aligned.wav"; job.start = 128. / rate; job.end = frames / double(rate);
        request.jobs.push_back(job); std::atomic<bool> cancel{false};
        audioExport::render(p, p.songs[0], media, request, cancel, {});
        AudioFormatManager formats; formats.registerBasicFormats();
        std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(request.directory.getChildFile(job.name)));
        require(reader && reader->sampleRate == rate && reader->numChannels == 2 && reader->lengthInSamples == frames - 128,
                "Export latency altered the requested file length/rate/channels");
        AudioBuffer<float> output(2, frames - 128); require(reader->read(&output, 0, output.getNumSamples(), 0, true, true), "Cannot read exported fixture");
        checkPCM(output, [](int n, int ch) { return 1.5f * sample(n + 128, ch); }, "CatStem exported PCM");
    });
}
} // namespace catlive::stemGraphTests
