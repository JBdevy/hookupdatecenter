#pragma once
#include "Common.h"
#include "MediaPath.h"
namespace catlive {
// The same signed RPKL peak scale and 256/1024/... hierarchy as the Mac.
// Immutable peak files are mapped, so a whole-show view touches only its coarse
// levels. PCM detail pages and decoder work never run on the message thread.
class WaveformCache final {
  public:
    struct Peak {
        int16 high = std::numeric_limits<int16>::min(), low = std::numeric_limits<int16>::max();
        void include(Peak p) { high = std::max(high, p.high); low = std::min(low, p.low); }
    };
    static int16 encode(float value) {
        if (!std::isfinite(value)) return 0;
        const float magnitude = std::abs(value);
        const float packed = magnitude <= 1 ? magnitude * 24576 : 24576 + 1024 * std::log2(magnitude);
        return (int16)jlimit(-32768l, 32767l, std::lround(value < 0 ? -packed : packed));
    }
    static float decode(int16 value) {
        const int magnitude = std::abs((int)value);
        const float amplitude = magnitude <= 24576 ? magnitude / 24576.f : std::exp2((magnitude - 24576) / 1024.f);
        return value < 0 ? -amplitude : amplitude;
    }
    struct Data {
        struct Level { int64 step; size_t offset, count; };
        double duration = 0, sampleRate = 0;
        int64 frames = 0;
        int sourceChannels = 0, storedChannels = 0;
        File source;
        String version;
        std::vector<Level> levels;
        MemoryBlock owned;
        std::unique_ptr<MemoryMappedFile> mapping;
        const uint8 *bytes() const { return (const uint8 *)(mapping ? mapping->getData() : owned.getData()); }
        Peak at(size_t level, int channel, size_t bucket) const {
            if (level >= levels.size() || bucket >= levels[level].count) return {0, 0};
            const auto *p = bytes() + levels[level].offset + (bucket * storedChannels + jlimit(0, storedChannels - 1, channel)) * 4;
            return {(int16)ByteOrder::littleEndianShort(p), (int16)ByteOrder::littleEndianShort(p + 2)};
        }
        std::pair<float, float> range(int channel, double start, double end) const {
            if (levels.empty() || !std::isfinite(start) || !std::isfinite(end) || end <= 0 || start >= duration || end <= start) return {};
            return rangeFrames(channel, (int64)std::floor(std::max(0., start) * sampleRate + 1e-7),
                (int64)std::ceil(std::min(duration, end) * sampleRate - 1e-7));
        }
        std::pair<float, float> rangeFrames(int channel, int64 start, int64 end) const {
            if (levels.empty() || end <= start || end <= 0 || start >= frames) return {};
            size_t a = (size_t)(std::max<int64>(0, start) / 256);
            size_t b = (size_t)((std::min(frames, end) + 255) / 256);
            Peak peak;
            // Decompose into aligned hierarchy nodes. Full-show queries remain
            // logarithmic, retaining transients instead of skipping samples.
            while (a < b) {
                size_t level = 0, factor = 1;
                while (level + 1 < levels.size() && a % (factor * 4) == 0 && factor * 4 <= b - a) { ++level; factor *= 4; }
                peak.include(at(level, channel, a / factor));
                a += factor;
            }
            return peak.high < peak.low ? std::pair<float,float>{} : std::pair<float,float>{decode(peak.low), decode(peak.high)};
        }
        size_t mappedBytes() const { return mapping ? mapping->getSize() : 0; }
    };
    struct Detail {
        static constexpr int64 pageFrames = 65536;
        int64 start = 0;
        AudioBuffer<float> samples;
        float sample(int channel, int64 frame) const {
            return samples.getSample(jlimit(0, samples.getNumChannels() - 1, channel),
                jlimit(0, samples.getNumSamples() - 1, (int)(frame - start)));
        }
    };
    WaveformCache() = default;
    ~WaveformCache() { cancelled.store(true); worker.removeAllJobs(true, -1); }
    std::shared_ptr<const Data> request(const File &requested) {
        const auto key = requested.getFullPathName();
        auto found = entries.find(key);
        if (found == entries.end()) {
            // Keep even a dense whole-show view resident. Mappings do not keep
            // every fine peak page in RAM; the OS pages only the requested level.
            if (entries.size() >= 4096) {
                auto oldest = entries.end();
                for (auto it = entries.begin(); it != entries.end(); ++it)
                    if (!it->second->pending.load() && (oldest == entries.end() || it->second->used < oldest->second->used)) oldest = it;
                if (oldest != entries.end()) { entries.erase(oldest); ++evictions; }
            }
            found = entries.emplace(key, std::make_shared<Entry>()).first;
        }
        auto entry = found->second; entry->used = ++clock;
        const auto now = Time::getMillisecondCounterHiRes();
        if (!entry->pending.load() && now >= entry->checkAfter && worker.getNumJobs() < 12) {
            entry->checkAfter = now + 5000;
            entry->pending.store(true);
            worker.addJob([this, entry, requested] {
                const auto file = existingMediaPath(requested);
                const auto modified = file.getLastModificationTime().toMilliseconds(), size = file.getSize();
                if (entry->modified != modified || entry->size != size || !std::atomic_load(&entry->data)) {
                    std::shared_ptr<Data> data;
                    entry->failure.store(0);
                    const auto destination = cacheFile(file, size, modified);
                    data = readCache(destination, size, modified);
                    if (!data) {
                        // Existing Mac-generated caches can be read directly.
                        data = readCache(macCacheFile(file), size, modified);
                    }
                    if (!data && !cancelled.load()) {
                        AudioFormatManager formats; registerAudioFormats(formats);
                        std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
                        data = reader ? analyse(*reader, &cancelled) : nullptr;
                        if (!data) entry->failure.store(!file.existsAsFile() ? 1 : !reader ? 2 : 3);
                        if (data) {
                            ++analyses;
                            if (writeCache(*data, destination, size, modified)) {
                                if (auto mapped = readCache(destination, size, modified)) data = std::move(mapped);
                            }
                        }
                    } else if (data) ++diskHits;
                    if (data) { data->source = file; data->version = file.getFullPathName() + ":" + String(size) + ":" + String(modified); }
                    entry->modified = modified; entry->size = size;
                    std::atomic_store(&entry->data, std::shared_ptr<const Data>(std::move(data)));
                    ++generation;
                }
                entry->pending.store(false);
            });
        }
        return std::atomic_load(&entry->data);
    }
    std::shared_ptr<const Detail> detail(const std::shared_ptr<const Data> &data, int64 frame) {
        if (!data || data->source == File() || frame < 0 || frame >= data->frames) return {};
        const int64 start = frame / Detail::pageFrames * Detail::pageFrames;
        const auto key = data->version + ":" + String(start);
        auto it = details.find(key);
        if (it == details.end()) {
            if (details.size() >= 64) {
                auto oldest = details.end();
                for (auto i = details.begin(); i != details.end(); ++i)
                    if (!i->second->pending.load() && (oldest == details.end() || i->second->used < oldest->second->used)) oldest = i;
                if (oldest == details.end()) return {};
                details.erase(oldest);
            }
            it = details.emplace(key, std::make_shared<DetailEntry>()).first;
        }
        auto entry = it->second; entry->used = ++clock;
        if (!entry->pending.load() && !entry->attempted && worker.getNumJobs() < 16) {
            entry->attempted = true; entry->pending.store(true);
            worker.addJob([this, entry, data, start] {
                AudioFormatManager formats; registerAudioFormats(formats);
                std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(data->source));
                if (reader && !cancelled.load()) {
                    auto page = std::make_shared<Detail>(); page->start = start;
                    const int count = (int)std::min(Detail::pageFrames, data->frames - start);
                    AudioBuffer<float> input(data->sourceChannels, count);
                    if (reader->read(&input, 0, count, start, true, true)) {
                        page->samples.setSize(data->storedChannels, count);
                        for (int c = 0; c < data->sourceChannels; ++c) page->samples.copyFrom(c, 0, input, c, 0, count);
                        if (data->storedChannels > data->sourceChannels) {
                            page->samples.clear(data->sourceChannels, 0, count);
                            for (int c = 0; c < data->sourceChannels; ++c)
                                page->samples.addFrom(data->sourceChannels, 0, input, c, 0, count, 1.f / data->sourceChannels);
                        }
                        std::atomic_store(&entry->data, std::shared_ptr<const Detail>(std::move(page)));
                        ++generation;
                    }
                }
                entry->pending.store(false);
            });
        }
        return std::atomic_load(&entry->data);
    }
    // Project opening performs the same analysis/cache validation as the grid,
    // on its worker. The viewport can then map the prepared peaks immediately.
    static std::shared_ptr<const Data> cachedMetadata(const File &requested) {
        const auto file = existingMediaPath(requested);
        if (!file.existsAsFile()) return {};
        const auto size = file.getSize(), modified = file.getLastModificationTime().toMilliseconds();
        auto data = readCache(cacheFile(file, size, modified), size, modified);
        if (!data) data = readCache(macCacheFile(file), size, modified);
        return data;
    }
    static void preload(const File &requested, const std::atomic<bool> *cancel = nullptr) {
        if (cancel && cancel->load()) return;
        const auto file = existingMediaPath(requested);
        if (!file.existsAsFile()) return;
        const auto size = file.getSize(), modified = file.getLastModificationTime().toMilliseconds();
        const auto target = cacheFile(file, size, modified);
        if (readCache(target, size, modified) || readCache(macCacheFile(file), size, modified)) return;
        AudioFormatManager formats; registerAudioFormats(formats);
        std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
        if (reader) if (auto data = analyse(*reader, cancel)) writeCache(*data, target, size, modified);
    }
    // BPM detection uses the same validated peak hierarchy as the timeline.
    // Reopening a decoder must not decode the complete show a second time just
    // to locate attacks that are already present in a prepared waveform cache.
    static std::shared_ptr<Data> forAnalysis(const File &requested, AudioFormatReader &reader,
                                              const std::atomic<bool> *cancel = nullptr) {
        if (cancel && cancel->load()) return {};
        const auto file = existingMediaPath(requested);
        const auto size = file.getSize(), modified = file.getLastModificationTime().toMilliseconds();
        const auto destination = cacheFile(file, size, modified);
        auto data = readCache(destination, size, modified);
        if (!data) data = readCache(macCacheFile(file), size, modified);
        if (data && (data->frames != reader.lengthInSamples || data->sampleRate != reader.sampleRate ||
                     data->sourceChannels != (int)reader.numChannels)) data.reset();
        if (!data) {
            data = analyse(reader, cancel);
            if (data && !(cancel && cancel->load())) writeCache(*data, destination, size, modified);
        }
        return data;
    }
    static std::shared_ptr<Data> analyse(AudioFormatReader &reader, const std::atomic<bool> *cancel = nullptr) {
        if (reader.lengthInSamples <= 0 || reader.sampleRate <= 0 || reader.numChannels == 0 || reader.numChannels > 64) return {};
        auto data = std::make_shared<Data>();
        data->sampleRate = reader.sampleRate; data->frames = reader.lengthInSamples;
        data->duration = data->frames / data->sampleRate;
        data->sourceChannels = (int)reader.numChannels;
        data->storedChannels = data->sourceChannels + (data->sourceChannels > 1 ? 1 : 0);
        size_t bins = (size_t)((data->frames + 255) / 256);
        if (bins > (size_t)std::numeric_limits<int>::max() / (data->storedChannels * 4)) return {};
        std::vector<Peak> peaks(bins * data->storedChannels);
        AudioBuffer<float> buffer(data->storedChannels, 32768);
        for (int64 at = 0; at < data->frames; at += buffer.getNumSamples()) {
            if (cancel && cancel->load()) return {};
            const auto count = (int)std::min<int64>(buffer.getNumSamples(), data->frames - at);
            if (!reader.read(&buffer, 0, count, at, true, true)) return {};
            if (data->storedChannels > data->sourceChannels) {
                buffer.clear(data->sourceChannels, 0, count);
                for (int c = 0; c < data->sourceChannels; ++c)
                    buffer.addFrom(data->sourceChannels, 0, buffer, c, 0, count, 1.f / data->sourceChannels);
            }
            for (int offset = 0; offset < count; offset += 256) {
                const size_t bucket = (size_t)((at + offset) / 256) * data->storedChannels;
                for (int c = 0; c < data->storedChannels; ++c) {
                    const auto range = FloatVectorOperations::findMinAndMax(buffer.getReadPointer(c, offset), std::min(256, count - offset));
                    peaks[bucket + c] = {encode(range.getEnd()), encode(range.getStart())};
                }
            }
        }
        MemoryOutputStream out;
        int64 step = 256;
        for (;;) {
            data->levels.push_back({step, out.getDataSize(), bins});
            for (const auto p : peaks) { out.writeShort(p.high); out.writeShort(p.low); }
            if (bins <= 1 || step >= (1 << 26)) break;
            const size_t nextBins = (bins + 3) / 4;
            std::vector<Peak> next(nextBins * data->storedChannels);
            for (size_t i = 0; i < bins; ++i)
                for (int c = 0; c < data->storedChannels; ++c) next[(i / 4) * data->storedChannels + c].include(peaks[i * data->storedChannels + c]);
            peaks = std::move(next); bins = nextBins; step *= 4;
        }
        data->owned = out.getMemoryBlock();
        return data;
    }
    static double sourcePosition(const jaras::AudioClip &clip, double local) {
        const double source = clip.sourceOffset + std::max(0., local) * std::max(.001, clip.playbackRate);
        const double loop = clip.loopLength.value_or(0), start = clip.loopStart.value_or(0);
        return loop > 0 && source >= start ? start + std::fmod(source - start, loop) : source;
    }
    static int64 step(double sampleRate, double sourceScale) {
        const double samples = std::max(1., sampleRate / std::max(.001, sourceScale) / 2);
        if (samples < 256) {
            int64 selected = 1;
            for (int64 detail : {1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 80, 96, 128, 192})
                if (detail <= samples) selected = detail;
            return selected;
        }
        return (int64)1 << jlimit(0, 26, (int)std::floor(std::log2(samples)));
    }
    uint64 revision() const { return generation.load(); }
    var diagnostics() const {
        auto result = object(); int ready = 0, pending = 0; int64 mapped = 0, owned = 0;
        for (const auto &entry : entries) {
            if (auto data = std::atomic_load(&entry.second->data)) { ++ready; mapped += (int64)data->mappedBytes(); owned += (int64)data->owned.getSize(); }
            pending += entry.second->pending.load();
        }
        Array<var> failures;
        for (const auto &entry : entries) if (entry.second->failure.load() && failures.size() < 8) {
            auto item = object(); put(item, "path", entry.first); put(item, "stage", entry.second->failure.load()); failures.add(item);
        }
        put(result, "failures", failures);
        put(result, "sources", (int)entries.size()); put(result, "ready", ready); put(result, "pending", pending);
        put(result, "mappedBytes", mapped); put(result, "ownedPeakBytes", owned);
        put(result, "detailPages", (int)details.size()); put(result, "analyses", (int64)analyses.load());
        put(result, "diskHits", (int64)diskHits.load()); put(result, "evictions", (int64)evictions);
        return result;
    }
    static bool writeCache(const Data &data, const File &destination, int64 size, int64 modified) {
        MemoryOutputStream out;
        out.write("JARASPK4", 8); out.writeInt64(size);
        out.writeDouble(modified / 1000. - 978307200.); // Foundation reference date (2001).
        out.writeDouble(data.sampleRate); out.writeInt64(data.frames);
        out.writeInt(data.storedChannels); out.writeInt((int)data.levels.size());
        size_t offset = 48 + data.levels.size() * 24;
        for (const auto &level : data.levels) {
            const size_t bytes = level.count * data.storedChannels * 4;
            out.writeInt64(level.step); out.writeInt64((int64)offset); out.writeInt64((int64)bytes); offset += bytes;
        }
        for (const auto &level : data.levels) out.write(data.bytes() + level.offset, level.count * data.storedChannels * 4);
        if (destination.getParentDirectory().createDirectory().failed()) return false;
        return destination.replaceWithData(out.getData(), out.getDataSize());
    }
    static std::shared_ptr<Data> readCache(const File &file, int64 size, int64 modified) {
        auto mapping = std::make_unique<MemoryMappedFile>(file, MemoryMappedFile::readOnly);
        const auto length = mapping->getSize();
        if (!mapping->getData() || length < 72 || length > (size_t)2 * 1024 * 1024 * 1024) return {};
        MemoryInputStream input(mapping->getData(), length, false);
        char magic[8]; input.read(magic, 8);
        if (std::memcmp(magic, "JARASPK4", 8) || input.readInt64() != size) return {};
        const double stamp = input.readDouble();
        if (!std::isfinite(stamp) || std::abs(stamp - (modified / 1000. - 978307200.)) > .002) return {};
        auto data = std::make_shared<Data>(); data->sampleRate = input.readDouble(); data->frames = input.readInt64();
        data->storedChannels = input.readInt(); const int count = input.readInt();
        if (!std::isfinite(data->sampleRate) || data->sampleRate < 1000 || data->sampleRate > 768000 || data->frames <= 0 || data->storedChannels < 1 || data->storedChannels > 65 || count < 1 || count > 16) return {};
        data->sourceChannels = data->storedChannels > 1 ? data->storedChannels - 1 : 1;
        data->duration = data->frames / data->sampleRate;
        int64 expectedStep = 256; size_t expectedOffset = 48 + count * 24;
        for (int i = 0; i < count; ++i) {
            const int64 step = input.readInt64(), offset = input.readInt64(), bytes = input.readInt64();
            if (step != expectedStep || offset < 0 || (size_t)offset != expectedOffset || bytes < 0 || expectedOffset > length || (uint64)bytes > length - expectedOffset) return {};
            const int64 bins = (data->frames - 1) / step + 1;
            if (bins > (int64)length / (data->storedChannels * 4) || bytes != bins * data->storedChannels * 4) return {};
            data->levels.push_back({step, (size_t)offset, (size_t)bins}); expectedOffset += (size_t)bytes; expectedStep *= 4;
        }
        if (expectedOffset != length || (data->levels.back().step < (1 << 26) && data->levels.back().count != 1)) return {};
        data->mapping = std::move(mapping);
        return data;
    }
  private:
    static File macCacheFile(const File &file) {
        for (auto parent = file.getParentDirectory(); parent != parent.getParentDirectory(); parent = parent.getParentDirectory())
            if (parent.getFileName().equalsIgnoreCase("Stems")) return parent.getChildFile("WF").getChildFile(file.getRelativePathFrom(parent) + ".waveform");
        return file.getParentDirectory().getChildFile("Stems/WF").getChildFile(file.getFileName() + ".waveform");
    }
    static File cacheFile(const File &file, int64 size, int64 modified) {
        String identity = file.getFullPathName();
        // Copies of a project can share a Stems junction; share its cache too.
        const auto handle = CreateFileW(file.getFullPathName().toWideCharPointer(), FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (handle != INVALID_HANDLE_VALUE) {
            wchar_t buffer[32768];
            const auto length = GetFinalPathNameByHandleW(handle, buffer, 32768, FILE_NAME_NORMALIZED);
            if (length > 0 && length < 32768) identity = String(buffer);
            CloseHandle(handle);
        }
        identity += ":" + String(size) + ":" + String(modified);
        return File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive/waveforms")
            .getChildFile(String::toHexString(identity.hashCode64()) + ".waveform");
    }
    struct Entry { uint64 used = 0; double checkAfter = 0; int64 modified = -1, size = -1;
        std::atomic<bool> pending{false}; std::atomic<int> failure{0}; std::shared_ptr<const Data> data; };
    struct DetailEntry { uint64 used = 0; bool attempted = false; std::atomic<bool> pending{false}; std::shared_ptr<const Detail> data; };
    std::map<String, std::shared_ptr<Entry>> entries;
    std::map<String, std::shared_ptr<DetailEntry>> details;
    uint64 clock = 0, evictions = 0;
    std::atomic<uint64> generation{0}, analyses{0}, diskHits{0};
    std::atomic<bool> cancelled{false};
    ThreadPool worker{2};
};
}
