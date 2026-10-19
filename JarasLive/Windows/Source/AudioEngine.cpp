#include "MediaSource.h"
#include "ProjectionSelection.h"
#include "MeterDisplay.h"
#include "AudioEngine.h"
#include "ProjectCodec.h"
#include "ClipAudio.h"
#include "WaveformCache.h"
#include "../../WindowsNative/Source/AudioFile.h"
#include <BinaryData.h>
namespace catlive {
struct AudioEngine::ReaderContext {
    AudioFormatManager formats;
    TimeSliceThread thread{"CatLive media read-ahead"};
    ReaderContext() { registerAudioFormats(formats); thread.startThread(Thread::Priority::high); }
    ~ReaderContext() { thread.stopThread(5000); }
};
AudioEngine::AudioEngine(double preparationRate, bool preparingOffline, std::shared_ptr<AudioDeviceManager> host)
    : deviceHost(host ? std::move(host) : std::make_shared<AudioDeviceManager>()), devices(*deviceHost) {
    rate = preparationRate;
    offlineMode = preparingOffline;
    for (int i = 0; i < 128; ++i)
        inputMapping[(size_t)i] = outputMapping[(size_t)i] = i;
    liveMidi.ensureSize(32768);
    midiInput.reset(48000);
    keyboardMidi.ensureSize(32768);
    for (int i = 0; i < 3; ++i) {
        midiSlots[i].reset(48000);
        slotMessages[i].ensureSize(32768);
    }
    registerAudioFormats(formats);
    metronome.a = ClickProgram::tone("Digital", true);
    metronome.b = ClickProgram::tone("Digital", false);
}
AudioEngine::~AudioEngine() {
    timecodeMIDI.stop();
    devices.removeMidiInputDeviceCallback({}, this);
    stopRecording();
    closeDevice();
    voices.clear();
}
void AudioEngine::startRecording(const File &file, int channels, int bits) {
    if (recording.load())
        return;
    auto *device = devices.getCurrentAudioDevice();
    if (!device || device->getActiveInputChannels().countNumberOfSetBits() < channels)
        throw std::runtime_error(
            "Ative os canais de entrada nas configurações de áudio antes de gravar.");
    if (file.existsAsFile())
        throw std::runtime_error("O arquivo da gravação já existe.");
    file.getParentDirectory().createDirectory();
    auto stream = std::make_unique<FileOutputStream>(file);
    if (!stream->openedOk())
        throw std::runtime_error("Não foi possível abrir a gravação.");
    WavAudioFormat wav;
    RecordingAiffFormat aiff;
    AudioFormat &format = file.hasFileExtension("aif;aiff") ? static_cast<AudioFormat &>(aiff)
                                                            : static_cast<AudioFormat &>(wav);
    if (bits != 16 && bits != 24 && bits != 32)
        throw std::runtime_error("Profundidade PCM inválida.");
    auto *writer =
        format.createWriterFor(stream.get(), rate.load(), (unsigned)channels, bits, {}, 0);
    if (!writer)
        throw std::runtime_error("Não foi possível criar o gravador de áudio.");
    stream.release();
    if (attached)
        devices.removeAudioCallback(this);
    recordingThread.startThread(Thread::Priority::high);
    recorder = std::make_unique<AudioFormatWriter::ThreadedWriter>(writer, recordingThread, 131072);
    recordingDrops = 0;
    recording = true;
    if (attached)
        devices.addAudioCallback(this);
}
void AudioEngine::stopRecording() {
    if (trackCapture)
        stopTrackRecording();
    if (!recorder)
        return;
    if (attached)
        devices.removeAudioCallback(this);
    recording = false;
    recorder.reset();
    recordingThread.stopThread(5000);
    if (attached)
        devices.addAudioCallback(this);
}
void AudioEngine::startTrackRecording(const std::vector<TrackCapture::Target> &targets, int bits,
                                      double bpm) {
    if (recording.load())
        throw std::runtime_error("Recording already in progress.");
    auto *device = devices.getCurrentAudioDevice();
    if (!device)
        throw std::runtime_error(
            "Selecione uma interface de áudio nas configurações antes de gravar.");
    for (const auto &target : targets)
        if (!target.bus && !target.midi) {
            for (int channel = 0; channel < target.channels; ++channel)
                if (!device->getActiveInputChannels()[target.input - 1 + channel])
                    throw std::runtime_error(
                        "Ative as entradas escolhidas no Patch antes de gravar.");
        }
    auto prepared = std::make_unique<TrackCapture>(targets, rate.load(), bits, bpm);
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        trackCapture.swap(prepared);
        recordedFrames = 0;
        recordingDrops = 0;
        recording = true;
    }
}
std::vector<TrackCapture::Take> AudioEngine::stopTrackRecording() {
    std::unique_ptr<TrackCapture> captured;
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        recording = false;
        captured.swap(trackCapture);
    }
    if (!captured)
        return {};
    recordingDrops = captured->overflows();
    return captured->finish();
}
void AudioEngine::startTrackFadeout(const std::set<ID> &selected, double seconds) {
    if (!std::isfinite(seconds) || seconds < 1 || seconds > 5)
        throw std::invalid_argument("Track fadeout duration must be between 1 and 5 seconds.");
    const ScopedLock lock(devices.getAudioCallbackLock());
    bool any = false;
    for (auto &bus : buses) {
        const bool enabled = selected.count(bus->id) != 0;
        bus->fadeoutSelected.store(enabled, std::memory_order_relaxed);
        any |= enabled;
    }
    if (!any) { transportFadeout.cancel(); return; }
    transportFadeout.start((uint32_t)std::llround(seconds * rate.load()));
}
void AudioEngine::cancelTrackFadeout() noexcept { transportFadeout.cancel(); }
double AudioEngine::trackFadeoutRemainingSeconds() const noexcept {
    const auto value = transportFadeout.block();
    return value.active ? value.remaining / rate.load() : 0;
}
float AudioEngine::trackFadeoutGain(const ID &id) const {
    const auto value = transportFadeout.block();
    if (value.active) for (const auto &bus : buses)
        if (bus->id == id && bus->fadeoutSelected.load(std::memory_order_relaxed)) return value.gain();
    return 1;
}
bool AudioEngine::trackFadeoutComplete() const noexcept {
    const auto value = transportFadeout.block();
    return value.active && value.remaining == 0;
}
bool AudioEngine::trackFadeoutActive() const noexcept { return transportFadeout.block().active; }
String AudioEngine::openDevice() {
    if (attached)
        return {};
    auto preferences = File::getSpecialLocation(File::userApplicationDataDirectory)
                           .getChildFile("Hook Developer/CatLive/audio-device.xml");
    auto saved = XmlDocument::parse(preferences);
    auto error = devices.getCurrentAudioDevice() ? String{} : devices.initialise(0, 2, saved.get(), true);
    if (error.isEmpty()) {
        devices.addAudioCallback(this);
        devices.removeMidiInputDeviceCallback({}, this);
        devices.addMidiInputDeviceCallback({}, this);
        attached = true;
    }
    return error;
}
void AudioEngine::previewMIDIItem(const jaras::Song &song,const jaras::AudioClip &clip) {
    for(const auto &track:song.tracks)if(std::any_of(track.clips.begin(),track.clips.end(),[&](const auto &c){return c.id==clip.id;})){
        auto draft=track;for(auto &item:draft.clips)if(item.id==clip.id)item=clip;
        auto notes=playbackNotes(draft,&song,true);auto sequence=MIDIPlayback::sequence(notes);
        auto externalEvents=sequence.events;
        const ScopedLock lock(devices.getAudioCallbackLock());
        for(auto &bus:buses)if(bus->id==track.id){
            bus->midiNotes.swap(notes);bus->externalEvents.swap(externalEvents);
            for(auto &expected:bus->externalExpected)expected=-1;
            if(bus->midi)bus->midi->replaceSequence(sequence,clip.muted);
        }
        return;
    }
}
void AudioEngine::refreshRegionPitch(const jaras::Song &song, const ID &region) {
    const auto part = std::find_if(song.parts.begin(), song.parts.end(), [&](const auto &p) { return p.id == region; });
    if (part == song.parts.end()) return;
    std::vector<std::pair<Voice *, std::unique_ptr<ClipAudio>>> replacements;
    struct MIDIUpdate { Bus *bus; MIDIPlayback::Sequence sequence; std::vector<PlaybackNote> notes; std::vector<MIDIPlayback::Event> events; };
    std::vector<MIDIUpdate> midi;
    for (const auto &track : song.tracks) {
        for (const auto &clip : track.clips) {
            if (clip.startTime >= part->endTime || clip.startTime + clip.duration <= part->startTime) continue;
            for (auto &voice : voices) if (voice->clipID == clip.id) {
                std::unique_ptr<ClipAudio> processor;
                if (ClipAudio::needed(song, track, clip)) processor = std::make_unique<ClipAudio>(song, track, clip, rate.load());
                replacements.emplace_back(voice.get(), std::move(processor));
            }
        }
        for (auto &bus : buses) if (bus->id == track.id && (!bus->midiNotes.empty() || bus->midi)) {
            auto notes = playbackNotes(track, &song, true);
            auto sequence = MIDIPlayback::sequence(notes);
            auto events = sequence.events;
            midi.push_back({bus.get(), std::move(sequence), std::move(notes), std::move(events)});
        }
    }
    // FFT preparation and destruction stay off the callback. Preserve readers,
    // FX instances and both transport clocks while publishing the new pitch.
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        for (auto &entry : replacements) entry.first->clipAudio.swap(entry.second);
        for (auto &entry : midi) {
            entry.bus->midiNotes.swap(entry.notes); entry.bus->externalEvents.swap(entry.events);
            for (auto &expected : entry.bus->externalExpected) expected = -1;
            if (entry.bus->midi) entry.bus->midi->replaceSequence(entry.sequence);
        }
    }
}
void AudioEngine::refreshTiming(const jaras::Song &song) {
    auto timing = ClickProgram::tempo(song);
    std::map<ID, std::vector<ClickProgram::Section>> clicks;
    for (const auto &track : song.tracks) if (track.role.id == "generatedClick") {
        ClickProgram program; program.prepare(song, &track);
        clicks.emplace(track.id, std::move(program.sections));
    }
    // Build sections before the callback lock; publish with allocation-free swaps.
    const ScopedLock lock(devices.getAudioCallbackLock());
    metronome.sections.swap(timing);
    for (auto &bus : buses) if (bus->click) {
        auto found = clicks.find(bus->id);
        if (found != clicks.end()) bus->click->sections.swap(found->second);
    }
}
void AudioEngine::closeDevice() {
    timecodeMIDI.stop();
    if (attached)
        devices.removeAudioCallback(this);
    attached = false;
    if (deviceHost.use_count() == 1) devices.closeAudioDevice();
}
void AudioEngine::configureMetronome(const var &settings) {
    const auto preset = str(settings, "preset", "Digital");
    ClickProgram::Sample a, b;
    if (preset == "User") {
        const auto first = str(settings, "pathA"), second = str(settings, "pathB");
        if (first.isNotEmpty())
            a = ClickProgram::decode(
                std::unique_ptr<AudioFormatReader>(formats.createReaderFor(File(first))));
        if (second.isNotEmpty())
            b = ClickProgram::decode(
                std::unique_ptr<AudioFormatReader>(formats.createReaderFor(File(second))));
    } else {
        a = ClickProgram::tone(preset, true);
        b = ClickProgram::tone(preset, false);
    }
    auto saved = settings.clone();
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        std::swap(metronome.a, a);
        std::swap(metronome.b, b);
        std::swap(metronomeSettings, saved);
        metronomeMode = jlimit(0, 2, (int)num(settings, "mode"));
        metronomeGainA = Decibels::decibelsToGain((float)num(settings, "gainA", -1));
        metronomeGainB = Decibels::decibelsToGain((float)num(settings, "gainB", -1));
        const auto output = get(settings, "output");
        metronomeOutput = jlimit(1, 128, (int)num(output, "firstChannel", 1));
        metronomeChannels = jlimit(1, 2, (int)num(output, "channelCount", 2));
        metronomeEnabled = flag(settings, "enabled");
    }
}
std::unique_ptr<AudioEngine::LatencyPlan> AudioEngine::makeLatencyPlan(const ID *replacement,const NativeFX *prepared)const {
    auto result=std::make_unique<LatencyPlan>();result->buses.resize(buses.size());
    auto latency=[&](const ID &id,const NativeFX &fx){return replacement&&*replacement==id?prepared->latencyFrames():fx.latencyFrames();};
    for(const auto &voice:voices)if(!voice->frozen)result->buses[voice->bus].own=std::max(result->buses[voice->bus].own,latency(voice->clipID,voice->fx[0]));
    for(size_t i=0;i<buses.size();i++)result->buses[i].input=result->buses[i].own;
    for(int index:busOrder) {
        const auto &bus=*buses[size_t(index)];auto &channel=result->buses[size_t(index)];
        channel.output=channel.input+latency(bus.id,bus.fx[0]);
        std::set<int> destinations(bus.sends.begin(),bus.sends.end());
        for(const auto &patch:bus.outputs) {
            if(patch.firstChannel==-2&&bus.parent>=0)destinations.insert(bus.parent);
            else if(patch.firstChannel==0)result->masterInput=std::max(result->masterInput,channel.output);
            else if(patch.firstChannel>0)result->total=std::max(result->total,channel.output);
        }
        for(int target:destinations)if(target>=0&&size_t(target)<buses.size()) {
            auto &next=result->buses[size_t(target)];next.input=std::max(next.input,channel.output);
            LatencyPlan::Route route;route.target=target;channel.routes.push_back(std::move(route));
        }
    }
    const auto masterLatency=latency({},masterFX);
    result->total=std::max(result->total,result->masterInput+masterLatency);
    // Move shared compensation before bus processing/faders. In particular a
    // dry track parallel to CatStem must retain instant volume/mute/fade control
    // after its audio has waited for the latent branch.
    result->masterInput=std::max(result->masterInput,result->total-masterLatency);
    for(auto order=busOrder.rbegin();order!=busOrder.rend();++order) {
        const auto &bus=*buses[size_t(*order)];auto &channel=result->buses[size_t(*order)];
        unsigned shift=std::numeric_limits<unsigned>::max();
        auto destination=[&](unsigned target){shift=std::min(shift,target>=channel.output?target-channel.output:0);};
        for(const auto &route:channel.routes)destination(result->buses[size_t(route.target)].input);
        for(const auto &patch:bus.outputs){if(patch.firstChannel==0)destination(result->masterInput);else if(patch.firstChannel>0)destination(result->total);}
        if(shift!=std::numeric_limits<unsigned>::max()){channel.input+=shift;channel.output+=shift;}
    }
    const auto masterOutput=result->masterInput+masterLatency;
    // Maximum graph delay is bounded before allocation, never in the callback.
    if(result->total>unsigned(rate.load()*30))throw std::runtime_error("A latência total da cadeia de efeitos excede 30 segundos.");
    if(latencyPlan&&latencyPlan->buses.size()==result->buses.size()&&latencyPlan->total==result->total&&latencyPlan->masterInput==result->masterInput&&latencyPlan->masterHardware.latency()==result->total-masterOutput) {
        bool equal=true;for(size_t i=0;i<buses.size();i++) {
            const auto &a=latencyPlan->buses[i],&b=result->buses[i];
            equal&=a.own==b.own&&a.input==b.input&&a.output==b.output;
        }
        for(const auto &voice:voices)if(!voice->frozen) {
            auto found=latencyPlan->clips.find(voice->clipID);
            equal&=found!=latencyPlan->clips.end()&&found->second[0].latency()==result->buses[voice->bus].own-latency(voice->clipID,voice->fx[0]);
        }
        if(equal)return {}; // Parameter edits retain all delay history.
    }
    for(auto &timeline:result->timeline)timeline=native::TimelineDelay(result->total);
    result->masterLive=native::StereoDelay(result->masterInput);
    result->metronome=native::StereoDelay(result->total);
    result->masterHardware=native::StereoDelay(result->total-masterOutput);
    for(size_t i=0;i<buses.size();i++) {
        auto &channel=result->buses[i];
        for(int h=0;h<2;h++) {
            channel.routed[h].setSize(2,4096);
            channel.direct[h]=native::StereoDelay(channel.own);
            channel.inputDelay[h]=native::StereoDelay(channel.input-channel.own);
            channel.master[h]=native::StereoDelay(result->masterInput>=channel.output?result->masterInput-channel.output:0);
            channel.hardware[h]=native::StereoDelay(result->total>=channel.output?result->total-channel.output:0);
            channel.frozen[h]=native::StereoDelay(channel.output);
            for(auto &route:channel.routes)route.delay[h]=native::StereoDelay(result->buses[size_t(route.target)].input-channel.output);
        }
    }
    for(const auto &voice:voices)if(!voice->frozen) {
        const auto own=latency(voice->clipID,voice->fx[0]);
        const auto delay=result->buses[voice->bus].own-own;
        result->clips.emplace(voice->clipID,std::array<native::StereoDelay,2>{native::StereoDelay(delay),native::StereoDelay(delay)});
        result->clipBypass.emplace(voice->clipID,std::array<native::StereoDelay,2>{native::StereoDelay(own),native::StereoDelay(own)});
    }
    return result;
}
uint64 AudioEngine::stemFingerprint()const {
    uint64 value=masterFX.latencyFrames()+1;
    for(const auto &bus:buses)for(const auto &fx:bus->fx)value=(value^fx.latencyFrames())*1099511628211ull;
    for(const auto &voice:voices)for(const auto &fx:voice->fx)value=(value^fx.latencyFrames())*1099511628211ull;
    return value;
}
void AudioEngine::activateStemLatency(){
    masterFX.releaseRemovedStems();masterFX.activateStemLatency();
    for(auto &bus:buses){for(auto &fx:bus->fx)fx.releaseRemovedStems();bus->fx[0].activateStemLatency();bus->fx[1].activateStemLatency(bus->fx[0].latencyFrames()>0);}
    for(auto &voice:voices){for(auto &fx:voice->fx)fx.releaseRemovedStems();voice->fx[0].activateStemLatency();voice->fx[1].activateStemLatency(voice->fx[0].latencyFrames()>0);}
    stemLatencyFingerprint=stemFingerprint();
}
void AudioEngine::refreshStemLatency(){
    // Changing lookahead in a running show would jump every compensated route.
    // Warm in parallel, then admit the prepared graph at the stopped boundary.
    if(offlineMode||playing.load()||subPlaying.load()||presentationTailing.load())return;
    bool pending=masterFX.pendingStemChange();
    for(auto &bus:buses)for(auto &fx:bus->fx)pending|=fx.pendingStemChange();
    for(auto &voice:voices)for(auto &fx:voice->fx)pending|=fx.pendingStemChange();
    if(!pending&&stemFingerprint()==stemLatencyFingerprint)return;
    {const ScopedLock lock(devices.getAudioCallbackLock());activateStemLatency();}
    auto prepared=makeLatencyPlan();
    const ScopedLock lock(devices.getAudioCallbackLock());if(prepared){latencyPlan.swap(prepared);publishLatency();}
}
native::stem::Status AudioEngine::stemStatus(const ID &id,const String &key)const {if(auto *fx=effects(id))return fx->stemStatus(key);return {};}
void AudioEngine::previewStemMix(const ID &id,const String &key,const native::stem::Mix &mix){for(int h=0;h<(id.empty()?1:2);h++)if(auto *fx=effects(id,h))fx->previewStemMix(key,mix);}
void AudioEngine::waitForStems(){masterFX.waitForStems();for(auto &bus:buses)bus->fx[0].waitForStems();for(auto &voice:voices)voice->fx[0].waitForStems();}
void AudioEngine::checkStemErrors()const{masterFX.checkStemErrors();for(auto &bus:buses)bus->fx[0].checkStemErrors();for(auto &voice:voices)voice->fx[0].checkStemErrors();}
unsigned AudioEngine::exportLatencyFrames()const {
    if(!latencyPlan)return 0;
    return exportBus<0?latencyPlan->masterInput+masterFX.latencyFrames():latencyPlan->buses[size_t(exportBus)].output;
}

