#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <map>
#include <sys/stat.h>
#include <sys/resource.h>
#include <thread>
#include <vector>
#include <time.h>

struct FixtureStats {
    static inline bool disableHits = false;
    static inline std::atomic<uint64_t> lookups{0}, reads{0}, hits{0};
    static void lookup() {
#if CATLIVE_CACHE_DIAGNOSTICS
        ++lookups;
#endif
    }
    static void hit() {
#if CATLIVE_CACHE_DIAGNOSTICS
        ++hits;
#endif
    }
};

@interface RequestTestFile : AVAudioFile {
@public
    std::atomic<bool> denied;
}
@end
@implementation RequestTestFile
- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)count error:(NSError **)error {
    ++FixtureStats::reads;
    if (denied.load()) {
        if (error) *error = [NSError errorWithDomain:@"CatLive.CacheRequestTest" code:1 userInfo:nil];
        return NO;
    }
    return [super readIntoBuffer:buffer frameCount:count error:error];
}
@end

// Generated from the actual cache/worker implementation by the test script.
#include "prepared-cache.inc"

using Status = PreparedPCMCache::Prefetch;
static constexpr int page = PreparedPCMCache::pageSize;

static std::shared_ptr<PreparedPCMCache> cacheAt(NSURL *url) {
    NSError *error = nil;
    auto file = [[RequestTestFile alloc] initForReading:url error:&error];
    assert(file && !error);
    file->denied.store(false);
    auto cache = std::make_shared<PreparedPCMCache>(file);
    cache->active.store(true);
    return cache;
}

static void checkPages(PreparedPCMCache &cache, int first, int count) {
    auto lease = cache.pages.read();
    for (int index = first; index < first + count; ++index) {
        const auto *data = cache.pageAt(int64_t(index) * page, lease);
        assert(data && data->count == page);
        assert(data->samples[0][0] == 0.25f && data->samples[1][data->count - 1] == -0.25f);
    }
}

static void testRequests(NSURL *url) {
    auto cache = cacheAt(url);
    assert(cache->prefetch(6) == Status::ready);
    const auto lookups = FixtureStats::lookups.load(), reads = FixtureStats::reads.load();
    for (int i = 0; i < 1000; ++i) assert(cache->prefetch(6, nullptr, true) == Status::ready);
    assert(FixtureStats::lookups == lookups && FixtureStats::reads == reads);
    checkPages(*cache, 0, 6);
    // Exact cursor comparison intentionally retains the old streaming work,
    // even when a changed position happens to remain inside the same page.
    cache->requested.store(0.5);
    assert(cache->prefetch(6) == Status::ready && FixtureStats::lookups > lookups);
    auto prior = FixtureStats::lookups.load();
    assert(cache->prefetch(7) == Status::ready && FixtureStats::lookups > prior);
    prior = FixtureStats::lookups.load();
    cache->loopStart.store(11); cache->loopEnd.store(page * 2 + 17);
    assert(cache->prefetch(7) == Status::ready && FixtureStats::lookups > prior);
    prior = FixtureStats::lookups.load();
    cache->loopStart.store(12); // Same initial page, different loop geometry.
    assert(cache->prefetch(7) == Status::ready && FixtureStats::lookups > prior);
    cache->loopStart.store(0); cache->loopEnd.store(0);
    cache->requested.store(page * 65);
    assert(cache->prefetch(6) == Status::ready);
    checkPages(*cache, 65, 6);
    std::cout << "PCM_REQUEST_UNCHANGED_FAST_CURSOR_LOOKAHEAD_LOOP_SEEK_OK\n";
}

