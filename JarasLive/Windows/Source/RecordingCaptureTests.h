#pragma once
#include "TrackCapture.h"
#include "AudioExport.h"
#include "FloatingControlTests.h"
#include <chrono>
#include <thread>

namespace catlive::recordingCaptureTests {
inline void require(bool passed, const String &message) {
    if (!passed) throw std::runtime_error(utf8(message));
}
inline TrackCapture::Take capture(const File &file, int rate, int channels, int bits,
                                  bool floatingPoint, int bitrate, bool impulse) {
    TrackCapture::Target target{uuid(), file, 1, channels};
    target.bits = bits; target.floatingPoint = floatingPoint; target.bitrate = bitrate;
    target.preview = std::make_shared<RecordingPreview>(rate, channels);
    TrackCapture recorder({target}, rate, bits, 120);
    std::array<int, 128> mapping; mapping.fill(-1); mapping[0] = 0; mapping[1] = 1;
    AudioBuffer<float> block(2, 512);
    const int frames = rate / 2;
    for (int at = 0; at < frames; at += block.getNumSamples()) {
        const int count = std::min(block.getNumSamples(), frames - at);
        block.clear();
        for (int i = 0; i < count; ++i) {
            const int position = at + i;
            const float value = impulse ? (position == rate / 8 ? .95f :
                position > rate / 4 ? .08f * (float)std::sin(2 * MathConstants<double>::pi * 440 * position / rate) : 0.f)
                : floatingPoint ? 1.25f : .25f;
            block.setSample(0, i, value); block.setSample(1, i, -.5f * value);
        }
        recorder.input(block.getArrayOfReadPointers(), 2, count, mapping);
        recorder.advance(count);
    }
    require(target.preview->frames.load() == frames, "Live recording duration is unavailable before Stop");
    for (int wait = 0; wait < 200 && target.preview->history.empty(); ++wait) { target.preview->drain(); Thread::sleep(5); }
    require(!target.preview->history.empty(), "Live waveform is unavailable before Stop");
    require(recorder.overflows() == 0, "Test capture overflowed");
    auto takes = recorder.finish();
    require(takes.size() == 1, "Capture did not return one take");
    return std::move(takes.front());
}
inline std::unique_ptr<AudioFormatReader> read(const File &file) {
    AudioFormatManager formats; registerAudioFormats(formats);
    auto reader = std::unique_ptr<AudioFormatReader>(formats.createReaderFor(file));
    require(reader != nullptr, "Unable to decode captured file: " + file.getFileName());
    return reader;
}
inline void rules() {
    using recordingEncoding::resolve;
    require(resolve({}, "WAV", 24, 320).extension == ".wav", "Default format is not WAV");
    require(resolve({}, "WAV", 32, 320).bits == 32 && !resolve({}, "WAV", 32, 320).floatingPoint,
            "Advanced WAV32 must be PCM");
    require(resolve("wav32", "MP3", 16, 320).floatingPoint && resolve("wav32", "MP3", 16, 320).extension == ".wav",
            "Track WAV32 must override Advanced and use float");
    require(resolve("wav", "AIFF", 32, 320).bits == 24 && resolve("wav", "AIFF", 32, 320).extension == ".wav",
            "Track WAV must override Advanced as 24-bit PCM");
    require(resolve({}, "AIFF", 16, 320).extension == ".aiff" && resolve({}, "AIFF", 16, 320).bits == 16,
            "Advanced AIFF16 changed");
    require(resolve({}, "invalid", 12, 129).bits == 24 && resolve({}, "invalid", 12, 129).bitrate == 320,
            "Invalid preferences do not use Mac defaults");
    for (int rate : recordingEncoding::mp3Bitrates)
        require(resolve("mp3", "WAV", 24, rate).bitrate == rate && resolve("mp3", "WAV", 24, rate).extension == ".mp3",
                "MP3 bitrate was discarded");
}
inline void pcm(const File &directory, const String &extension, int bits, bool floatingPoint) {
    const auto file = directory.getChildFile(text(uuid()) + extension);
    const auto take = capture(file, 48000, 1, bits, floatingPoint, 320, false);
    auto reader = read(take.file);
    require(reader->bitsPerSample == (unsigned)bits && reader->usesFloatingPointData == floatingPoint,
            "Recorded PCM/float encoding differs from the selected format");
    require(reader->lengthInSamples == 24000 && reader->sampleRate == 48000 && reader->numChannels == 1,
            "Recorded PCM changed sample count/rate/channels");
    AudioBuffer<float> block(1, 32); reader->read(&block, 0, 32, 100, true, false);
    require(std::abs(block.getSample(0, 0) - (floatingPoint ? 1.25f : .25f)) < .0001f,
            "Recorded float was clipped or PCM amplitude changed");
}
inline void mp3(const File &directory, int bitrate, int channels, int rate = 48000) {
    const auto file = directory.getChildFile(text(uuid()) + ".mp3");
    auto take = capture(file, rate, channels, 24, false, bitrate, true);
    const auto raw = take.file;
    require(raw.hasFileExtension("wav") && !file.existsAsFile(), "MP3 capture was encoded on the realtime path");
    TrackCapture::finalizeEncoding(take);
    require(take.file == file && !raw.existsAsFile(), "Finalized MP3 did not replace its temporary capture");
    auto reader = read(take.file);
    const auto outputRate = rate == 32000 || rate == 44100 || rate == 48000 ? rate : 48000;
    require(reader->numChannels == (unsigned)channels && reader->sampleRate == outputRate,
            "MP3 changed channel count or expected rate");
    require(std::abs(take.duration - .5) < 1e-9 &&
            reader->lengthInSamples == outputRate / 2, "MP3 gapless PCM length changed");
    MemoryBlock encoded; require(file.loadFileAsData(encoded), "Could not inspect MP3 frame header");
    const auto *bytes = static_cast<const uint8 *>(encoded.getData());
    constexpr int rates[]{0,32,40,48,56,64,80,96,112,128,160,192,224,256,320,0};
    int headerRate = 0;
    for (size_t i = 0; i + 4 < encoded.getSize(); ++i)
        if (bytes[i] == 0xff && (bytes[i + 1] & 0xfe) == 0xfa && rates[bytes[i + 2] >> 4]) {
            headerRate = rates[bytes[i + 2] >> 4]; break;
        }
    require(headerRate == bitrate, "MP3 frame bitrate differs from preference: " + String(headerRate));
    AudioBuffer<float> decoded(channels, (int)reader->lengthInSamples);
    reader->read(&decoded, 0, decoded.getNumSamples(), 0, true, true);
    int peak = 0;
    for (int i = 1; i < std::min(decoded.getNumSamples(), outputRate / 4); ++i)
        if (std::abs(decoded.getSample(0, i)) > std::abs(decoded.getSample(0, peak))) peak = i;
    require(std::abs(decoded.getSample(0, peak)) > .1f, "MP3 lost captured impulse");
    const int delay = peak - outputRate / 8;
    require(std::abs(delay) <= 2, "MP3 impulse delay=" + String(delay) + " samples; " +
            String(bitrate) + " kbps, " + String(channels) + "ch, " + String(rate) + "Hz; metadata=" +
            reader->metadataValues.getDescription() + "; encoder delay=" + String(take.encoderDelaySamples));
    AudioBuffer<float> seek(channels, 333);
    require(reader->read(&seek, 0, 333, outputRate / 8 - 100, true, true), "MP3 backward seek failed");
    for (int ch = 0; ch < channels; ++ch) for (int i = 0; i < 333; ++i)
        require(seek.getSample(ch, i) == decoded.getSample(ch, outputRate / 8 - 100 + i),
                "MP3 seek changed the decoded waveform");
}
inline void collision(const File &directory) {
    const auto file = directory.getChildFile(text(uuid()) + ".mp3");
    auto take = capture(file, 48000, 1, 24, false, 192, true);
    require(file.replaceWithText("existing"), "Could not create collision fixture");
    bool rejected = false;
    try { TrackCapture::finalizeEncoding(take); } catch (...) { rejected = true; }
    require(rejected && take.file.existsAsFile() && take.file.hasFileExtension("wav") && file.loadFileAsString() == "existing",
            "Failed MP3 finalization destroyed the raw take or existing destination");
}
inline void aiff32Export(const File &directory) {
    const auto folder = directory.getChildFile("aiff32-export-" + text(uuid()));
    folder.createDirectory();
    capture(folder.getChildFile("source.wav"), 48000, 2, 24, false, 320, false);
    jaras::Project project; project.id = uuid();
    jaras::Song song; song.id = uuid(); song.duration = .5;
    jaras::Track track; track.id = uuid(); track.name = "AIFF32 export";
    track.role.id = "other"; track.volume = 1;
    track.outputs = std::vector<jaras::OutputPatch>{{0, 2}};
    jaras::AudioClip clip; clip.id = uuid(); clip.duration = .5;
    clip.audioFile = jaras::AudioFile{"source.wav", {}};
    track.clips.push_back(clip); song.tracks.push_back(track); project.songs.push_back(song);
    ExportRequest request; request.directory = folder.getChildFile("exported");
    auto &encoding = request.encodings[0];
    encoding.format = "AIFF"; encoding.bits = 32; encoding.rate = 48000; encoding.channels = 2;
    ExportJob job; job.name = "render-32.aiff"; job.start = 0; job.end = .5; job.track = track.id;
    request.jobs.push_back(job);
    std::atomic<bool> cancel{false};
    audioExport::render(project, song, folder, request, cancel, {});
    auto reader = read(request.directory.getChildFile(job.name));
    require(reader->bitsPerSample == 32 && !reader->usesFloatingPointData &&
            reader->numChannels == 2 && reader->sampleRate == 48000 && reader->lengthInSamples == 24000,
            "AIFF32 export did not preserve requested signed PCM depth/rate/channels/length");
    AudioBuffer<float> decoded(2, 64);
    require(reader->read(&decoded, 0, 64, 100, true, true), "AIFF32 export could not be decoded");
    require(std::abs(decoded.getSample(0, 0) - .25f) < .0002f &&
            std::abs(decoded.getSample(1, 0) + .125f) < .0002f, "AIFF32 export changed the PCM amplitude");
}
inline void previewBackpressure() {
    RecordingPreview preview(48000, 2);
    AudioBuffer<float> block(2, 960);
    FloatVectorOperations::fill(block.getWritePointer(0), .25f, 960);
    FloatVectorOperations::fill(block.getWritePointer(1), -.5f, 960);
    // Leave UI stalled longer than its visual FIFO. Audio peaks must coalesce
    // without losing the sample clock, signed channel values or blocking audio.
    for (int i = 0; i < 3000; ++i) preview.append(block.getArrayOfReadPointers(), 960);
    require(preview.drain(), "Stalled preview has no queued peaks");
    preview.flush(); preview.drain();
    int64 end = 0;
    for (const auto &peak : preview.history) {
        require(peak.start == end && peak.end > peak.start, "Preview lost or reordered captured frames");
        require(peak.high[0] == .25f && peak.low[1] == -.5f && peak.low[0] == 0 && peak.high[1] == 0,
                "Live preview lost signed stereo channel peaks");
        end = peak.end;
    }
    require(end == 3000 * 960, "Preview dropped time while UI was stalled");
}
inline void stages(const File &directory) {
    for (bool postFader : {false, true}) for (bool postFX : {false, true}) {
        TrackCapture::Target target{uuid(), directory.getChildFile(text(uuid()) + ".wav"), 1, 2};
        target.postFader = postFader; target.postFX = postFX; target.gain = .25f;
        target.floatingPoint = true; target.bits = 32;
        target.effects = JSON::parse(R"({"inserted":["Compressor"],"compressorEnabled":true,"ratio":1,"makeup":6})");
        target.preview = std::make_shared<RecordingPreview>(48000, 2);
        TrackCapture capture({target}, 48000, 32, 120);
        AudioBuffer<float> input(2, 512);
        std::array<int,128> mapping; mapping.fill(-1); mapping[0] = 0; mapping[1] = 1;
        for (int frame = 0; frame < 24000; frame += 512) {
            const int count = std::min(512, 24000 - frame);
            for (int i = 0; i < count; ++i) { input.setSample(0, i, .2f); input.setSample(1, i, -.1f); }
            capture.input(input.getArrayOfReadPointers(), 2, count, mapping); capture.advance(count);
        }
        auto takes = capture.finish(); auto reader = read(takes[0].file);
        require(reader->lengthInSamples == 24000, "Post-FX recording changed captured length");
        AudioBuffer<float> result(2, 512); reader->read(&result, 0, 512, 12000, true, true);
        const float gain = (postFader ? .25f : 1.f) * (postFX ? Decibels::decibelsToGain(6.f) : 1.f);
        require(std::abs(result.getSample(0, 0) - .2f * gain) < .0001f &&
                std::abs(result.getSample(1, 0) + .1f * gain) < .0001f, "Pre/post stages changed channels or ignored selected gain/FX");
        target.preview->drain();
        require(!target.preview->history.empty() && std::abs(target.preview->history.back().high[0] - .2f * gain) < .0001f,
                "Live recording preview differs from processed recorded PCM");
    }
}
inline void liveArming(const File &directory) {
    TrackCapture::Target first{uuid(), directory.getChildFile(text(uuid()) + ".wav"), 1, 2};
    first.postFX=first.postFader=false;first.clip=uuid();
    first.preview=std::make_shared<RecordingPreview>(48000,2);
    TrackCapture capture({},48000,24,120);
    capture.advance(480);
    auto add=capture.prepareTargets({first},{first.track},24);
    require(capture.applyTargets(add)==480,"Late arm did not use the live sample clock");
    AudioBuffer<float> input(2,480);input.clear();
    FloatVectorOperations::fill(input.getWritePointer(0),.25f,480);
    FloatVectorOperations::fill(input.getWritePointer(1),-.125f,480);
    std::array<int,128> mapping;mapping.fill(-1);mapping[0]=0;mapping[1]=1;
    capture.input(input.getArrayOfReadPointers(),2,480,mapping);capture.advance(480);
    TrackCapture::Target second=first;second.track=uuid();second.clip=uuid();second.file=directory.getChildFile(text(uuid())+".wav");
    second.preview=std::make_shared<RecordingPreview>(48000,2);
    auto both=capture.prepareTargets({second},{first.track,second.track},24);capture.applyTargets(both);
    capture.input(input.getArrayOfReadPointers(),2,480,mapping);capture.advance(480);
    auto remove=capture.prepareTargets({}, {second.track},24);capture.applyTargets(remove);
    capture.input(input.getArrayOfReadPointers(),2,480,mapping);capture.advance(480);
    TrackCapture::Target again=first;again.clip=uuid();again.file=directory.getChildFile(text(uuid())+".wav");
    again.preview=std::make_shared<RecordingPreview>(48000,2);
    auto rearm=capture.prepareTargets({again},{first.track,second.track},24);capture.applyTargets(rearm);
    capture.input(input.getArrayOfReadPointers(),2,480,mapping);capture.advance(480);
    auto takes=capture.finish();
    require(takes.size()==3,"Rearming must retain the prior take and create a new one");
    const double starts[]{.01,.02,.04}, lengths[]{.02,.03,.01};
    const ID ids[]{first.clip,second.clip,again.clip};
    for(size_t i=0;i<takes.size();++i) {
        require(takes[i].clip==ids[i] && std::abs(takes[i].startOffset-starts[i])<1e-9 &&
                std::abs(takes[i].duration-lengths[i])<1e-9,"Arming another track moved or truncated a take");
        auto reader=read(takes[i].file);AudioBuffer<float> pcm(2,int(reader->lengthInSamples));
        reader->read(&pcm,0,pcm.getNumSamples(),0,true,true);
        require(reader->lengthInSamples==int64(lengths[i]*48000) && std::abs(pcm.getSample(0,pcm.getNumSamples()-1)-.25f)<.0001f,
                "Dynamic capture has missing samples");
    }
    require(first.preview->frames.load()==960 && second.preview->frames.load()==1440 && again.preview->frames.load()==480,
            "Disarmed take kept growing or another track reset its waveform");
}
inline void outputExcludesItems(const File &directory) {
    const auto source=directory.getChildFile("existing-playback.wav");
    auto stream=source.createOutputStream();WavAudioFormat wav;
    std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),48000,2,24,{},0));
    require(writer!=nullptr,"Cannot create playback fixture");stream.release();
    AudioBuffer<float> pcm(2,48000);for(int ch=0;ch<2;++ch)FloatVectorOperations::fill(pcm.getWritePointer(ch),.125f,48000);
    writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples());writer.reset();
    for(bool live:{false,true})for(bool fx:{false,true})for(bool postFader:{false,true}) {
        auto project=Session::makeEmptyProject("Overdub");auto &song=project.songs.front();song.duration=1;
        jaras::Track track;track.id=uuid();track.name="Overdub";track.role.id=live?"vinhetas":"other";track.volume=.5;
        const auto effects=JSON::parse(R"({"inserted":["Compressor"],"compressorEnabled":true,"ratio":1,"makeup":6})");
        track.fxJSON=utf8(JSON::toString(effects));
        jaras::AudioClip clip;clip.id=uuid();clip.duration=1;clip.audioFile=jaras::AudioFile{utf8(source.getFileName()),{}};
        track.clips={clip};song.tracks={track};
        AudioEngine engine;engine.prepareOffline(48000);engine.prepareSong(song,directory,{},&project);engine.setOffline(true);engine.setMixer(project,song);
        TrackCapture::Target target{track.id,directory.getChildFile(text(uuid())+".wav"),1,2};
        target.bus=target.output=true;target.postFX=target.postFader=false;target.outputPostFX=fx;target.outputPostFader=postFader;target.effects=effects;
        if(live) {
            auto sample=std::make_shared<VinhetasAudio::Sample>();sample->rate=48000;sample->pcm.setSize(2,48000);
            for(int ch=0;ch<2;++ch)FloatVectorOperations::fill(sample->pcm.getWritePointer(ch),.25f,48000);
            const auto *retained=engine.vinhetas.retain(sample);engine.vinhetas.setOutputAvailable(true);
            require(engine.vinhetas.enqueue({VinhetasAudio::Kind::start,1,0,0,1,retained}),"Live capture fixture did not start");
        }
        engine.armTrack(track.id,true);engine.startTrackRecording({target},24,120);
        AudioEngine::State state;state.playing=true;engine.transport(state);
        AudioBuffer<float> output(2,480);
        for(int block=0;block<10;++block) {
            engine.render(output.getArrayOfWritePointers(),2,480);
            require(output.getMagnitude(0,480)>.06f,"Armed recording silenced the existing item");
        }
        const auto takes=engine.stopTrackRecording();require(takes.size()==1,"Output recording lost its take");
        auto reader=read(takes.front().file);AudioBuffer<float> recorded(2,int(reader->lengthInSamples));
        reader->read(&recorded,0,recorded.getNumSamples(),0,true,true);
        const float expected=live?.25f*(fx?std::pow(10.f,6.f/20):1.f)*(postFader?.5f:1.f):0.f;
        require(std::abs(recorded.getMagnitude(0,recorded.getNumSamples())-expected)<.0001f,
                "Output capture lost live audio/FX/fader or included an existing item");
    }
}
inline void immediateReplay(const File &directory) {
    Session session;session.inspection=true;session.audio.prepareOffline(48000);
    auto project=Session::makeEmptyProject("Recording readiness");auto &song=project.songs.front();song.duration=20;
    jaras::Track track;track.id=uuid();track.name="Output";track.role.id="other";track.recordingOutput=true;song.tracks={track};
    session.restoreSnapshot(ProjectCodec::encode(project));session.mediaDirectory=directory;session.audio.setOffline(true);
    session.cycleRecordArm(track.id);session.toggleRecording();
    AudioBuffer<float> output(2,480);
    for(int i=0;i<4;++i)session.audio.render(output.getArrayOfWritePointers(),2,480);
    session.toggleRecording();session.command(jaras::CommandKind::play);
    require(!session.transport().playing,"Play started before the captured file was published");
    const auto deadline=Time::getMillisecondCounterHiRes()+10000;
    while((session.busy||session.preparingLiveAudio()||!session.transport().playing)&&Time::getMillisecondCounterHiRes()<deadline)
        floatingControlTests::pump();
    require(!session.busy&&!session.preparingLiveAudio()&&session.transport().playing,"Queued Play did not resume after capture preparation");
    require(session.song()->tracks[0].clips.size()==1,"Captured item was lost");
    const auto &clip=session.song()->tracks[0].clips[0];
    require(clip.audioFile && session.audio.activeMediaPaths().count(unicodeCase(directory.getChildFile(text(clip.audioFile->path)).getFullPathName(),false)),
            "Play resumed with a graph that did not contain the recorded item");
    session.command(jaras::CommandKind::stopAll);
    // Starting a second take immediately must first publish the previous take
    // into playback; otherwise graph adoption is deferred for all of REC.
    session.toggleRecording();
    for(int i=0;i<4;++i)session.audio.render(output.getArrayOfWritePointers(),2,480);
    session.toggleRecording();session.toggleRecording();
    const auto recordDeadline=Time::getMillisecondCounterHiRes()+10000;
    while(!session.audio.isRecording() && Time::getMillisecondCounterHiRes()<recordDeadline)floatingControlTests::pump();
    require(session.audio.isRecording() && session.song()->tracks[0].clips.size()==2,"Immediate re-recording lost the completed take");
    const auto &prior=session.song()->tracks[0].clips.back();
    require(prior.audioFile && session.audio.activeMediaPaths().count(unicodeCase(directory.getChildFile(text(prior.audioFile->path)).getFullPathName(),false)),
            "Overdub started before the previous item entered the playback graph");
    session.command(jaras::CommandKind::stopAll);
    const auto stopDeadline=Time::getMillisecondCounterHiRes()+10000;
    while((session.busy||session.preparingLiveAudio()) && Time::getMillisecondCounterHiRes()<stopDeadline)floatingControlTests::pump();
}
inline void preparedStart(const File& directory) {
    AudioEngine engine(48000,true);
    jaras::Song song;song.id=uuid();song.duration=3;
    jaras::Track track;track.id=uuid();track.role.id="other";song.tracks={track};
    engine.prepareSong(song,directory);
    TrackCapture::Target target{track.id,directory.getChildFile(text(uuid())+".wav"),1,2};
    std::atomic<bool> held{false},release{false},timedOut{false};
    std::thread device([&] {
        const ScopedLock lock(engine.devices.getAudioCallbackLock());held.store(true);
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(!release.load() && std::chrono::steady_clock::now()<deadline)std::this_thread::yield();
        timedOut.store(!release.load());
    });
    while(!held.load())std::this_thread::yield();
    try { engine.startTrackRecording({target},24,120); }
    catch(...) {release.store(true);device.join();throw;}
    release.store(true);device.join();
    require(!timedOut.load(),"Prepared capture start waited for device callback lock");
    require(engine.isRecording() && engine.recordedSamples()==0,"Capture start state/frame count");
    AudioEngine::State state;state.playing=true;engine.transport(state);
    AudioBuffer<float> input(2,512),output(2,512);
    FloatVectorOperations::fill(input.getWritePointer(0),.25f,512);
    FloatVectorOperations::fill(input.getWritePointer(1),-.5f,512);
    for(int i=0;i<2;++i)engine.render(output.getArrayOfWritePointers(),2,512,input.getArrayOfReadPointers(),2);
    held=false;release=false;timedOut=false;
    std::thread stopDevice([&] {
        const ScopedLock lock(engine.devices.getAudioCallbackLock());held.store(true);
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(!release.load() && std::chrono::steady_clock::now()<deadline)std::this_thread::yield();
        timedOut.store(!release.load());
    });
    while(!held.load())std::this_thread::yield();
    std::vector<TrackCapture::Take> takes;
    try { takes=engine.stopTrackRecording(); }
    catch(...) {release.store(true);stopDevice.join();throw;}
    release.store(true);stopDevice.join();
    require(!timedOut.load(),"Capture stop waited for device callback lock");
    require(takes.size()==1 && engine.recordedSamples()==1024,"Prepared capture skipped its first block");
    auto reader=read(takes[0].file);
    require(reader->lengthInSamples==1024,"Capture finalization lost queued frames");
    AudioBuffer<float> captured(2,1024);reader->read(&captured,0,1024,0,true,true);
    require(std::abs(captured.getSample(0,0)-.25f)<.00001f && std::abs(captured.getSample(1,1023)+.5f)<.00001f,
            "Prepared capture changed first/last PCM samples");
    target.file=directory.getChildFile(text(uuid())+".wav");
    engine.startTrackRecording({target},24,120);
    const auto cancelled=engine.stopTrackRecording(); // No intervening callback.
    require(cancelled.size()==1 && cancelled[0].duration==0,"Stop before first callback retained recording state");
    engine.render(output.getArrayOfWritePointers(),2,512,input.getArrayOfReadPointers(),2);
    require(!engine.isRecording() && engine.recordedSamples()==0,"Late start resurrected a completed capture");

    target.file=directory.getChildFile(text(uuid())+".wav");
    engine.startTrackRecording({target},24,120);
    std::atomic<int> blocks{0};std::atomic<bool> finished{false};
    engine.setExternalRenderDriven(true);
    std::thread callback([&] {
        while(!finished.load()) {
            engine.render(output.getArrayOfWritePointers(),2,512,input.getArrayOfReadPointers(),2);
            ++blocks;
            Thread::sleep(1);
        }
    });
    while(blocks.load()<4)Thread::sleep(1);
    double targetOffset=0;
    try {targetOffset=engine.changeRecordingTargets({}, {track.id},24);}
    catch(...) {finished=true;callback.join();engine.setExternalRenderDriven(false);throw;}
    auto detached=engine.detachTrackRecording();
    const auto exactFrames=engine.recordedSamples();
    Thread::sleep(5); // Playback callbacks continue after recording withdrawal.
    const bool stable=engine.recordedSamples()==exactFrames;
    finished=true;callback.join();
    engine.setExternalRenderDriven(false);
    require(targetOffset>=2048./48000 && targetOffset<=double(exactFrames)/48000,
            "Prepared target edit was not acknowledged on the recording sample clock");
    require(detached && stable && exactFrames>=2048 && exactFrames%512==0,"Recording withdrawal crossed a block or admitted a late writer");
    const auto concurrentTakes=detached->finish();
    require(concurrentTakes.size()==1 && detached->overflows()==0,"Concurrent recording stop lost its take");
    auto concurrentReader=read(concurrentTakes[0].file);
    require(concurrentReader->lengthInSamples==int64(exactFrames),"Detached recording was finalized at the wrong frame");
}
template <typename Register>
void registerTests(const File &directory, Register &&test) {
    const auto folder = directory.getChildFile("recording-encoding-" + text(uuid()));
    folder.createDirectory();
    test("Prepared recording start and Stop avoid device lock and preserve first and last blocks", [=] { preparedStart(folder); });
    test("Recording height only divides when the growing take overlaps another item", [] {
        jaras::Track track;
        jaras::AudioClip earlier; earlier.id="earlier"; earlier.duration=4;
        auto stacked=earlier;stacked.id="stacked";stacked.recordingLane=0;
        auto later=earlier;later.id="later";later.startTime=20;
        track.clips={earlier,stacked,later};
        jaras::AudioClip take;take.id="live";take.startTime=10;take.duration=1./48000;take.recordingLane=2;
        auto refs=ItemLanes::references(track);refs.push_back(&take);
        auto height=[&]{return ItemLanes(refs).geometry(take.id,120).height;};
        require(height()==120,"Unrelated overlapping items shrank a new recording");
        require(!ItemLanes::growRecordingClip(take,10,refs) && height()==120,"Touching a future item prematurely divided height");
        require(ItemLanes::growRecordingClip(take,10.1,refs),"Entering an existing item did not invalidate layout");
        const auto overlap=ItemLanes(refs);
        require(height()==60 && overlap.geometry(take.id,120).top==60,"Overdub did not appear below the original during capture");
        require(!ItemLanes::growRecordingClip(take,11,refs),"Every audio frame rebuilt the lane layout");
        take.startTime=1;take.duration=1./48000;
        require(height()==40,"Recording directly over two takes did not divide immediately");
    });
    test("Recording live arming preserves existing takes and timestamps", [=] { liveArming(folder); });
    test("Recording output excludes existing items while keeping them audible", [=] { outputExcludesItems(folder); });
    test("Recording immediate Play waits for the completed take and prepared graph", [=] { immediateReplay(folder); });
    test("Recording preview tolerates stalled UI without dropping captured time", [] { previewBackpressure(); });
    test("Recording pre/post fader and FX print only input with matching live waveform", [=] { stages(folder); });
    test("Recording format defaults and track overrides match Mac", [] { rules(); });
    for (int bits : {16, 24, 32}) for (const String extension : {String(".wav"), String(".aiff")})
        test("Recording PCM " + extension + " " + String(bits), [=] { pcm(folder, extension, bits, false); });
    test("Recording WAV32 float preserves headroom", [=] { pcm(folder, ".wav", 32, true); });
    for (int bitrate : recordingEncoding::mp3Bitrates) for (int channels : {1, 2})
        test("Recording MP3 " + String(bitrate) + "kbps " + String(channels) + "ch alignment", [=] { mp3(folder, bitrate, channels); });
    test("Recording MP3 resamples 96kHz without shifting timeline", [=] { mp3(folder, 192, 2, 96000); });
    test("Recording MP3 failure keeps captured WAV and existing destination", [=] { collision(folder); });
    test("AIFF32 export renders real signed PCM and reopens correctly", [=] { aiff32Export(folder); });
}
} // namespace catlive::recordingCaptureTests
