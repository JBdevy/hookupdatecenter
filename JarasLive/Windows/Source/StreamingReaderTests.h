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
    std::atomic<int> opened{0}, closed{0};
    std::atomic<bool> holdSlow{false}, slowEntered{false}, holdRead{false}, readEntered{false};
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
        if (fixture.holdRead.load()) {
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