NativeFX *AudioEngine::effects(const ID &id,int head) const {
    if(id.empty())return const_cast<NativeFX*>(&masterFX);
    for(const auto &bus:buses)if(bus->id==id)return &bus->fx[head];
    for(const auto &voice:voices)if(voice->clipID==id)return &voice->fx[head];
    return nullptr;
}
std::shared_ptr<native::vst3::Processor> AudioEngine::externalEffect(const ID &id,const String &key) const {
    if(auto *chain=effects(id))return chain->external(key);
    return {};
}
void AudioEngine::captureExternalEffects(const ID &id,var &settings) const {
    if(auto *chain=effects(id))chain->captureExternalState(settings);
}
void AudioEngine::setEffects(const ID &id, const var &settings) {
    NativeFX prepared[2];
    auto saved = settings.clone();
    const auto sampleRate = rate.load();
    prepared[0].prepare(saved, sampleRate, effects(id),offlineMode,true);
    if (!id.empty())
        prepared[1].prepare(saved, sampleRate, effects(id,1),offlineMode,false);
    const bool running=playing.load()||subPlaying.load()||presentationTailing.load();
    for(int h=0;h<(id.empty()?1:2);h++){
        if(running){if(auto *old=effects(id,h))prepared[h].holdRemovedStems(*old);}
        else prepared[h].activateStemLatency(h>0&&prepared[0].latencyFrames()>0);
    }
    if(!id.empty())prepared[1].shareStems(prepared[0]);
    auto preparedLatency=makeLatencyPlan(&id,&prepared[0]);
    // Item edits replace only the processors; readers and playback heads stay alive.
    for (auto &voice : voices)
        if (voice->clipID == id) {
            const ScopedLock lock(devices.getAudioCallbackLock());
            voice->fx[0].swap(prepared[0]);
            voice->fx[1].swap(prepared[1]);
            std::swap(voice->fxSettings, saved);
            if(preparedLatency){latencyPlan.swap(preparedLatency);publishLatency();}
            stemLatencyFingerprint=stemFingerprint();
            return;
        }
    auto signature = [](const var &fx) {
        Array<var> values;
        for (auto value : instrumentAssets::settings(fx))
            values.add(get(value, "instrumentID"));
        return JSON::toString(values, true);
    };
    Bus *target = nullptr;
    for (auto &bus : buses)
        if (bus->id == id) {
            target = bus.get();
            break;
        }
    if (!id.empty() && !target) return;
    const bool changeMIDI =
        signature(settings) != signature(target ? target->settings : masterFXSettings);
    std::unique_ptr<MIDIPlayback> midi;
    if (changeMIDI) {
        midi =
            std::make_unique<MIDIPlayback>(target ? target->midiNotes : std::vector<PlaybackNote>{},
                                           settings, instrumentDirectory, sampleRate);
        midi->enableLive();
    } else {
        auto *current = target ? target->midi.get() : masterMIDI.get();
        if (current)
            current->configure(settings);
    }
    // Construction and destruction stay off the callback. The lock only swaps owned state.
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        if(preparedLatency){latencyPlan.swap(preparedLatency);publishLatency();}
        if (id.empty()) {
            masterFX.swap(prepared[0]);
            std::swap(masterFXSettings, saved);
            if (changeMIDI)
                masterMIDI.swap(midi);
        } else
            for (auto &bus : buses)
                if (bus->id == id) {
                    bus->fx[0].swap(prepared[0]);
                    bus->fx[1].swap(prepared[1]);
                    for(auto &expected:bus->externalExpected)expected=-1;
                    std::swap(bus->settings, saved);
                    if (changeMIDI)
                        bus->midi.swap(midi);
                    break;
                }
        stemLatencyFingerprint=stemFingerprint();
    }
}
void AudioEngine::prepareSong(const jaras::Song &song, const File &directory,
                              const var &masterSettings, const jaras::Project *project,
                              const PreparationControl *control) {
    const auto checkpoint=[&] { if(control&&control->checkpoint)control->checkpoint(); };
    if(control&&attached)throw std::runtime_error("Background preparation requires an isolated audio engine.");
    const int workTotal=2+int(song.tracks.size())*2;
    int workDone=0;
    const auto progress=[&] {
        checkpoint();
        if(control&&control->progress)control->progress(workDone,workTotal);
    };
    const NativeFX::Dispatcher pluginDispatcher=control?control->pluginDispatcher:NativeFX::Dispatcher{};
    progress();
    preparationDiagnostics = object();
    const auto *messageManager=MessageManager::getInstanceWithoutCreating();
    put(preparationDiagnostics,"preparedOffMessageThread",messageManager&&!messageManager->isThisTheMessageThread());
    const auto preparationStart = Time::getMillisecondCounterHiRes();
    auto stageStart = preparationStart;
    const auto stage = [&](const char *name) {
        const auto now = Time::getMillisecondCounterHiRes();
        put(preparationDiagnostics, Identifier(name), now - stageStart);
        stageStart = now;
    };
    const bool resume = attached;
    if (resume)
        devices.removeAudioCallback(this);
    cancelTrackFadeout();
    stage("detachMilliseconds");
    // The callback has finished before any reader or scratch buffer is replaced.
    // Structural edits keep the same media. Retain its decoders/metadata while
    // rebuilding voices; changed and unreferenced files are not kept in a cache.
    std::map<std::string, std::shared_ptr<Source>> previousSources;
    std::map<ID, std::unique_ptr<ClipAudio>> previousProcessors;
    for (auto &voice : voices) {
        previousSources.emplace(utf8(voice->source->file.getFullPathName()), voice->source);
        if (voice->clipAudio)
            previousProcessors.emplace(voice->clipID, std::move(voice->clipAudio));
    }
    voices.clear();
    latencyPlan.reset();
    instrumentDirectory = directory;
    masterMIDI.reset();
    std::map<ID,float> heldPeaks;
    const auto nextPeakProject=project?project->id:song.id;
    if(peakProject==nextPeakProject){for(const auto &bus:buses)heldPeaks[bus->id]=bus->held.amplitude();}
    else masterPeakHold.clear();
    peakProject=nextPeakProject;
    buses.clear();
    stage("releaseMilliseconds");
    busOrder.clear();
    missingFiles.clear();
    unsupported.clear();
    duration = song.duration;
    metronome.prepare(song);
    timecodeProgram = {};
    timecodeMIDI.prepare({}, song.duration, false);
    timecodeGain = 1;
    current = {};
    playing = false;
    subPlaying = false;
    elapsedSamples = 0;
    fifo.reset();
    masterOutputs = project && project->masterOutputs
                        ? *project->masterOutputs
                        : std::vector<jaras::OutputPatch>{project && project->masterPatch
                                                              ? *project->masterPatch
                                                              : jaras::OutputPatch{1, 2}};
    if (project && !project->masterOutputs && project->masterSecondaryPatch)
        masterOutputs.push_back(*project->masterSecondaryPatch);
    try {
        jaras::validateRouting(song);
        if (song.tracks.size() > 512)
            throw std::runtime_error("O projeto excede 512 pistas.");
        masterAutomation.prepare(project && project->masterAutomationJSON ? JSON::parse(text(*project->masterAutomationJSON)) : var());
        masterFXSettings = masterSettings;
        masterFX.prepare(masterSettings, rate.load(),nullptr,offlineMode,true,pluginDispatcher);
        try {
            masterMIDI = std::make_unique<MIDIPlayback>(std::vector<PlaybackNote>{}, masterSettings,
                                                        directory, rate.load());
            masterMIDI->enableLive();
        } catch (const std::exception &e) {
            missingFiles.addIfNotAlreadyThere(String::fromUTF8(e.what()));
        }
        unsupported.addArray(masterFX.unsupported);
        ++workDone;progress();
        for (const auto &track : song.tracks) {
            checkpoint();
            auto bus = std::make_unique<Bus>();
            bus->id = track.id;
            bus->held.record(heldPeaks[track.id]);
            bus->timecode = track.role.id == "timecode";
            if (bus->timecode) {
                timecodeProgram = jaras::TimecodeProgram(song, track);
                timecodeMIDI.prepare(timecodeProgram, song.duration, track.mute);
            }
            bus->volume = (float)track.volume;
            bus->pan = (float)track.pan;
            bus->mute = track.mute;
            bus->solo = track.solo;
            bus->phase = track.phaseInverted.value_or(false);
            bus->inputFirst = track.inputPatch ? track.inputPatch->firstChannel : 0;
            bus->inputChannels = track.inputPatch ? track.inputPatch->channelCount : 2;
            bus->inputMonitoring = track.inputMonitoring.value_or(true);
            bus->outputs = track.outputPatches();
            bus->settings = track.fxJSON ? JSON::parse(text(*track.fxJSON)) : var();
            bus->midiNotes = playbackNotes(track, &song);
            bus->externalEvents = MIDIPlayback::sequence(bus->midiNotes).events;
            for(auto &messages:bus->externalMIDI)messages.ensureSize(131072);
            bus->midiSlot = track.midiInput.value_or(0);
            bus->midiChannel = track.midiChannel.value_or(0);
            bus->midiMessages.ensureSize(32768);
            try {
                bus->midi = std::make_unique<MIDIPlayback>(bus->midiNotes, bus->settings, directory,
                                                           rate.load());
                bus->midi->enableLive();
            } catch (const std::exception &e) {
                missingFiles.addIfNotAlreadyThere(String::fromUTF8(e.what()));
            }
            for (int h=0;h<2;h++)
                bus->fx[h].prepare(bus->settings,rate.load(),nullptr,offlineMode,h==0,pluginDispatcher);
            bus->fx[1].shareStems(bus->fx[0]);
            bus->automation.prepare(track.automationJSON ? JSON::parse(text(*track.automationJSON))
                                                         : var());
            for (auto value : bus->fx[0].unsupported)
                unsupported.addIfNotAlreadyThere(text(track.name) + ": " + value);
            if (track.role.id == "generatedClick") {
                bus->click = std::make_unique<ClickProgram>();
                bus->click->prepare(song, &track);
                std::unique_ptr<AudioFormatReader> reader;
                if (track.clickSound)
                    reader.reset(formats.createReaderFor(
                        ProjectCodec::resolveMedia(directory, track.clickSound->path)));
                else
                    reader.reset(formats.createReaderFor(std::make_unique<MemoryInputStream>(
                        BinaryData::Click_mp3, BinaryData::Click_mp3Size, false)));
                bus->click->a = ClickProgram::decode(std::move(reader));
                bus->click->b = bus->click->a;
            }
            buses.push_back(std::move(bus));
            ++workDone;progress();
        }
        for (size_t i = 0; i < song.tracks.size(); ++i) {
            if (song.tracks[i].parentTrackID)
                for (size_t j = 0; j < song.tracks.size(); ++j)
                    if (song.tracks[j].id == *song.tracks[i].parentTrackID)
                        buses[i]->parent = (int)j;
        }
        auto busIndex = [&](const ID &id) {
            for (size_t i = 0; i < buses.size(); ++i)
                if (buses[i]->id == id)
                    return (int)i;
            return -1;
        };
        auto link = [&](int source, int target) {
            if (source < 0 || target < 0 || source == target)
                return;
            auto &sends = buses[(size_t)source]->sends;
            if (std::find(sends.begin(), sends.end(), target) == sends.end())
                sends.push_back(target);
        };
        for (size_t i = 0; i < song.tracks.size(); ++i)
            if (const auto &routing = song.tracks[i].routing; routing) {
                for (const auto &target : routing->transmitters)
                    if (target)
                        link((int)i, busIndex(*target));
                for (const auto &source : routing->receives)
                    if (source)
                        link(busIndex(*source), (int)i);
            }
        std::vector<int> visits(buses.size(), 0);
        std::function<void(int)> visit = [&](int index) {
            if (visits[(size_t)index] == 2)
                return;
            if (visits[(size_t)index] == 1)
                throw std::runtime_error("O roteamento cria um retorno de áudio.");
            visits[(size_t)index] = 1;
            const auto &bus = *buses[(size_t)index];
            for (int target : bus.sends)
                visit(target);
            for (const auto &patch : bus.outputs)
                if (patch.firstChannel == -2 && bus.parent >= 0)
                    visit(bus.parent);
            visits[(size_t)index] = 2;
            busOrder.push_back(index);
        };
        for (size_t i = 0; i < buses.size(); ++i)
            visit((int)i);
        std::reverse(busOrder.begin(), busOrder.end());
        stage("busesMilliseconds");
        std::map<std::string, std::shared_ptr<Source>> sources;
        int reusedSources = 0, reusedProcessors = 0, cachedMetadataSources = 0, lightweightMetadataSources = 0;
        double metadataMilliseconds = 0;
        for (const auto &track : song.tracks) {
            checkpoint();
            if (track.role.id == "video" || jaras::isTeleprompterRole(track.role) ||
                track.role.id == "chords") {
                ++workDone;progress();
                continue;
            }
            for (const auto &clip : track.clips) {
                checkpoint();
                const auto &sourceFile = clip.audioFile ? clip.audioFile : track.audioFile;
                if (!sourceFile || clip.duration <= 0 ||
                    (clip.midi && !clip.frozenMIDI.value_or(false)))
                    continue;
                const auto file = ProjectCodec::resolveMedia(directory, sourceFile->path);
                if(file.hasFileExtension("png;jpg;jpeg;bmp;gif;tif;tiff"))continue;
                if(projectionMedia(clip))try{if(!inspectMediaSource(file).audio)continue;}catch(...){}
                auto voice = std::make_unique<Voice>();
                voice->frozen = clip.frozenMIDI.value_or(false);
                if (voices.size() >= 20000)
                    throw std::runtime_error("Too many audio items in one timeline.");
                auto sourceKey = utf8(file.getFullPathName());
                auto found = sources.find(sourceKey);
                if (found != sources.end())
                    voice->source = found->second;
                else {
                    const auto previous = previousSources.find(sourceKey);
                    if (previous != previousSources.end() && file.existsAsFile() &&
                        file.getSize() == previous->second->fileSize &&
                        file.getLastModificationTime() == previous->second->modified) {
                        voice->source = previous->second;
                        ++reusedSources;
                    } else {
                        const auto metadataStart = Time::getMillisecondCounterHiRes();
                        StreamingReader::Metadata metadata;
                        if (file.hasFileExtension("mp3")) {
                            try {
                                // MP3 caches may originate in another decoder/platform.
                                // Inspect the actual gapless clock without building its
                                // expensive synthesis/seek index for an inactive source.
                                const auto info = native::AudioFile::inspect(std::filesystem::path(file.getFullPathName().toWideCharPointer()));
                                metadata.format = "MP3";metadata.sampleRate = info.sampleRate;
                                metadata.frames = (int64)info.frameCount;metadata.channels = info.channels;
                                ++lightweightMetadataSources;
                            } catch (...) {} // Retain the registered format fallback for unsupported containers.
                        } else if (const auto cached = WaveformCache::cachedMetadata(file)) {
                            metadata.format = file.getFileExtension();
                            metadata.sampleRate = cached->sampleRate;
                            metadata.frames = cached->frames;
                            metadata.channels = (unsigned int)cached->sourceChannels;
                            ++cachedMetadataSources;
                        }
                        if (metadata.sampleRate == 0) {
                            std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
                            if (reader) metadata = StreamingReader::Metadata(*reader);
                        }
                        metadataMilliseconds += Time::getMillisecondCounterHiRes() - metadataStart;
                        if (metadata.sampleRate <= 0 || metadata.sampleRate > 384000 ||
                            metadata.channels == 0 || metadata.frames <= 0) {
                            missingFiles.addIfNotAlreadyThere(file.getFullPathName());
                            continue;
                        }
                        voice->source = std::make_shared<Source>();
                        voice->source->file = file;
                        voice->source->fileSize = file.getSize();
                        voice->source->modified = file.getLastModificationTime();
                        if(!readerContext)readerContext=std::make_shared<ReaderContext>();
                        voice->source->context=readerContext;
                        for (int h = 0; h < 2; ++h)
                            voice->source->readers[h] = std::make_unique<StreamingReader>(
                                file, metadata, readerContext->formats, readerContext->thread);
                    }
                }
                for (int h = 0; h < 2; ++h) {
                    voice->processed[h].setSize(2, 4096);
                    voice->fxSettings = clip.fxJSON ? JSON::parse(text(*clip.fxJSON)) : var();
                    voice->fx[h].prepare(voice->fxSettings,rate.load(),nullptr,offlineMode,h==0,pluginDispatcher);
                    for (auto value : voice->fx[h].unsupported)
                        unsupported.addIfNotAlreadyThere(text(clip.name) + ": " + value);
                }
                sources[sourceKey] = voice->source;
                voice->track = track.id;
                voice->clipID = clip.id;
                voice->start = clip.startTime;
                voice->playbackStart = jaras::playbackItemStart(song, clip);
                voice->duration = clip.duration;
                voice->offset = clip.sourceOffset;
                voice->speed = clip.playbackRate;
                voice->clipGain = clip.gain.value_or(1) * clip.normalizationGain.value_or(1) *
                                  (clip.phaseInverted.value_or(false) ? -1 : 1);
                voice->itemMuted = clip.muted;
                voice->fxBypassed = clip.fxBypassed.value_or(false);
                voice->clipPan = clip.pan.value_or(0);
                voice->fadeIn = clip.fadeIn.value_or(0);
                voice->fadeOut = clip.fadeOut.value_or(0);
                voice->fadeInShape = {clip.fadeInCurve.value_or(0), clip.fadeInSCurve.value_or(1)};
                voice->fadeOutShape = {clip.fadeOutCurve.value_or(0), clip.fadeOutSCurve.value_or(1)};
                voice->channelMode = clip.channelMode.value_or(0);
                if (ClipAudio::needed(song, track, clip)) {
                    const auto previous = previousProcessors.find(clip.id);
                    if (previous != previousProcessors.end()) {
                        voice->clipAudio = std::move(previous->second);
                        voice->clipAudio->configure(song, track, clip, rate.load());
                        ++reusedProcessors;
                    } else
                        voice->clipAudio = std::make_unique<ClipAudio>(song, track, clip, rate.load());
                }
                voice->fx[1].shareStems(voice->fx[0]);
                voice->automation.prepare(
                    clip.automationJSON ? JSON::parse(text(*clip.automationJSON)) : var(), true);
                for (size_t i = 0; i < buses.size(); ++i)
                    if (buses[i]->id == track.id)
                        voice->bus = i;
                voices.push_back(std::move(voice));
            }
            ++workDone;progress();
        }
        put(preparationDiagnostics, "reusedSources", reusedSources);
        put(preparationDiagnostics, "reusedProcessors", reusedProcessors);
        put(preparationDiagnostics, "sources", (int)sources.size());
        put(preparationDiagnostics, "cachedMetadataSources", cachedMetadataSources);
        put(preparationDiagnostics, "lightweightMetadataSources", lightweightMetadataSources);
        put(preparationDiagnostics, "metadataMilliseconds", metadataMilliseconds);
        stage("voicesMilliseconds");
        activateStemLatency();latencyPlan=makeLatencyPlan();publishLatency();
        if(control&&project) {
            // Finish mixer setup on the isolated engine too. No queued command
            // may refer to the retiring graph when it is adopted.
            setMixer(*project,song);
            applyUpdates();
        }
        ++workDone;progress();
    } catch (...) {
        if (resume)
            devices.addAudioCallback(this);
        throw;
    }
    if (resume)
        devices.addAudioCallback(this);
    stage("reattachMilliseconds");
    previousSources.clear();
    previousProcessors.clear();
    put(preparationDiagnostics, "totalMilliseconds", Time::getMillisecondCounterHiRes() - preparationStart);
}
void AudioEngine::adoptPreparedSong(AudioEngine &prepared) {
    const auto started=Time::getMillisecondCounterHiRes();
    if(&prepared==this||prepared.attached||prepared.recording.load())
        throw std::runtime_error("Invalid prepared audio graph.");
    prepared.applyUpdates();
    auto mtc=prepared.timecodeProgram;
    bool timecodeMuted=false;
    for(const auto &bus:prepared.buses)if(bus->timecode)timecodeMuted=bus->mute;
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        if(rate.load()!=prepared.rate.load()||offlineMode!=prepared.offlineMode)
            throw std::runtime_error("A configuração de áudio mudou durante a abertura. Abra o projeto novamente.");
        if(recording.load()||playing.load()||subPlaying.load())
            throw std::runtime_error("Pare a reprodução antes de abrir outro projeto.");
        cancelTrackFadeout();
        voices.swap(prepared.voices);buses.swap(prepared.buses);busOrder.swap(prepared.busOrder);
        readerContext.swap(prepared.readerContext);latencyPlan.swap(prepared.latencyPlan);
        masterFX.swap(prepared.masterFX);masterMIDI.swap(prepared.masterMIDI);
        std::swap(masterAutomation,prepared.masterAutomation);
        std::swap(instrumentDirectory,prepared.instrumentDirectory);
        std::swap(masterFXSettings,prepared.masterFXSettings);
        std::swap(timecodeProgram,prepared.timecodeProgram);
        std::swap(timecodeGain,prepared.timecodeGain);
        // The click samples/output are user preferences; only its timeline is
        // project-owned. Preserve the configured metronome sound and routing.
        metronome.sections.swap(prepared.metronome.sections);
        masterOutputs.swap(prepared.masterOutputs);
        std::swap(duration,prepared.duration);
        std::swap(masterVolume,prepared.masterVolume);std::swap(masterPan,prepared.masterPan);
        std::swap(masterMute,prepared.masterMute);std::swap(masterMono,prepared.masterMono);
        std::swap(masterPhase,prepared.masterPhase);std::swap(masterSolo,prepared.masterSolo);
        std::swap(peakProject,prepared.peakProject);
        std::swap(stemLatencyFingerprint,prepared.stemLatencyFingerprint);
        missingFiles.swapWith(prepared.missingFiles);unsupported.swapWith(prepared.unsupported);
        std::swap(preparationDiagnostics,prepared.preparationDiagnostics);
        fifo.reset();current={};position=0;subPosition=0;playing=false;subPlaying=false;elapsedSamples=0;
        keyboardTarget=-1;meter=0;masterPeakHold.clear();masterFXInput=0;masterFXOutput=0;
        presentationTailing=false;presentationDelay=latencyPlan?latencyPlan->total:0;
        for(int h=0;h<2;++h) {
            masterLevels[h]=0;presentedPosition[h]=0;presentedPlaying[h]=false;
            tailFrames[h]=0;tailCursor[h]=0;
        }
        lastPrimedSources=0;lastPrimeWaitMilliseconds=0;renderClock=0;
        timecodeMIDI.publishAudioClock(0,false,false,0);
    }
    timecodeMIDI.prepare(std::move(mtc),duration,timecodeMuted);
    put(preparationDiagnostics,"commitMilliseconds",Time::getMillisecondCounterHiRes()-started);
}
void AudioEngine::enqueue(const Update &update) {
    int a, n, b, m;
    fifo.prepareToWrite(1, a, n, b, m);
    if (!n) {
        // Inspection and a stopped device have no render callback to drain the
        // queue. A large mixer update can also outpace an active callback.
        // Take exclusive consumer ownership before applying pending commands;
        // preserve their order instead of dropping a stop, mute or seek.
        const ScopedLock lock(devices.getAudioCallbackLock());
        applyUpdates();
        fifo.prepareToWrite(1, a, n, b, m);
    }
    jassert(n == 1);
    updates[(size_t)a] = update;
    fifo.finishedWrite(1);
}
void AudioEngine::transport(const State &state) {
    if(presentationDelay.load()&&!state.playing&&!state.subPlaying) {
        presentedPosition[0]=state.position;presentedPosition[1]=state.subPosition;
        presentedPlaying[0]=false;presentedPlaying[1]=false;
    }
    const auto primeStart = Time::getMillisecondCounterHiRes();
    lastPrimedSources = 0;
    // Prime only heads that will play. A stopped edit (including creating a
    // Click track) must not wait for the two-second disk-read deadline, and a
    // Stop must reach the callback without waiting for inactive media.
    // The ongoing device callback continues with its current transport meanwhile.
    struct Prime { StreamingReader *reader; int64 position; int count; };
    std::vector<Prime> pending;
    for (int head = 0; head < 2; ++head) {
        if (head == 0 ? !state.playing : !state.subPlaying) continue;
        const auto cursor = head == 0 ? state.position : state.subPosition;
        for (auto& voice : voices) {
            if (!state.scope[head].allows(voice->playbackStart) || voice->start > cursor + 2 ||
                voice->start + voice->duration <= cursor) continue;
            auto* reader = voice->source->readers[head].get();
            const double local = std::max(0., cursor - voice->start);
            const double source = voice->clipAudio ? voice->clipAudio->sourcePosition(local) : voice->offset + local * voice->speed;
            auto position = (int64)std::floor(source * reader->sampleRate);
            int count = 4096;
            if (voice->clipAudio) {
                const auto range = voice->clipAudio->readAheadRange(local, .15);
                const auto first = (int64)std::floor(range.first * reader->sampleRate);
                const auto frames = (int64)std::ceil((range.second-range.first) * reader->sampleRate) + 2;
                if (frames <= 131072) { position = first; count = (int)std::max<int64>(4096, frames); }
            }
            reader->request(position);
            ++lastPrimedSources;
            if (voice->start <= cursor) pending.push_back({reader, position, count});
        }
    }
    const auto deadline = Time::getMillisecondCounter() + 2000;
    while (!pending.empty()) {
        pending.erase(std::remove_if(pending.begin(), pending.end(), [](const auto& entry) {
            return entry.reader->ready(entry.position, entry.count);
        }), pending.end());
        if (pending.empty() || (int32)(Time::getMillisecondCounter() - deadline) >= 0) break;
        Thread::sleep(1);
    }

    lastPrimeWaitMilliseconds = Time::getMillisecondCounterHiRes() - primeStart;
    Update u;
    u.kind = Update::transport;
    u.state = state;
    enqueue(u);
    timecodeMIDI.transport(state.position, state.playing, state.loop, state.loopStart,
        state.loopEnd, state.end, state.timecodePreferred, attached && !exportCapture);
}
void AudioEngine::setItemControls(const jaras::AudioClip &clip) {
    for(size_t i=0;i<voices.size();++i) if(voices[i]->clipID==clip.id) {
        Update u; u.kind=Update::item; u.index=(int)i;
        u.itemGain=clip.gain.value_or(1)*clip.normalizationGain.value_or(1)*(clip.phaseInverted.value_or(false)?-1:1);
        u.itemPan=clip.pan.value_or(0); u.fadeIn=clip.fadeIn.value_or(0); u.fadeOut=clip.fadeOut.value_or(0);
        u.fadeInShape={clip.fadeInCurve.value_or(0),clip.fadeInSCurve.value_or(1)}; u.fadeOutShape={clip.fadeOutCurve.value_or(0),clip.fadeOutSCurve.value_or(1)};
        u.mute=clip.muted; u.fxBypassed=clip.fxBypassed.value_or(false); enqueue(u);
    }
}
void AudioEngine::setMixer(const jaras::Project &project, const jaras::Song &song) {
    Update u;
    u.kind = Update::mixer;
    u.index = -1;
    u.volume = (float)project.masterVolume;
    u.pan = (float)project.masterPan;
    u.mute = project.masterMute;
    u.mono = project.masterMono;
    u.phase = project.masterPhaseInverted.value_or(false);
    u.solo = project.masterSolo;
    enqueue(u);
    for (size_t i = 0; i < buses.size(); ++i)
        for (const auto &t : song.tracks)
            if (t.id == buses[i]->id) {
                if (buses[i]->timecode) timecodeMIDI.mute(t.mute);
                u = {};
                u.kind = Update::mixer;
                u.index = (int)i;
                u.volume = (float)t.volume;
                u.phase = t.phaseInverted.value_or(false);
                u.pan = (float)t.pan;
                u.mute = t.mute;
                u.solo = t.solo;
                u.inputMonitoring=t.inputMonitoring.value_or(true);
                u.midiSlot=t.midiInput.value_or(0);u.midiChannel=t.midiChannel.value_or(0);
                enqueue(u);
                break;
            }
}
void AudioEngine::publishLatency()noexcept {
    const auto next=latencyPlan?latencyPlan->total:0;
    if(presentationDelay.exchange(next)!=next) {
        resetLatencyHead(0,current.position);resetLatencyHead(1,current.subPosition);
    }
}
void AudioEngine::resetLatencyHead(int head,double at)noexcept {
    tailFrames[head]=0;tailCursor[head]=at;
    presentedPosition[head]=at;presentedPlaying[head]=false;
    if(!latencyPlan)return;
    latencyPlan->timeline[head].reset(at);
    for(auto &bus:latencyPlan->buses) {
        bus.direct[head].reset();bus.inputDelay[head].reset();bus.master[head].reset();bus.hardware[head].reset();bus.frozen[head].reset();
        for(auto &route:bus.routes)route.delay[head].reset();
    }
    for(auto &clip:latencyPlan->clips)clip.second[size_t(head)].reset();
    for(auto &clip:latencyPlan->clipBypass)clip.second[size_t(head)].reset();
    if(head==0)latencyPlan->metronome.reset();
}
AudioEngine::State AudioEngine::presentationState()const {
    auto result=state();
    if(presentationDelay.load()) {
        result.position=presentedPosition[0].load();result.subPosition=presentedPosition[1].load();
        result.playing=presentedPlaying[0].load();result.subPlaying=presentedPlaying[1].load();
    }
    return result;
}
AudioEngine::State AudioEngine::state() const {
    State s;
    s.position = position.load();
    s.subPosition = subPosition.load();
    s.playing = playing.load();
    s.subPlaying = subPlaying.load();
    return s;
}
void AudioEngine::setOffline(bool enabled) {
    for (auto &voice : voices)
        for (auto &reader : voice->source->readers)
            reader->setOffline(enabled);
}
double AudioEngine::takeElapsed() { return (double)elapsedSamples.exchange(0) / rate.load(); }
void AudioEngine::applyUpdates() {
    int a, n, b, m;
    fifo.prepareToRead(1024, a, n, b, m);
    auto apply = [this](const Update &u) {
        if (u.kind == Update::transport) {
            bool changed[2]{};
            for(int h=0;h<2;h++) {
                const bool before=h==0?current.playing:current.subPlaying,after=h==0?u.state.playing:u.state.subPlaying;
                const double at=h==0?u.state.position:u.state.subPosition,old=h==0?current.position:current.subPosition;
                changed[h]=!u.state.preserveLatency&&(before!=after||std::abs(at-old)>1.5/rate.load());
                if(changed[h])resetLatencyHead(h,at);
                else if(u.state.preserveLatency) {
                    if(before&&!after){tailFrames[h]=latencyPlan?latencyPlan->total:0;tailCursor[h]=at;}
                    else if(after)tailFrames[h]=0;
                }
            }
            // The shared separator follows the sum of both heads. Starting or
            // stopping SubPlay must not flush the main head's wet history.
            if((changed[0]&&!current.subPlaying&&!u.state.subPlaying)||(changed[1]&&!current.playing&&!u.state.playing)) {
                masterFX.resetStems();for(auto &bus:buses)bus->fx[0].resetStems();for(auto &voice:voices)voice->fx[0].resetStems();
                if(latencyPlan){latencyPlan->masterLive.reset();latencyPlan->masterHardware.reset();}
            }
            current = u.state;
        }
        else if (u.kind == Update::item) {
            if (u.index>=0 && u.index<(int)voices.size()) {
                auto &v=*voices[(size_t)u.index]; v.clipGain=u.itemGain; v.clipPan=u.itemPan;
                v.fadeIn=u.fadeIn; v.fadeOut=u.fadeOut; v.fadeInShape=u.fadeInShape; v.fadeOutShape=u.fadeOutShape; v.itemMuted=u.mute; v.fxBypassed=u.fxBypassed;
            }
        } else if (u.index < 0) {
            masterVolume = u.volume;
            masterPan = u.pan;
            masterMute = u.mute;
            masterMono = u.mono;
            masterPhase = u.phase;
            masterSolo = u.solo;
        } else if (u.index < (int)buses.size()) {
            auto &v = *buses[(size_t)u.index];
            v.volume = u.volume;
            v.pan = u.pan;
            v.mute = u.mute;
            v.solo = u.solo;
            v.inputMonitoring=u.inputMonitoring;v.midiSlot=u.midiSlot;v.midiChannel=u.midiChannel;
            v.phase = u.phase;
        }
    };
    for (int i = 0; i < n; ++i)
        apply(updates[(size_t)(a + i)]);
    for (int i = 0; i < m; ++i)
        apply(updates[(size_t)(b + i)]);
    fifo.finishedRead(n + m);
}
void AudioEngine::mixVoice(Voice &v, int head, double at, float *const *out, int channels, int dest,
                           int count) {
    if (v.itemMuted) return;
    const double sr = rate.load(std::memory_order_relaxed);
    auto &reader = *v.source->readers[head];
    const unsigned busDelay=latencyPlan&&!v.frozen?latencyPlan->buses[v.bus].own:0;
    const bool delayed=busDelay>0;
    if(at+count/sr<=v.start||at>=v.start+v.duration+busDelay/sr)return;
    int begin=jlimit(0,count,(int)std::ceil((v.start-at)*sr-1e-7));
    int end=jlimit(0,count,(int)std::ceil((v.start+v.duration-at)*sr-1e-7));
    if(begin>=end&&!delayed)return;
    if(begin<end) {
    const double step = reader.sampleRate / sr * v.speed;
    if (step <= 0 || (!v.clipAudio && step > 32))
        return;
    auto &scratch = readScratch[head];
    if (v.clipAudio) {
        if (!v.clipAudio->render(reader, scratch, v.processed[head], head,
                                 at + begin / sr - v.start, end - begin)) {
            underruns.fetch_add(1);
            return;
        }
    } else {
        const double source =
            (v.offset + (at + begin / sr - v.start) * v.speed) * reader.sampleRate;
        const auto first = (int64)std::floor(source);
        const int needed = (int)std::ceil((end - begin) * step) + 2;
        if (needed > scratch.getNumSamples()) {
            underruns.fetch_add(1);
            return;
        }
        scratch.clear(0, needed);
        if (!reader.read(&scratch, 0, needed, first, true, true)) {
            underruns.fetch_add(1);
            return;
        }
        for (int ch = 0; ch < 2; ++ch) {
            auto *output = v.processed[head].getWritePointer(ch);
            auto *input = scratch.getReadPointer(reader.numChannels > 1 ? ch : 0);
            for (int n = 0; n < end - begin; ++n) {
                const double pos = source - first + n * step;
                const int k = (int)pos;
                output[n] = input[k] + (float)(pos - k) * (input[k + 1] - input[k]);
            }
        }
    }
    for (int i = begin; i < end; ++i) {
        float a = v.processed[head].getSample(0, i - begin),
              b = v.processed[head].getSample(1, i - begin);
        if (v.channelMode == 1)
            b = a;
        else if (v.channelMode == 2)
            a = b;
        else if (v.channelMode == 3)
            a = b = (a + b) * .5f;
        const double local = at + (double)i / sr - v.start;
        const auto values =
            v.automation.evaluate(v.offset + std::max(0., local) * v.speed, v.clipGain, v.clipPan);
        float left = values.mute ? 0 : (float)values.gain, right = left;
        if (values.pan > 0)
            left *= 1 - (float)values.pan;
        else
            right *= 1 + (float)values.pan;
        float fade = 1;
        if (v.fadeIn > 0)
            fade *= (float)v.fadeInShape.value(local / std::min(v.duration, v.fadeIn));
        if (v.fadeOut > 0)
            fade *= (float)v.fadeOutShape.value((v.duration - local) / std::min(v.duration, v.fadeOut));
        v.processed[head].setSample(0, i - begin, a * left * fade);
        v.processed[head].setSample(1, i - begin, b * right * fade);
    }
    }
    if(v.fx[0].hasActiveStem()&&!v.frozen) {
        for(int ch=0;ch<2;ch++)if(end>begin)v.stemInput[head].addFrom(ch,dest+begin,v.processed[head],ch,0,end-begin);
        return;
    }
    if(delayed) {
        // FX latency must drain after the clip boundary, and partial first/last
        // blocks include the correct silent prefix/suffix in the same clock.
        const int inputCount=std::max(0,end-begin);
        for(int ch=0;ch<2;ch++) {
            auto *data=v.processed[head].getWritePointer(ch);
            if(inputCount&&begin)std::memmove(data+begin,data,size_t(inputCount)*sizeof(float));
            std::fill_n(data,begin,0.f);std::fill(data+std::max(begin,end),data+count,0.f);
        }
        if(!v.fxBypassed)v.fx[head].process(v.processed[head],count,at,true,nullptr,(renderClock+dest)/sr);
        else if(auto bypass=latencyPlan->clipBypass.find(v.clipID);bypass!=latencyPlan->clipBypass.end())bypass->second[size_t(head)].process(v.processed[head].getWritePointer(0),v.processed[head].getWritePointer(1),count,int64_t(renderClock)+dest,true);
        auto found=latencyPlan->clips.find(v.clipID);
        if(found!=latencyPlan->clips.end())found->second[size_t(head)].process(v.processed[head].getWritePointer(0),v.processed[head].getWritePointer(1),count,int64_t(renderClock)+dest,true);
        for(int ch=0;ch<std::min(2,channels);ch++)if(out[ch])FloatVectorOperations::add(out[ch]+dest,v.processed[head].getReadPointer(ch),count);
    } else {
        if(!v.fxBypassed)v.fx[head].process(v.processed[head],end-begin,at+begin/sr);
        for(int ch=0;ch<std::min(2,channels);ch++)if(out[ch])FloatVectorOperations::add(out[ch]+dest+begin,v.processed[head].getReadPointer(ch),end-begin);
    }
}
void AudioEngine::render(float *const *out, int channels, int samples, const float *const *input,
                         int inputChannels) {
    if (samples > 4096) {
        for (int pos = 0; pos < samples; pos += 4096) {
            std::array<float *, 128> pointers{};
            for (int ch = 0; ch < std::min(channels, 128); ++ch)
                pointers[(size_t)ch] = out[ch] ? out[ch] + pos : nullptr;
            std::array<const float *, 128> inputPointers{};
            for (int ch = 0; ch < std::min(inputChannels, 128); ++ch)
                inputPointers[(size_t)ch] = input && input[ch] ? input[ch] + pos : nullptr;
            render(pointers.data(), std::min(channels, 128), std::min(4096, samples - pos),
                   inputPointers.data(), std::min(inputChannels, 128));
        }
        return;
    }
    for (int ch = 0; ch < channels; ++ch)
        if (out[ch])
            FloatVectorOperations::clear(out[ch], samples);
    applyUpdates();
    const auto fadeout = transportFadeout.block();
    if (fadeout.active)
        for (int frame = 0; frame < samples; ++frame)
            trackFadeoutGains[(size_t)frame] = fadeout.gain((uint32_t)frame);
    if (trackCapture)
        trackCapture->input(input, inputChannels, samples, inputMapping);
    liveMidi.clear();
    midiInput.removeNextBlockOfMessages(liveMidi, samples);
    keyboardMidi.clear();
    keyboardState.processNextMidiBuffer(keyboardMidi, 0, samples, true);
    for (int slot = 0; slot < 3; ++slot) {
        slotMessages[slot].clear();
        midiSlots[slot].removeNextBlockOfMessages(slotMessages[slot], samples);
    }
    const bool allowInstrument = instrumentAllowed.load(std::memory_order_relaxed);
    bool routedKeyboard = false, routedHardware = false;
    const double sr = rate.load(std::memory_order_relaxed);
    const bool renderingHead[2]{current.playing||tailFrames[0]>0,current.subPlaying||tailFrames[1]>0};
    const bool active = renderingHead[0] || renderingHead[1];
    const auto blockClock=int64_t(renderClock);
    for(auto &voice:voices)if(voice->fx[0].hasActiveStem())for(auto &buffer:voice->stemInput)buffer.clear(0,samples);
    masterBuffer.clear(0, samples);
    if(latencyPlan)latencyPlan->metronomeBuffer.clear(0,samples);
    bool anySolo = false;
    for (auto &bus : buses) {
        anySolo |= bus->solo;
        bus->buffer.clear(0, samples);
        bus->subBuffer.clear(0, samples);
        for(auto &buffer:bus->frozen)buffer.clear(0,samples);
        for(auto &buffer:bus->clips)buffer.clear(0,samples);
        for(auto &messages:bus->externalMIDI)messages.clear();
        if (((bus->midi && !bus->midi->empty()) || bus->fx[0].hasExternal()) && bus->midiSlot > 0)
            routedHardware = true;
    }
    std::array<bool, 512> audible{};
    for (size_t i = 0; i < buses.size(); ++i) {
        bool muted = false, solo = false;
        int index = (int)i;
        while (index >= 0) {
            auto &bus = *buses[(size_t)index];
            muted |= bus.mute && !bus.automation.controlsMute();
            solo |= bus.solo;
            index = bus.parent;
        }
        audible[i] = !muted && (!anySolo || solo);
    }
    if(latencyPlan)for(auto &channel:latencyPlan->buses)for(auto &buffer:channel.routed)buffer.clear(0,samples);
    const bool keepPipeline=latencyPlan&&latencyPlan->total>0;
    auto sourceAudible=[&](size_t index){return keepPipeline||audible[index];};
    auto routeAudible = audible;
    for (size_t i = 0; i < buses.size(); ++i)
        if (audible[i]) {
            int parent = buses[i]->parent;
            while (parent >= 0) {
                routeAudible[(size_t)parent] = true;
                parent = buses[(size_t)parent]->parent;
            }
        }
    for (int head = 0; head < 2; ++head) {
        bool &run = head == 0 ? current.playing : current.subPlaying;
        double &cursor = head == 0 ? current.position : current.subPosition;
        int done = 0;
        std::fill_n(timelinePositions[(size_t)head].begin(), samples, cursor);
        std::fill_n(timelineRunning[size_t(head)].begin(),samples,false);
        if (!run)
            for (auto &bus : buses) {
                if (bus->midi)
                    bus->midi->reset(head);
                if(bus->externalExpected[head]>=0){
                    for(int channel=1;channel<=16;++channel)
                        bus->externalMIDI[head].addEvent(MidiMessage::allNotesOff(channel),0);
                    bus->externalExpected[head]=-1;
                }
            }
        while (run && done < samples) {
            const bool looping = head == 0 && current.loop && current.loopEnd > current.loopStart;
            double boundary = looping ? std::min(duration, current.loopEnd) : duration;
            if (head == 0 && !looping) boundary = std::min(boundary, current.end);
            if (cursor >= boundary - 1e-9) {
                if (looping)
                    cursor = current.loopStart;
                else {
                    run = false;
                    tailFrames[head]=latencyPlan?latencyPlan->total:0;tailCursor[head]=cursor;
                    break;
                }
            }
            int count = std::min(samples - done,
                                 std::max(1, (int)std::ceil((boundary - cursor) * sr - 1e-7)));
            for(size_t index=0;index<buses.size();++index) {
                auto &bus=*buses[index];
                if(!bus.fx[head].hasExternal())continue;
                auto &messages=bus.externalMIDI[head];
                const auto scope=current.scope[head];
                const bool reset=std::abs(bus.externalExpected[head]-cursor)>1.5/sr||bus.externalScopes[head]!=scope;
                if(reset || !sourceAudible(index)) {
                    for(int channel=1;channel<=16;++channel)messages.addEvent(MidiMessage::allNotesOff(channel),done);
                    if(sourceAudible(index))for(const auto &note:bus.midiNotes)
                        if(note.velocity>0&&scope.allows(note.playbackStart)&&note.start<cursor-1e-9&&note.end>cursor+1e-9)
                            messages.addEvent(MidiMessage::noteOn(note.channel,note.pitch,(uint8)note.velocity),done);
                }
                if(!sourceAudible(index)){bus.externalExpected[head]=-1;continue;}
                const double end=cursor+count/sr;
                auto event=std::lower_bound(bus.externalEvents.begin(),bus.externalEvents.end(),cursor-1e-9,
                    [](const MIDIPlayback::Event &event,double value){return event.time<value;});
                for(;event!=bus.externalEvents.end()&&event->time<end-1e-9;++event) {
                    const auto &note=event->note;if(!scope.allows(note.playbackStart))continue;
                    messages.addEvent(event->on?MidiMessage::noteOn(note.channel,note.pitch,(uint8)note.velocity):MidiMessage::noteOff(note.channel,note.pitch),
                        done+jlimit(0,count-1,(int)std::round((event->time-cursor)*sr)));
                }
                bus.externalExpected[head]=end;bus.externalScopes[head]=scope;
            }
            for (auto &v : voices)
                if (sourceAudible(v->bus) && current.scope[head].allows(v->playbackStart)) {
                    if (v->start > cursor && v->start <= cursor + 2)
                        v->source->readers[head]->request((int64)std::floor((v->clipAudio ? v->clipAudio->sourcePosition(0) : v->offset) * v->source->readers[head]->sampleRate));
                    mixVoice(*v, head, cursor, (v->frozen ? buses[v->bus]->frozen[head] : buses[v->bus]->clips[head]).getArrayOfWritePointers(), 2, done, count);
                }
            for (size_t index = 0; index < buses.size(); ++index)
                if (sourceAudible(index) && buses[index]->midi)
                    buses[index]->midi->render(head, cursor, buses[index]->head(head), done, count, current.scope[head]);
            for (size_t busIndex = 0; busIndex < buses.size(); ++busIndex)
                if (sourceAudible(busIndex) && buses[busIndex]->click) {
                    auto &bus = *buses[busIndex];
                    auto &buffer = bus.head(head);
                    for (int n = 0; n < count; ++n) {
                        const float sample = bus.click->sample(cursor + n / sr, 1);
                        buffer.addSample(0, done + n, sample);
                        buffer.addSample(1, done + n, sample);
                    }
                }
            if (head == 0 && (keepPipeline||metronomeEnabled.load(std::memory_order_relaxed)))
                for (int n = 0; n < count; ++n) {
                    const float sample = metronome.sample(cursor + n / sr, metronomeMode,
                                                          metronomeGainA, metronomeGainB);
                    if(latencyPlan)for(int c=0;c<2;c++)latencyPlan->metronomeBuffer.addSample(c,done+n,sample);
                }
            if (head == 0 && !timecodeProgram.spans.empty()) {
                const auto* span = timecodeProgram.at(cursor, current.timecodePreferred, 2);
                for (auto& bus : buses) if (bus->timecode && (keepPipeline||!bus->mute)) {
                    const float target = bus->volume * (bus->phase ? -1.f : 1.f);
                    const float smoothing = float(1 - std::exp(-1.0 / (sr * .01)));
                    for (int n = 0; n < count; ++n) {
                        const double at = cursor + n / sr;
                        if (!span || at >= span->end) span = timecodeProgram.at(at, current.timecodePreferred, 2);
                        if (!span || at < span->start || span->muted || span->settings.mode != "ltc") continue;
                        timecodeGain += (target - timecodeGain) * smoothing;
                        const auto value = timecodeWaveform.sample(span->time(at), span->settings.frameRate) * timecodeGain;
                        for (int ch = 0; ch < 2; ++ch) bus->buffer.addSample(ch, done + n, value);
                    }
                }
            }
            for (int n = 0; n < count; ++n) {
                timelinePositions[(size_t)head][(size_t)(done + n)] = cursor + n / sr;
                timelineRunning[size_t(head)][size_t(done+n)]=true;
            }
            cursor += (double)count / sr;
            done += count;
        }
        if(!run&&tailFrames[head]&&done<samples) {
            const int count=std::min<unsigned>(unsigned(samples-done),tailFrames[head]);
            // Flush delayed item processors as well as downstream bus delays.
            for(auto &voice:voices)if(sourceAudible(voice->bus)&&current.scope[head].allows(voice->playbackStart))
                mixVoice(*voice,head,tailCursor[head],(voice->frozen?buses[voice->bus]->frozen[head]:buses[voice->bus]->clips[head]).getArrayOfWritePointers(),2,done,count);
            for(int n=done;n<samples;n++)timelinePositions[size_t(head)][size_t(n)]=tailCursor[head]+(n-done)/sr;
            tailCursor[head]+=count/sr;tailFrames[head]-=unsigned(count);
        }
    }
    // Item-level CatStem sees the already clipped/faded audio of both heads.
    // Scope/ignore rules and item automation were applied before this sum.
    for(auto &voice:voices)if(voice->fx[0].hasActiveStem()&&!voice->frozen) {
        const int head=renderingHead[0]?0:renderingHead[1]?1:0;
        auto &buffer=voice->stemInput[0];for(int ch=0;ch<2;ch++)buffer.addFrom(ch,0,voice->stemInput[1],ch,0,samples);
        const auto clock=blockClock;
        if(!voice->fxBypassed)voice->fx[0].process(buffer,samples,timelinePositions[size_t(head)][0],active,nullptr,blockClock/sr);
        else if(auto bypass=latencyPlan->clipBypass.find(voice->clipID);bypass!=latencyPlan->clipBypass.end())bypass->second[0].process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,clock,active);
        if(auto delay=latencyPlan->clips.find(voice->clipID);delay!=latencyPlan->clips.end())delay->second[0].process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,clock,active);
        for(int ch=0;ch<2;ch++)buses[voice->bus]->clips[head].addFrom(ch,0,buffer,ch,0,samples);
    }
    for (int index : busOrder)
        if (routeAudible[(size_t)index]) {
            const auto &bus = *buses[(size_t)index];
            for (int target : bus.sends)
                routeAudible[(size_t)target] = true;
            for (const auto &patch : bus.outputs)
                if (patch.firstChannel == -2 && bus.parent >= 0)
                    routeAudible[(size_t)bus.parent] = true;
        }
    auto routeHardware = [&](const AudioBuffer<float> &source, const jaras::OutputPatch &patch) {
        if (patch.firstChannel < 1)
            return;
        int first = patch.firstChannel - 1;
        if (patch.channelCount == 1) {
            if (first < channels && out[first])
                for (int n = 0; n < samples; ++n)
                    out[first][n] += (source.getSample(0, n) + source.getSample(1, n)) * .5f;
        } else
            for (int c = 0; c < 2; ++c) {
                int ch = first + c;
                if (ch < channels && out[ch])
                    FloatVectorOperations::add(out[ch], source.getReadPointer(c), samples);
            }
    };
    if(latencyPlan) {
        auto &buffer=latencyPlan->metronomeBuffer;
        latencyPlan->metronome.process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,blockClock,renderingHead[0]);
        for(int c=0;c<metronomeChannels;c++) {
            const int channel=metronomeOutput-1+c;
            if(metronomeEnabled.load(std::memory_order_relaxed)&&channel>=0&&channel<channels&&out[channel])FloatVectorOperations::add(out[channel],buffer.getReadPointer(std::min(1,c)),samples);
        }
    }
    auto automationTime=[&](int head,int frame,unsigned delay) {
        if(delay>unsigned(frame)&&latencyPlan)return latencyPlan->timeline[head].previous(delay-unsigned(frame)).position;
        const int sample=frame-int(delay);
        return timelineRunning[size_t(head)][size_t(sample)]?timelinePositions[size_t(head)][size_t(sample)]:(head==0?current.position:current.subPosition);
    };
    for (int index : busOrder) {
        auto &bus = *buses[(size_t)index];
        const bool fadeSelected = fadeout.active && bus.fadeoutSelected.load(std::memory_order_relaxed);
        if (bus.timecode) {
            // LTC is a direct physical route, independent of Master gain,
            // track solo, pan, FX, sends and the secondary playback head.
            if (fadeSelected) for (int ch = 0; ch < 2; ++ch)
                FloatVectorOperations::multiply(bus.buffer.getWritePointer(ch), trackFadeoutGains.data(), samples);
            const float peak = bus.mute ? 0.f : bus.buffer.getMagnitude(0, samples);
            bus.held.record(peak);
            bus.peak.store(peak, std::memory_order_relaxed);
            for (int ch = 0; ch < 2; ++ch)
                bus.levels[(size_t)ch].store(bus.mute ? 0.f : bus.buffer.getMagnitude(ch, 0, samples));
            if(latencyPlan) {
                auto &path=latencyPlan->buses[size_t(index)];
                path.direct[0].process(bus.buffer.getWritePointer(0),bus.buffer.getWritePointer(1),samples,blockClock,renderingHead[0]);
                path.inputDelay[0].process(bus.buffer.getWritePointer(0),bus.buffer.getWritePointer(1),samples,blockClock,renderingHead[0]);
                path.hardware[0].process(bus.buffer.getWritePointer(0),bus.buffer.getWritePointer(1),samples,blockClock,renderingHead[0]);
            }
            if (!bus.mute && !masterSolo) for (const auto& patch : bus.outputs) routeHardware(bus.buffer, patch);
            continue;
        }
        bus.midiMessages.clear();
        if (bus.midiSlot >= 1 && bus.midiSlot <= 3)
            appendLiveTrackMIDI(bus.midiMessages, slotMessages[bus.midiSlot - 1], samples, bus.armed.load() && liveInputEnabled.load());
        if (index == keyboardTarget.load()) {
            appendLiveTrackMIDI(bus.midiMessages, keyboardMidi, samples, bus.armed.load() && liveInputEnabled.load());
            routedKeyboard = true;
        }
        if (trackCapture)
            trackCapture->midi(bus.id, bus.midiMessages, samples, bus.midiChannel);
        if(allowInstrument)for(const auto event:bus.midiMessages)
            if(bus.midiChannel<=0||event.getMessage().getChannel()==bus.midiChannel)
                bus.externalMIDI[0].addEvent(event.getMessage(),event.samplePosition);
        if(!allowInstrument&&instrumentWasAllowed)
            for(int channel=1;channel<=16;++channel)bus.externalMIDI[0].addEvent(MidiMessage::allNotesOff(channel),0);
        liveRecordBuffer.clear(0, samples);
        if (bus.midi && !bus.midi->empty()) {
            if (allowInstrument)
                bus.midi->live(liveRecordBuffer, bus.midiMessages, samples, bus.midiChannel);
            else if (instrumentWasAllowed)
                bus.midi->stopLive();
        }
        if (allowInstrument && liveInputEnabled.load() && bus.armed.load() && bus.inputMonitoring && bus.inputFirst > 0 &&
            input)
            for (int ch = 0; ch < 2; ++ch) {
                const int physical = bus.inputFirst - 1 + (bus.inputChannels == 1 ? 0 : ch);
                const int packed = physical < 128 ? inputMapping[(size_t)physical] : -1;
                if (packed >= 0 && packed < inputChannels && input[packed])
                    liveRecordBuffer.addFrom(ch, 0, input[packed], samples);
            }
        if (trackCapture)
            trackCapture->bus(bus.id, liveRecordBuffer, samples);
        for (int ch = 0; ch < 2; ++ch)
            bus.buffer.addFrom(ch, 0, liveRecordBuffer, ch, 0, samples);
        float peak=0,fxInput=0,fxOutput=0;std::array<float,2> stereoPeak{};
        auto *compensation=latencyPlan?&latencyPlan->buses[size_t(index)]:nullptr;
        const bool combined=bus.fx[0].hasActiveStem();
        const bool perHeadAutomation=combined&&!bus.automation.curves.empty();
        bool volumeEnvelope=false,panEnvelope=false;
        if(perHeadAutomation)for(const auto &curve:bus.automation.curves){volumeEnvelope|=curve.target==AutomationCurve::volume;panEnvelope|=curve.target==AutomationCurve::pan;}
        const bool absoluteVolume=volumeEnvelope&&!bus.automation.trim&&!bus.automation.take;
        const int combinedHead=renderingHead[0]?0:renderingHead[1]?1:0;
        auto applyGain=[&](AudioBuffer<float> &buffer,int head,bool beforeEffect=false,bool frozen=false) {
            const unsigned delay=compensation?(beforeEffect&&!frozen?compensation->input:compensation->output):0;
            for(int n=0;n<samples;n++) {
                const auto values=bus.automation.evaluate(automationTime(head,n,delay),beforeEffect?1:bus.volume,beforeEffect&&!panEnvelope?0:bus.pan,beforeEffect?false:bus.mute);
                float left=values.mute?0:(float)values.gain,right=left;
                if(values.pan>0)left*=1-(float)values.pan;else right*=1+(float)values.pan;
                if(!beforeEffect){if(bus.phase)left=-left,right=-right;if(fadeSelected)left*=trackFadeoutGains[size_t(n)],right*=trackFadeoutGains[size_t(n)];}
                buffer.setSample(0,n,buffer.getSample(0,n)*left);buffer.setSample(1,n,buffer.getSample(1,n)*right);
            }
        };
        // Prepare each head independently before a CatStem bus merges them.
        // A normal chain keeps its existing per-head processing behavior.
        for(int head=0;head<2;head++) {
            auto &buffer=bus.head(head);const auto clock=blockClock;
            const bool moving=renderingHead[head];
            if(compensation)compensation->direct[head].process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,clock,moving);
            for(int ch=0;ch<2;ch++)buffer.addFrom(ch,0,bus.clips[head],ch,0,samples);
            if(compensation) {
                compensation->inputDelay[head].process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,clock,moving);
                for(int ch=0;ch<2;ch++)buffer.addFrom(ch,0,compensation->routed[head],ch,0,samples);
                compensation->frozen[head].process(bus.frozen[head].getWritePointer(0),bus.frozen[head].getWritePointer(1),samples,clock,moving);
            }
            if(perHeadAutomation){applyGain(buffer,head,true);applyGain(bus.frozen[head],head,true,true);}
        }
        if(combined) {
            const int other=1-combinedHead;for(int ch=0;ch<2;ch++){
                bus.head(combinedHead).addFrom(ch,0,bus.head(other),ch,0,samples);
                bus.frozen[combinedHead].addFrom(ch,0,bus.frozen[other],ch,0,samples);
            }
            bus.head(other).clear(0,samples);bus.frozen[other].clear(0,samples);
            bus.externalMIDI[combinedHead].addEvents(bus.externalMIDI[other],0,samples,0);
        }
        for(int head=0;head<2;head++) {
            if(combined&&head!=combinedHead)continue;
            auto &buffer=bus.head(head);const auto clock=blockClock;
            const bool moving=combined?active:renderingHead[head];
            fxInput=std::max(fxInput,buffer.getMagnitude(0,samples));
            bus.fx[combined?0:head].process(buffer,samples,timelinePositions[size_t(head)][0],moving,&bus.externalMIDI[head],blockClock/sr);
            for(int ch=0;ch<2;ch++)buffer.addFrom(ch,0,bus.frozen[head],ch,0,samples);
            fxOutput=std::max(fxOutput,buffer.getMagnitude(0,samples));
            if(!perHeadAutomation)applyGain(buffer,head);
            else for(int ch=0;ch<2;ch++) {
                // Trim/read gain decomposes without division, so even a fader
                // raised from silence responds immediately after inference.
                float gain=absoluteVolume?1:bus.volume;
                if((!bus.automation.controlsMute()||bus.automation.take)&&bus.mute)gain=0;
                if(bus.phase)gain=-gain;
                if(!panEnvelope){if(ch==0&&bus.pan>0)gain*=1-bus.pan;else if(ch==1&&bus.pan<0)gain*=1+bus.pan;}
                FloatVectorOperations::multiply(buffer.getWritePointer(ch),gain,samples);
                if(fadeSelected)FloatVectorOperations::multiply(buffer.getWritePointer(ch),trackFadeoutGains.data(),samples);
            }
            const bool silent = !routeAudible[(size_t)index];
            peak = std::max(peak, silent ? 0.f : buffer.getMagnitude(0, samples));
            if (!silent) for (int ch = 0; ch < 2; ++ch)
                stereoPeak[(size_t)ch] = std::max(stereoPeak[(size_t)ch], buffer.getMagnitude(ch, 0, samples));
            if(silent)buffer.clear(0,samples);
            auto routeBus=[&](int target) {
                if(!compensation)return;
                for(auto &route:compensation->routes)if(route.target==target) {
                    auto &scratch=latencyPlan->scratch;
                    for(int ch=0;ch<2;ch++)scratch.copyFrom(ch,0,buffer,ch,0,samples);
                    route.delay[head].process(scratch.getWritePointer(0),scratch.getWritePointer(1),samples,clock,moving);
                    for(int ch=0;ch<2;ch++)latencyPlan->buses[size_t(target)].routed[head].addFrom(ch,0,scratch,ch,0,samples);
                    return;
                }
            };
            std::array<int,513> sentTargets{};unsigned sentCount=0;
            auto sendOnce=[&](int target) {if(std::find(sentTargets.begin(),sentTargets.begin()+sentCount,target)==sentTargets.begin()+sentCount){sentTargets[sentCount++]=target;routeBus(target);}};
            for(int target:bus.sends)sendOnce(target);
            bool sentMaster=false,preparedHardware=false;
            for(const auto &patch:bus.outputs) {
                if(patch.firstChannel==-2&&bus.parent>=0)sendOnce(bus.parent);
                else if(patch.firstChannel==0&&!sentMaster) {
                    sentMaster=true;auto &scratch=latencyPlan->scratch;
                    for(int ch=0;ch<2;ch++)scratch.copyFrom(ch,0,buffer,ch,0,samples);
                    compensation->master[head].process(scratch.getWritePointer(0),scratch.getWritePointer(1),samples,clock,moving);
                    for(int ch=0;ch<2;ch++)masterBuffer.addFrom(ch,0,scratch,ch,0,samples);
                } else if(patch.firstChannel>0) {
                    auto &scratch=latencyPlan->hardwareScratch;
                    if(!preparedHardware){for(int ch=0;ch<2;ch++)scratch.copyFrom(ch,0,buffer,ch,0,samples);compensation->hardware[head].process(scratch.getWritePointer(0),scratch.getWritePointer(1),samples,clock,moving);preparedHardware=true;}
                    if(!masterSolo)routeHardware(scratch,patch);
                }
            }
        }
        bus.fxInput.store(std::max(fxInput, bus.fxInput.load() * .85f));
        bus.fxOutput.store(std::max(fxOutput, bus.fxOutput.load() * .85f));
        const double elapsed = samples / rate.load();
        bus.held.record(peak);
        bus.peak.store(meterDisplay::envelope(bus.peak.load(), peak, elapsed), std::memory_order_relaxed);
        for (int ch = 0; ch < 2; ++ch)
            bus.levels[(size_t)ch].store(meterDisplay::envelope(bus.levels[(size_t)ch].load(), stereoPeak[(size_t)ch], elapsed), std::memory_order_relaxed);
    }
    if (routedHardware)
        liveMidi.clear();
    if (!routedKeyboard)
        appendLiveTrackMIDI(liveMidi, keyboardMidi, samples, liveInputEnabled.load());
    liveRecordBuffer.clear(0,samples);
    if (allowInstrument) {
        if (masterMIDI && !masterMIDI->empty())
            masterMIDI->live(liveRecordBuffer, liveMidi, samples);
        else
            instrument.render(liveRecordBuffer, liveMidi, samples);
    } else if (instrumentWasAllowed) {
        instrument.stop();
        if (masterMIDI)
            masterMIDI->stopLive();
    }
    instrumentWasAllowed = allowInstrument;
    if(latencyPlan)latencyPlan->masterLive.process(liveRecordBuffer.getWritePointer(0),liveRecordBuffer.getWritePointer(1),samples,blockClock,active);
    for(int ch=0;ch<2;ch++)masterBuffer.addFrom(ch,0,liveRecordBuffer,ch,0,samples);
    masterFXInput.store(
        std::max(masterBuffer.getMagnitude(0, samples), masterFXInput.load() * .85f));
    masterFX.process(masterBuffer, samples,timelinePositions[0][0],active,allowInstrument?&liveMidi:nullptr,blockClock/sr);
    masterFXOutput.store(
        std::max(masterBuffer.getMagnitude(0, samples), masterFXOutput.load() * .85f));
    float maxPeak = 0;
    for (int i = 0; i < samples; ++i) {
        if (masterMono)
            masterBuffer.setSample(
                0, i, (masterBuffer.getSample(0, i) + masterBuffer.getSample(1, i)) * .5f),
                masterBuffer.setSample(1, i, masterBuffer.getSample(0, i));
        for (int ch = 0; ch < 2; ++ch) {
            const auto values=masterAutomation.evaluate(automationTime(0,i,latencyPlan?latencyPlan->masterInput+masterFX.latencyFrames():0),masterVolume,masterPan,masterMute);
            float gain = values.mute ? 0 : (float)values.gain * (masterPhase ? -1.0f : 1.0f);
            if (ch % 2 == 0 && values.pan > 0)
                gain *= 1 - (float)values.pan;
            if (ch % 2 == 1 && values.pan < 0)
                gain *= 1 + (float)values.pan;
            masterBuffer.setSample(ch, i, masterBuffer.getSample(ch, i) * gain);
        }
    }
    if(latencyPlan) {
        auto &scratch=latencyPlan->scratch;for(int ch=0;ch<2;ch++)scratch.copyFrom(ch,0,masterBuffer,ch,0,samples);
        latencyPlan->masterHardware.process(scratch.getWritePointer(0),scratch.getWritePointer(1),samples,blockClock,active);
        for(const auto &patch:masterOutputs)routeHardware(scratch,patch);
    }
    if (exportCapture) {
        for (int ch = 0; ch < channels; ++ch)
            if (out[ch])
                FloatVectorOperations::clear(out[ch], samples);
        if (exportBus < 0) {
            for (int ch = 0; ch < std::min(channels, 2); ++ch)
                if (out[ch])
                    FloatVectorOperations::copy(out[ch], masterBuffer.getReadPointer(ch), samples);
        } else if (routeAudible[(size_t)exportBus]) {
            const auto &bus = *buses[(size_t)exportBus];
            for (int ch = 0; ch < std::min(channels, 2); ++ch)
                if (out[ch]) {
                    FloatVectorOperations::copy(out[ch], bus.buffer.getReadPointer(ch), samples);
                    FloatVectorOperations::add(out[ch], bus.subBuffer.getReadPointer(ch), samples);
                }
        }
    }
    // A completed transport fade remains held until the next Play/cancel.
    // Silence the physical outputs after Stop as well: Master reverb/delay and
    // unselected monitor routes must not leak their tails into a stopped fade.
    // During playback only the selected buses are affected by the fade ramp.
    if (fadeout.active && fadeout.remaining == 0 && !current.playing && !current.subPlaying) {
        masterBuffer.clear(0, samples);
        for (int ch = 0; ch < channels; ++ch)
            if (out[ch]) FloatVectorOperations::clear(out[ch], samples);
    }
    for (int ch = 0; ch < channels; ++ch)
        if (out[ch]) {
            auto range = FloatVectorOperations::findMinAndMax(out[ch], samples);
            maxPeak =
                std::max(maxPeak, std::max(std::abs(range.getStart()), std::abs(range.getEnd())));
        }
    masterPeakHold.record(masterBuffer.getMagnitude(0,samples));
    meter.store(meterDisplay::envelope(meter.load(), maxPeak, samples / rate.load()), std::memory_order_relaxed);
    for (int ch = 0; ch < 2; ++ch)
        masterLevels[(size_t)ch].store(meterDisplay::envelope(masterLevels[(size_t)ch].load(),
            masterBuffer.getMagnitude(ch, 0, samples), samples / rate.load()), std::memory_order_relaxed);
    if(latencyPlan&&latencyPlan->total) {
        for(int h=0;h<2;h++) {
            native::TimelineDelay::Frame shown;
            const auto stopped=h==0?current.position:current.subPosition;
            for(int n=0;n<samples;n++)shown=latencyPlan->timeline[h].process({timelineRunning[size_t(h)][size_t(n)]?timelinePositions[size_t(h)][size_t(n)]:stopped,timelineRunning[size_t(h)][size_t(n)]});
            presentedPosition[h]=shown.position+(shown.moving?1/sr:0);
            presentedPlaying[h]=(h==0?current.playing:current.subPlaying)||tailFrames[h]>0||shown.moving;
            if(h==0)timecodeMIDI.publishAudioClock(shown.position+(shown.moving?1/sr:0),shown.moving,true,samples/sr);
        }
    } else timecodeMIDI.publishAudioClock(current.position,current.playing,false,samples/sr);
    presentationTailing=tailFrames[0]>0||tailFrames[1]>0;
    renderClock+=unsigned(samples);
    position.store(current.position);
    subPosition.store(current.subPosition);
    playing.store(current.playing);
    subPlaying.store(current.subPlaying);
    if (active)
        elapsedSamples.fetch_add((uint64)samples, std::memory_order_relaxed);
    if (trackCapture) {
        trackCapture->advance(samples);
        recordedFrames = trackCapture->sampleCount();
    }
    transportFadeout.advance(fadeout, (uint32_t)std::max(0, samples));
}
void AudioEngine::audioDeviceIOCallbackWithContext(const float *const *input, int inputs,
                                                   float *const *out, int channels, int samples,
                                                   const AudioIODeviceCallbackContext &) {
    if (recording.load(std::memory_order_relaxed) && recorder && inputs > 0) {
        if (!recorder->write(input, samples))
            recordingDrops.fetch_add(1, std::memory_order_relaxed);
    }
    // JUCE packs enabled device channels. The routing graph uses physical,
    // one-based channel numbers, including gaps in the enabled channel mask.
    std::array<float *, 128> physical{};
    for(int channel=0;channel<channels;++channel)if(out[channel])FloatVectorOperations::clear(out[channel],samples);
    int count = 0;
    for (int channel = 0; channel < 128; ++channel) {
        const int packed = outputMapping[(size_t)channel];
        if (packed >= 0 && packed < channels) {
            physical[(size_t)channel] = out[packed];
            count = channel + 1;
        }
    }
    render(physical.data(), count, samples, input, inputs);
}
void AudioEngine::configureDeviceChannels(const BigInteger &inputs, const BigInteger &outputs) {
    inputMapping.fill(-1);
    outputMapping.fill(-1);
    int input = 0, output = 0;
    for (int channel = 0; channel < 128; ++channel) {
        if (inputs[channel]) inputMapping[(size_t)channel] = input++;
        if (outputs[channel]) outputMapping[(size_t)channel] = output++;
    }
}
void AudioEngine::audioDeviceAboutToStart(AudioIODevice *d) {
    cancelTrackFadeout();
    rate = d->getCurrentSampleRate();
    configureDeviceChannels(d->getActiveInputChannels(), d->getActiveOutputChannels());
    masterFX.prepare(masterFXSettings, rate.load(),nullptr,offlineMode);
    midiInput.reset(rate.load());
    for (auto &slot : midiSlots)
        slot.reset(rate.load());
    if (masterMIDI)
        masterMIDI->prepare(rate.load());
    instrument.prepare(rate.load());
    for (auto &bus : buses) {
        if (bus->midi)
            bus->midi->prepare(rate.load());
        for(int h=0;h<2;h++)
            bus->fx[h].prepare(bus->settings,rate.load(),nullptr,offlineMode,h==0);
        bus->fx[1].shareStems(bus->fx[0]);
    }
    for (auto &voice : voices) {
        if (voice->clipAudio)
            voice->clipAudio->prepare(rate.load());
        for(int h=0;h<2;h++)
            voice->fx[h].prepare(voice->fxSettings,rate.load(),nullptr,offlineMode,h==0);
        voice->fx[1].shareStems(voice->fx[0]);
    }
    latencyPlan.reset();activateStemLatency();latencyPlan=makeLatencyPlan();publishLatency();
}
void AudioEngine::setMIDISlot(int slot, const String &identifier) {
    if (slot < 0 || slot >= 3)
        return;
    const ScopedLock lock(midiRoutingLock);
    midiDevices[slot] = identifier;
}
void AudioEngine::handleIncomingMidiMessage(MidiInput *source, const MidiMessage &message) {
    midiInput.addMessageToQueue(message);
    if (source) {
        const ScopedLock lock(midiRoutingLock);
        for (int slot = 0; slot < 3; ++slot)
            if (midiDevices[slot] == source->getIdentifier())
                midiSlots[slot].addMessageToQueue(message);
    }
}
void AudioEngine::loadSoundFont(const File &file) {
    if (attached)
        devices.removeAudioCallback(this);
    try {
        instrument.loadSoundFont(file);
    } catch (...) {
        if (attached)
            devices.addAudioCallback(this);
        throw;
    }
    if (attached)
        devices.addAudioCallback(this);
}
void AudioEngine::audioDeviceStopped() {
    cancelTrackFadeout();
    playing = false;
    subPlaying = false;
}
} // namespace catlive
