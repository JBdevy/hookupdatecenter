#include "MediaSource.h"
#include "ProjectionSelection.h"
#include "MeterDisplay.h"
#include "AudioEngine.h"
#include "AudioDeviceChannels.h"
#include "ProjectCodec.h"
#include "ClipAudio.h"
#include "WaveformCache.h"
#include "../../WindowsNative/Source/AudioFile.h"
#include <BinaryData.h>
namespace catlive {
struct AudioEngine::ReaderContext {
    AudioFormatManager formats;
    TimeSliceThread thread{"CatLive media read-ahead"};
    StreamingReader::Service streams{formats, thread};
    ReaderContext() { registerAudioFormats(formats); thread.startThread(Thread::Priority::high); }
    ~ReaderContext() { streams.stop(); thread.stopThread(5000); }
};
AudioEngine::AudioEngine(double preparationRate, bool preparingOffline, std::shared_ptr<AudioDeviceManager> host)
    : deviceHost(host ? std::move(host) : std::make_shared<AudioDeviceManager>()), devices(*deviceHost),
      systemDefaults(devices, [this] { return !isRecording(); }) {
    rate = preparationRate;
    offlineMode = preparingOffline;
    for (int i = 0; i < 128; ++i)
        inputMapping[(size_t)i] = outputMapping[(size_t)i] = i;
    liveMidi.ensureSize(32768);
    midiInput.reset(48000);
    keyboardMidi.ensureSize(32768);
    for (int i = 0; i < 6; ++i) {
        midiSlots[i].reset(48000);
        slotMessages[i].ensureSize(32768);
    }
    registerAudioFormats(formats);
    metronome.a = ClickProgram::tone("Digital", true);
    metronome.b = ClickProgram::tone("Digital", false);
}
AudioEngine::~AudioEngine() {
    cancelTransportPreparation();
    if(transportWorker)transportWorker->removeAllJobs(true,-1);
    timecodeMIDI.stop();
    devices.removeMidiInputDeviceCallback({}, this);
    stopRecording();
    closeDevice();
    voices.clear();
    removedItemVoices.clear();
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
    if (!device && !offlineMode && !targets.empty())
        throw std::runtime_error(
            "Selecione uma interface de áudio nas configurações antes de gravar.");
    for (const auto &target : targets)
        if (!target.bus && !target.midi) {
            for (int channel = 0; channel < target.channels; ++channel)
                if (!offlineMode && (!device || !device->getActiveInputChannels()[target.input - 1 + channel]))
                    throw std::runtime_error(
                        "Ative as entradas escolhidas no Patch antes de gravar.");
        }
    auto outputs = prepareRecordingOutputs(targets);
    auto prepared = std::make_unique<TrackCapture>(targets, rate.load(), bits, bpm);
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        trackCapture.swap(prepared);
        recordingOutputs.swap(outputs);
        recordedFrames = 0;
        recordingDrops = 0;
        recording = true;
    }
}
std::vector<TrackCapture::Take> AudioEngine::stopTrackRecording() {
    std::unique_ptr<TrackCapture> captured;
    std::vector<RecordingOutput> outputs;
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        recording = false;
        captured.swap(trackCapture);
        outputs.swap(recordingOutputs);
    }
    if (!captured)
        return {};
    auto result = captured->finish();
    recordingDrops = captured->overflows();
    return result;
}
double AudioEngine::changeRecordingTargets(const std::vector<TrackCapture::Target> &targets,
                                           const std::set<ID> &active, int bits) {
    if (!trackCapture) throw std::runtime_error("Recording is not active.");
    auto *device = devices.getCurrentAudioDevice();
    for (const auto &target : targets) if (!target.bus && !target.midi)
        for (int channel = 0; channel < target.channels; ++channel)
            if (!offlineMode && (!device || !device->getActiveInputChannels()[target.input - 1 + channel]))
                throw std::runtime_error("Ative as entradas escolhidas no Patch antes de gravar.");
    auto outputs = prepareRecordingOutputs(targets);
    outputs.reserve(outputs.size() + recordingOutputs.size());
    auto change = trackCapture->prepareTargets(targets, active, bits);
    int64 frame = 0;
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        frame = trackCapture->applyTargets(change);
        for (auto &output : recordingOutputs) if (active.count(output.track)) outputs.push_back(std::move(output));
        recordingOutputs.swap(outputs);
    }
    return (double)frame / rate.load();
}
std::vector<AudioEngine::RecordingOutput> AudioEngine::prepareRecordingOutputs(const std::vector<TrackCapture::Target> &targets) {
    std::vector<RecordingOutput> result;
    for (const auto &target : targets) if (target.output && !target.midi) {
        RecordingOutput output{target.track, {}};
        if (target.outputPostFX) {
            auto settings = target.effects.clone();
            captureExternalEffects(target.track, settings);
            output.fx = std::make_unique<NativeFX>();
            output.fx->prepare(settings, rate.load(), nullptr, offlineMode, true, {}, instrumentDirectory);
        }
        result.push_back(std::move(output));
    }
    return result;
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
String AudioEngine::outputAvailabilityError() const {
    if (!deviceSessionRequested || offlineMode) return {};
    auto *device=devices.getCurrentAudioDevice();
    if (!device || !device->isOpen() || !device->isPlaying() || device->getActiveOutputChannels().isZero())
        return "The selected audio output is disconnected.";
    return {};
}
String AudioEngine::openDevice() {
    deviceSessionRequested = true;
    if (attached)
        return audioDeviceChannels::enableAvailable(devices);
    auto preferences = File::getSpecialLocation(File::userApplicationDataDirectory)
                           .getChildFile("Hook Developer/CatLive/audio-device.xml");
    auto saved = XmlDocument::parse(preferences);
    systemDefaults.read(saved.get());
    auto error = devices.getCurrentAudioDevice() ? String{} : devices.initialise(0, 2, saved.get(), saved == nullptr);
    if (error.isEmpty()) error = systemDefaults.start(saved.get());
    if (error.isEmpty())
        error = audioDeviceChannels::enableAvailable(devices);
    if (error.isEmpty()) {
        devices.addAudioCallback(this);
        devices.removeMidiInputDeviceCallback({}, this);
        devices.addMidiInputDeviceCallback({}, this);
        attached = true;
    }
    return error;
}
AudioEngine::SharedMIDIUpdate AudioEngine::sharedMIDISequence(size_t bus, const Voice *replacement,
                                                            bool ownsReplacement) const {
    std::vector<PlaybackNote> notes;
    for (const auto &voice : voices)
        if (voice->bus == bus && voice->midiItem &&
            !(voice.get() == replacement ? ownsReplacement : voice->ownsMIDI()))
            notes.insert(notes.end(), voice->sharedMIDINotes.begin(), voice->sharedMIDINotes.end());
    std::stable_sort(notes.begin(), notes.end(), [](const auto &a, const auto &b) { return a.start < b.start; });
    return SharedMIDIUpdate(std::move(notes));
}
void AudioEngine::replaceSharedMIDI(size_t index, SharedMIDIUpdate &next) {
    auto &bus = *buses[index];
    bus.midiNotes.swap(next.external.notes);
    bus.externalEvents.swap(next.external.events);
    for (auto &expected : bus.externalExpected) expected = -1;
    if (bus.midi) bus.midi->replaceSequence(next.synth, true);
}
void AudioEngine::previewMIDIItem(const jaras::Song &song,const jaras::AudioClip &clip) {
    for(const auto &track:song.tracks)if(std::any_of(track.clips.begin(),track.clips.end(),[&](const auto &c){return c.id==clip.id;})){
        auto draft=track;for(auto &item:draft.clips)if(item.id==clip.id)item=clip;
        SharedMIDIUpdate shared(playbackNotes(draft,&song,true,true));
        auto sequence=MIDIPlayback::sequence(takePlaybackNotes(draft,clip,song,true));
        auto sharedNotes=takePlaybackNotes(draft,clip,song,false);
        auto timing=std::make_unique<ClipTempo>(clip,&song);
        std::unique_ptr<LatencyPlan> preparedLatency;
        bool updateShared=true;
        for(const auto &voice:voices)if(voice->clipID==clip.id && voice->midiItem) {
            updateShared=!voice->ownsMIDI()||!hasTakeInstrument(clip);
            preparedLatency=makeLatencyPlan(&clip.id,&voice->fx[0],
                voice->midiInstrument&&!clip.fxBypassed.value_or(false));
        }
        setItemControls(clip);
        const ScopedLock lock(devices.getAudioCallbackLock());
        applyUpdates();
        for(auto &voice:voices)if(voice->clipID==clip.id && voice->midiItem) {
            std::swap(voice->midiSequence,sequence);
            voice->sharedMIDINotes.swap(sharedNotes);
            voice->midiTiming.swap(timing);
            voice->start=clip.startTime;voice->duration=clip.duration;
            voice->offset=clip.sourceOffset;voice->speed=clip.playbackRate;
            voice->playbackStart=jaras::playbackItemStart(song,clip); voice->regionOwnerIndex=jaras::playbackOwnerIndex(song,clip.regionOwnerID);
            voice->fadeIn=clip.fadeIn.value_or(0); voice->fadeOut=clip.fadeOut.value_or(0);
            for(auto &expected:voice->midiExpected)expected=-2;
        }
        for(size_t index=0;index<buses.size();++index)if(updateShared&&buses[index]->id==track.id){
            replaceSharedMIDI(index,shared);
        }
        if(preparedLatency){latencyPlan.swap(preparedLatency);publishLatency();}
        return;
    }
}
bool AudioEngine::cacheSplitItems(const jaras::Song &song, const std::map<ID, ID> &sources) {
    if (sources.empty()) return true;
    std::vector<std::unique_ptr<Voice>> added;
    std::set<ID> newIDs = preparedItemIDs;
    for (const auto &track : song.tracks) for (const auto &clip : track.clips) {
        const auto sourceID = sources.find(clip.id);
        if (sourceID == sources.end()) continue;
        const Voice *original = nullptr;
        for (const auto &voice : voices) if (voice->clipID == sourceID->second) { original = voice.get(); break; }
        if (!original) {
            if (!preparedItemIDs.count(sourceID->second)) return false;
            newIDs.insert(clip.id); continue; // visual-only or missing media
        }
        if (original->midiItem || original->clipAudio || !original->fx[0].empty() || !original->fx[1].empty() || ClipAudio::needed(song, track, clip)) return false;
        auto voice = std::make_unique<Voice>();
        voice->track=track.id; voice->clipID=clip.id; voice->source=original->source; voice->bus=original->bus;
        voice->start=clip.startTime; voice->duration=clip.duration; voice->offset=clip.sourceOffset; voice->speed=clip.playbackRate;
        voice->playbackStart=jaras::playbackItemStart(song,clip); voice->regionOwnerIndex=jaras::playbackOwnerIndex(song,clip.regionOwnerID);
        voice->clipGain=original->clipGain; voice->clipPan=original->clipPan; voice->channelMode=original->channelMode;
        voice->fadeIn=clip.fadeIn.value_or(0); voice->fadeOut=clip.fadeOut.value_or(0); voice->fadeInShape=original->fadeInShape; voice->fadeOutShape=original->fadeOutShape;
        voice->volume=original->volume; voice->pan=original->pan; voice->mute=original->mute; voice->solo=original->solo;
        voice->itemMuted=original->itemMuted; voice->fxBypassed=original->fxBypassed; voice->frozen=original->frozen;
        voice->firstOutput=original->firstOutput; voice->outputChannels=original->outputChannels;
        voice->automation.prepare(clip.automationJSON ? JSON::parse(text(*clip.automationJSON)) : var(),true);
        for(int h=0;h<2;++h){voice->processed[h].setSize(2,4096);voice->fx[h].prepare({},rate.load());}
        newIDs.insert(clip.id); added.push_back(std::move(voice));
    }
    // Cache until refreshItemPresence publishes all halves atomically.
    removedItemVoices.reserve(removedItemVoices.size()+added.size());
    { const ScopedLock lock(devices.getAudioCallbackLock());
      for(auto& voice:added) removedItemVoices.push_back(std::move(voice));
      preparedItemIDs.swap(newIDs);
    }
    return true;
}
bool AudioEngine::refreshItemPresence(const jaras::Song &song) {
    if (song.tracks.size() != buses.size()) return false;
    // A hierarchy edit retains the bus/processor order while the document's
    // tracks move. Every per-bus rebuild must resolve the track by identity.
    std::map<ID, const jaras::Track *> tracksByID;
    for (const auto &track : song.tracks)
        if (!tracksByID.emplace(track.id, &track).second) return false;
    std::map<ID, const jaras::AudioClip *> wanted;
    std::map<ID,size_t> wantedBuses;
    for (size_t i = 0; i < buses.size(); ++i) {
        const auto found = tracksByID.find(buses[i]->id);
        if (found == tracksByID.end()) return false;
        for (const auto &clip : found->second->clips) {
            // Missing media and visual-only items legitimately have no voice.
            // Only an item absent from this graph's original model needs preparation.
            if (!preparedItemIDs.count(clip.id)) return false;
            wanted.emplace(clip.id, &clip);
            wantedBuses.emplace(clip.id,i);
        }
    }
    std::map<ID, Voice *> available;
    for (const auto &voice : voices) available.emplace(voice->clipID, voice.get());
    for (const auto &voice : removedItemVoices) available.emplace(voice->clipID, voice.get());
    for (const auto &entry : wanted) if (const auto found=available.find(entry.first);found!=available.end()) {
        const auto &v=*found->second; const auto &c=*entry.second;
        if(v.bus!=wantedBuses.at(entry.first))return false;
        if ((v.midiItem || v.clipAudio) && (v.start!=c.startTime || v.duration!=c.duration || v.offset!=c.sourceOffset || v.speed!=c.playbackRate)) return false;
    }
    std::vector<Voice *> active;
    active.reserve(wanted.size());
    for (const auto &track : song.tracks) for (const auto &clip : track.clips)
        if (const auto found = available.find(clip.id); found != available.end()) active.push_back(found->second);
    auto nextLatency = makeLatencyPlan(nullptr, nullptr, {}, false, false, &active);
    std::vector<std::pair<size_t, SharedMIDIUpdate>> midi;
    std::map<size_t, std::vector<ClickProgram::Section>> clicks;
    std::optional<jaras::TimecodeProgram> timecode;
    bool timecodeMuted = false;
    for (size_t i = 0; i < buses.size(); ++i) {
        const auto &track = *tracksByID.at(buses[i]->id);
        bool changedMIDI = false;
        for (const auto &voice : voices) if (voice->bus == i && voice->midiItem && !wanted.count(voice->clipID)) changedMIDI = true;
        for (const auto &voice : removedItemVoices) if (voice->bus == i && voice->midiItem && wanted.count(voice->clipID)) changedMIDI = true;
        if (changedMIDI) midi.emplace_back(i, SharedMIDIUpdate(playbackNotes(track, &song, true, true)));
        if (buses[i]->click) { ClickProgram program; program.prepare(song, &track); clicks.emplace(i, std::move(program.sections)); }
        if (buses[i]->timecode) { timecode.emplace(song, track); timecodeMuted = track.mute; }
    }
    std::vector<std::unique_ptr<Voice>> next, retired;
    next.reserve(active.size()); retired.reserve(voices.size() + removedItemVoices.size());
    std::map<ID, std::unique_ptr<Voice> *> owners;
    for (auto &voice : voices) owners.emplace(voice->clipID, &voice);
    for (auto &voice : removedItemVoices) owners.emplace(voice->clipID, &voice);
    std::vector<std::unique_ptr<Voice> *> ordered;
    ordered.reserve(active.size());
    for (auto *voice : active) ordered.push_back(owners.at(voice->clipID));
    // No file access, plugin construction or destruction while publishing.
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        applyUpdates(); // queued item controls still refer to the old indices
        for (auto &voice : voices) if (!wanted.count(voice->clipID) && voice->midiItem)
            for (int head = 0; head < 2; ++head) mixMIDIVoice(*voice, head, head ? current.subPosition : current.position, nullptr, 0, 0, 1, false);
        for (auto *owner : ordered) next.push_back(std::move(*owner));
        for (auto &voice : voices) if (voice) retired.push_back(std::move(voice));
        for (auto &voice : removedItemVoices) if (voice) retired.push_back(std::move(voice));
        voices.swap(next); removedItemVoices.swap(retired);
        for (auto &voice : voices) if (const auto found=wanted.find(voice->clipID);found!=wanted.end()) {
            const auto &clip=*found->second;
            voice->start=clip.startTime; voice->duration=clip.duration; voice->offset=clip.sourceOffset; voice->speed=clip.playbackRate;
            voice->playbackStart=jaras::playbackItemStart(song,clip); voice->regionOwnerIndex=jaras::playbackOwnerIndex(song,clip.regionOwnerID);
            voice->fadeIn=clip.fadeIn.value_or(0); voice->fadeOut=clip.fadeOut.value_or(0);
        }
        for (auto &entry : midi) replaceSharedMIDI(entry.first, entry.second);
        for (auto &entry : clicks) buses[entry.first]->click->sections.swap(entry.second);
        if (timecode) std::swap(timecodeProgram, *timecode);
        installLatencyPlan(nextLatency, current.playing || current.subPlaying);
        stemLatencyFingerprint = stemFingerprint();
        duration = song.duration;
    }
    if (timecode) timecodeMIDI.updateProgram(timecodeProgram, song.duration, timecodeMuted);
    return true;
}
void AudioEngine::refreshItemTiming(const jaras::Song &song, const jaras::AudioClip &clip) {
    const auto owner = std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto &track) {
        return std::any_of(track.clips.begin(), track.clips.end(), [&](const auto &item) { return item.id == clip.id; });
    });
    if (owner == song.tracks.end()) throw std::runtime_error("Item track no longer exists.");
    if (clip.midi && !clip.frozenMIDI.value_or(false)) {
        previewMIDIItem(song, clip);
        const ScopedLock lock(devices.getAudioCallbackLock());
        duration = song.duration;
        return;
    }
    Voice *target = nullptr;
    for (const auto &voice : voices) if (voice->clipID == clip.id) { target = voice.get(); break; }
    std::unique_ptr<ClipAudio> processor;
    if (target && ClipAudio::needed(song, *owner, clip))
        processor = std::make_unique<ClipAudio>(song, *owner, clip, rate.load());
    auto playbackStart = jaras::playbackItemStart(song, clip);
    std::optional<jaras::TimecodeProgram> timecode;
    if (owner->role.id == "timecode") timecode.emplace(song, *owner);
    // Decoder/DSP preparation and retired-object destruction remain outside
    // the callback lock. Publication changes only this item's time mapping.
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        if (target) {
            target->start = clip.startTime; target->duration = clip.duration;
            target->offset = clip.sourceOffset; target->speed = clip.playbackRate;
            target->playbackStart.swap(playbackStart);
            target->regionOwnerIndex=jaras::playbackOwnerIndex(song,clip.regionOwnerID);
            target->clipAudio.swap(processor);
        }
        duration = song.duration;
        if (timecode) std::swap(timecodeProgram, *timecode);
    }
    if (timecode) timecodeMIDI.updateProgram(timecodeProgram, song.duration, owner->mute);
}
void AudioEngine::refreshItemPitch(const jaras::Song &song, const ID &id) {
    for (const auto &track : song.tracks) for (const auto &clip : track.clips) if (clip.id == id) {
        for (const auto &voice : voices) if (voice->clipID == id) {
            std::unique_ptr<ClipAudio> processor;
            if (voice->clipAudio || ClipAudio::needed(song, track, clip))
                processor = std::make_unique<ClipAudio>(song, track, clip, rate.load(),
                    !voice->clipAudio || !voice->clipAudio->hasPreparedPitch());
            if (voice->clipAudio && processor && voice->clipAudio->sameMapping(*processor)) return;
            // Prepare FFT memory outside the callback, then retain the running
            // heads, decoders and FX. Pitch edits do not seek either transport.
            {
                const ScopedLock lock(devices.getAudioCallbackLock());
                if (voice->clipAudio && processor && voice->clipAudio->hasPreparedPitch())
                    voice->clipAudio->adoptTiming(*processor);
                else voice->clipAudio.swap(processor);
            }
            return;
        }
        return;
    }
}
void AudioEngine::refreshRegionPitch(const jaras::Song &song, const ID &region) {
    const auto part = std::find_if(song.parts.begin(), song.parts.end(), [&](const auto &p) { return p.id == region; });
    if (part == song.parts.end()) return;
    jaras::TempoEditMap::PlaybackRates compiled(song);
    std::vector<std::pair<Voice *, std::unique_ptr<ClipAudio>>> replacements;
    std::unordered_map<ID, Voice*> byID;
    for (auto& voice : voices) byID.emplace(voice->clipID, voice.get());
    struct MIDIUpdate { Bus *bus; MIDIPlayback::Sequence sequence; std::vector<PlaybackNote> notes; std::vector<MIDIPlayback::Event> events; };
    std::vector<MIDIUpdate> midi;
    struct TakeUpdate { Voice *voice; MIDIPlayback::Sequence sequence; std::vector<PlaybackNote> shared; };
    std::vector<TakeUpdate> takes;
    for (const auto &track : song.tracks) {
        for (const auto &clip : track.clips) {
            if (clip.startTime >= part->endTime || clip.startTime + clip.duration <= part->startTime) continue;
            const auto found = byID.find(clip.id);
            if (found != byID.end()) {
                auto* voice = found->second;
                if (voice->midiItem) {
                    takes.push_back({voice,MIDIPlayback::sequence(takePlaybackNotes(track,clip,song,true)),
                                     takePlaybackNotes(track,clip,song,false)});
                    continue;
                }
                std::unique_ptr<ClipAudio> processor;
                // Keep the prepared FFT and both playback heads when changing
                // semitones, including returning to zero and changing again.
                if (voice->clipAudio || ClipAudio::needed(song, track, clip, &compiled))
                    processor = std::make_unique<ClipAudio>(song, track, clip, rate.load(),
                        !voice->clipAudio || !voice->clipAudio->hasPreparedPitch(), &compiled);
                if (voice->clipAudio && processor && voice->clipAudio->sameMapping(*processor)) continue;
                replacements.emplace_back(voice, std::move(processor));
            }
        }
        for (auto &bus : buses) if (bus->id == track.id && (!bus->midiNotes.empty() || bus->midi)) {
            auto notes = playbackNotes(track, &song, true, true);
            auto sequence = MIDIPlayback::sequence(notes);
            auto events = sequence.events;
            midi.push_back({bus.get(), std::move(sequence), std::move(notes), std::move(events)});
        }
    }
    // FFT preparation and destruction stay off the callback. Preserve readers,
    // FX instances and both transport clocks while publishing the new pitch.
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        for (auto &entry : replacements) {
            if (entry.first->clipAudio && entry.second && entry.first->clipAudio->hasPreparedPitch())
                entry.first->clipAudio->adoptTiming(*entry.second);
            else entry.first->clipAudio.swap(entry.second);
        }
        for (auto &entry : takes) {
            std::swap(entry.voice->midiSequence,entry.sequence);
            entry.voice->sharedMIDINotes.swap(entry.shared);
            for (auto &expected : entry.voice->midiExpected) expected=-2;
        }
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
void AudioEngine::refreshTempo(const jaras::Song &before, const jaras::Song &after) {
    const jaras::TempoEditMap map(before, after);
    jaras::TempoEditMap::PlaybackRates compiled(after);
    auto clickTiming = ClickProgram::tempo(after);
    std::map<ID, std::vector<ClickProgram::Section>> clickSections;
    for (const auto &track : after.tracks) if (track.role.id == "generatedClick") {
        ClickProgram program; program.prepare(after, &track);
        clickSections.emplace(track.id, std::move(program.sections));
    }
    const auto remap = [&](double at) {
        return before.bpm != after.bpm && after.timeSettings.value_or(jaras::ProjectTimeSettings{}).timebase == jaras::ProjectTimebase::relative
            ? at * before.bpm / after.bpm : map.position(at);
    };
    struct Edit {
        Voice *voice;
        const jaras::AudioClip *clip;
        std::optional<double> playbackStart;
        std::unique_ptr<ClipAudio> processor;
        std::unique_ptr<ClipTempo> midiTiming;
        MIDIPlayback::Sequence midi;
        std::vector<PlaybackNote> shared;
    };
    std::map<ID, Voice *> byID;
    for (auto &voice : voices) byID.emplace(voice->clipID, voice.get());
    std::vector<Edit> edits;
    std::vector<std::pair<size_t, SharedMIDIUpdate>> midiBuses;
    std::optional<jaras::TimecodeProgram> mtc;
    bool mtcMuted = false;
    for (const auto &track : after.tracks) {
        if (track.role.id == "timecode") { mtc.emplace(after, track); mtcMuted = track.mute; }
        bool hasMIDI = false;
        for (const auto &clip : track.clips) {
            const auto found = byID.find(clip.id);
            if (found == byID.end()) continue;
            auto *voice = found->second;
            Edit edit{voice, &clip, jaras::playbackItemStart(after, clip), {}, {}, {}, {}};
            if (voice->midiItem) {
                hasMIDI = true;
                edit.midiTiming = std::make_unique<ClipTempo>(clip, &after, &compiled);
                edit.midi = MIDIPlayback::sequence(takePlaybackNotes(track, clip, after, true));
                edit.shared = takePlaybackNotes(track, clip, after, false);
            } else if (voice->clipAudio || ClipAudio::needed(after, track, clip, &compiled)) {
                edit.processor = std::make_unique<ClipAudio>(after, track, clip, rate.load(), !voice->clipAudio || !voice->clipAudio->hasPreparedPitch(), &compiled);
            }
            edits.push_back(std::move(edit));
        }
        if (hasMIDI) for (size_t i = 0; i < buses.size(); ++i) if (buses[i]->id == track.id)
            midiBuses.emplace_back(i, SharedMIDIUpdate(playbackNotes(track, &after, true, true)));
    }
    // Keep file decoders, FX, FFT history and latency buffers. Only mappings
    // and clocks change, together at the same audio block boundary.
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        applyUpdates();
        const double oldCursor = current.playing ? current.position : current.subPosition;
        const double unreported = double(elapsedSamples.load()) / rate.load();
        if ((current.playing || current.subPlaying) && unreported > 0) {
            // UI/core already remapped its last sampled cursor. Frames played
            // while preparing this edit belong to the old tempo epoch; report
            // their mapped duration or syncClock will mistake the difference
            // for a seek and repeat an earlier block.
            const double mapped = remap(oldCursor) - remap(oldCursor - unreported);
            elapsedSamples = uint64(std::max(0., std::round(mapped * rate.load())));
        }
        for (auto &edit : edits) {
            auto &voice = *edit.voice;
            if (voice.clipAudio && edit.processor && voice.clipAudio->hasPreparedPitch()) voice.clipAudio->adoptTiming(*edit.processor);
            else voice.clipAudio.swap(edit.processor);
            voice.start = edit.clip->startTime; voice.duration = edit.clip->duration;
            voice.offset = edit.clip->sourceOffset; voice.speed = edit.clip->playbackRate;
            voice.playbackStart.swap(edit.playbackStart);
            voice.regionOwnerIndex=jaras::playbackOwnerIndex(after,edit.clip->regionOwnerID);
            if (voice.midiItem) {
                voice.midiTiming.swap(edit.midiTiming);
                std::swap(voice.midiSequence, edit.midi); voice.sharedMIDINotes.swap(edit.shared);
                for (auto &expected : voice.midiExpected) if (expected >= 0) expected = remap(expected);
            }
        }
        for (auto &entry : midiBuses) replaceSharedMIDI(entry.first, entry.second);
        current.position = remap(current.position); current.subPosition = remap(current.subPosition);
        current.loopStart = remap(current.loopStart); current.loopEnd = remap(current.loopEnd);
        current.end = std::isfinite(current.end) ? remap(current.end) : current.end;
        position = current.position; subPosition = current.subPosition;
        for (int h = 0; h < 2; ++h) {
            for(auto* scope : {&current.scope[h],&current.exclusiveScope[h]}) {
                if (std::isfinite(scope->minimum)) scope->minimum = remap(scope->minimum);
                if (std::isfinite(scope->maximum)) scope->maximum = remap(scope->maximum);
            }
            presentedPosition[h] = remap(presentedPosition[h].load());
            tailCursor[h] = remap(tailCursor[h]);
            if (latencyPlan) latencyPlan->timeline[h].remap(remap);
        }
        duration = after.duration;
        metronome.sections.swap(clickTiming);
        for (auto &bus : buses) if (bus->click) {
            const auto found = clickSections.find(bus->id);
            if (found != clickSections.end()) bus->click->sections.swap(found->second);
        }
        if (mtc) std::swap(timecodeProgram, *mtc);
    }
    if (mtc) timecodeMIDI.updateProgram(timecodeProgram, after.duration, mtcMuted);
}
void AudioEngine::closeDevice() {
    systemDefaults.stop();
    cancelTransportPreparation();
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
std::unique_ptr<AudioEngine::LatencyPlan> AudioEngine::makeLatencyPlan(const ID *replacement,const NativeFX *prepared,
                                                                    std::optional<bool> midiTakeActive,bool admitReady,
                                                                    bool releaseRemoved,const std::vector<Voice *> *itemVoices,
                                                                    const std::vector<TrackRoute> *routes,const std::vector<int> *routingOrder)const {
    const auto &order = routingOrder ? *routingOrder : busOrder;
    std::vector<Voice *> active;
    if (!itemVoices) { active.reserve(voices.size()); for (const auto &voice : voices) active.push_back(voice.get()); itemVoices = &active; }
    auto result=std::make_unique<LatencyPlan>();result->buses.resize(buses.size());
    auto latency=[&](const ID &id,const NativeFX &fx){
        const auto &chain=replacement&&*replacement==id?*prepared:fx;
        return admitReady?chain.readyLatencyFrames(releaseRemoved):chain.latencyFrames();
    };
    auto voiceLatency=[&](const Voice &voice) {
        const bool owns=replacement&&*replacement==voice.clipID&&midiTakeActive
                            ? *midiTakeActive : voice.ownsMIDI();
        return voice.midiItem&&!owns ? 0u : latency(voice.clipID,voice.fx[0]);
    };
    for(const auto *voice:*itemVoices)if(!voice->frozen)result->buses[voice->bus].own=std::max(result->buses[voice->bus].own,voiceLatency(*voice));
    for(size_t i=0;i<buses.size();i++)result->buses[i].input=result->buses[i].own;
    for(int index:order) {
        const auto &bus=*buses[size_t(index)];auto &channel=result->buses[size_t(index)];
        channel.output=channel.input+latency(bus.id,bus.fx[0]);
        std::set<int> destinations(bus.sends.begin(),bus.sends.end());
        const auto parent=routes?(*routes)[size_t(index)].parent:bus.parent;
        for(const auto &patch:routes?(*routes)[size_t(index)].outputs:bus.outputs) {
            if(patch.firstChannel==-2&&parent>=0)destinations.insert(parent);
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
    for(auto it=order.rbegin();it!=order.rend();++it) {
        const auto &bus=*buses[size_t(*it)];auto &channel=result->buses[size_t(*it)];
        unsigned shift=std::numeric_limits<unsigned>::max();
        auto destination=[&](unsigned target){shift=std::min(shift,target>=channel.output?target-channel.output:0);};
        for(const auto &route:channel.routes)destination(result->buses[size_t(route.target)].input);
        for(const auto &patch:routes?(*routes)[size_t(*it)].outputs:bus.outputs){if(patch.firstChannel==0)destination(result->masterInput);else if(patch.firstChannel>0)destination(result->total);}
        if(shift!=std::numeric_limits<unsigned>::max()){channel.input+=shift;channel.output+=shift;}
    }
    const auto masterOutput=result->masterInput+masterLatency;
    // Maximum graph delay is bounded before allocation, never in the callback.
    if(result->total>unsigned(rate.load()*30))throw std::runtime_error("A latência total da cadeia de efeitos excede 30 segundos.");
    if(latencyPlan&&latencyPlan->buses.size()==result->buses.size()&&latencyPlan->total==result->total&&latencyPlan->masterInput==result->masterInput&&latencyPlan->masterHardware.latency()==result->total-masterOutput) {
        bool equal=true;for(size_t i=0;i<buses.size();i++) {
            const auto &a=latencyPlan->buses[i],&b=result->buses[i];
            equal&=a.own==b.own&&a.input==b.input&&a.output==b.output;
            equal&=a.routes.size()==b.routes.size();
            for(size_t j=0;j<std::min(a.routes.size(),b.routes.size());++j)equal&=a.routes[j].target==b.routes[j].target;
        }
        for(const auto *voice:*itemVoices)if(!voice->frozen) {
            auto found=latencyPlan->clips.find(voice->clipID);
            equal&=found!=latencyPlan->clips.end()&&found->second[0].latency()==result->buses[voice->bus].own-voiceLatency(*voice);
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
    for(const auto *voice:*itemVoices)if(!voice->frozen) {
        const auto own=voiceLatency(*voice);
        const auto delay=result->buses[voice->bus].own-own;
        result->clips.emplace(voice->clipID,std::array<native::StereoDelay,2>{native::StereoDelay(delay),native::StereoDelay(delay)});
        result->clipBypass.emplace(voice->clipID,std::array<native::StereoDelay,2>{native::StereoDelay(own),native::StereoDelay(own)});
    }
    return result;
}
uint64 AudioEngine::stemFingerprint(bool admitReady,bool releaseRemoved)const {
    auto latency=[&](const NativeFX &fx){return admitReady?fx.readyLatencyFrames(releaseRemoved):fx.latencyFrames();};
    uint64 value=latency(masterFX)+1;
    for(const auto &bus:buses)for(const auto &fx:bus->fx)value=(value^latency(fx))*1099511628211ull;
    for(const auto &voice:voices)for(const auto &fx:voice->fx)value=(value^latency(fx))*1099511628211ull;
    return value;
}
void AudioEngine::activateStemLatency(bool releaseRemoved){
    if(releaseRemoved)masterFX.releaseRemovedStems();masterFX.activateStemLatency();
    for(auto &bus:buses){if(releaseRemoved)for(auto &fx:bus->fx)fx.releaseRemovedStems();bus->fx[0].activateStemLatency();bus->fx[1].activateStemLatency(bus->fx[0].latencyFrames()>0);}
    for(auto &voice:voices){if(releaseRemoved)for(auto &fx:voice->fx)fx.releaseRemovedStems();voice->fx[0].activateStemLatency();voice->fx[1].activateStemLatency(voice->fx[0].latencyFrames()>0);}
    stemLatencyFingerprint=stemFingerprint();
}
void AudioEngine::refreshStemLatency(){
    if(offlineMode)return;
    const bool running=playing.load()||subPlaying.load()||presentationTailing.load();
    // Removed effects keep their dry delay until Stop so live removal never
    // discards already queued audio. New ready effects can join during Play.
    const bool releaseRemoved=!running;
    bool pending=masterFX.pendingStemChange();
    for(auto &bus:buses)for(auto &fx:bus->fx)pending|=fx.pendingStemChange();
    for(auto &voice:voices)for(auto &fx:voice->fx)pending|=fx.pendingStemChange();
    if(!pending&&stemFingerprint()==stemLatencyFingerprint)return;
    const auto expected=stemFingerprint(true,releaseRemoved);
    if(running&&expected==stemFingerprint())return;
    // Hold the exact pending processors in the plan, including their lifetime.
    // Worker readiness is independent of the device lock and can disappear on
    // failure. The commit must not reread readiness or admit a newly ready FX
    // that was absent when its compensation buffers were allocated.
    std::vector<std::shared_ptr<native::stem::Processor>> admissions;
    masterFX.collectReadyStemActivations(admissions);
    for(const auto &bus:buses)for(const auto &fx:bus->fx)fx.collectReadyStemActivations(admissions);
    for(const auto &voice:voices)for(const auto &fx:voice->fx)fx.collectReadyStemActivations(admissions);
    // Plan allocation never touches the admitted DSP or callback history.
    auto prepared=makeLatencyPlan(nullptr,nullptr,{},true,releaseRemoved);
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        // Model readiness/transport may have changed while buffers allocated.
        // Retry on the next control tick; never publish a mismatched plan.
        if(expected!=stemFingerprint(true,releaseRemoved)||
           running!=(playing.load()||subPlaying.load()||presentationTailing.load()))return;
        if(releaseRemoved) {
            masterFX.releaseRemovedStems();
            for(auto &bus:buses)for(auto &fx:bus->fx)fx.releaseRemovedStems();
            for(auto &voice:voices)for(auto &fx:voice->fx)fx.releaseRemovedStems();
        }
        for(const auto &processor:admissions)processor->activate(true);
        stemLatencyFingerprint=stemFingerprint();
        if(prepared)installLatencyPlan(prepared,running);
    }
}
native::stem::Status AudioEngine::stemStatus(const ID &id,const String &key)const {if(auto *fx=effects(id))return fx->stemStatus(key);return {};}
std::array<std::shared_ptr<analysis::Capture>, 2> AudioEngine::eqAnalysis(const ID &id, const String &key) const {
    std::array<std::shared_ptr<analysis::Capture>, 2> result;
    // Only retain the ring owners under the callback lock. PCM snapshots and
    // FFT work run after this short scope, entirely outside the audio thread.
    const ScopedLock lock(devices.getAudioCallbackLock());
    for (int head = 0; head < (id.empty() ? 1 : 2); ++head)
        if (auto *chain = effects(id, head)) result[std::size_t(head)] = chain->eqAnalysis(key);
    return result;
}
void AudioEngine::previewDynamics(const ID &id, const String &key, const var &settings) {
    const auto snapshot = NativeFX::dynamicsPreview(settings);
    if (trackCapture) trackCapture->previewDynamics(id, key, snapshot);
    const ScopedLock lock(devices.getAudioCallbackLock());
    for (int head = 0; head < (id.empty() ? 1 : 2); ++head) if (auto *fx = effects(id, head)) fx->previewDynamics(key, snapshot);
    for (auto &output : recordingOutputs) if (output.track == id && output.fx) output.fx->previewDynamics(key, snapshot);
}
void AudioEngine::previewNativeParameters(const ID &id, const String &key, const String &kind, const var &settings, const var &chainSettings) {
    if (kind == "Instruments") {
        // SF2 controls are atomic in SoundFontRenderer. Configuration clones
        // its document values here on the UI thread, never under the device lock.
        for (auto &bus : buses) if (bus->id == id && bus->midi) bus->midi->configure(chainSettings);
        return;
    }
    const auto snapshot=NativeFX::parameterPreview(kind,settings,rate.load());
    if (snapshot.kind==NativeFX::ParameterPreview::none) return;
    if (trackCapture) trackCapture->previewNativeParameters(id,key,snapshot);
    const ScopedLock lock(devices.getAudioCallbackLock());
    for (int head=0;head<(id.empty()?1:2);++head) if (auto *fx=effects(id,head)) fx->previewParameters(key,snapshot);
    for (auto &output : recordingOutputs) if (output.track == id && output.fx) output.fx->previewParameters(key,snapshot);
}
void AudioEngine::previewStemMix(const ID &id,const String &key,const native::stem::Mix &mix){
    for(int h=0;h<(id.empty()?1:2);h++)if(auto *fx=effects(id,h))fx->previewStemMix(key,mix);
    for(auto &output:recordingOutputs)if(output.track==id && output.fx)output.fx->previewStemMix(key,mix);
}
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
    prepared[0].prepare(saved, sampleRate, effects(id),offlineMode,true,{},instrumentDirectory);
    if (!id.empty())
        prepared[1].prepare(saved, sampleRate, effects(id,1),offlineMode,false,{},instrumentDirectory);
    if (trackCapture) trackCapture->updateEffects(id, saved);
    std::unique_ptr<NativeFX> captureEffects;
    RecordingOutput *captureTarget = nullptr;
    for (auto &output : recordingOutputs) if (output.track == id && output.fx) {
        captureTarget = &output;
        captureEffects = std::make_unique<NativeFX>();
        captureEffects->prepare(saved, sampleRate, output.fx.get(), offlineMode, true, {}, instrumentDirectory);
        break;
    }
    const bool running=playing.load()||subPlaying.load()||presentationTailing.load();
    for(int h=0;h<(id.empty()?1:2);h++){
        if(running){if(auto *old=effects(id,h))prepared[h].holdRemovedStems(*old);}
        else prepared[h].activateStemLatency(h>0&&prepared[0].latencyFrames()>0);
    }
    if(!id.empty())prepared[1].shareStems(prepared[0]);
    std::optional<bool> midiTakeActive;
    for (const auto &voice : voices) if (voice->clipID == id && voice->midiItem)
        midiTakeActive = hasTakeInstrument(saved, voice->fxBypassed);
    auto preparedLatency=makeLatencyPlan(&id,&prepared[0],midiTakeActive);
    // Item edits replace only the processors; readers and playback heads stay alive.
    for (auto &voice : voices)
        if (voice->clipID == id) {
            auto shared = voice->midiItem && voice->ownsMIDI()!=*midiTakeActive
                              ? std::make_unique<SharedMIDIUpdate>(sharedMIDISequence(voice->bus, voice.get(), *midiTakeActive))
                              : nullptr;
            const bool instrument=hasTakeInstrument(saved);
            const ScopedLock lock(devices.getAudioCallbackLock());
            if (voice->midiItem) {
                // Release held notes through the old processors before swapping.
                for (int head = 0; head < 2; ++head)
                    mixMIDIVoice(*voice, head, 0, nullptr, 0, 0, 1, false);
                voice->midiInstrument = instrument;
                if (shared) replaceSharedMIDI(voice->bus, *shared);
            }
            prepared[0].adoptDynamicsState(voice->fx[0]); prepared[1].adoptDynamicsState(voice->fx[1]);
            voice->fx[0].swap(prepared[0]);
            voice->fx[1].swap(prepared[1]);
            std::swap(voice->fxSettings, saved);
            if(preparedLatency)installLatencyPlan(preparedLatency,running);
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
        if(preparedLatency)installLatencyPlan(preparedLatency,running);
        if (captureTarget) {
            captureEffects->adoptDynamicsState(*captureTarget->fx);
            captureTarget->fx.swap(captureEffects);
        }
        if (id.empty()) {
            prepared[0].adoptDynamicsState(masterFX);
            masterFX.swap(prepared[0]);
            std::swap(masterFXSettings, saved);
            if (changeMIDI)
                masterMIDI.swap(midi);
        } else
            for (auto &bus : buses)
                if (bus->id == id) {
                    prepared[0].adoptDynamicsState(bus->fx[0]); prepared[1].adoptDynamicsState(bus->fx[1]);
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
    cancelTransportPreparation();
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
        if (voice->source)
            previousSources.emplace(utf8(voice->source->file.getFullPathName()), voice->source);
        if (voice->clipAudio)
            previousProcessors.emplace(voice->clipID, std::move(voice->clipAudio));
    }
    voices.clear();
    removedItemVoices.clear();
    latencyPlan.reset();
    preparedItemIDs.clear();
    for (const auto &track : song.tracks) for (const auto &clip : track.clips) preparedItemIDs.insert(clip.id);
    instrumentDirectory = directory;
    masterMIDI.reset();
    std::map<ID,float> heldPeaks;
    const auto nextPeakProject=project?project->id:song.id;
    if(peakProject==nextPeakProject){for(const auto &bus:buses)heldPeaks[bus->id]=bus->held.amplitude();}
    else masterPeakHold.clear();
    peakProject=nextPeakProject;
    const auto oldPadBus = std::find_if(buses.begin(), buses.end(), [](const auto &bus) { return bus->vinhetasBus; });
    const auto newPadTrack = std::find_if(song.tracks.begin(), song.tracks.end(), [](const auto &track) { return track.role.id == "vinhetas"; });
    if (oldPadBus == buses.end() || newPadTrack == song.tracks.end() || (*oldPadBus)->id != newPadTrack->id) {
        vinhetas.setOutputAvailable(false); vinhetas.discard();
    }
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
    appliedTransportSerial=transportSerial;
    masterOutputs = project && project->masterOutputs
                        ? *project->masterOutputs
                        : std::vector<jaras::OutputPatch>{project && project->masterPatch
                                                              ? *project->masterPatch
                                                              : jaras::OutputPatch{1, 2}};
    if (project && !project->masterOutputs && project->masterSecondaryPatch)
        masterOutputs.push_back(*project->masterSecondaryPatch);
    try {
        jaras::validateRouting(song);
        masterAutomation.prepare(project && project->masterAutomationJSON ? JSON::parse(text(*project->masterAutomationJSON)) : var());
        masterFXSettings = masterSettings;
        masterFX.prepare(masterSettings, rate.load(),nullptr,offlineMode,true,pluginDispatcher,directory);
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
            bus->subplayExclusive=project && project->regionSetlist && project->regionSetlist->subplayExclusiveTrackIDs && std::find(project->regionSetlist->subplayExclusiveTrackIDs->begin(),project->regionSetlist->subplayExclusiveTrackIDs->end(),track.id)!=project->regionSetlist->subplayExclusiveTrackIDs->end();
            bus->held.record(heldPeaks[track.id]);
            bus->timecode = track.role.id == "timecode";
            bus->vinhetasBus = track.role.id == "vinhetas";
            if (bus->timecode) {
                timecodeProgram = jaras::TimecodeProgram(song, track);
                timecodeMIDI.prepare(timecodeProgram, song.duration, track.mute);
            }
            bus->volume = (float)track.volume;
            bus->pan = (float)track.pan;
            bus->mute = track.mute;
            bus->solo = track.solo;
            bus->phase = track.phaseInverted.value_or(false);
            bus->inputFirst = !bus->vinhetasBus && track.inputPatch ? track.inputPatch->firstChannel : 0;
            bus->inputChannels = track.inputPatch ? track.inputPatch->channelCount : 2;
            bus->inputMonitoring = track.inputMonitoring.value_or(true);
            bus->outputs = track.outputPatches();
            bus->settings = track.fxJSON ? JSON::parse(text(*track.fxJSON)) : var();
            bus->midiNotes = playbackNotes(track, &song, false, true);
            bus->externalEvents = MIDIPlayback::sequence(bus->midiNotes).events;
            for(auto &messages:bus->externalMIDI)messages.ensureSize(131072);
            bus->midiSlot = bus->vinhetasBus ? 0 : track.midiInput.value_or(0);
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
                bus->fx[h].prepare(bus->settings,rate.load(),nullptr,offlineMode,h==0,pluginDispatcher,directory);
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
        vinhetas.setOutputAvailable(std::any_of(buses.begin(), buses.end(), [](const auto &bus) { return bus->vinhetasBus; }));
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
                const bool midiItem = clip.midi && !clip.frozenMIDI.value_or(false);
                if ((!sourceFile && !midiItem) || clip.duration <= 0)
                    continue;
                auto voice = std::make_unique<Voice>();
                voice->midiItem = midiItem;
                voice->fxSettings = clip.fxJSON ? JSON::parse(text(*clip.fxJSON)) : var();
                voice->midiInstrument = hasTakeInstrument(voice->fxSettings);
                if (midiItem) {
                    voice->midiSequence = MIDIPlayback::sequence(takePlaybackNotes(track, clip, song, true));
                    voice->sharedMIDINotes = takePlaybackNotes(track, clip, song, false);
                    voice->midiTiming = std::make_unique<ClipTempo>(clip, &song);
                    for (auto &messages : voice->midiMessages) messages.ensureSize(131072);
                }
                voice->frozen = clip.frozenMIDI.value_or(false);
                if (voices.size() >= 20000)
                    throw std::runtime_error("Too many audio items in one timeline.");
                if (!midiItem) {
                    const auto file = ProjectCodec::resolveMedia(directory, sourceFile->path);
                    if(file.hasFileExtension("png;jpg;jpeg;bmp;gif;tif;tiff"))continue;
                    if(projectionMedia(clip))try{if(!inspectMediaSource(file).audio)continue;}catch(...){}
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
                            for (int h = 0; h < 2; ++h) {
                                voice->source->readers[h] = std::make_unique<StreamingReader>(
                                    file, metadata, readerContext->streams);
                                voice->source->readers[h]->setOffline(offlineRendering, offlineMode);
                            }
                        }
                    }
                    sources[sourceKey] = voice->source;
                }
                for (int h = 0; h < 2; ++h) {
                    voice->processed[h].setSize(2, 4096);
                    voice->fx[h].prepare(voice->fxSettings,rate.load(),nullptr,offlineMode,h==0,pluginDispatcher,directory);
                    for (auto value : voice->fx[h].unsupported)
                        unsupported.addIfNotAlreadyThere(text(clip.name) + ": " + value);
                }
                voice->track = track.id;
                voice->clipID = clip.id;
                voice->start = clip.startTime;
                voice->playbackStart = jaras::playbackItemStart(song, clip); voice->regionOwnerIndex=jaras::playbackOwnerIndex(song,clip.regionOwnerID);
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
                if (!midiItem && ClipAudio::needed(song, track, clip)) {
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
void AudioEngine::adoptPreparedSong(AudioEngine &prepared, bool preservePlayback) {
    cancelTransportPreparation();
    const auto started=Time::getMillisecondCounterHiRes();
    if(&prepared==this||prepared.attached||prepared.recording.load())
        throw std::runtime_error("Invalid prepared audio graph.");
    prepared.applyUpdates();
    auto mtc=prepared.timecodeProgram;
    bool timecodeMuted=false;
    for(const auto &bus:prepared.buses)if(bus->timecode)timecodeMuted=bus->mute;
    struct VoiceMigration { Voice *old, *next; bool effects, processor, midiClock; };
    struct BusMigration {
        Bus *old, *next; bool effects, sameNotes;
        MIDIPlayback::Sequence sequence;
    };
    std::vector<VoiceMigration> voiceMigrations;
    std::vector<BusMigration> busMigrations;
    std::vector<std::pair<native::StereoDelay *, native::StereoDelay *>> delays;
    auto equalNotes=[](const auto &a,const auto &b) {
        return a.size()==b.size() && std::equal(a.begin(),a.end(),b.begin(),[](const auto &x,const auto &y) {
            return x.start==y.start && x.end==y.end && x.pitch==y.pitch && x.velocity==y.velocity &&
                   x.channel==y.channel && x.playbackStart==y.playbackStart && x.regionOwnerIndex==y.regionOwnerIndex;
        });
    };
    const bool sameMaster=preservePlayback && JSON::toString(masterFXSettings)==JSON::toString(prepared.masterFXSettings);
    const bool sameLatency=preservePlayback && latencyPlan && prepared.latencyPlan &&
                           latencyPlan->total==prepared.latencyPlan->total;
    auto retainDelay=[&](native::StereoDelay &old,native::StereoDelay &next) {
        if(old.latency()==next.latency())delays.emplace_back(&old,&next);
    };
    // All matching/allocation happens on the control thread. Callback state is
    // transferred later with pointer/buffer swaps under one short lock.
    if(preservePlayback) {
        std::map<ID,size_t> oldBuses;std::map<ID,Voice *> oldVoices;
        for(size_t i=0;i<buses.size();++i)oldBuses.emplace(buses[i]->id,i);
        for(const auto &voice:voices)oldVoices.emplace(voice->clipID,voice.get());
        for(size_t i=0;i<prepared.buses.size();++i) {
            const auto found=oldBuses.find(prepared.buses[i]->id);if(found==oldBuses.end())continue;
            auto *old=buses[found->second].get(),*next=prepared.buses[i].get();
            const bool sameFX=JSON::toString(old->settings)==JSON::toString(next->settings);
            const bool sameNotes=equalNotes(old->midiNotes,next->midiNotes);
            busMigrations.push_back({old,next,sameFX,sameNotes,
                sameFX&&!sameNotes?MIDIPlayback::sequence(next->midiNotes):MIDIPlayback::Sequence{}});
            if(sameLatency) {
                auto &a=latencyPlan->buses[found->second],&b=prepared.latencyPlan->buses[i];
                for(int h=0;h<2;++h) {
                    retainDelay(a.direct[h],b.direct[h]);retainDelay(a.inputDelay[h],b.inputDelay[h]);
                    retainDelay(a.master[h],b.master[h]);retainDelay(a.hardware[h],b.hardware[h]);
                    retainDelay(a.frozen[h],b.frozen[h]);
                    for(auto &route:b.routes)for(auto &oldRoute:a.routes)
                        if(buses[size_t(oldRoute.target)]->id==prepared.buses[size_t(route.target)]->id)
                            retainDelay(oldRoute.delay[h],route.delay[h]);
                }
            }
        }
        for(const auto &next:prepared.voices) {
            const auto found=oldVoices.find(next->clipID);if(found==oldVoices.end())continue;
            auto *old=found->second;
            if(old->source && next->source && old->source->file==next->source->file &&
                old->source->fileSize==next->source->fileSize && old->source->modified==next->source->modified) {
                prepared.retiredSources.push_back(next->source);
                next->source=old->source; // Keep already primed independent main/Subplay readers.
            }
            const bool sameFX=JSON::toString(old->fxSettings)==JSON::toString(next->fxSettings);
            const bool processor=old->clipAudio && next->clipAudio && old->clipAudio->sameMapping(*next->clipAudio);
            const bool midiClock=old->midiItem && next->midiItem && old->start==next->start &&
                old->duration==next->duration && old->offset==next->offset && old->speed==next->speed &&
                equalNotes(old->midiSequence.notes,next->midiSequence.notes);
            voiceMigrations.push_back({old,next.get(),sameFX,processor,midiClock});
            if(sameLatency) {
                for(auto maps:{std::pair{&latencyPlan->clips,&prepared.latencyPlan->clips},
                               std::pair{&latencyPlan->clipBypass,&prepared.latencyPlan->clipBypass}}) {
                    auto a=maps.first->find(next->clipID),b=maps.second->find(next->clipID);
                    if(a!=maps.first->end()&&b!=maps.second->end())
                        for(int h=0;h<2;++h)retainDelay(a->second[size_t(h)],b->second[size_t(h)]);
                }
            }
        }
        if(sameLatency) {
            retainDelay(latencyPlan->masterLive,prepared.latencyPlan->masterLive);
            retainDelay(latencyPlan->masterHardware,prepared.latencyPlan->masterHardware);
            retainDelay(latencyPlan->metronome,prepared.latencyPlan->metronome);
        }
    }
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        if(rate.load()!=prepared.rate.load()||offlineMode!=prepared.offlineMode)
            throw std::runtime_error("A configuração de áudio mudou durante a abertura. Abra o projeto novamente.");
        if(recording.load())throw std::runtime_error("Conclua a gravação antes de trocar o projeto.");
        applyUpdates();
        if(preservePlayback) {
            for(auto &pair:delays)std::swap(*pair.first,*pair.second);
            if(sameLatency)for(int h=0;h<2;++h)std::swap(latencyPlan->timeline[h],prepared.latencyPlan->timeline[h]);
            if(sameMaster){masterFX.swap(prepared.masterFX);masterMIDI.swap(prepared.masterMIDI);}
            for(auto &entry:busMigrations) {
                if(entry.effects) {
                    for(int h=0;h<2;++h)entry.old->fx[h].swap(entry.next->fx[h]);
                    entry.old->midi.swap(entry.next->midi);
                    if(!entry.sameNotes && entry.next->midi)entry.next->midi->replaceSequence(entry.sequence,true);
                    if(entry.sameNotes)for(int h=0;h<2;++h) {
                        entry.next->externalExpected[h]=entry.old->externalExpected[h];
                        entry.next->externalScopes[h]=entry.old->externalScopes[h];
                    }
                }
                entry.next->armed.store(entry.old->armed.load());
                entry.next->fadeoutSelected.store(entry.old->fadeoutSelected.load());
                entry.next->keyboardRoute=entry.old->keyboardRoute;
                entry.next->peak.store(entry.old->peak.load());entry.next->held.record(entry.old->held.amplitude());
                for(int h=0;h<2;++h)entry.next->levels[h].store(entry.old->levels[h].load());
            }
            for(auto &entry:voiceMigrations) {
                if(entry.effects)for(int h=0;h<2;++h)entry.old->fx[h].swap(entry.next->fx[h]);
                if(entry.processor)entry.old->clipAudio.swap(entry.next->clipAudio);
                if(entry.effects&&entry.midiClock)for(int h=0;h<2;++h) {
                    entry.next->midiExpected[h]=entry.old->midiExpected[h];entry.next->midiScopes[h]=entry.old->midiScopes[h];
                }
            }
        } else cancelTrackFadeout();
        const auto oldPad = std::find_if(buses.begin(), buses.end(), [](const auto &bus) { return bus->vinhetasBus; });
        const auto newPad = std::find_if(prepared.buses.begin(), prepared.buses.end(), [](const auto &bus) { return bus->vinhetasBus; });
        if (oldPad == buses.end() || newPad == prepared.buses.end() || (*oldPad)->id != (*newPad)->id) {
            vinhetas.setOutputAvailable(false); vinhetas.discard();
        }
        voices.swap(prepared.voices);removedItemVoices.swap(prepared.removedItemVoices);preparedItemIDs.swap(prepared.preparedItemIDs);buses.swap(prepared.buses);busOrder.swap(prepared.busOrder);
        vinhetas.setOutputAvailable(std::any_of(buses.begin(), buses.end(), [](const auto &bus) { return bus->vinhetasBus; }));
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
        fifo.reset();
        appliedTransportSerial=transportSerial;
        if(preservePlayback) {
            // The graph changes at this sample boundary; both source clocks,
            // elapsed sample accounting and unchanged DSP histories continue.
            if(!sameLatency)publishLatency();
        } else {
            readerHeads[0]=0;readerHeads[1]=1;publishedPromotion=0;
            current={};position=0;subPosition=0;playing=false;subPlaying=false;elapsedSamples=0;
            meter=0;masterPeakHold.clear();masterFXInput=0;masterFXOutput=0;
            presentationTailing=false;presentationDelay=latencyPlan?latencyPlan->total:0;
            for(int h=0;h<2;++h) {
                masterLevels[h]=0;presentedPosition[h]=0;presentedPlaying[h]=false;
                tailFrames[h]=0;tailCursor[h]=0;
            }
            lastPrimedSources=0;lastPrimeWaitMilliseconds=0;renderClock=0;
            timecodeMIDI.publishAudioClock(0,false,false,0);
        }
    }
    if(preservePlayback)timecodeMIDI.updateProgram(std::move(mtc),duration,timecodeMuted);
    else timecodeMIDI.prepare(std::move(mtc),duration,timecodeMuted);
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
void AudioEngine::cancelTransportPreparation(bool all) {
    stopTimer();
    if(transportPreparation) {
        transportPreparation->cancelled=true;
        for(const auto &read:transportPreparation->reads)if(read.loop)read.reader().clearLoopReserve();
    }
    transportPreparation.reset();
    if(all && queuedPreparation){queuedPreparation->cancelled=true;queuedPreparation.reset();}
}
bool AudioEngine::preparingTransport() const {
    return transportPreparation && transportPreparation->sendTransport && !transportPreparation->routingOnly;
}
std::vector<AudioEngine::TransportRead> AudioEngine::transportReads(const State &state) {
    std::vector<TransportRead> reads;
    for(int head=0;head<2;++head) {
        if(head==0?!state.playing:!state.subPlaying)continue;
        const double cursor=head==0?state.position:state.subPosition;
        std::map<const Source*,std::vector<const Voice*>> activeSources;
        for(const auto &voice:voices)
            if(voice->source && trackScope(state,head,voice->bus).allows(voice->playbackStart,voice->regionOwnerIndex) &&
               voice->start<=cursor && voice->start+voice->duration>cursor)
                activeSources[voice->source.get()].push_back(voice.get());
        for(const auto &voice:voices) {
            if(!voice->source || !trackScope(state,head,voice->bus).allows(voice->playbackStart,voice->regionOwnerIndex))continue;
            const auto add=[&](double at,bool loop) {
                if(voice->start>at+(loop?0:2) || voice->start+voice->duration<=at)return;
                // Continuous cut halves share the same physical source clock.
                // Their forward read-ahead is already covered by the active half;
                // reserving the future half would replace PCM needed at Play.
                // Different trims/offsets and processed mappings still prefetch.
                if(!loop && voice->start>at && !voice->clipAudio) {
                    const auto active=activeSources.find(voice->source.get());
                    if(active!=activeSources.end() && std::any_of(active->second.begin(),active->second.end(),[&](const Voice* previous) {
                        return !previous->clipAudio && std::abs(previous->speed-voice->speed)<1e-9 &&
                            std::abs(previous->offset+(voice->start-previous->start)*previous->speed-voice->offset)
                                <.25/voice->source->readers[readerHeads[size_t(head)].load()]->sampleRate;
                    }))return;
                }
                auto &reader=*voice->source->readers[readerHeads[size_t(head)].load()];
                const double local=std::max(0.,at-voice->start);
                auto range=voice->clipAudio?voice->clipAudio->readAheadRange(local,loop?.75:.15)
                    :std::pair<double,double>{voice->offset+local*voice->speed,voice->offset+(local+.15)*voice->speed};
                const auto frames=(int64)std::ceil((range.second-range.first)*reader.sampleRate)+2;
                const auto position=(int64)std::floor(range.first*reader.sampleRate);
                const int count=(int)std::max<int64>(4096,std::min<int64>(131072,frames));
                const auto duplicate=std::find_if(reads.begin(),reads.end(),[&](const auto &r){
                    return r.source==voice->source && r.head==readerHeads[size_t(head)].load() && r.position==position && r.count==count && r.loop==loop;
                });
                if(duplicate==reads.end())reads.push_back({voice->source,readerHeads[size_t(head)].load(),position,count,loop});
            };
            add(cursor,false);
            if(state.loop && state.loopEnd>state.loopStart)add(state.loopStart,true);
        }
    }
    return reads;
}
void AudioEngine::commitPreparedTransport(const State &state,bool routingOnly) {
    Update update;update.kind=routingOnly?Update::routing:Update::transport;update.state=state;
    update.resetElapsed=!routingOnly;
    if(!routingOnly){update.transportSerial=++transportSerial;++transportRepositions;}
    enqueue(update);
    if(routingOnly)timecodeMIDI.updateRouting(state.loop,state.loopStart,state.loopEnd,state.end,state.timecodePreferred);
    else timecodeMIDI.transport(state.position,state.playing,state.loop,state.loopStart,state.loopEnd,
        state.end,state.timecodePreferred,attached&&!exportCapture);
    if(!state.playing&&!state.subPlaying) {
        presentedPosition[0]=state.position;presentedPosition[1]=state.subPosition;
        presentedPlaying[0]=false;presentedPlaying[1]=false;
    }
}
bool AudioEngine::publishPromotion(const State &state) {
    const bool promote=state.promotion!=publishedPromotion && state.playing && !state.subPlaying && subPlaying.load();
    publishedPromotion=state.promotion;
    if(!promote)return false;
    // This is an ownership transfer of an already running head, never a seek.
    // Do not read files or wait for the control thread's sampled position.
    cancelTransportPreparation();
    Update update;update.kind=Update::promotion;update.state=state;
    update.transportSerial=++transportSerial;enqueue(update);
    return true;
}
void AudioEngine::promotePlaybackHeads() {
    const auto first=readerHeads[0].load();readerHeads[0]=readerHeads[1].load();readerHeads[1]=first;
    for(auto &voice:voices) {
        if(voice->clipAudio)voice->clipAudio->swapPlaybackHeads();
        if(!voice->fx[0].hasActiveStem())voice->fx[0].swap(voice->fx[1]);
        std::swap(voice->midiExpected[0],voice->midiExpected[1]);std::swap(voice->midiScopes[0],voice->midiScopes[1]);
    }
    for(auto &bus:buses) {
        if(!bus->fx[0].hasActiveStem())bus->fx[0].swap(bus->fx[1]);
        if(bus->midi)bus->midi->swapPlaybackHeads();
        std::swap(bus->externalExpected[0],bus->externalExpected[1]);std::swap(bus->externalScopes[0],bus->externalScopes[1]);
    }
    if(latencyPlan) {
        for(auto &bus:latencyPlan->buses) {
            std::swap(bus.direct[0],bus.direct[1]);std::swap(bus.inputDelay[0],bus.inputDelay[1]);
            std::swap(bus.master[0],bus.master[1]);std::swap(bus.hardware[0],bus.hardware[1]);std::swap(bus.frozen[0],bus.frozen[1]);
            for(auto &route:bus.routes)std::swap(route.delay[0],route.delay[1]);
        }
        for(auto *map:{&latencyPlan->clips,&latencyPlan->clipBypass})for(auto &entry:*map)std::swap(entry.second[0],entry.second[1]);
        std::swap(latencyPlan->timeline[0],latencyPlan->timeline[1]);
    }
    std::swap(tailFrames[0],tailFrames[1]);std::swap(tailCursor[0],tailCursor[1]);
    std::swap(playbackStartRamp[0],playbackStartRamp[1]);std::swap(playbackStartFrame[0],playbackStartFrame[1]);
    presentedPosition[0]=presentedPosition[1].load();presentedPlaying[0]=presentedPlaying[1].load();
}
void AudioEngine::transportAsync(const State &state) {
    if(publishPromotion(state))return;
    asynchronousTransport=true;
    scheduleTransportPreparation(state,false);
}
void AudioEngine::scheduleTransportPreparation(const State &state,bool routingOnly) {
    routingOnly=routingOnly&&!preparingTransport();
    const bool playing=state.playing||state.subPlaying;
    if(!playing)commitPreparedTransport(state,routingOnly);
    auto warmState=state;
    if(!playing)warmState.playing=true;
    auto reads=transportReads(warmState);
    // Arming a queue must not seek/decode the currently playing readers again.
    // Routing updates need only a loop reserve; queued destinations are warmed
    // separately without disturbing either running head.
    if(routingOnly && playing)
        reads.erase(std::remove_if(reads.begin(),reads.end(),[](const auto &read){return !read.loop;}),reads.end());
    // Keep the selected start warm while stopped; the rest of the timeline
    // still retires normally. Repeated Play can reuse an in-flight prefetch.
    const auto sameReads=[&](const auto &previous) {
        return previous.size()==reads.size() && std::equal(reads.begin(),reads.end(),previous.begin(),[](const auto &a,const auto &b){
            return a.source==b.source && a.head==b.head && a.position==b.position && a.count==b.count && a.loop==b.loop;
        });
    };
    if(transportPreparation && sameReads(transportPreparation->reads)) {
        transportPreparation->state=state;transportPreparation->sendTransport=playing;
        transportPreparation->routingOnly=routingOnly;
        startTimer(20);timerCallback();return;
    }
    cancelTransportPreparation(false);
    auto task=std::make_shared<TransportPreparation>();task->state=state;task->reads=std::move(reads);
    task->sendTransport=playing;task->routingOnly=routingOnly;
    transportPreparation=task;
    bool ready=true;
    for(const auto &read:task->reads) {
        read.reader().keepTransitionWarm(read.loop);
        if(!playing)read.reader().request(read.position);
        ready=read.reader().transitionReady(read.position,read.count,read.loop)&&ready;
    }
    if(ready)task->done=true;
    else runTransportPreparation(task);
    startTimer(20);timerCallback();
}
void AudioEngine::runTransportPreparation(const std::shared_ptr<TransportPreparation> &task) {
    if (task->reads.empty()) { task->done=true; return; }
    // Independent stems may decode in parallel; the callback still receives
    // one transport commit only after every required source is prepared.
    if(!transportWorker)transportWorker=std::make_unique<ThreadPool>(jlimit(1,4,SystemStats::getNumCpus()/2));
    const auto started=Time::getMillisecondCounterHiRes();
    auto remaining=std::make_shared<std::atomic<size_t>>(task->reads.size());
    for(size_t index=0;index<task->reads.size();++index)
        transportWorker->addJob([task,index,remaining,started] {
            try {
                const auto &read=task->reads[index];
                if(!task->cancelled && !read.reader().prepareTransition(read.position,read.count,read.loop) &&
                   !task->destinationOnly) {
                    read.reader().request(read.position);
                    const auto deadline=Time::getMillisecondCounter()+2000;
                    while(!task->cancelled && !read.reader().ready(read.position,read.count) &&
                          (int32)(Time::getMillisecondCounter()-deadline)<0)Thread::sleep(2);
                }
            } catch(...) { /* Missing/unreadable media must not block transport. */ }
            if(remaining->fetch_sub(1)==1) {
                task->milliseconds=Time::getMillisecondCounterHiRes()-started;
                task->done=true;
            }
        });
}
void AudioEngine::prewarmTransportDestination(const std::optional<State> &state) {
    auto reads=state?transportReads(*state):std::vector<TransportRead>{};
    if(queuedPreparation && reads.size()==queuedPreparation->reads.size() &&
       std::equal(reads.begin(),reads.end(),queuedPreparation->reads.begin(),[](const auto &a,const auto &b){
           return a.source==b.source && a.head==b.head && a.position==b.position && a.count==b.count && a.loop==b.loop;
       }))return;
    if(queuedPreparation)queuedPreparation->cancelled=true;
    queuedPreparation.reset();
    if(reads.empty())return;
    auto task=std::make_shared<TransportPreparation>();task->state=*state;
    task->reads=std::move(reads);task->destinationOnly=true;queuedPreparation=task;
    for(const auto &read:task->reads)read.reader().keepTransitionWarm(read.loop);
    runTransportPreparation(task);startTimer(20);
}
void AudioEngine::timerCallback() {
    if(queuedPreparation)for(const auto &read:queuedPreparation->reads)read.reader().keepTransitionWarm(read.loop);
    const auto task=transportPreparation;
    if(!task || task->cancelled){if(!queuedPreparation)stopTimer();return;}
    // No disk reads or locks on this path. Retain only the selected destination
    // when stopped; a playing reader chooses its own forward read position.
    if(!task->state.playing&&!task->state.subPlaying)
        for(const auto &read:task->reads)read.reader().request(read.position);
    if(task->sendTransport)for(const auto &read:task->reads)read.reader().keepTransitionWarm(read.loop);
    if(!task->done)return;
    lastPrimedSources=(int)task->reads.size();lastPrimeWaitMilliseconds=task->milliseconds;
    if(task->sendTransport) {
        commitPreparedTransport(task->state,task->routingOnly);
        task->sendTransport=false;
    }
    if(!queuedPreparation && (task->state.playing||task->state.subPlaying))stopTimer();
}
void AudioEngine::transport(const State &state) {
    if(publishPromotion(state))return;
    ++transportRepositions;
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
        if (offlineRendering) break; // Offline readers decode synchronously on demand.
        if (head == 0 ? !state.playing : !state.subPlaying) continue;
        const auto cursor = head == 0 ? state.position : state.subPosition;
        for (auto& voice : voices) {
            if (!voice->source || !trackScope(state,head,voice->bus).allows(voice->playbackStart,voice->regionOwnerIndex) || voice->start > cursor + 2 ||
                voice->start + voice->duration <= cursor) continue;
            auto* reader = voice->source->readers[readerHeads[size_t(head)].load()].get();
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
            if (voice->start <= cursor && !reader->prepareTransition(position, count))
                pending.push_back({reader, position, count});
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
    primeLoop(state);
    Update u;
    u.kind = Update::transport;
    u.state = state;
    enqueue(u);
    timecodeMIDI.transport(state.position, state.playing, state.loop, state.loopStart,
        state.loopEnd, state.end, state.timecodePreferred, attached && !exportCapture);
}
void AudioEngine::updateTransportRouting(const State &state) {
    if(publishPromotion(state))return;
    if(asynchronousTransport){scheduleTransportPreparation(state,true);return;}
    primeLoop(state);
    Update update; update.kind = Update::routing; update.state = state;
    enqueue(update);
    timecodeMIDI.updateRouting(state.loop, state.loopStart, state.loopEnd, state.end, state.timecodePreferred);
}
void AudioEngine::primeLoop(const State &state) {
    if (!state.loop || state.loopEnd <= state.loopStart || (!state.playing && !state.subPlaying)) {
        for (auto &voice : voices) if (voice->source)
            for (auto &reader : voice->source->readers) if (reader) reader->clearLoopReserve();
        return;
    }
    for (auto &voice : voices) {
        if (!voice->source) continue;
        if (voice->start > state.loopStart || voice->start + voice->duration <= state.loopStart) {
            for (auto &reader : voice->source->readers) if (reader) reader->clearLoopReserve();
            continue;
        }
        const double local = state.loopStart - voice->start;
        for (auto &reader : voice->source->readers) if (reader) {
            const auto range = voice->clipAudio ? voice->clipAudio->readAheadRange(local, .75)
                : std::pair<double,double>{voice->offset + local * voice->speed, voice->offset + (local + .75) * voice->speed};
            const auto first = int64(std::floor(range.first * reader->sampleRate));
            const auto frames = int64(std::ceil((range.second - range.first) * reader->sampleRate)) + 2;
            if (frames > 0 && frames <= 131072) reader->prepareTransition(first, int(frames), true);
        }
    }
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
bool AudioEngine::refreshTrackRouting(const jaras::Song &song) {
    if(song.tracks.size()!=buses.size())return false;
    jaras::validateRouting(song);
    std::map<ID,int> indices;
    for(size_t i=0;i<buses.size();++i)indices.emplace(buses[i]->id,(int)i);
    std::vector<TrackRoute> routes(buses.size());
    for(const auto &track:song.tracks) {
        const auto found=indices.find(track.id);if(found==indices.end())return false;
        auto &route=routes[size_t(found->second)];route.outputs=track.outputPatches();
        if(track.parentTrackID){const auto parent=indices.find(*track.parentTrackID);if(parent==indices.end())return false;route.parent=parent->second;}
    }
    // Keep bus indices, readers, instruments and FX instances. Only the
    // parent/output edges and their processing order change on a track drop.
    std::vector<int> order,visits(buses.size(),0);order.reserve(buses.size());
    std::function<void(int)> visit=[&](int i){
        if(visits[size_t(i)]==2)return;
        if(visits[size_t(i)]==1)throw std::runtime_error("Track routing creates an audio feedback loop.");
        visits[size_t(i)]=1;
        for(int target:buses[size_t(i)]->sends)visit(target);
        for(const auto &patch:routes[size_t(i)].outputs)if(patch.firstChannel==-2&&routes[size_t(i)].parent>=0)visit(routes[size_t(i)].parent);
        visits[size_t(i)]=2;order.push_back(i);
    };
    for(const auto &track:song.tracks)visit(indices.at(track.id));
    std::reverse(order.begin(),order.end());
    auto latency=makeLatencyPlan(nullptr,nullptr,{},false,false,nullptr,&routes,&order);
    {
        const ScopedLock lock(devices.getAudioCallbackLock());
        applyUpdates();
        for(size_t i=0;i<buses.size();++i){buses[i]->parent=routes[i].parent;buses[i]->outputs.swap(routes[i].outputs);}
        busOrder.swap(order);installLatencyPlan(latency,true);
    }
    return true;
}
void AudioEngine::setMixer(const jaras::Project &project, const jaras::Song &song) {
    timecodeMIDI.programChanges(song);
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
                u.subplayExclusive=project.regionSetlist && project.regionSetlist->subplayExclusiveTrackIDs && std::find(project.regionSetlist->subplayExclusiveTrackIDs->begin(),project.regionSetlist->subplayExclusiveTrackIDs->end(),t.id)!=project.regionSetlist->subplayExclusiveTrackIDs->end();
                u.midiSlot=t.role.id=="vinhetas"?0:t.midiInput.value_or(0);u.midiChannel=t.midiChannel.value_or(0);
                enqueue(u);
                break;
            }
}
void AudioEngine::installLatencyPlan(std::unique_ptr<LatencyPlan> &next,bool preservePlayback)noexcept {
    if(!next)return;
    const double audible[2]{presentationDelay.load()?presentedPosition[0].load():current.position,
                            presentationDelay.load()?presentedPosition[1].load():current.subPosition};
    const bool sameTotal=latencyPlan&&latencyPlan->total==next->total;
    if(preservePlayback&&latencyPlan) {
        // The graph topology is unchanged here. Preserve every delay whose
        // length stayed the same; swapping vectors is bounded, allocation-free.
        auto retain=[](native::StereoDelay &old,native::StereoDelay &prepared){
            if(old.latency()==prepared.latency())std::swap(old,prepared);
        };
        for(size_t i=0;i<std::min(latencyPlan->buses.size(),next->buses.size());++i) {
            auto &old=latencyPlan->buses[i],&prepared=next->buses[i];
            for(int h=0;h<2;++h) {
                retain(old.direct[h],prepared.direct[h]);retain(old.inputDelay[h],prepared.inputDelay[h]);
                retain(old.master[h],prepared.master[h]);retain(old.hardware[h],prepared.hardware[h]);
                retain(old.frozen[h],prepared.frozen[h]);
                for(auto &route:prepared.routes)for(auto &previous:old.routes)
                    if(route.target==previous.target)retain(previous.delay[h],route.delay[h]);
            }
        }
        for(auto maps:{std::pair{&latencyPlan->clips,&next->clips},std::pair{&latencyPlan->clipBypass,&next->clipBypass}})
            for(auto &entry:*maps.second)if(auto old=maps.first->find(entry.first);old!=maps.first->end())
                for(int h=0;h<2;++h)retain(old->second[size_t(h)],entry.second[size_t(h)]);
        retain(latencyPlan->masterLive,next->masterLive);retain(latencyPlan->masterHardware,next->masterHardware);
        retain(latencyPlan->metronome,next->metronome);
        if(sameTotal)for(int h=0;h<2;++h)std::swap(latencyPlan->timeline[h],next->timeline[h]);
    }
    latencyPlan.swap(next);
    if(!preservePlayback){publishLatency();return;}
    presentationDelay=latencyPlan->total;
    if(!sameTotal)for(int h=0;h<2;++h) {
        // A first live insertion must prime its new lookahead. Hold the audible
        // cursor at that boundary while the source heads keep advancing; never
        // manufacture Stop/Play or flush the separator's generation/history.
        latencyPlan->timeline[h].reset(audible[h]);
        presentedPosition[h]=audible[h];
        presentedPlaying[h]=(h==0?current.playing:current.subPlaying)||tailFrames[h]>0;
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
    offlineRendering=enabled;
    for (auto &voice : voices) if (voice->source)
        for (auto &reader : voice->source->readers)
            reader->setOffline(enabled, offlineMode);
}
double AudioEngine::takeElapsed() { return (double)elapsedSamples.exchange(0) / rate.load(); }
void AudioEngine::applyUpdates() {
    int a, n, b, m;
    fifo.prepareToRead(1024, a, n, b, m);
    auto apply = [this](const Update &u) {
        if (u.kind == Update::promotion) {
            if(current.subPlaying && current.promotion!=u.state.promotion) {
                const auto at=current.subPosition;
                promotePlaybackHeads();current=u.state;current.position=at;
                current.subPlaying=false;tailFrames[1]=0;
            }
            if(u.transportSerial)appliedTransportSerial=u.transportSerial;
        }
        else if (u.kind == Update::transport) {
            if(u.resetElapsed)elapsedSamples=0;
            const bool startingFromStop=!offlineMode&&!offlineRendering&&!current.playing&&!current.subPlaying&&(u.state.playing||u.state.subPlaying);
            bool changed[2]{};
            for(int h=0;h<2;h++) {
                const bool before=h==0?current.playing:current.subPlaying,after=h==0?u.state.playing:u.state.subPlaying;
                const double at=h==0?u.state.position:u.state.subPosition,old=h==0?current.position:current.subPosition;
                changed[h]=!u.state.preserveLatency&&(before!=after||std::abs(at-old)>1.5/rate.load());
                if(changed[h]){resetLatencyHead(h,at);playbackStartRamp[h]=startingFromStop&&after?at:-1;playbackStartFrame[h]=renderClock;}
                else if(u.state.preserveLatency) {
                    if(before&&!after){tailFrames[h]=latencyPlan?latencyPlan->total:0;tailCursor[h]=at;}
                    else if(after)tailFrames[h]=0;
                }
            }
            // The shared separator follows the sum of both heads. Starting or
            // stopping SubPlay must not flush the main head's wet history.
            if((changed[0]&&changed[1])||
               (changed[0]&&!current.subPlaying&&!u.state.subPlaying)||(changed[1]&&!current.playing&&!u.state.playing)) {
                masterFX.resetStems();for(auto &bus:buses)bus->fx[0].resetStems();for(auto &voice:voices)voice->fx[0].resetStems();
                if(latencyPlan){latencyPlan->masterLive.reset();latencyPlan->masterHardware.reset();}
            }
            current = u.state;
            if(u.transportSerial)appliedTransportSerial=u.transportSerial;
        }
        else if (u.kind == Update::routing) {
            // Queue selection moves only an idle secondary cursor. Preserve
            // the running head and decoder history until Sub Play actually starts.
            if (!current.subPlaying && !u.state.subPlaying) current.subPosition=u.state.subPosition;
            current.scope[0]=u.state.scope[0]; current.scope[1]=u.state.scope[1];
            current.exclusiveScope[0]=u.state.exclusiveScope[0];current.exclusiveScope[1]=u.state.exclusiveScope[1];
            current.loop=u.state.loop; current.loopStart=u.state.loopStart; current.loopEnd=u.state.loopEnd;
            current.end=u.state.end; current.timecodePreferred=u.state.timecodePreferred;
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
            if (trackCapture) trackCapture->setGain(buses[(size_t)u.index]->id, u.volume);
            v.pan = u.pan;
            v.mute = u.mute;
            v.solo = u.solo;
            v.subplayExclusive=u.subplayExclusive;v.inputMonitoring=u.inputMonitoring;v.midiSlot=u.midiSlot;v.midiChannel=u.midiChannel;
            v.phase = u.phase;
        }
    };
    for (int i = 0; i < n; ++i)
        apply(updates[(size_t)(a + i)]);
    for (int i = 0; i < m; ++i)
        apply(updates[(size_t)(b + i)]);
    fifo.finishedRead(n + m);
}
void AudioEngine::mixMIDIVoice(Voice &v, int head, double at, float *const *out, int channels,
                              int dest, int count, bool running) {
    const double sr=rate.load(std::memory_order_relaxed);
    const unsigned ownDelay=v.ownsMIDI()?v.fx[head].latencyFrames():0;
    const unsigned busDelay=latencyPlan?latencyPlan->buses[v.bus].own:ownDelay;
    running=running&&v.ownsMIDI()&&!v.itemMuted&&trackScope(current,head,v.bus).allows(v.playbackStart,v.regionOwnerIndex);
    const bool intersects=at+count/sr>v.start&&at<v.start+v.duration+busDelay/sr;
    if (!running || !intersects) {
        if (v.midiExpected[head] == -1) return;
        // Stopping, muting, changing scope or bypassing a take releases only
        // this take's held notes; the track's live MIDI bank stays untouched.
        auto &messages=v.midiMessages[head];messages.clear();
        MIDIPlayback::appendExternal(v.midiSequence,messages,v.midiExpected[head],v.midiScopes[head],
                                     at,count,sr,{},false);
        v.processed[head].clear(0,count);
        v.fx[head].process(v.processed[head],count,at,false,&messages,(renderClock+dest)/sr);
        if(latencyPlan)if(auto delay=latencyPlan->clips.find(v.clipID);delay!=latencyPlan->clips.end())
            delay->second[size_t(head)].reset();
        return;
    }
    auto &buffer=v.processed[head];buffer.clear(0,count);
    auto &messages=v.midiMessages[head];messages.clear();
    const bool timelineRunning=head==0?current.playing:current.subPlaying;
    MIDIPlayback::appendExternal(v.midiSequence,messages,v.midiExpected[head],v.midiScopes[head],
                                 at,count,sr,trackScope(current,head,v.bus),timelineRunning);
    const double automationAt=v.midiTiming->sourceAt(std::max(v.start,at));
    v.fx[head].applyAutomation(v.automation,automationAt);
    v.fx[head].process(buffer,count,at,timelineRunning,&messages,(renderClock+dest)/sr);
    // A generator has no input samples to attenuate. Apply the take fader,
    // source-time automation, pan and fades to its generated audio exactly once.
    for(int n=0;n<count;++n) {
        const double time=at+(n-double(ownDelay))/sr,local=time-v.start;
        if(local<0||local>=v.duration){buffer.setSample(0,n,0);buffer.setSample(1,n,0);continue;}
        const auto values=v.automation.evaluate(v.midiTiming->sourceAt(time),v.clipGain,v.clipPan);
        double gain=values.mute?0:values.gain;
        if(v.fadeIn>0)gain*=v.fadeInShape.value(local/std::min(v.duration,v.fadeIn));
        if(v.fadeOut>0)gain*=v.fadeOutShape.value((v.duration-local)/std::min(v.duration,v.fadeOut));
        float left=buffer.getSample(0,n),right=buffer.getSample(1,n);
        if(v.channelMode==1)right=left;
        else if(v.channelMode==2)left=right;
        else if(v.channelMode==3)left=right=(left+right)*.5f;
        else if(v.channelMode==4)std::swap(left,right);
        buffer.setSample(0,n,left*(float)(gain*(values.pan>0?1-values.pan:1)));
        buffer.setSample(1,n,right*(float)(gain*(values.pan<0?1+values.pan:1)));
    }
    if(latencyPlan)if(auto delay=latencyPlan->clips.find(v.clipID);delay!=latencyPlan->clips.end())
        delay->second[size_t(head)].process(buffer.getWritePointer(0),buffer.getWritePointer(1),
                                            count,int64_t(renderClock)+dest,true);
    for(int ch=0;ch<std::min(2,channels);++ch)if(out[ch])
        FloatVectorOperations::add(out[ch]+dest,buffer.getReadPointer(ch),count);
}
void AudioEngine::mixVoice(Voice &v, int head, double at, float *const *out, int channels, int dest,
                           int count) {
    if (v.midiItem) {mixMIDIVoice(v,head,at,out,channels,dest,count,true);return;}
    if (v.itemMuted) return;
    const double sr = rate.load(std::memory_order_relaxed);
    auto &reader = *v.source->readers[readerHeads[size_t(head)].load()];
    const unsigned busDelay=latencyPlan&&!v.frozen?latencyPlan->buses[v.bus].own:0;
    const bool delayed=busDelay>0;
    if(at+count/sr<=v.start||at>=v.start+v.duration+busDelay/sr)return;
    // Clamp before narrowing: a long item can end more than INT_MAX samples
    // away even though this callback only needs a few hundred samples.
    int begin=(int)jlimit(0.,double(count),std::ceil((v.start-at)*sr-1e-7));
    int end=(int)jlimit(0.,double(count),std::ceil((v.start+v.duration-at)*sr-1e-7));
    if(begin>=end&&!delayed)return;
    AudioCallbackMetrics::Detail readProfile(callbackMetrics,0);
    if(begin<end) {
    const double step = reader.sampleRate / sr * v.speed;
    if (step <= 0 || (!v.clipAudio && step > 32))
        return;
    auto &scratch = readScratch[head];
    if (v.clipAudio) {
        if (!v.clipAudio->render(reader, scratch, v.processed[head], head,
                                 at + begin / sr - v.start, end - begin)) {
            underruns.fetch_add(1);
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
        }
        // A cache miss can leave valid PCM before its zero-filled remainder.
        // Keep those samples and advance the effects with the complete block;
        // dropping the whole voice amplifies a short miss into a full dropout.
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
    readProfile.finish();
    AudioCallbackMetrics::Detail gainProfile(callbackMetrics,1);
    for (int i = begin; i < end; ++i) {
        float a = v.processed[head].getSample(0, i - begin),
              b = v.processed[head].getSample(1, i - begin);
        if (v.channelMode == 1)
            b = a;
        else if (v.channelMode == 2)
            a = b;
        else if (v.channelMode == 3)
            a = b = (a + b) * .5f;
        else if (v.channelMode == 4)
            std::swap(a, b);
        const double local = at + (double)i / sr - v.start;
        const auto values =
            v.automation.evaluate(v.offset + std::max(0., local) * v.speed, v.clipGain, v.clipPan);
        float left = values.mute ? 0 : (float)values.gain, right = left;
        if (values.pan > 0)
            left *= 1 - (float)values.pan;
        else
            right *= 1 + (float)values.pan;
        float fade = 1;
        const double entry=playbackStartRamp[head];
        if(entry>=0 && v.start<=entry+1e-7)
            fade*=float(jlimit(0.,1.,double(renderClock+dest+i-playbackStartFrame[head])/(sr*.003)));
        if (v.fadeIn > 0)
            fade *= (float)v.fadeInShape.value(local / std::min(v.duration, v.fadeIn));
        if (v.fadeOut > 0)
            fade *= (float)v.fadeOutShape.value((v.duration - local) / std::min(v.duration, v.fadeOut));
        v.processed[head].setSample(0, i - begin, a * left * fade);
        v.processed[head].setSample(1, i - begin, b * right * fade);
    }
    }
    readProfile.finish();
    AudioCallbackMetrics::Detail effectProfile(callbackMetrics,2);
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
        if(!v.fxBypassed){v.fx[head].applyAutomation(v.automation,v.offset+std::max(0.,at-v.start)*v.speed);v.fx[head].process(v.processed[head],count,at,true,nullptr,(renderClock+dest)/sr);}
        else if(auto bypass=latencyPlan->clipBypass.find(v.clipID);bypass!=latencyPlan->clipBypass.end())bypass->second[size_t(head)].process(v.processed[head].getWritePointer(0),v.processed[head].getWritePointer(1),count,int64_t(renderClock)+dest,true);
        auto found=latencyPlan->clips.find(v.clipID);
        if(found!=latencyPlan->clips.end())found->second[size_t(head)].process(v.processed[head].getWritePointer(0),v.processed[head].getWritePointer(1),count,int64_t(renderClock)+dest,true);
        for(int ch=0;ch<std::min(2,channels);ch++)if(out[ch])FloatVectorOperations::add(out[ch]+dest,v.processed[head].getReadPointer(ch),count);
    } else {
        if(!v.fxBypassed){v.fx[head].applyAutomation(v.automation,v.offset+std::max(0.,at+begin/sr-v.start)*v.speed);v.fx[head].process(v.processed[head],end-begin,at+begin/sr);}
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
    ScopedNoDenormals noDenormals;
    AudioCallbackMetrics::RenderProfile renderProfile(callbackMetrics);
    for (int ch = 0; ch < channels; ++ch)
        if (out[ch])
            FloatVectorOperations::clear(out[ch], samples);
    applyUpdates();
    const auto fadeout = transportFadeout.block();
    if (fadeout.active)
        for (int frame = 0; frame < samples; ++frame)
            trackFadeoutGains[(size_t)frame] = fadeout.gain((uint32_t)frame);
    const bool captureActive = trackCapture && current.playing;
    if (captureActive)
        trackCapture->input(input, inputChannels, samples, inputMapping);
    liveMidi.clear();
    midiInput.removeNextBlockOfMessages(liveMidi, samples);
    keyboardMidi.clear();
    keyboardState.processNextMidiBuffer(keyboardMidi, 0, samples, true);
    for (int slot = 0; slot < 6; ++slot) {
        slotMessages[slot].clear();
        midiSlots[slot].removeNextBlockOfMessages(slotMessages[slot], samples);
    }
    const bool allowInstrument = instrumentAllowed.load(std::memory_order_relaxed);
    bool routedHardware = false;
    const double sr = rate.load(std::memory_order_relaxed);
    const bool renderingHead[2]{current.playing||tailFrames[0]>0,current.subPlaying||tailFrames[1]>0};
    const bool active = renderingHead[0] || renderingHead[1];
    const auto blockClock=int64_t(renderClock);
    for(auto &voice:voices)if(!voice->midiItem&&voice->fx[0].hasActiveStem())for(auto &buffer:voice->stemInput)buffer.clear(0,samples);
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
    for (size_t i = 0; i < buses.size(); ++i) {
        bool muted = false, solo = false;
        int index = (int)i;
        while (index >= 0) {
            auto &bus = *buses[(size_t)index];
            muted |= bus.mute && !bus.automation.controlsMute();
            solo |= bus.solo;
            index = bus.parent;
        }
        buses[i]->renderAudible = !muted && (!anySolo || solo);
    }
    if(latencyPlan)for(auto &channel:latencyPlan->buses)for(auto &buffer:channel.routed)buffer.clear(0,samples);
    const bool keepPipeline=latencyPlan&&latencyPlan->total>0;
    // Keep every source/voice processing while any track is soloed. The
    // solo gate still clears non-audible buses before routing, but keeping
    // their playback and FX state warm lets all tracks return together when
    // the last solo is released.
    auto sourceAudible=[&](size_t index){return keepPipeline||anySolo||buses[index]->renderAudible;};
    for (auto &bus : buses) bus->renderRouteAudible = bus->renderAudible;
    for (size_t i = 0; i < buses.size(); ++i)
        if (buses[i]->renderAudible) {
            int parent = buses[i]->parent;
            while (parent >= 0) {
                buses[(size_t)parent]->renderRouteAudible = true;
                parent = buses[(size_t)parent]->parent;
            }
        }
    renderProfile.mark();
    for (int head = 0; head < 2; ++head) {
        bool &run = head == 0 ? current.playing : current.subPlaying;
        double &cursor = head == 0 ? current.position : current.subPosition;
        int done = 0;
        std::fill_n(timelinePositions[(size_t)head].begin(), samples, cursor);
        std::fill_n(timelineRunning[size_t(head)].begin(),samples,false);
        if (!run && !tailFrames[head])
            for (auto &voice : voices) if (voice->midiItem)
                mixMIDIVoice(*voice,head,cursor,nullptr,0,0,samples,false);
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
            // The secondary head also runs through silence outside the arrangement.
            double boundary = head == 1 ? std::max(duration, cursor + (samples - done) / sr + 1.0)
                                       : looping ? std::min(duration, current.loopEnd) : duration;
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
            // A long setlist (over 12.4 hours at 48 kHz) can exceed INT_MAX
            // remaining samples. Narrowing that value first produced one-frame
            // chunks and rescanned every item hundreds of times per callback.
            const int count = (int)jlimit(1., double(samples - done),
                                          std::ceil((boundary - cursor) * sr - 1e-7));
            callbackMetrics.renderedSegment();
            for(size_t index=0;index<buses.size();++index) {
                auto &bus=*buses[index];
                if(!bus.fx[head].hasExternal())continue;
                auto &messages=bus.externalMIDI[head];
                const auto scope=trackScope(current,head,index);
                const bool reset=std::abs(bus.externalExpected[head]-cursor)>1.5/sr||bus.externalScopes[head]!=scope;
                if(reset || !sourceAudible(index)) {
                    for(int channel=1;channel<=16;++channel)messages.addEvent(MidiMessage::allNotesOff(channel),done);
                    if(sourceAudible(index))for(const auto &note:bus.midiNotes)
                        if(note.velocity>0&&scope.allows(note.playbackStart,note.regionOwnerIndex)&&note.start<cursor-1e-9&&note.end>cursor+1e-9)
                            messages.addEvent(MidiMessage::noteOn(note.channel,note.pitch,(uint8)note.velocity),done);
                }
                if(!sourceAudible(index)){bus.externalExpected[head]=-1;continue;}
                const double end=cursor+count/sr;
                auto event=std::lower_bound(bus.externalEvents.begin(),bus.externalEvents.end(),cursor-1e-9,
                    [](const MIDIPlayback::Event &event,double value){return event.time<value;});
                for(;event!=bus.externalEvents.end()&&event->time<end-1e-9;++event) {
                    const auto &note=event->note;if(!scope.allows(note.playbackStart,note.regionOwnerIndex))continue;
                    messages.addEvent(event->on?MidiMessage::noteOn(note.channel,note.pitch,(uint8)note.velocity):MidiMessage::noteOff(note.channel,note.pitch),
                        done+jlimit(0,count-1,(int)std::round((event->time-cursor)*sr)));
                }
                bus.externalExpected[head]=end;bus.externalScopes[head]=scope;
            }
            {
            AudioCallbackMetrics::Detail traversalProfile(callbackMetrics,3);
            for (auto &v : voices)
                if (sourceAudible(v->bus) && trackScope(current,head,v->bus).allows(v->playbackStart,v->regionOwnerIndex)) {
                    if (v->source && v->start > cursor && v->start <= cursor + 2)
                        v->source->readers[readerHeads[size_t(head)].load()]->requestUpcoming((int64)std::floor((v->clipAudio ? v->clipAudio->sourcePosition(0) : v->offset) * v->source->readers[readerHeads[size_t(head)].load()]->sampleRate), v->start-cursor, renderClock+done);
                    mixVoice(*v, head, cursor, (v->frozen ? buses[v->bus]->frozen[head] : buses[v->bus]->clips[head]).getArrayOfWritePointers(), 2, done, count);
                } else if (v->midiItem)
                    mixMIDIVoice(*v,head,cursor,nullptr,0,done,count,false);
            }
            AudioCallbackMetrics::Detail generatorProfile(callbackMetrics,4);
            for (size_t index = 0; index < buses.size(); ++index)
                if (sourceAudible(index) && buses[index]->midi)
                    buses[index]->midi->render(head, cursor, buses[index]->head(head), done, count, trackScope(current,head,index));
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
            for(auto &voice:voices)if(sourceAudible(voice->bus)&&trackScope(current,head,voice->bus).allows(voice->playbackStart,voice->regionOwnerIndex))
                mixVoice(*voice,head,tailCursor[head],(voice->frozen?buses[voice->bus]->frozen[head]:buses[voice->bus]->clips[head]).getArrayOfWritePointers(),2,done,count);
            for(int n=done;n<samples;n++)timelinePositions[size_t(head)][size_t(n)]=tailCursor[head]+(n-done)/sr;
            tailCursor[head]+=count/sr;tailFrames[head]-=unsigned(count);
        }
        if (!run && !tailFrames[head])
            for (auto &voice : voices) if (voice->midiItem)
                mixMIDIVoice(*voice,head,cursor,nullptr,0,0,1,false);
    }
    // Item-level CatStem sees the already clipped/faded audio of both heads.
    // Scope/ignore rules and item automation were applied before this sum.
    for(auto &voice:voices)if(!voice->midiItem&&voice->fx[0].hasActiveStem()&&!voice->frozen) {
        const int head=renderingHead[0]?0:renderingHead[1]?1:0;
        auto &buffer=voice->stemInput[0];for(int ch=0;ch<2;ch++)buffer.addFrom(ch,0,voice->stemInput[1],ch,0,samples);
        const auto clock=blockClock;
        if(!voice->fxBypassed)voice->fx[0].process(buffer,samples,timelinePositions[size_t(head)][0],active,nullptr,blockClock/sr);
        else if(auto bypass=latencyPlan->clipBypass.find(voice->clipID);bypass!=latencyPlan->clipBypass.end())bypass->second[0].process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,clock,active);
        if(auto delay=latencyPlan->clips.find(voice->clipID);delay!=latencyPlan->clips.end())delay->second[0].process(buffer.getWritePointer(0),buffer.getWritePointer(1),samples,clock,active);
        for(int ch=0;ch<2;ch++)buses[voice->bus]->clips[head].addFrom(ch,0,buffer,ch,0,samples);
    }
    // Only the item editor left open needs idle DSP. Never mix this output:
    // stopping or reaching the item boundary must still cut its audio/tails.
    for(auto &voice:voices)for(int head=0;head<2;++head)
        voice->fx[head].processIdleEditors(samples,head==0?current.position:current.subPosition,
                                           head==0?current.playing:current.subPlaying);
    renderProfile.mark();
    for (int index : busOrder)
        if (buses[(size_t)index]->renderRouteAudible) {
            const auto &bus = *buses[(size_t)index];
            for (int target : bus.sends)
                buses[(size_t)target]->renderRouteAudible = true;
            for (const auto &patch : bus.outputs)
                if (patch.firstChannel == -2 && bus.parent >= 0)
                    buses[(size_t)bus.parent]->renderRouteAudible = true;
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
        if (bus.midiSlot >= 1 && bus.midiSlot <= 6)
            appendLiveTrackMIDI(bus.midiMessages, slotMessages[bus.midiSlot - 1], samples, bus.armed.load() && liveInputEnabled.load(), bus.midiChannel);
        bus.keyboardRoute.append(bus.midiMessages, keyboardMidi, samples,
            !bus.vinhetasBus && bus.armed.load() && liveInputEnabled.load(), keyboardChannel.load(), bus.midiChannel);
        if (captureActive)
            trackCapture->midi(bus.id, bus.midiMessages, samples, 0);
        if(allowInstrument)for(const auto event:bus.midiMessages)
            bus.externalMIDI[0].addEvent(event.getMessage(),event.samplePosition);
        if(!allowInstrument&&instrumentWasAllowed)
            for(int channel=1;channel<=16;++channel)bus.externalMIDI[0].addEvent(MidiMessage::allNotesOff(channel),0);
        liveRecordBuffer.clear(0, samples);
        if (bus.vinhetasBus) vinhetas.render(liveRecordBuffer, samples, sr);
        if (bus.midi && !bus.midi->empty()) {
            if (allowInstrument)
                bus.midi->live(liveRecordBuffer, bus.midiMessages, samples);
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
        if (captureActive)
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
            if (bus.automation.curves.empty() && !fadeSelected) {
                float left = beforeEffect ? 1.f : (bus.mute ? 0.f : bus.volume);
                float right = left;
                const float pan = beforeEffect && !panEnvelope ? 0.f : bus.pan;
                if (pan > 0) left *= 1 - pan; else right *= 1 + pan;
                if (!beforeEffect && bus.phase) { left = -left; right = -right; }
                if (left != 1.f) FloatVectorOperations::multiply(buffer.getWritePointer(0), left, samples);
                if (right != 1.f) FloatVectorOperations::multiply(buffer.getWritePointer(1), right, samples);
                return;
            }
            const unsigned delay=compensation?(beforeEffect&&!frozen?compensation->input:compensation->output):0;
            for(int n=0;n<samples;n++) {
                const auto values=bus.automation.evaluate(automationTime(head,n,delay),beforeEffect?1:bus.volume,beforeEffect&&!panEnvelope?0:bus.pan,beforeEffect?false:bus.mute);
                float left=values.mute?0:(float)values.gain,right=left;
                if(values.pan>0)left*=1-(float)values.pan;else right*=1+(float)values.pan;
                if(!beforeEffect){if(bus.phase)left=-left,right=-right;if(fadeSelected)left*=trackFadeoutGains[size_t(n)],right*=trackFadeoutGains[size_t(n)];}
                buffer.setSample(0,n,buffer.getSample(0,n)*left);buffer.setSample(1,n,buffer.getSample(1,n)*right);
            }
        };
        // Capture the live source independently of the arrangement. Existing
        // items remain in the playback mix, but never feed the new output take.
        if (captureActive) for (auto &capture : recordingOutputs) if (capture.track == bus.id) {
            trackCapture->bus(bus.id, liveRecordBuffer, samples, true, false, false);
            for (int ch=0; ch<2; ++ch) outputRecordScratch.copyFrom(ch,0,liveRecordBuffer,ch,0,samples);
            applyGain(outputRecordScratch,0);
            trackCapture->bus(bus.id, outputRecordScratch, samples, true, false, true);
            if (capture.fx) {
                capture.fx->applyAutomation(bus.automation, current.position);
                capture.fx->process(liveRecordBuffer,samples,current.position,current.playing,&bus.midiMessages,blockClock/sr);
                trackCapture->bus(bus.id, liveRecordBuffer, samples, true, true, false);
                applyGain(liveRecordBuffer,0);
                trackCapture->bus(bus.id, liveRecordBuffer, samples, true, true, true);
            }
        }
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
            bus.fx[combined?0:head].applyAutomation(bus.automation,automationTime(head,0,compensation?compensation->input:0));
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
            const bool silent = !buses[(size_t)index]->renderRouteAudible;
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
        // An armed track indicates its selected input even with transport and
        // audible monitoring off. This does not route that signal to the master.
        if (bus.armed.load() && liveInputEnabled.load() && bus.inputFirst > 0 && input)
            for (int channel = 0; channel < 2; ++channel) {
                const int physical = bus.inputFirst - 1 + (bus.inputChannels == 1 ? 0 : channel);
                const int packed = physical < 128 ? inputMapping[(size_t)physical] : -1;
                if (packed >= 0 && packed < inputChannels && input[packed]) {
                    const auto range = FloatVectorOperations::findMinAndMax(input[packed], samples);
                    const float level = range.getEnd(), negative = -range.getStart();
                    stereoPeak[(size_t)channel] = std::max(stereoPeak[(size_t)channel], std::max(level, negative));
                    peak = std::max(peak, stereoPeak[(size_t)channel]);
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
    renderProfile.mark();
    if (routedHardware)
        liveMidi.clear();
    liveRecordBuffer.clear(0,samples);
    if (std::none_of(buses.begin(), buses.end(), [](const auto &bus) { return bus->vinhetasBus; })) vinhetas.discard();
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
    masterFX.applyAutomation(masterAutomation,automationTime(0,0,latencyPlan?latencyPlan->masterInput:0));
    masterFX.process(masterBuffer, samples,timelinePositions[0][0],active,allowInstrument?&liveMidi:nullptr,blockClock/sr);
    masterFXOutput.store(
        std::max(masterBuffer.getMagnitude(0, samples), masterFXOutput.load() * .85f));
    float maxPeak = 0;
    if (masterMono) {
        auto* left = masterBuffer.getWritePointer(0);
        FloatVectorOperations::add(left, masterBuffer.getReadPointer(1), samples);
        FloatVectorOperations::multiply(left, .5f, samples);
        FloatVectorOperations::copy(masterBuffer.getWritePointer(1), left, samples);
    }
    if (masterAutomation.curves.empty()) {
        float left = masterMute ? 0.f : masterVolume * (masterPhase ? -1.f : 1.f);
        float right = left;
        if (masterPan > 0) left *= 1 - masterPan;
        if (masterPan < 0) right *= 1 + masterPan;
        if (left != 1.f) FloatVectorOperations::multiply(masterBuffer.getWritePointer(0), left, samples);
        if (right != 1.f) FloatVectorOperations::multiply(masterBuffer.getWritePointer(1), right, samples);
    } else {
        const unsigned delay = latencyPlan ? latencyPlan->masterInput + masterFX.latencyFrames() : 0;
        for (int i = 0; i < samples; ++i) {
            const auto values = masterAutomation.evaluate(automationTime(0, i, delay), masterVolume, masterPan, masterMute);
            float left = values.mute ? 0.f : (float)values.gain * (masterPhase ? -1.f : 1.f);
            float right = left;
            if (values.pan > 0) left *= 1 - (float)values.pan;
            if (values.pan < 0) right *= 1 + (float)values.pan;
            masterBuffer.setSample(0, i, masterBuffer.getSample(0, i) * left);
            masterBuffer.setSample(1, i, masterBuffer.getSample(1, i) * right);
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
        } else if (buses[(size_t)exportBus]->renderRouteAudible) {
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
    renderProfile.mark();
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
    } else timecodeMIDI.publishAudioClock(current.position,current.playing,true,samples/sr);
    std::array<double,2> programAt;std::array<bool,2> programPlaying;
    for(int head=0;head<2;++head) {
        const bool delayed=latencyPlan&&latencyPlan->total;
        programPlaying[head]=delayed?presentedPlaying[head].load():(head?current.subPlaying:current.playing);
        // Publish the first sample of this output block, including a cue at zero.
        programAt[head]=delayed?std::max(0.,presentedPosition[head].load()-(programPlaying[head]?samples/sr:0)):
            programPlaying[head]?timelinePositions[size_t(head)][0]:(head?current.subPosition:current.position);
    }
    timecodeMIDI.publishProgramClocks(programAt,programPlaying,attached&&!offlineMode&&!offlineRendering&&!exportCapture,samples/sr,current.promotion);
    presentationTailing=tailFrames[0]>0||tailFrames[1]>0;
    renderClock+=unsigned(samples);
    position.store(current.position);
    subPosition.store(current.subPosition);
    playing.store(current.playing);
    subPlaying.store(current.subPlaying);
    if (active)
        elapsedSamples.fetch_add((uint64)samples, std::memory_order_relaxed);
    if (captureActive) {
        trackCapture->advance(samples);
        recordedFrames = trackCapture->sampleCount();
    }
    transportFadeout.advance(fadeout, (uint32_t)std::max(0, samples));
}
void AudioEngine::audioDeviceIOCallbackWithContext(const float *const *input, int inputs,
                                                   float *const *out, int channels, int samples,
                                                   const AudioIODeviceCallbackContext &) {
    if (asioCallbackScheduling)
        callbackMetrics.scheduling(AudioThreadScheduling::asioCallback());
    AudioCallbackMetrics::Scope callbackScope(callbackMetrics, samples, rate.load());
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
    asioCallbackScheduling = d->getTypeName() == "ASIO";
    callbackMetrics.deviceStarted();
    cancelTrackFadeout();
    rate = d->getCurrentSampleRate();
    configureDeviceChannels(d->getActiveInputChannels(), d->getActiveOutputChannels());
    masterFX.prepare(masterFXSettings, rate.load(),nullptr,offlineMode,true,{},instrumentDirectory);
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
            bus->fx[h].prepare(bus->settings,rate.load(),nullptr,offlineMode,h==0,{},instrumentDirectory);
        bus->fx[1].shareStems(bus->fx[0]);
    }
    for (auto &voice : voices) {
        if (voice->clipAudio)
            voice->clipAudio->prepare(rate.load());
        for (auto &expected : voice->midiExpected) expected=-1;
        for(int h=0;h<2;h++)
            voice->fx[h].prepare(voice->fxSettings,rate.load(),nullptr,offlineMode,h==0,{},instrumentDirectory);
        voice->fx[1].shareStems(voice->fx[0]);
    }
    latencyPlan.reset();activateStemLatency();latencyPlan=makeLatencyPlan();publishLatency();
}
void AudioEngine::setMIDISlot(int slot, const String &identifier) {
    if (slot < 0 || slot >= 6)
        return;
    const ScopedLock lock(midiRoutingLock);
    if(midiDevices[slot] != identifier)midiProgramChanges[size_t(slot)].store(0);
    midiDevices[slot] = identifier;
}
void AudioEngine::handleIncomingMidiMessage(MidiInput *source, const MidiMessage &message) {
    if(source && message.isProgramChange()) {
        const auto value=(++programChangeSerial<<12) | uint64((message.getChannel()-1)<<7) | uint64(message.getProgramChangeNumber());
        const ScopedLock lock(midiRoutingLock);
        for(int slot=0;slot<6;++slot)if(midiDevices[slot]==source->getIdentifier())midiProgramChanges[size_t(slot)].store(value);
    }
    if(vinhetas.handlesMIDI(message))return;
    midiInput.addMessageToQueue(message);
    if (source) {
        const ScopedLock lock(midiRoutingLock);
        for (int slot = 0; slot < 6; ++slot)
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
    callbackMetrics.deviceStopped();
    cancelTrackFadeout();
    playing = false;
    subPlaying = false;
}
} // namespace catlive
