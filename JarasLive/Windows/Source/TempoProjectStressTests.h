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
    session.restoreSnapshot(ProjectCodec::read(file));
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
    try {
        session.command(jaras::CommandKind::seek,{},SystemStats::getEnvironmentVariable("CATLIVE_TEMPO_STRESS_START","5").getDoubleValue());
        session.command(jaras::CommandKind::play);
        Thread::sleep(3000);phase=1;
        const double base=session.tempoBPM();
        for(int i=0;i<60;++i){session.setTempo(base+(i<30?i+1:59-i));Thread::sleep(interval);}
        phase=2;Thread::sleep(2500);
        session.command(jaras::CommandKind::stopAll);
    } catch(...) {error=std::current_exception();}
    running=false;callback.join();session.audio.setExternalRenderDriven(false);
    auto report=object();put(report,"tempoIntervalMs",interval);put(report,"tracks",(int)session.song()->tracks.size());put(report,"hardwareFrames",512);
    put(report,"sourceUnderruns",(int64)session.audio.getUnderruns());put(report,"records",(int)count);put(report,"stream",session.audio.streamDiagnostics());put(report,"callback",session.audio.callbackMetrics.snapshot());
    Array<var> slowBlocks;
    for(size_t i=0;i<count;++i)if((*records)[i].milliseconds>512000./48000.){auto row=object();put(row,"index",(int)i);put(row,"phase",(*records)[i].phase);put(row,"ms",(*records)[i].milliseconds);slowBlocks.add(row);}
    put(report,"slowBlocks",slowBlocks);
    for(int stage=0;stage<3;++stage) {
        std::vector<double> times;int over=0,silent=0;
        for(size_t i=0;i<count;++i)if((*records)[i].phase==stage){const auto &r=(*records)[i];times.push_back(r.milliseconds);over+=r.milliseconds>512000./48000.;silent+=r.peak<.0000001f;}
        std::sort(times.begin(),times.end());auto row=object();put(row,"blocks",(int)times.size());put(row,"overBudget",over);put(row,"silent",silent);
        if(!times.empty()){put(row,"medianMs",times[times.size()/2]);put(row,"p95Ms",times[std::min(times.size()-1,size_t(times.size()*.95))]);put(row,"maxMs",times.back());}
        put(report,stage==0?"beforeTempo":stage==1?"changingTempo":"afterTempo",row);
    }
    directory.getChildFile("tempo-project-stress.json").replaceWithText(JSON::toString(report));
    MemoryBlock after;if(!file.loadFileAsData(after) || after!=original)throw std::runtime_error("Tempo benchmark changed the source project");
    if(error)std::rethrow_exception(error);
}
}
