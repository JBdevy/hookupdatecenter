#pragma once
#include "Session.h"
#include "AudioThreadScheduling.h"
#include <thread>
#include <psapi.h>
#include <chrono>

namespace catlive::tempoProjectStressTests {
// Sample the first block containing signal, including the live asynchronous start.
inline void measureStart(Session &session, const File &directory, const std::function<void()>& controls = {}) {
    const auto& song = *session.song();
    const double position = session.project().savedCursor && session.project().savedCursor->songID == song.id
        ? session.project().savedCursor->position : session.transport().editPosition;
    const int tracks = (int)song.tracks.size();
    int items = 0;
    std::set<std::string> media;
    for (const auto& track : song.tracks) for (const auto& clip : track.clips) {
        ++items;
        if (clip.audioFile) media.insert(clip.audioFile->path);
    }
    std::atomic<bool> running{true};
    std::atomic<double> firstSignal{0};
    std::atomic<double> firstMaster{0};
    int overBudget = 0;
    session.audio.setExternalRenderDriven(true);
    session.inspection = false;
    std::thread render([&] {
        AudioThreadScheduling priority;
        AudioBuffer<float> output(32, 512);
        const auto period = std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(512./48000.));
        auto deadline = std::chrono::steady_clock::now();
        while (running) {
            const auto t = Time::getMillisecondCounterHiRes();
            session.audio.render(output.getArrayOfWritePointers(), output.getNumChannels(), 512);
            const auto end = Time::getMillisecondCounterHiRes();
            if (end-t > 512000./48000.) ++overBudget;
            if (!firstSignal.load() && output.getMagnitude(0, 512) > 1.e-6f) firstSignal.store(end);
            const auto master=session.audio.meterLevels();
            if (!firstMaster.load() && std::max(master[0],master[1]) > 1.e-6f) firstMaster.store(end);
            deadline += period;
            std::this_thread::sleep_until(deadline);
            if (std::chrono::steady_clock::now() > deadline + period) deadline = std::chrono::steady_clock::now();
        }
    });
    struct Finish {
        Session& session; std::atomic<bool>& running; std::thread& render;
        ~Finish() { running=false; if (render.joinable()) render.join(); session.inspection=true; session.audio.setExternalRenderDriven(false); }
    } finish{session, running, render};
    const auto wait = [](double duration) {
        const auto until = Time::getMillisecondCounterHiRes()+duration;
        do {
            MSG message;
            while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessage(&message); }
            Timer::callPendingTimersSynchronously();
            Thread::sleep(5);
        } while (Time::getMillisecondCounterHiRes()<until);
    };
    session.command(jaras::CommandKind::seek, {}, position);
    wait(1000.);
    const auto began = Time::getMillisecondCounterHiRes();
    session.command(jaras::CommandKind::play);
    const auto dispatched = Time::getMillisecondCounterHiRes()-began;
    wait(3000.);
    const int active = (int)session.core.activeAudioFileCount();
    std::vector<int64> resident, committed;
    for (int i=0; i<9; ++i) {
        PROCESS_MEMORY_COUNTERS_EX counters{}; counters.cb=sizeof(counters);
        if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters), sizeof(counters))) {
            resident.push_back((int64)counters.WorkingSetSize); committed.push_back((int64)counters.PrivateUsage);
        }
        wait(500.);
    }
    auto report=object();
    put(report,"playing",session.audio.state().playing); put(report,"preparing",session.audio.preparingTransport());
    put(report,"masterMute",session.project().masterMute); put(report,"masterVolume",session.project().masterVolume);
    put(report,"cursorAfter",session.audio.state().position);
    put(report,"firstMasterMs",firstMaster.load()>0 ? firstMaster.load()-began : -1.);
    put(report,"stream",session.audio.streamDiagnostics());
    if (controls) controls();
    const auto missed=session.audio.getUnderruns();
    session.command(jaras::CommandKind::stopAll);
    running=false; render.join();
    put(report,"tracks",tracks); put(report,"items",items); put(report,"mediaPaths",(int)media.size());
    put(report,"cursor",position); put(report,"activeAudio",active); put(report,"playDispatchMs",dispatched);
    put(report,"firstOutputMs",firstSignal.load() > 0 ? firstSignal.load()-began : -1.);
    put(report,"overBudgetBlocks",overBudget); put(report,"sourceUnderruns",(int64)missed);
    if (!resident.empty()) {
        std::sort(resident.begin(),resident.end()); std::sort(committed.begin(),committed.end());
        put(report,"workingSetMedianBytes",resident[resident.size()/2]); put(report,"privateMedianBytes",committed[committed.size()/2]);
    }
    directory.getChildFile("play-project-stress.json").replaceWithText(JSON::toString(report));
    if (firstSignal.load() <= began) throw std::runtime_error("Did not observe a new non-silent master block");
}
inline void run(const File &directory) {
    const auto path=SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_PROJECT",{});
    if(path.isEmpty())return;
    const File file(path);
    MemoryBlock original;if(!file.loadFileAsData(original))throw std::runtime_error("Could not read source project");
    Session session;session.inspection=true;session.document=file;session.mediaDirectory=file.getParentDirectory();
    auto raw = ProjectCodec::read(file);
    const bool tuner = SystemStats::getEnvironmentVariable("CATLIVE_STRESS_LIVE_TUNER", {}) == "1";
    const int voices = SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_VOICES", {}).getIntValue();
    size_t sourceFiles = 0;
    if (voices > 0 || SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_FREE_EMPTY", {}) == "1") {
        auto model = ProjectCodec::decode(raw);
        model.regionSetlist.reset();
        for (auto& song : model.songs) {
            song.parts.clear();
            song.markers.reset();
            auto settings = song.timeSettings.value_or(jaras::ProjectTimeSettings{});
            settings.timebase = jaras::ProjectTimebase::free;
            song.timeSettings = settings;
            song.regionOwnershipInitialized = false;
        }
        if (voices > 0) {
            auto& song = model.songs.front();
            std::vector<jaras::AudioClip> sources;
            std::set<std::string> paths;
            for (const auto& track : song.tracks)
                for (const auto& clip : track.clips)
                    if (clip.audioFile && clip.duration >= 60. && paths.insert(clip.audioFile->path).second)
                        sources.push_back(clip);
            if (sources.empty()) throw std::runtime_error("No playable 60-second sources for the dense test");
            sourceFiles = sources.size();
            song.tracks.clear();
            song.duration = 60.;
            for (int i = 0; i < voices; ++i) {
                jaras::Track track; track.id = uuid(); track.role.id = "other"; track.name = "Source " + std::to_string(i+1);
                const auto& source = sources[static_cast<size_t>(i) % sources.size()];
                jaras::AudioClip clip; clip.id = uuid(); clip.name = source.name; clip.audioFile = source.audioFile;
                clip.duration = 60.; clip.sourceOffset = source.sourceOffset; clip.gain = .1;
                track.clips.push_back(std::move(clip));
                song.tracks.push_back(std::move(track));
            }
        }
        jaras::synchronizeRegionOwnership(model);
        raw = ProjectCodec::encode(model);
    }
    if (tuner) {
        auto model = ProjectCodec::decode(raw);
        auto& song = model.songs.front();
        if (song.parts.empty()) {
            jaras::Part region; region.id = uuid(); region.name = "Tuner"; region.endTime = song.duration;
            song.parts.push_back(region);
            for (auto& track : song.tracks) for (auto& clip : track.clips) clip.regionOwnerID = region.id;
        }
        raw = ProjectCodec::encode(model);
    }
    session.restoreSnapshot(raw);
    raw = var();
    if(!session.song() || !session.audio.missingFiles.isEmpty())throw std::runtime_error("Tempo stress project has missing media");
    if (SystemStats::getEnvironmentVariable("CATLIVE_PLAY_STRESS_COMPARE", {}) == "1") {
        measureStart(session, directory);
        MemoryBlock after;
        if (!file.loadFileAsData(after) || after!=original) throw std::runtime_error("Startup benchmark changed the source project");
        return;
    }
    struct Record { double milliseconds=0; int phase=0; float peak=0; };
    auto records=std::make_unique<std::array<Record,6000>>();
    const int interval=jlimit(20,1000,SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_INTERVAL","120").getIntValue());
    size_t count=0;std::atomic<bool> running{true};std::atomic<int> phase{0};
    session.audio.setExternalRenderDriven(true);
    std::thread callback([&] {
        AudioThreadScheduling priority;
        AudioBuffer<float> output(2,512);
        const auto period=std::chrono::duration<double>(512./48000.);
        auto deadline=std::chrono::steady_clock::now();
        while(running.load()) {
            const auto began=Time::getMillisecondCounterHiRes();
            session.audio.render(output.getArrayOfWritePointers(),2,512);
            const double elapsed=Time::getMillisecondCounterHiRes()-began;
            if(count<records->size())(*records)[count++]={elapsed,phase.load(),output.getMagnitude(0,512)};
            deadline+=std::chrono::duration_cast<std::chrono::steady_clock::duration>(period);
            std::this_thread::sleep_until(deadline);
            if(std::chrono::steady_clock::now()>deadline+std::chrono::milliseconds(100))deadline=std::chrono::steady_clock::now();
        }
    });
    std::exception_ptr error;
    bool tempoChanged = false;
    const bool measureSeek = SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_SEEK", {}) == "1";
    double seekArrivalMs = -1, longestSeekDispatchMs = 0;
    uint64 seekSourceMisses = 0;
    try {
        const auto& firstPart = session.song()->parts;
        const double start = tuner ? firstPart.front().startTime + std::min(5., (firstPart.front().endTime-firstPart.front().startTime)*.1) :
            SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_START","5").getDoubleValue();
        session.command(jaras::CommandKind::seek,{},start);
        session.command(jaras::CommandKind::play);
        Thread::sleep(3000);phase=1;
        const double base=session.tempoBPM();
        if (tuner) {
            const auto id = session.song()->parts.front().id;
            const auto tracks = regionPitch::defaults(*session.song(),false), groups = regionPitch::defaults(*session.song(),true);
            session.command(jaras::CommandKind::stopAll);
            session.setRegionPitch(id,3,tracks,groups);
            session.command(jaras::CommandKind::seek,{},start);
            session.command(jaras::CommandKind::play);
            for (int value : {1,2,3,2,1,-1,-2,-3,2,3}) {
                session.setRegionPitch(id,value,tracks,groups);
                if(session.song()->parts.front().pitchSemitones!=3) throw std::runtime_error("Live Tuner changed the selected pitch");
                Thread::sleep(interval);
            }
        } else {
            for(int i=0;i<60;++i){session.setTempo(base+(i<30?i+1:59-i));tempoChanged |= session.tempoBPM() != base;Thread::sleep(interval);}
        }
        phase=2;Thread::sleep(2500);
        if (tuner) {
            phase=3;
            session.command(jaras::CommandKind::stopAll);
            session.setRegionPitch(session.song()->parts.front().id,0,regionPitch::defaults(*session.song(),false),regionPitch::defaults(*session.song(),true));
            session.command(jaras::CommandKind::seek,{},start);
            session.command(jaras::CommandKind::play);
            Thread::sleep(2000);
        }
        if (measureSeek) {
            // Probe a queued transition above the UI admission limit using the existing
            // core and stream prewarmer. Only the in-memory benchmark uses this path.
            const double destination = 35.;
            session.inspection = false; // Exercise the live asynchronous path with the external render clock.
            Timer::callPendingTimersSynchronously();
            const auto missesBefore = session.audio.getUnderruns();
            phase = 3;
            const double requested = Time::getMillisecondCounterHiRes();
            if (session.core.activeAudioFileCount() <= jaras::playbackCapacity::limit) {
                session.command(jaras::CommandKind::queueBeatSeek, {}, destination);
            } else {
                // A timeline seek only moves the main head. The session's
                // ordinary control path is exercised by the 250-voice case.
                auto target = session.audio.state();
                target.position = destination;
                target.subPlaying = false;
                session.audio.prewarmTransportDestination(target);
                session.core.execute({jaras::CommandKind::queueBeatSeek, {}, destination});
            }
            while (Time::getMillisecondCounterHiRes() - requested < 8000.) {
                const double dispatch = Time::getMillisecondCounterHiRes();
                Timer::callPendingTimersSynchronously();
                longestSeekDispatchMs = std::max(longestSeekDispatchMs, Time::getMillisecondCounterHiRes() - dispatch);
                if (seekArrivalMs < 0 && session.audio.state().position >= destination)
                    seekArrivalMs = Time::getMillisecondCounterHiRes() - requested;
                if (seekArrivalMs >= 0 && Time::getMillisecondCounterHiRes() - requested > seekArrivalMs + 1500.) break;
                Thread::sleep(5);
            }
            seekSourceMisses = session.audio.getUnderruns() - missesBefore;
            session.audio.prewarmTransportDestination(std::nullopt);
            session.inspection = true;
        }
        session.command(jaras::CommandKind::stopAll);
    } catch(...) {error=std::current_exception();}
    running=false;callback.join();session.audio.setExternalRenderDriven(false);
    auto report=object();put(report,"tempoIntervalMs",interval);put(report,"tracks",(int)session.song()->tracks.size());put(report,"hardwareFrames",512);
    if (measureSeek) {
        put(report,"seekArrivalMs",seekArrivalMs);
        put(report,"seekSourceMisses",static_cast<int64>(seekSourceMisses));
        put(report,"longestSeekDispatchMs",longestSeekDispatchMs);
    }
    put(report,"tempoChanged",tempoChanged); put(report,"denseSourceFiles",(int)sourceFiles);
    put(report,"parts",(int)session.song()->parts.size());
    put(report,"tempoMarkers",session.song()->markers ? (int)std::count_if(session.song()->markers->begin(),session.song()->markers->end(),[](const auto& m){return m.tempoBPM.has_value();}) : 0);
    put(report,"relative",session.song()->timeSettings.value_or(jaras::ProjectTimeSettings{}).timebase == jaras::ProjectTimebase::relative);
    put(report,"sourceUnderruns",(int64)session.audio.getUnderruns());put(report,"records",(int)count);put(report,"stream",session.audio.streamDiagnostics());put(report,"callback",session.audio.callbackMetrics.snapshot());
    Array<var> slowBlocks;
    for(size_t i=0;i<count;++i)if((*records)[i].milliseconds>512000./48000.){auto row=object();put(row,"index",(int)i);put(row,"phase",(*records)[i].phase);put(row,"ms",(*records)[i].milliseconds);slowBlocks.add(row);}
    put(report,"slowBlocks",slowBlocks);
    for(int stage=0;stage<(measureSeek || tuner ? 4 : 3);++stage) {
        std::vector<double> times;int over=0,silent=0;
        for(size_t i=0;i<count;++i)if((*records)[i].phase==stage){const auto &r=(*records)[i];times.push_back(r.milliseconds);over+=r.milliseconds>512000./48000.;silent+=r.peak<.0000001f;}
        std::sort(times.begin(),times.end());auto row=object();put(row,"blocks",(int)times.size());put(row,"overBudget",over);put(row,"silent",silent);
        if(!times.empty()){put(row,"medianMs",times[times.size()/2]);put(row,"p95Ms",times[std::min(times.size()-1,size_t(times.size()*.95))]);put(row,"maxMs",times.back());}
        put(report,tuner ? (stage==0?"dry":stage==1?"changingPitch":stage==2?"heldPitch":"returnedToZero") :
            (stage==0?"beforeTempo":stage==1?"changingTempo":stage==2?"afterTempo":"preparedSeek"), row);
    }
    directory.getChildFile("tempo-project-stress.json").replaceWithText(JSON::toString(report));
    MemoryBlock after;if(!file.loadFileAsData(after) || after!=original)throw std::runtime_error("Tempo benchmark changed the source project");
    if(error)std::rethrow_exception(error);
    if(measureSeek && seekArrivalMs < 0) throw std::runtime_error("Dense seek never reached the destination");
    if(voices>0 && !tempoChanged)throw std::runtime_error("Dense free-timebase audio did not accept the tempo change");
}
}
