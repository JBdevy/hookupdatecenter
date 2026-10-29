#pragma once
#include "SystemAudioDefaultsTests.h"
#include <thread>
#include <chrono>

namespace catlive::audioThreadSchedulingTests {
template <typename Test> void registerTests(const File& directory, Test& test) {
    test("ASIO callback retains continuous PCM under CPU load on its own prioritized thread", [&] {
        const auto require=[](bool ok,const char* why){if(!ok)throw std::runtime_error(why);};
        const auto folder=directory.getNonexistentChildFile("asio-thread-load","");
        require(folder.createDirectory().wasOk(),"Cannot create ASIO fixture folder");
        jaras::Song song;song.id=uuid();song.name="ASIO load";song.duration=8;
        for(int fileIndex=0;fileIndex<8;++fileIndex) {
            const auto name="tone-"+String(fileIndex)+".wav";
            WavAudioFormat wav;auto stream=folder.getChildFile(name).createOutputStream();
            std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.release(),48000,2,24,{},0));
            require(bool(writer),"Cannot create ASIO fixture audio");
            AudioBuffer<float> second(2,48000);
            for(int ch=0;ch<2;++ch)FloatVectorOperations::fill(second.getWritePointer(ch),.02f+float(fileIndex)*.001f,48000);
            for(int i=0;i<8;++i)require(writer->writeFromAudioSampleBuffer(second,0,48000),"Cannot write ASIO fixture");
            jaras::Track track;track.id=uuid();track.name="Track "+std::to_string(fileIndex);track.role.id="other";
            jaras::AudioClip clip;clip.id=uuid();clip.name=track.name;clip.duration=8;
            clip.audioFile=jaras::AudioFile{utf8(name),{}};track.clips={clip};song.tracks.push_back(track);
        }
        AudioEngine engine;
        systemAudioDefaultsTests::Device device("Speaker A",{},"ASIO");
        BigInteger outputs;outputs.setRange(0,2,true);device.open({},outputs,48000,1024);
        auto& callback=static_cast<AudioIODeviceCallback&>(engine);
        callback.audioDeviceAboutToStart(&device);
        engine.prepareSong(song,folder);
        AudioEngine::State state;state.playing=true;engine.transport(state);
        const auto uiThread=GetCurrentThreadId(),processPriority=GetPriorityClass(GetCurrentProcess());
        const auto uiPriority=GetThreadPriority(GetCurrentThread());
        std::atomic<bool> done{false};std::atomic<uint64> work{0};
        std::vector<std::thread> load;
        const int workers=jlimit(1,2,SystemStats::getNumCpus()-1);
        for(int i=0;i<workers;++i)load.emplace_back([&] {
            uint64 value=17;
            while(!done.load(std::memory_order_relaxed)) {
                for(int n=0;n<65536;++n)value=value*6364136223846793005ULL+1;
                work.fetch_add(value,std::memory_order_relaxed);
            }
        });
        int silentBlocks=0;DWORD actualThread=0;
        // A driver-like worker invokes the real callback; no message-loop pump
        // is running while CPU workers compete with read-ahead and rendering.
        std::thread audio([&] {
            actualThread=GetCurrentThreadId();AudioBuffer<float> pcm(2,1024);
            auto next=std::chrono::steady_clock::now();
            for(int block=0;block<192;++block) {
                callback.audioDeviceIOCallbackWithContext(nullptr,0,pcm.getArrayOfWritePointers(),2,1024,{});
                if(block>0 && (pcm.getMagnitude(0,0,1024)<.1f || pcm.getMagnitude(1,0,1024)<.1f))++silentBlocks;
                next+=std::chrono::nanoseconds(21333333);
                std::this_thread::sleep_until(next);
            }
        });
        audio.join();done=true;for(auto& worker:load)worker.join();
        const auto metrics=engine.callbackMetrics.snapshot();
        const auto scheduler=get(metrics,"asioScheduling");
        auto result=object();put(result,"callback",metrics);put(result,"silentBlocks",silentBlocks);
        put(result,"cpuWorkers",workers);put(result,"streaming",engine.streamDiagnostics());
        put(result,"bufferSamples",1024);put(result,"sampleRate",48000);
        directory.getChildFile("asio-thread-load.json").replaceWithText(JSON::toString(result,true));
        callback.audioDeviceStopped();
        require(actualThread!=uiThread && (DWORD)(int64)get(scheduler,"threadID")==actualThread,"ASIO scheduling was applied to the wrong thread");
        require(flag(scheduler,"mmcss") || flag(scheduler,"fallback") || (int)get(scheduler,"priority")>=THREAD_PRIORITY_HIGHEST,"ASIO callback has no audio scheduling or priority fallback");
        require(!flag(scheduler,"mmcss") || flag(scheduler,"critical"),"ASIO MMCSS priority request failed");
        require(GetPriorityClass(GetCurrentProcess())==processPriority && GetThreadPriority(GetCurrentThread())==uiPriority,"Audio scheduling changed process or UI priority");
        require((int64)get(metrics,"callbacks")==192 && silentBlocks==0,"ASIO callback lost PCM while the CPU was busy");
        require(engine.state().position>4,"ASIO transport stopped or waited for the UI thread");
    });
}
}
