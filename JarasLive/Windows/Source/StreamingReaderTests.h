#pragma once
#include "StreamingReader.h"
#include <thread>

namespace catlive::streamingReaderTests {
inline void require(bool value, const String& message) {
    if (!value) throw std::runtime_error(utf8(message));
}
template <typename Predicate>
bool until(Predicate&& ready, int milliseconds = 3000) {
    const auto start = Time::getMillisecondCounter();
    do {
        if (ready()) return true;
        Thread::sleep(2);
    } while (uint32(Time::getMillisecondCounter() - start) < uint32(milliseconds));
    return ready();
}
struct Fixture {
    std::atomic<int> opened{0}, closed{0}, deepSeeks{0};
    std::atomic<bool> holdColdFill{false}, coldFillEntered{false};
    WaitableEvent releaseColdFill{true};
    std::atomic<bool> holdSlow{false}, slowEntered{false}, holdRead{false}, readEntered{false};
    std::atomic<int64> holdReadAt{0};
    std::atomic<bool> destroyedOnReader{false};
    std::atomic<Thread::ThreadID> readingThread{nullptr};
    WaitableEvent releaseSlow{true};
    WaitableEvent releaseRead{true};
};
class Reader final : public AudioFormatReader {
  public:
    Reader(InputStream* stream, Fixture& value) : AudioFormatReader(stream, "Scheduling fixture"), fixture(value) {
        sampleRate = 48000; numChannels = 2; lengthInSamples = 48000 * 16;
        bitsPerSample = 32; usesFloatingPointData = true;
    }
    ~Reader() override {
        if (Thread::getCurrentThreadId() == fixture.readingThread.load()) fixture.destroyedOnReader = true;
        ++fixture.closed;
    }
    static float sample(int64 at) { return .1f + float(at) / 10000000.f; }
    bool readSamples(int* const* output, int channels, int offset, int64 at, int count) override {
        if (at >= 48000 * 6 && !deepPrepared) {
            deepPrepared = true;
            ++fixture.deepSeeks;
            auto* worker = Thread::getCurrentThread();
            if (fixture.holdColdFill.load() && worker && worker->getThreadName() == "Test cold prefix fill") {
                fixture.coldFillEntered = true;
                fixture.releaseColdFill.wait(8000);
            }
        }
        if (fixture.holdRead.load() && at>=fixture.holdReadAt.load()) {
            fixture.readEntered = true;
            fixture.releaseRead.wait(8000);
        }
        for (int c = 0; c < channels; ++c) if (output[c]) {
            auto* values = reinterpret_cast<float*>(output[c]) + offset;
            for (int i = 0; i < count; ++i)
                values[i] = at + i < lengthInSamples ? sample(at + i) * (c == 0 ? 1.f : -2.f) : 0.f;
        }
        return true;
    }
  private:
    Fixture& fixture;
    bool deepPrepared = false;
};
class Format final : public AudioFormat {
  public:
    explicit Format(Fixture& value) : AudioFormat("Scheduling fixture", ".sched"), fixture(value) {}
    Array<int> getPossibleSampleRates() override { return {48000}; }
    Array<int> getPossibleBitDepths() override { return {32}; }
    bool canDoStereo() override { return true; }
    bool canDoMono() override { return true; }
    bool isCompressed() override { return false; }
    AudioFormatReader* createReaderFor(InputStream* stream, bool deleteIfInvalid) override {
        if (auto* file = dynamic_cast<FileInputStream*>(stream)) {
            if (file->getFile().getFileName() == "slow.sched" && fixture.holdSlow.load()) {
                fixture.slowEntered = true;
                fixture.releaseSlow.wait(5000);
            }
            ++fixture.opened;
            return new Reader(stream, fixture);
        }
        if (deleteIfInvalid) delete stream;
        return nullptr;
    }
    std::unique_ptr<AudioFormatWriter> createWriterFor(std::unique_ptr<OutputStream>&,
                                                       const AudioFormatWriterOptions&) override { return {}; }
  private:
    Fixture& fixture;
};
inline void verifyPCM(StreamingReader& reader, int64 at) {
    AudioBuffer<float> pcm(2, 512);
    require(reader.read(&pcm, 0, 512, at, true, true), "Scheduled stream has missing PCM");
    for (int n = 0; n < 512; ++n) {
        require(std::abs(pcm.getSample(0, n) - Reader::sample(at + n)) < .000001f,
                "Scheduled stream read the other playback head's position");
        require(std::abs(pcm.getSample(1, n) + 2 * Reader::sample(at + n)) < .000001f,
                "Scheduled stream changed stereo samples");
    }
}
inline void scheduling(const File& directory) {
    const auto folder = directory.getChildFile("stream-scheduler");
    require(folder.createDirectory().wasOk(), "Cannot create stream scheduler fixture");
    const auto normal = folder.getChildFile("normal.sched"), slow = folder.getChildFile("slow.sched");
    require(normal.replaceWithText("fixture") && slow.replaceWithText("fixture"), "Cannot write stream fixtures");
    Fixture fixture;
    AudioFormatManager formats; formats.registerFormat(new Format(fixture), true);
    TimeSliceThread fill("Test active stream fill");
    require(fill.startThread(Thread::Priority::high), "Cannot start stream fill worker");
    StreamingReader::Service service(formats, fill);
    StreamingReader::Metadata metadata; metadata.format = "Scheduling fixture";
    metadata.sampleRate = 48000; metadata.frames = 48000 * 16; metadata.channels = 2;
    std::vector<std::unique_ptr<StreamingReader>> readers;
    for (int i = 0; i < 1000; ++i)
        readers.push_back(std::make_unique<StreamingReader>(normal, metadata, service));
    auto slowReader = std::make_unique<StreamingReader>(slow, metadata, service);
    // Unblock the service before reader destructors even if an assertion fails.
    struct Release { Fixture& fixture; ~Release() { fixture.releaseSlow.signal(); } } release{fixture};
    require(fill.getNumClients() == 0 && fixture.opened.load() == 0,
            "Inactive files entered the high-priority fill queue or opened a decoder");
    auto& main = *readers[0]; auto& sub = *readers[1];
    main.request(0); sub.request(48000 * 6);
    require(until([&] { return main.ready(0, 512) && sub.ready(48000 * 6, 512); }),
            "Independent playback heads failed to activate");
    require(fill.getNumClients() == 2 && fixture.opened.load() == 2,
            "Active fills scale with all files instead of demanded heads");
    verifyPCM(main, 0); verifyPCM(sub, 48000 * 6);

    fixture.holdSlow = true; slowReader->request(0);
    require(until([&] { return fixture.slowEntered.load(); }), "Slow decoder fixture did not start");
    // A seek beyond the existing four-block cache requires a new fill while
    // opening another file is deliberately stalled. The callback only posts
    // atomic demand; the independent fill thread must keep working.
    const int64 next = 48000 * 10;
    main.request(next);
    require(until([&] { return main.ready(next, 512); }, 1000),
            "Opening an unrelated slow file blocked an active stream's cache fill");
    verifyPCM(main, next); verifyPCM(sub, 48000 * 6);
    fixture.releaseSlow.signal();
    require(until([&] { return slowReader->ready(0, 512); }), "Slow decoder did not finish after release");
    require(until([&] { return fill.getNumClients() == 0; }, 4000),
            "Inactive delegates remained on the fill worker after retirement");
    require(!main.cached() && !sub.cached() && !slowReader->cached(), "Retirement left stale cache state");
    main.setOffline(true);
    verifyPCM(main, 48000 * 2);
    require(fixture.opened.load() == 4, "Offline reactivation opened unrelated files");
}
inline void retirementDuringRead(const File& directory, bool slowOpen = false) {
    const auto folder = directory.getChildFile(slowOpen ? "stream-slow-offline" : "stream-retirement");
    require(folder.createDirectory().wasOk(), "Cannot create stream retirement fixture");
    const auto file = folder.getChildFile(slowOpen ? "slow.sched" : "normal.sched");
    require(file.replaceWithText("fixture"), "Cannot write stream retirement fixture");
    Fixture fixture;
    AudioFormatManager formats; formats.registerFormat(new Format(fixture), true);
    TimeSliceThread fill("Test guarded stream fill");
    require(fill.startThread(Thread::Priority::high), "Cannot start guarded stream fill worker");
    StreamingReader::Service service(formats, fill);
    StreamingReader::Metadata metadata; metadata.format = "Scheduling fixture";
    metadata.sampleRate = 48000; metadata.frames = 48000 * 16; metadata.channels = 2;
    StreamingReader reader(file, metadata, service);
    if (!slowOpen) {
        reader.request(0);
        require(until([&] { return reader.ready(0, 512); }), "Guarded stream did not activate");
    }

    // An offline read intentionally waits beyond the two-second retirement
    // deadline. This proves pointer withdrawal cannot destroy a delegate still
    // used by a reader, rather than relying on a short lucky timing window.
    reader.setOffline(true);
    fixture.holdRead = true;
    fixture.holdSlow = slowOpen;
    std::exception_ptr failure;
    std::atomic<bool> finished{false};
    std::thread pending([&] {
        fixture.readingThread = Thread::getCurrentThreadId();
        try { verifyPCM(reader, 48000 * 10); }
        catch (...) { failure = std::current_exception(); }
        finished = true;
    });
    struct Join {
        Fixture& fixture; std::thread& thread;
        ~Join() {
            fixture.releaseSlow.signal(); fixture.releaseRead.signal();
            if (thread.joinable()) thread.join();
        }
    } join{fixture, pending};
    if (slowOpen) {
        require(until([&] { return fixture.slowEntered.load(); }), "Offline slow open did not start");
        // The demand predates opening. Once opening finishes the service may
        // immediately retire this delegate, even before the first PCM arrives.
        Thread::sleep(2100);
        fixture.releaseSlow.signal();
    }
    require(until([&] { return fixture.readEntered.load(); }), "Guarded read did not reach the delayed fill");
    require(until([&] { return !reader.cached(); }, 3500), "Idle delegate was not withdrawn during a read");
    require(!finished.load() && fixture.closed.load() == 0,
            "Reader delegate was reclaimed before its in-flight read completed");
    fixture.releaseRead.signal();
    pending.join();
    if (failure) std::rethrow_exception(failure);
    require(until([&] { return fixture.closed.load() == 1; }), "Retired delegate was never reclaimed");
    require(!fixture.destroyedOnReader.load(), "Decoder was destroyed on the reading thread");
    reader.setOffline(false);
    reader.request(48000 * 2);
    require(until([&] { return reader.ready(48000 * 2, 512); }), "Reactivation after guarded retirement failed");
    verifyPCM(reader, 48000 * 2);
    require(fixture.opened.load() == 2, "Guarded reactivation opened extra decoders");
}
template <typename Register>
void registerTests(const File& directory, Register&& test) {
    test("Realtime PCM pages never wait for a blocked decoder", [&] {
        Fixture fixture; TimeSliceThread worker("Blocked decoder fixture");worker.startThread();
        fixture.holdReadAt=49152;fixture.holdRead=true;
        RealtimeBufferedReader reader(new Reader(nullptr,fixture),worker,131072);
        struct Release { Fixture &fixture; ~Release(){fixture.holdRead=false;fixture.releaseRead.signal();} } release{fixture};
        AudioBuffer<float> pcm(2,512);
        require(until([&]{return reader.read(&pcm,0,512,32768,true,true);}),"Initial PCM page did not become ready");
        require(until([&]{return fixture.readEntered.load();}),"Worker never entered the blocked decoder");
        const auto began=Time::getMillisecondCounterHiRes();
        for(int block=0;block<40;++block) {
            require(reader.read(&pcm,0,512,32768,true,true),"An unrelated blocked fill silenced a ready PCM page");
            require(std::abs(pcm.getSample(0,0)-Reader::sample(32768))<1.e-6f,"Ready page was overwritten during read");
        }
        require(Time::getMillisecondCounterHiRes()-began<100,"Realtime reads waited for the decode worker");
        fixture.holdRead=false;fixture.releaseRead.signal();
        require(until([&]{return reader.read(&pcm,0,512,16384-128,true,true);}),"Read across PCM page boundaries failed");
        for(int n=0;n<512;++n)require(std::abs(pcm.getSample(0,n)-Reader::sample(16384-128+n))<1.e-6f,"A page boundary changed the PCM");
    });
    test("Realtime PCM covers unaligned engine blocks and zero-padded EOF", [&] {
        Fixture fixture; TimeSliceThread worker("PCM window fixture");worker.startThread();
        RealtimeBufferedReader reader(new Reader(nullptr,fixture),worker,131072);
        reader.setReadTimeout(1000);
        // The engine reserves 131080 samples, including interpolation tails.
        // Starting at the final sample of a page requires ten forward pages.
        constexpr int count=131080;
        AudioBuffer<float> pcm(2,count);
        for(int64 at : {int64(0),int64(16383)}) {
            require(reader.read(&pcm,0,count,at,true,true),"A full engine block exceeded the forward PCM window");
            for(int n=0;n<count;++n) {
                require(std::abs(pcm.getSample(0,n)-Reader::sample(at+n))<1.e-6f,"An unaligned PCM block changed samples");
                require(std::abs(pcm.getSample(1,n)+2*Reader::sample(at+n))<1.e-6f,"An unaligned PCM block changed stereo samples");
            }
        }
        const auto tail=reader.lengthInSamples-64;
        require(reader.read(&pcm,0,512,tail,true,true),"The final partial PCM page failed");
        for(int n=0;n<512;++n) {
            const auto expected=n<64?Reader::sample(tail+n):0.f;
            require(std::abs(pcm.getSample(0,n)-expected)<1.e-6f,"EOF padding changed the final PCM block");
            require(std::abs(pcm.getSample(1,n)+2*expected)<1.e-6f,"EOF padding changed the final stereo block");
        }
        require(reader.read(&pcm,0,512,reader.lengthInSamples+17,true,true),"A read beyond EOF reported a cache miss");
        require(pcm.getMagnitude(0,512)==0.f,"A read beyond EOF retained old PCM");
    });
    test("Concurrent PCM leases preserve ready pages and writer release", [&] {
        for(bool blocked : {false,true}) {
            Fixture fixture;fixture.holdRead=blocked;
            TimeSliceThread worker("Concurrent PCM fixture");worker.startThread();
            RealtimeBufferedReader reader(new Reader(nullptr,fixture),worker,131072);
            struct Release { Fixture &fixture; ~Release(){fixture.holdRead=false;fixture.releaseRead.signal();} } release{fixture};
            AudioBuffer<float> probe(2,64);
            if(blocked)require(until([&]{return fixture.readEntered.load();}),"Writer did not acquire the initial page");
            else require(until([&]{return reader.read(&probe,0,64,0,true,true);}),"Concurrent fixture did not warm its page");
            std::atomic<bool> begin{false};
            std::atomic<int> reads{0},successes{0},misses{0},invalid{0};
            std::vector<std::thread> readers;
            for(int lane=0;lane<8;++lane)readers.emplace_back([&] {
                AudioBuffer<float> pcm(2,64);
                while(!begin.load())std::this_thread::yield();
                for(int block=0;block<20000;++block) {
                    const bool ok=reader.read(&pcm,0,64,0,true,true);
                    if(ok)++successes;else ++misses;
                    for(int ch=0;ch<2;++ch)for(int n=0;n<64;++n) {
                        const auto expected=ok?Reader::sample(n)*(ch==0?1.f:-2.f):0.f;
                        if(pcm.getSample(ch,n)!=expected)++invalid;
                    }
                    ++reads;
                }
            });
            begin=true;
            if(blocked) {
                while(reads.load()<1000)Thread::sleep(1);
                fixture.holdRead=false;fixture.releaseRead.signal();
            }
            for(auto &thread:readers)thread.join();
            require(invalid.load()==0,"Concurrent readers observed PCM before its writer published it");
            require(successes.load()>0,"Rejected reader leases prevented the writer from publishing its page");
            if(blocked)require(misses.load()>0,"The writer-contention fixture never exercised a rejected lease");
            else require(misses.load()==0,"Concurrent readers caused a false miss on an immutable ready page");
            require(reader.read(&probe,0,64,0,true,true),"Concurrent lease release left the ready page inaccessible");
        }
    });
    test("Decoded failures return promptly and never expose fixed-point bytes as PCM", [&] {
        class FailingReader final : public AudioFormatReader {
          public:
            explicit FailingReader(int failureMode) : AudioFormatReader(nullptr,"Failure fixture"),mode(failureMode) {
                sampleRate=48000;numChannels=2;lengthInSamples=32768;bitsPerSample=32;
                usesFloatingPointData=mode!=1;
            }
            bool readSamples(int* const* output,int channels,int offset,int64,int count)override {
                for(int ch=0;ch<channels;++ch)if(output[ch]) {
                    if(usesFloatingPointData)FloatVectorOperations::fill(reinterpret_cast<float*>(output[ch])+offset,.25f,count);
                    else std::fill(output[ch]+offset,output[ch]+offset+count,0x7fffffff);
                }
                if(mode==2)throw std::runtime_error("Fixture decode failure");
                return false;
            }
          private:
            int mode;
        };
        for(int mode=0;mode<3;++mode) {
            TimeSliceThread worker("PCM failure fixture");worker.startThread();
            RealtimeBufferedReader reader(new FailingReader(mode),worker,131072);
            reader.setReadTimeout(500);
            AudioBuffer<float> pcm(2,512);
            const auto began=Time::getMillisecondCounterHiRes();
            require(!reader.read(&pcm,0,512,0,true,true),"A failed decode was reported as successful");
            require(Time::getMillisecondCounterHiRes()-began<250,"A published decode failure waited for the offline timeout");
            for(int ch=0;ch<2;++ch)for(int n=0;n<512;++n)
                require(pcm.getSample(ch,n)==(mode==0?.25f:0.f),"Failed decode exposed invalid floating-point PCM");
            require(reader.read(&pcm,0,512,reader.lengthInSamples,true,true),"A failed earlier page contaminated EOF success");
            require(pcm.getMagnitude(0,512)==0.f,"EOF after a decode failure was not silent");
        }
    });
    test("Offline export reads PCM without a realtime fill worker", [&] {
        const auto file=directory.getChildFile("direct-offline.sched"); file.replaceWithText("fixture");
        Fixture fixture; AudioFormatManager formats; formats.registerFormat(new Format(fixture),true);
        TimeSliceThread fill("Offline test intentionally stopped");
        StreamingReader::Service service(formats,fill);
        StreamingReader::Metadata metadata;metadata.format="Scheduling fixture";metadata.sampleRate=48000;metadata.frames=48000*16;metadata.channels=2;
        StreamingReader reader(file,metadata,service);reader.setOffline(true,true);
        for(int64 at : {int64(0),int64(70000),int64(3000),int64(400000)})verifyPCM(reader,at);
        require(fill.getNumClients()==0 && fixture.opened==1,"Offline export waited on the realtime reader service");
    });
    test("Stream demand remains fresh across concurrent clock publication and timer wrap", [&] {
        // The callback published at 10001 after the service sampled 10000.
        // Treating the unsigned age as elapsed used to withdraw active readers,
        // causing silent blocks while the transport continued moving.
        require(!StreamingReader::demandExpired(10001, 10000),
                "A newer callback demand expired against an older service clock");
        require(!StreamingReader::demandExpired(10000, 10000), "Current demand expired");
        require(!StreamingReader::demandExpired(10000, 12000), "Demand retired before the idle deadline");
        require(StreamingReader::demandExpired(10000, 12001), "Idle demand never retired");
        const auto lastTick = std::numeric_limits<uint32>::max();
        require(!StreamingReader::demandExpired(lastTick - 10, 20),
                "Counter wrap retired a recently used reader");
        require(StreamingReader::demandExpired(lastTick - 1000, 1001),
                "Counter wrap prevented normal idle retirement");
        require(!StreamingReader::demandExpired(0, lastTick),
                "Concurrent demand across counter wrap expired");
    });
    test("Prepared streams keep PCM through cold service, loop and active seek handoffs", [&] {
        const auto folder = directory.getChildFile("prepared-forward-handoffs");
        require(folder.createDirectory().wasOk(), "Cannot create prepared handoff fixtures");
        const auto file = folder.getChildFile("normal.sched");
        require(file.replaceWithText("fixture"), "Cannot write prepared handoff fixture");
        for (int mode = 0; mode < 5; ++mode) {
            Fixture fixture; fixture.holdColdFill = true;
            AudioFormatManager formats; formats.registerFormat(new Format(fixture), true);
            TimeSliceThread fill("Test cold prefix fill"); fill.startThread(Thread::Priority::high);
            StreamingReader::Service service(formats, fill);
            StreamingReader::Metadata meta; meta.format="Scheduling fixture"; meta.sampleRate=48000;
            meta.frames=48000*16; meta.channels=2;
            const auto source = mode == 4 ? folder.getChildFile("slow.sched") : file;
            require(source.replaceWithText("fixture"), "Cannot write handoff source");
            StreamingReader reader(source,meta,service);
            struct Release { Fixture& value; ~Release() { value.releaseColdFill.signal(); value.releaseSlow.signal(); } } release{fixture};
            const int64 destination = 48000 * 8;
            if (mode == 0) {
                // Existing decoder is stuck decoding a cold MP3-like prefix.
                // Prepared audio must not queue behind it on the same worker.
                reader.request(destination);
                require(until([&]{return fixture.coldFillEntered.load();}), "Cold fill fixture did not block");
            } else {
                require(reader.prepareTransition(0,4096,mode==1), "Old onset was not prepared");
                verifyPCM(reader,0);
            }
            require(reader.prepareTransition(destination,4096), "New onset was not prepared");
            if (mode != 0) {
                // Reserving a new destination cannot replace the audible head.
                // In mode 2 this also replaces slot 0 while its old forward
                // remains selected, requiring safe retired ownership.
                Thread::sleep(50);
                require(until([&]{return reader.ready(48000,512);}), "Old forward was retired before the seek");
                verifyPCM(reader,48000);
            }
            if (mode >= 3) {
                const auto start = Time::getMillisecondCounter();
                while (uint32(Time::getMillisecondCounter()-start) < 2200) {
                    reader.keepTransitionWarm(); Thread::sleep(10);
                }
                require(!reader.cached(), "Old published reader did not retire while the queued reserve stayed warm");
                if (mode == 4) {
                    fixture.holdSlow=true; reader.request(0);
                    require(until([&]{return fixture.slowEntered.load();}), "Fallback opening did not overlap queued playback");
                }
            }
            verifyPCM(reader,destination);
            require(until([&]{return reader.ready(destination+60000,512);}), "Prepared forward stalled beyond onset reserve");
            verifyPCM(reader,destination+60000);
            require(reader.cacheMisses.load()==0 && reader.inactiveMisses.load()==0,
                    "Prepared handoff dropped audio after the reserve");
            fixture.releaseColdFill.signal();
            fixture.releaseSlow.signal();
            if (mode == 4) {
                Thread::sleep(50);
                verifyPCM(reader,destination+61024);
            }
            require(until([&]{return !reader.cached();},4000), "Selected prepared forward never retired when idle");
        }
    });
    test("Prepared Play activates forward streaming before the onset reserve runs out", [&] {
        const auto folder = directory.getChildFile("play-forward-handoff");
        require(folder.createDirectory().wasOk(), "Cannot create handoff fixture");
        const auto slow = folder.getChildFile("slow.sched"), normal = folder.getChildFile("normal.sched");
        require(slow.replaceWithText("fixture") && normal.replaceWithText("fixture"), "Cannot write handoff fixtures");
        Fixture fixture; AudioFormatManager formats; formats.registerFormat(new Format(fixture), true);
        TimeSliceThread fill("Play handoff fill"); fill.startThread(Thread::Priority::high);
        StreamingReader::Service service(formats, fill);
        StreamingReader::Metadata meta; meta.format="Scheduling fixture"; meta.sampleRate=48000;
        meta.frames=48000*16; meta.channels=2;
        StreamingReader blocked(slow,meta,service), reader(normal,meta,service);
        struct Release { Fixture& value; ~Release() { value.releaseSlow.signal(); } } release{fixture};
        fixture.holdSlow=true; blocked.request(0);
        require(until([&]{return fixture.slowEntered.load();}), "Slow activation did not start");
        require(reader.prepareTransition(0,4096), "Play onset was not prepared");
        // A different file can hold up the serial activation service. The Play
        // preparation must activate this source itself, before its one-second
        // pinned onset ends; PCM beyond that reserve must already be available.
        require(reader.cached(), "Prepared Play left forward decoding dependent on the activation queue");
        require(until([&]{return reader.ready(48000,512);}), "Forward PCM was not ready after the onset reserve");
        verifyPCM(reader,0); verifyPCM(reader,48000);
        require(reader.cacheMisses.load()==0 && reader.inactiveMisses.load()==0, "Play handoff dropped PCM");
    });
    test("Seek and loop reserves preserve the old playback cache and exact destination PCM", [&] {
        const auto file = directory.getChildFile("transition.sched"); file.replaceWithText("fixture");
        Fixture fixture; AudioFormatManager formats; formats.registerFormat(new Format(fixture), true);
        TimeSliceThread fill("Transition fill"); fill.startThread(Thread::Priority::high);
        StreamingReader::Service service(formats, fill);
        StreamingReader::Metadata meta; meta.format="Scheduling fixture"; meta.sampleRate=48000;
        meta.frames=48000*16; meta.channels=2;
        StreamingReader reader(file,meta,service);
        reader.request(0); require(until([&]{return reader.ready(0,512);}),"Initial cache unavailable");
        require(reader.prepareTransition(48000*8,4096),"Destination reserve unavailable");
        verifyPCM(reader,0); // Preparing a seek must not evict the old playback.
        require(reader.prepareTransition(0,4096,true),"Loop reserve unavailable");
        fixture.holdRead=true;
        // The fill thread may now be stalled; callback reads must use reserved
        // samples immediately, including repeated wraps and independent seeks.
        for(int n=0;n<8;++n){ verifyPCM(reader,48000*8+n*512); verifyPCM(reader,n*512); }
        fixture.releaseRead.signal(); fixture.holdRead=false;
        require(reader.cacheMisses.load()==0 && reader.inactiveMisses.load()==0,"Reserved transition underrun");
    });
    test("Inactive streams stay off fill queue and slow decoder opening cannot block active cache fills",
         [&] { scheduling(directory); });
    test("Stream retirement preserves in-flight PCM and reclaims delegates outside the reader thread",
         [&] { retirementDuringRead(directory); });
    test("Offline first read survives file opening longer than the cache retirement deadline",
         [&] { retirementDuringRead(directory, true); });
}
} // namespace catlive::streamingReaderTests
