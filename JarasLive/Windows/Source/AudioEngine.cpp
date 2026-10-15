#include "AudioEngine.h"
#include "ProjectCodec.h"
#include "ClipAudio.h"
#include <BinaryData.h>
namespace catlive {
AudioEngine::AudioEngine() {
    for (int i = 0; i < 128; ++i)
        inputMapping[(size_t)i] = i;
    liveMidi.ensureSize(32768);
    midiInput.reset(48000);
    keyboardMidi.ensureSize(32768);
    for (int i = 0; i < 3; ++i) {
        midiSlots[i].reset(48000);
        slotMessages[i].ensureSize(32768);
    }
    formats.registerBasicFormats();
    metronome.a = ClickProgram::tone("Digital", true);
    metronome.b = ClickProgram::tone("Digital", false);
    readAhead.startThread(Thread::Priority::high);
}
AudioEngine::~AudioEngine() {
    devices.removeMidiInputDeviceCallback({}, this);
    stopRecording();
    closeDevice();
    voices.clear();
    readAhead.stopThread(5000);
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
    AiffAudioFormat aiff;
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
String AudioEngine::openDevice() {
    if (attached)
        return {};
    auto preferences = File::getSpecialLocation(File::userApplicationDataDirectory)
                           .getChildFile("Hook Developer/CatLive/audio-device.xml");
    auto saved = XmlDocument::parse(preferences);
    auto error = devices.initialise(0, 2, saved.get(), true);
    if (error.isEmpty()) {
        devices.addAudioCallback(this);
        devices.removeMidiInputDeviceCallback({}, this);
        devices.addMidiInputDeviceCallback({}, this);
        attached = true;
    }
    return error;
}
void AudioEngine::closeDevice() {
    if (attached)
        devices.removeAudioCallback(this);
    attached = false;
    devices.closeAudioDevice();
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
void AudioEngine::setEffects(const ID &id, const var &settings) {
    NativeFX prepared[2];
    auto saved = settings.clone();
    const auto sampleRate = rate.load();
    prepared[0].prepare(saved, sampleRate);
    if (!id.empty())
        prepared[1].prepare(saved, sampleRate);
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
                    std::swap(bus->settings, saved);
                    if (changeMIDI)
                        bus->midi.swap(midi);
                    break;
                }
    }
}
void AudioEngine::prepareSong(const jaras::Song &song, const File &directory,
                              const var &masterSettings, const jaras::Project *project) {
    const bool resume = attached;
    if (resume)
        devices.removeAudioCallback(this);
    // The callback has finished before any reader or scratch buffer is replaced.
    voices.clear();
    instrumentDirectory = directory;
    masterMIDI.reset();
    buses.clear();
    busOrder.clear();
    missingFiles.clear();
    unsupported.clear();
    duration = song.duration;
    metronome.prepare(song);
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
        masterFXSettings = masterSettings;
        masterFX.prepare(masterSettings, rate.load());
        try {
            masterMIDI = std::make_unique<MIDIPlayback>(std::vector<PlaybackNote>{}, masterSettings,
                                                        directory, rate.load());
            masterMIDI->enableLive();
        } catch (const std::exception &e) {
            missingFiles.addIfNotAlreadyThere(String::fromUTF8(e.what()));
        }
        unsupported.addArray(masterFX.unsupported);
        for (const auto &track : song.tracks) {
            auto bus = std::make_unique<Bus>();
            bus->id = track.id;
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
            for (auto &fx : bus->fx)
                fx.prepare(bus->settings, rate.load());
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
        std::map<std::string, std::shared_ptr<Source>> sources;
        for (const auto &track : song.tracks) {
            if (track.role.id == "video" || jaras::isTeleprompterRole(track.role) ||
                track.role.id == "chords")
                continue;
            for (const auto &clip : track.clips) {
                const auto &sourceFile = clip.audioFile ? clip.audioFile : track.audioFile;
                if (!sourceFile || clip.muted || clip.duration <= 0 ||
                    (clip.midi && !clip.frozenMIDI.value_or(false)))
                    continue;
                const auto file = ProjectCodec::resolveMedia(directory, sourceFile->path);
                auto voice = std::make_unique<Voice>();
                if (voices.size() >= 20000)
                    throw std::runtime_error("Too many audio items in one timeline.");
                auto sourceKey = utf8(file.getFullPathName());
                auto found = sources.find(sourceKey);
                if (found != sources.end())
                    voice->source = found->second;
                else {
                    if (sources.size() >= 256)
                        throw std::runtime_error("Too many simultaneous streaming files.");
                    voice->source = std::make_shared<Source>();
                }
                bool valid = true;
                for (int h = 0; h < 2; ++h) {
                    if (found == sources.end()) {
                        std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
                        if (!reader || reader->sampleRate <= 0 || reader->sampleRate > 384000 ||
                            reader->numChannels == 0) {
                            valid = false;
                            break;
                        }
                        voice->source->readers[h] = std::make_unique<BufferingAudioReader>(
                            reader.release(), readAhead, 131072);
                        voice->source->readers[h]->setReadTimeout(0);
                        voice->source->scratch[h].setSize(2, 131080, false, true);
                    }
                    voice->processed[h].setSize(2, 4096);
                    voice->fxSettings = clip.fxJSON ? JSON::parse(text(*clip.fxJSON)) : var();
                    voice->fx[h].prepare(voice->fxSettings, rate.load());
                    for (auto value : voice->fx[h].unsupported)
                        unsupported.addIfNotAlreadyThere(text(clip.name) + ": " + value);
                }
                if (!valid) {
                    missingFiles.addIfNotAlreadyThere(file.getFullPathName());
                    continue;
                }
                sources[sourceKey] = voice->source;
                voice->track = track.id;
                voice->start = clip.startTime;
                voice->playbackStart = jaras::playbackItemStart(song, clip);
                voice->duration = clip.duration;
                voice->offset = clip.sourceOffset;
                voice->speed = clip.playbackRate;
                voice->clipGain = clip.gain.value_or(1) * clip.normalizationGain.value_or(1) *
                                  (clip.phaseInverted.value_or(false) ? -1 : 1);
                voice->clipPan = clip.pan.value_or(0);
                voice->fadeIn = clip.fadeIn.value_or(0);
                voice->fadeOut = clip.fadeOut.value_or(0);
                voice->channelMode = clip.channelMode.value_or(0);
                if (ClipAudio::needed(song, track, clip))
                    voice->clipAudio = std::make_unique<ClipAudio>(song, track, clip, rate.load());
                voice->automation.prepare(
                    clip.automationJSON ? JSON::parse(text(*clip.automationJSON)) : var(), true);
                for (size_t i = 0; i < buses.size(); ++i)
                    if (buses[i]->id == track.id)
                        voice->bus = i;
                voices.push_back(std::move(voice));
            }
        }
    } catch (...) {
        if (resume)
            devices.addAudioCallback(this);
        throw;
    }
    if (resume)
        devices.addAudioCallback(this);
}
void AudioEngine::enqueue(const Update &update) {
    int a, n, b, m;
    fifo.prepareToWrite(1, a, n, b, m);
    if (n) {
        updates[(size_t)a] = update;
        fifo.finishedWrite(1);
    } else
        throw std::runtime_error("Audio command queue is full. Stop and retry.");
}
void AudioEngine::transport(const State &state) {
    Update u;
    u.kind = Update::transport;
    u.state = state;
    enqueue(u);
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
                u = {};
                u.kind = Update::mixer;
                u.index = (int)i;
                u.volume = (float)t.volume;
                u.phase = t.phaseInverted.value_or(false);
                u.pan = (float)t.pan;
                u.mute = t.mute;
                u.solo = t.solo;
                enqueue(u);
                break;
            }
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
            reader->setReadTimeout(enabled ? 5000 : 0);
}
double AudioEngine::takeElapsed() { return (double)elapsedSamples.exchange(0) / rate.load(); }
void AudioEngine::applyUpdates() {
    int a, n, b, m;
    fifo.prepareToRead(1024, a, n, b, m);
    auto apply = [this](const Update &u) {
        if (u.kind == Update::transport)
            current = u.state;
        else if (u.index < 0) {
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
    const double sr = rate.load(std::memory_order_relaxed);
    auto &reader = *v.source->readers[head];
    int begin = std::max(0, (int)std::ceil((v.start - at) * sr - 1e-7));
    int end = std::min(count, (int)std::ceil((v.start + v.duration - at) * sr - 1e-7));
    if (begin >= end)
        return;
    const double step = reader.sampleRate / sr * v.speed;
    if (step <= 0 || (!v.clipAudio && step > 32))
        return;
    auto &scratch = v.source->scratch[head];
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
            fade *= jlimit(0.0f, 1.0f, (float)(local / v.fadeIn));
        if (v.fadeOut > 0)
            fade *= jlimit(0.0f, 1.0f, (float)((v.duration - local) / v.fadeOut));
        v.processed[head].setSample(0, i - begin, a * left * fade);
        v.processed[head].setSample(1, i - begin, b * right * fade);
    }
    v.fx[head].process(v.processed[head], end - begin);
    for (int ch = 0; ch < std::min(2, channels); ++ch)
        if (out[ch])
            FloatVectorOperations::add(out[ch] + dest + begin, v.processed[head].getReadPointer(ch),
                                       end - begin);
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
    const bool active = current.playing || current.subPlaying;
    masterBuffer.clear(0, samples);
    bool anySolo = false;
    for (auto &bus : buses) {
        anySolo |= bus->solo;
        bus->buffer.clear(0, samples);
        bus->subBuffer.clear(0, samples);
        if (bus->midi && !bus->midi->empty() && bus->midiSlot > 0)
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
        if (!run)
            for (auto &bus : buses)
                if (bus->midi)
                    bus->midi->reset(head);
        while (run && done < samples) {
            const bool looping = head == 0 && current.loop && current.loopEnd > current.loopStart;
            double boundary = looping ? std::min(duration, current.loopEnd) : duration;
            if (head == 0 && !looping) boundary = std::min(boundary, current.end);
            if (cursor >= boundary - 1e-9) {
                if (looping)
                    cursor = current.loopStart;
                else {
                    run = false;
                    break;
                }
            }
            int count = std::min(samples - done,
                                 std::max(1, (int)std::ceil((boundary - cursor) * sr - 1e-7)));
            for (auto &v : voices)
                if (audible[v->bus] && current.scope[head].allows(v->playbackStart))
                    mixVoice(*v, head, cursor, buses[v->bus]->head(head).getArrayOfWritePointers(),
                             2, done, count);
            for (size_t index = 0; index < buses.size(); ++index)
                if (audible[index] && buses[index]->midi)
                    buses[index]->midi->render(head, cursor, buses[index]->head(head), done, count, current.scope[head]);
            for (size_t busIndex = 0; busIndex < buses.size(); ++busIndex)
                if (audible[busIndex] && buses[busIndex]->click) {
                    auto &bus = *buses[busIndex];
                    auto &buffer = bus.head(head);
                    for (int n = 0; n < count; ++n) {
                        const float sample = bus.click->sample(cursor + n / sr, 1);
                        buffer.addSample(0, done + n, sample);
                        buffer.addSample(1, done + n, sample);
                    }
                }
            if (head == 0 && metronomeEnabled.load(std::memory_order_relaxed))
                for (int n = 0; n < count; ++n) {
                    const float sample = metronome.sample(cursor + n / sr, metronomeMode,
                                                          metronomeGainA, metronomeGainB);
                    for (int c = 0; c < metronomeChannels; ++c) {
                        const int channel = metronomeOutput - 1 + c;
                        if (channel < channels && out[channel])
                            out[channel][done + n] += sample;
                    }
                }
            for (int n = 0; n < count; ++n)
                timelinePositions[(size_t)head][(size_t)(done + n)] = cursor + n / sr;
            cursor += (double)count / sr;
            done += count;
        }
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
    for (int index : busOrder) {
        auto &bus = *buses[(size_t)index];
        bus.midiMessages.clear();
        if (bus.midiSlot >= 1 && bus.midiSlot <= 3)
            bus.midiMessages.addEvents(slotMessages[bus.midiSlot - 1], 0, samples, 0);
        if (index == keyboardTarget.load()) {
            bus.midiMessages.addEvents(keyboardMidi, 0, samples, 0);
            routedKeyboard = true;
        }
        if (trackCapture)
            trackCapture->midi(bus.id, bus.midiMessages, samples, bus.midiChannel);
        liveRecordBuffer.clear(0, samples);
        if (bus.midi && !bus.midi->empty()) {
            if (allowInstrument)
                bus.midi->live(liveRecordBuffer, bus.midiMessages, samples, bus.midiChannel);
            else if (instrumentWasAllowed)
                bus.midi->stopLive();
        }
        if (allowInstrument && bus.armed.load() && bus.inputMonitoring && bus.inputFirst > 0 &&
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
        float peak = 0, fxInput = 0, fxOutput = 0;
        for (int head = 0; head < 2; ++head) {
            auto &buffer = bus.head(head);
            fxInput = std::max(fxInput, buffer.getMagnitude(0, samples));
            bus.fx[head].process(buffer, samples);
            fxOutput = std::max(fxOutput, buffer.getMagnitude(0, samples));
            for (int n = 0; n < samples; ++n) {
                const auto values = bus.automation.evaluate(
                    timelinePositions[(size_t)head][(size_t)n], bus.volume, bus.pan, bus.mute);
                float left = values.mute ? 0 : (float)values.gain * (bus.phase ? -1.f : 1.f),
                      right = left;
                if (values.pan > 0)
                    left *= 1 - (float)values.pan;
                else
                    right *= 1 + (float)values.pan;
                buffer.setSample(0, n, buffer.getSample(0, n) * left);
                buffer.setSample(1, n, buffer.getSample(1, n) * right);
            }
            const bool silent = !routeAudible[(size_t)index];
            peak = std::max(peak, silent ? 0.f : buffer.getMagnitude(0, samples));
            if (silent)
                continue;
            for (int target : bus.sends)
                for (int ch = 0; ch < 2; ++ch)
                    buses[(size_t)target]->head(head).addFrom(ch, 0, buffer, ch, 0, samples);
            for (const auto &patch : bus.outputs) {
                if (patch.firstChannel == -2 && bus.parent >= 0) {
                    auto &parent = *buses[(size_t)bus.parent];
                    for (int ch = 0; ch < 2; ++ch)
                        parent.head(head).addFrom(ch, 0, buffer, ch, 0, samples);
                } else if (patch.firstChannel == 0) {
                    for (int ch = 0; ch < 2; ++ch)
                        masterBuffer.addFrom(ch, 0, buffer, ch, 0, samples);
                } else if (!masterSolo)
                    routeHardware(buffer, patch);
            }
        }
        bus.fxInput.store(std::max(fxInput, bus.fxInput.load() * .85f));
        bus.fxOutput.store(std::max(fxOutput, bus.fxOutput.load() * .85f));
        bus.peak.store(std::max(peak, bus.peak.load(std::memory_order_relaxed) * .85f),
                       std::memory_order_relaxed);
    }
    if (routedHardware)
        liveMidi.clear();
    if (!routedKeyboard)
        liveMidi.addEvents(keyboardMidi, 0, samples, 0);
    if (allowInstrument) {
        if (masterMIDI && !masterMIDI->empty())
            masterMIDI->live(masterBuffer, liveMidi, samples);
        else
            instrument.render(masterBuffer, liveMidi, samples);
    } else if (instrumentWasAllowed) {
        instrument.stop();
        if (masterMIDI)
            masterMIDI->stopLive();
    }
    instrumentWasAllowed = allowInstrument;
    masterFXInput.store(
        std::max(masterBuffer.getMagnitude(0, samples), masterFXInput.load() * .85f));
    masterFX.process(masterBuffer, samples);
    masterFXOutput.store(
        std::max(masterBuffer.getMagnitude(0, samples), masterFXOutput.load() * .85f));
    float maxPeak = 0;
    for (int i = 0; i < samples; ++i) {
        if (masterMono)
            masterBuffer.setSample(
                0, i, (masterBuffer.getSample(0, i) + masterBuffer.getSample(1, i)) * .5f),
                masterBuffer.setSample(1, i, masterBuffer.getSample(0, i));
        for (int ch = 0; ch < 2; ++ch) {
            float gain = masterMute ? 0 : masterVolume * (masterPhase ? -1.0f : 1.0f);
            if (ch % 2 == 0 && masterPan > 0)
                gain *= 1 - masterPan;
            if (ch % 2 == 1 && masterPan < 0)
                gain *= 1 + masterPan;
            masterBuffer.setSample(ch, i, masterBuffer.getSample(ch, i) * gain);
        }
    }
    for (const auto &patch : masterOutputs)
        routeHardware(masterBuffer, patch);
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
    for (int ch = 0; ch < channels; ++ch)
        if (out[ch]) {
            auto range = FloatVectorOperations::findMinAndMax(out[ch], samples);
            maxPeak =
                std::max(maxPeak, std::max(std::abs(range.getStart()), std::abs(range.getEnd())));
        }
    meter.store(std::max(maxPeak, meter.load(std::memory_order_relaxed) * .9f),
                std::memory_order_relaxed);
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
}
void AudioEngine::audioDeviceIOCallbackWithContext(const float *const *input, int inputs,
                                                   float *const *out, int channels, int samples,
                                                   const AudioIODeviceCallbackContext &) {
    if (recording.load(std::memory_order_relaxed) && recorder && inputs > 0) {
        if (!recorder->write(input, samples))
            recordingDrops.fetch_add(1, std::memory_order_relaxed);
    }
    render(out, channels, samples, input, inputs);
}
void AudioEngine::audioDeviceAboutToStart(AudioIODevice *d) {
    rate = d->getCurrentSampleRate();
    inputMapping.fill(-1);
    int packed = 0;
    for (int channel = 0; channel < 128; ++channel)
        if (d->getActiveInputChannels()[channel])
            inputMapping[(size_t)channel] = packed++;
    masterFX.prepare(masterFXSettings, rate.load());
    midiInput.reset(rate.load());
    for (auto &slot : midiSlots)
        slot.reset(rate.load());
    if (masterMIDI)
        masterMIDI->prepare(rate.load());
    instrument.prepare(rate.load());
    for (auto &bus : buses) {
        if (bus->midi)
            bus->midi->prepare(rate.load());
        for (auto &fx : bus->fx)
            fx.prepare(bus->settings, rate.load());
    }
    for (auto &voice : voices) {
        if (voice->clipAudio)
            voice->clipAudio->prepare(rate.load());
        for (auto &fx : voice->fx)
            fx.prepare(voice->fxSettings, rate.load());
    }
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
    playing = false;
    subPlaying = false;
}
} // namespace catlive
