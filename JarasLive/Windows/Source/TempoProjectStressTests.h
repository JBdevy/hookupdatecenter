#pragma once
#include "Session.h"
#include "AudioThreadScheduling.h"
#include <thread>
#include <chrono>

namespace catlive::tempoProjectStressTests {
inline void run(const File &directory) {
    const auto path=SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_PROJECT",{});
    if(path.isEmpty())return;
    const File file(path);
    MemoryBlock original;if(!file.loadFileAsData(original))throw std::runtime_error("Could not read source project");
    Session session;session.inspection=true;session.document=file;session.mediaDirectory=file.getParentDirectory();
    auto raw = ProjectCodec::read(file);
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
    session.restoreSnapshot(raw);
    raw = var();
    if(!session.song() || !session.audio.missingFiles.isEmpty())throw std::runtime_error("Tempo stress project has missing media");
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
        session.command(jaras::CommandKind::seek,{},SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_START","5").getDoubleValue());
        session.command(jaras::CommandKind::play);
        Thread::sleep(3000);phase=1;
        const double base=session.tempoBPM();
        for(int i=0;i<60;++i){session.setTempo(base+(i<30?i+1:59-i));tempoChanged |= session.tempoBPM() != base;Thread::sleep(interval);}
        phase=2;Thread::sleep(2500);
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
    for(int stage=0;stage<(measureSeek ? 4 : 3);++stage) {
        std::vector<double> times;int over=0,silent=0;
        for(size_t i=0;i<count;++i)if((*records)[i].phase==stage){const auto &r=(*records)[i];times.push_back(r.milliseconds);over+=r.milliseconds>512000./48000.;silent+=r.peak<.0000001f;}
        std::sort(times.begin(),times.end());auto row=object();put(row,"blocks",(int)times.size());put(row,"overBudget",over);put(row,"silent",silent);
        if(!times.empty()){put(row,"medianMs",times[times.size()/2]);put(row,"p95Ms",times[std::min(times.size()-1,size_t(times.size()*.95))]);put(row,"maxMs",times.back());}
        put(report,stage==0?"beforeTempo":stage==1?"changingTempo":stage==2?"afterTempo":"preparedSeek",row);
    }
    directory.getChildFile("tempo-project-stress.json").replaceWithText(JSON::toString(report));
    MemoryBlock after;if(!file.loadFileAsData(after) || after!=original)throw std::runtime_error("Tempo benchmark changed the source project");
    if(error)std::rethrow_exception(error);
    if(measureSeek && seekArrivalMs < 0) throw std::runtime_error("Dense seek never reached the destination");
    if(voices>0 && !tempoChanged)throw std::runtime_error("Dense free-timebase audio did not accept the tempo change");
}
}