static void testIncomplete(NSURL *url) {
    auto cache = cacheAt(url);
    assert(cache->prefetch(64) == Status::ready);
    cache->requested.store(page * 64);
    assert(cache->prefetch(64, nullptr, true) == Status::pending);
    // The partial new window evicted the start of the former ready window.
    // Seeking back must actually inspect/refill it, even if that read fails.
    cache->requested.store(0);
    cache->pages.collectRetired();
    auto file = (RequestTestFile *)cache->file;
    file->denied.store(true);
    const auto before = FixtureStats::reads.load();
    assert(cache->prefetch(64) == Status::failed && FixtureStats::reads > before);
    assert(cache->prefetch(64, nullptr, true) == Status::busy);
    file->denied.store(false);
    assert(cache->prefetch(64) == Status::ready);
    checkPages(*cache, 0, 64);

    auto idle = cacheAt(url);
    idle->active.store(false);
    assert(idle->prefetch(6, nullptr, true) == Status::ready);
    idle->active.store(true);
    assert(idle->prefetch(6, nullptr, true) == Status::pending);
    idle->active.store(false);
    assert(idle->prefetch(6, nullptr, true) == Status::ready);
    idle->active.store(true);
    assert(idle->prefetch(6, nullptr, true) == Status::ready);
    checkPages(*idle, 0, 6);

    std::atomic<bool> entered{false}, release{false};
    std::thread held([&] {
        std::lock_guard<std::mutex> lock(idle->decoder);
        entered.store(true);
        while (!release.load()) std::this_thread::yield();
    });
    while (!entered.load()) std::this_thread::yield();
    idle->requested.store(page * 80);
    assert(idle->prefetch(6, nullptr, true) == Status::busy);
    release.store(true); held.join();
    assert(idle->prefetch(6) == Status::ready);
    checkPages(*idle, 80, 6);
    std::cout << "PCM_REQUEST_PARTIAL_EVICTION_FAILED_BACKOFF_PENDING_INACTIVE_BUSY_OK\n";
}

static void testRetirementAndWorkers(NSURL *url) {
    auto cache = cacheAt(url);
    assert(cache->prefetch(6) == Status::ready);
    {
        auto lease = cache->pages.read();
        const auto *original = lease.get(0);
        assert(original && original->first == 0);
        cache->requested.store(page * 70);
        assert(cache->prefetch(64) == Status::ready);
        assert(cache->pages.retiredCount() > 0);
        assert(original->first == 0 && original->samples[0][0] == 0.25f);
        const auto searches = FixtureStats::lookups.load();
        assert(cache->prefetch(64, nullptr, true) == Status::ready);
        assert(FixtureStats::lookups == searches && cache->pages.retiredCount() > 0);
    }
    const auto searches = FixtureStats::lookups.load();
    assert(cache->prefetch(64, nullptr, true) == Status::ready);
    assert(FixtureStats::lookups == searches && cache->pages.retiredCount() == 0);
    auto work = [&] {
        @autoreleasepool {
            for (int i = 0; i < 100; ++i) {
                cache->requested.store((i % 2) * page * 64);
                cache->prefetch(6, nullptr, true);
            }
        }
    };
    std::thread first(work), second(work); first.join(); second.join();
    cache->requested.store(0); assert(cache->prefetch(6) == Status::ready);
    checkPages(*cache, 0, 6);
    std::cout << "PCM_REQUEST_RETIRED_LEASE_COLLECTION_TWO_PRODUCERS_OK\n";
}

static double cpuSeconds() {
    timespec value{}; clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

static void testSharedMedia(NSURL *url) {
    rlimit original{}; assert(getrlimit(RLIMIT_NOFILE, &original) == 0);
    rlimit limited = original; limited.rlim_cur = std::min<rlim_t>(original.rlim_cur, 64);
    assert(setrlimit(RLIMIT_NOFILE, &limited) == 0);
    @autoreleasepool {
        NSMutableArray<AVAudioFile *> *files = [NSMutableArray new];
        NSError *failure = nil;
        for (int i = 0; i < 119; ++i) {
            AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&failure];
            if (!file) break;
            [files addObject:file];
        }
        assert(files.count < 119 && failure);
        std::cout << "PCM_INDEPENDENT_READERS_EXHAUST_LIMIT count=" << files.count
                  << " error=" << failure.code << "\n";
    }
    std::vector<std::shared_ptr<PreparedPCMCache>> copies;
    for (int i = 0; i < 512; ++i) {
        NSError *error = nil;
        auto reader = PreparedPCMReader::open(url, &error);
        assert(reader && !error);
        if (!copies.empty()) assert(reader == copies[0]->reader);
        auto cache = std::make_shared<PreparedPCMCache>(reader);
        cache->active.store(true);
        assert(cache->prefetch(6) == Status::ready);
        checkPages(*cache, 0, 6);
        if (!copies.empty()) assert(cache->pages.producerView(0)->block == copies[0]->pages.producerView(0)->block);
        copies.push_back(cache);
    }
    assert(copies[0]->reader->blocks.size() == 2);
    auto originalBlock = copies[0]->pages.producerView(0)->block;
    copies[1]->requested.store(page * 70); copies[1]->loopStart.store(page * 70 + 5); copies[1]->loopEnd.store(page * 73 + 17);
    assert(copies[1]->prefetch(6) == Status::ready);
    checkPages(*copies[0], 0, 6);
    assert(copies[0]->pages.producerView(0)->block == originalBlock);
    auto work = [&](int index) {
        @autoreleasepool {
            auto &cache = copies[index];
            for (int i = 0; i < 100; ++i) {
                cache->requested.store((index * 10 + i % 3) * page);
                cache->prefetch(6, nullptr, true);
            }
            assert(cache->prefetch(6) == Status::ready);
            checkPages(*cache, index * 10, 6);
        }
    };
    std::thread first(work, 2), second(work, 3); first.join(); second.join();
    assert(copies[0]->reader->recentBytes <= 8 * 1024 * 1024);
    // Replacing a file at the same path cannot revive the former decoder.
    NSError *error = nil;
    assert([[NSFileManager defaultManager] removeItemAtURL:url error:&error]);
    auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    auto pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:page * 8];
    pcm.frameLength = pcm.frameCapacity;
    for (int ch = 0; ch < 2; ++ch) std::fill_n(pcm.floatChannelData[ch], pcm.frameLength, 0.5f);
    auto writer = [[AVAudioFile alloc] initForWriting:url settings:format.settings error:&error];
    assert(writer && [writer writeFromBuffer:pcm error:&error]); writer = nil;
    auto replaced = PreparedPCMReader::open(url, &error);
    assert(replaced && replaced != copies[0]->reader);
    PreparedPCMCache replacement(replaced);
    assert(replacement.prefetch(6) == Status::ready);
    assert(replacement.pages.producerView(0)->samples[0][0] == 0.5f);
    assert(originalBlock->samples[0][0] == 0.25f);
    assert(setrlimit(RLIMIT_NOFILE, &original) == 0);
    std::cout << "PCM_512_COPIES_ONE_DESCRIPTOR_SHARED_PCM_INDEPENDENT_SEEK_LOOP_WORKERS_REPLACED_FILE_OK\n";
}

static void benchmark(NSURL *url, bool baseline, int voices) {
    FixtureStats::disableHits = baseline;
    std::vector<std::shared_ptr<PreparedPCMCache>> caches;
    // Metadata-only resident pages isolate the worker's polling cost. Playback
    // correctness uses full PCM above and the existing prepared-audio fixtures.
    for (int voice = 0; voice < voices; ++voice) {
        auto cache = cacheAt(url);
        for (int i = 0; i < 6; ++i) {
            auto data = std::make_unique<PreparedPCMPage>(); data->first = i * page; data->count = page;
            cache->pages.publish(i, std::move(data));
        }
        assert(cache->prefetch(6) == Status::ready);
        caches.push_back(std::move(cache));
    }
    auto &workers = PreparedPCMWorkers::shared();
    for (const auto &cache : caches) workers.add(cache);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    const double cpu = cpuSeconds();
    const auto began = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::seconds(3));
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - began).count();
    const double consumed = cpuSeconds() - cpu;
    std::cout << "PCM_IDLE_WORKERS mode=" << (baseline ? "baseline" : "cached") << " voices=" << voices
              << " seconds=" << elapsed << " cpu_seconds=" << consumed << " cpu_percent=" << consumed / elapsed * 100 << "\n";
    for (const auto &cache : caches) cache->active.store(false);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:
            [@"catlive-pcm-request-" stringByAppendingFormat:@"%@.wav", NSUUID.UUID.UUIDString]];
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        auto pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:page * 128];
        pcm.frameLength = pcm.frameCapacity;
        std::fill_n(pcm.floatChannelData[0], pcm.frameLength, 0.25f);
        std::fill_n(pcm.floatChannelData[1], pcm.frameLength, -0.25f);
        NSError *error = nil;
        auto file = [[AVAudioFile alloc] initForWriting:url settings:format.settings error:&error];
        assert(file && [file writeFromBuffer:pcm error:&error] && !error);
        file = nil; pcm = nil;
        if (argc > 1) benchmark(url, std::string(argv[1]) == "baseline", argc > 2 ? std::atoi(argv[2]) : 256);
        else { testRequests(url); testIncomplete(url); testRetirementAndWorkers(url); testSharedMedia(url); }
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    }
    return 0;
}
