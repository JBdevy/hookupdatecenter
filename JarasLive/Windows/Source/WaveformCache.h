#pragma once
#include "Common.h"
namespace catlive {
// Separate, bounded analysis cache: opening a Mac document never rewrites it.
// Decoders and sample reads run on one worker, not the UI or audio callback.
class WaveformCache final {
  public:
    struct Data {
        double duration = 0;
        int64 samplesPerBin = 256;
        double sampleRate = 0;
        std::vector<std::vector<std::pair<float, float>>> channels;
        std::pair<float, float> range(int channel, double start, double end) const {
            if (channels.empty() || end <= 0 || start >= duration) return {};
            const auto &peaks = channels[(size_t)jlimit(0, (int)channels.size() - 1, channel)];
            if (peaks.empty()) return {};
            auto a = (size_t)jlimit<int64>(0, peaks.size() - 1, (int64)(std::max(0., start) * sampleRate / samplesPerBin));
            auto b = (size_t)jlimit<int64>(a, peaks.size() - 1, (int64)(std::max(start, end) * sampleRate / samplesPerBin));
            std::pair<float, float> result{};
            for (auto i = a; i <= b; ++i) { result.first = std::min(result.first, peaks[i].first); result.second = std::max(result.second, peaks[i].second); }
            return result;
        }
    };
    WaveformCache() = default;
    ~WaveformCache() { cancelled.store(true); worker.removeAllJobs(true, -1); }
    std::shared_ptr<const Data> request(const File &file) {
        const auto key = file.getFullPathName();
        auto found = entries.find(key);
        if (found == entries.end()) {
            if (entries.size() >= 32) {
                auto oldest = std::min_element(entries.begin(), entries.end(), [](auto &a, auto &b) { return a.second->used < b.second->used; });
                entries.erase(oldest);
            }
            found = entries.emplace(key, std::make_shared<Entry>()).first;
        }
        auto entry = found->second; entry->used = ++clock;
        const auto now = Time::getMillisecondCounterHiRes();
        if (!entry->pending.load() && now >= entry->checkAfter && worker.getNumJobs() < 32) {
            entry->checkAfter = now + 5000;
            entry->pending.store(true);
            worker.addJob([this, entry, file] {
                const auto modified = file.getLastModificationTime().toMilliseconds(), size = file.getSize();
                if (entry->modified != modified || entry->size != size || !std::atomic_load(&entry->data)) {
                    AudioFormatManager formats; formats.registerBasicFormats();
                    std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
                    auto data = reader ? analyse(*reader, &cancelled) : nullptr;
                    entry->modified = modified; entry->size = size;
                    std::atomic_store(&entry->data, std::shared_ptr<const Data>(std::move(data)));
                    ++generation;
                }
                entry->pending.store(false);
            });
        }
        return std::atomic_load(&entry->data);
    }
    static std::shared_ptr<Data> analyse(AudioFormatReader &reader, const std::atomic<bool> *cancel = nullptr) {
        if (reader.lengthInSamples <= 0 || reader.sampleRate <= 0) return {};
        auto data = std::make_shared<Data>();
        data->sampleRate = reader.sampleRate;
        data->duration = reader.lengthInSamples / reader.sampleRate;
        data->samplesPerBin = std::max<int64>(256, (reader.lengthInSamples + 65535) / 65536);
        const auto bins = (size_t)((reader.lengthInSamples + data->samplesPerBin - 1) / data->samplesPerBin);
        data->channels.resize(std::min(2u, reader.numChannels), std::vector<std::pair<float,float>>(bins));
        AudioBuffer<float> buffer((int)data->channels.size(), 32768);
        for (int64 at = 0; at < reader.lengthInSamples; at += buffer.getNumSamples()) {
            if (cancel && cancel->load()) return {};
            const auto count = (int)std::min<int64>(buffer.getNumSamples(), reader.lengthInSamples - at);
            if (!reader.read(&buffer, 0, count, at, true, true)) return {};
            for (int ch = 0; ch < buffer.getNumChannels(); ++ch)
                for (int n = 0; n < count; ++n) {
                    auto &peak = data->channels[(size_t)ch][(size_t)((at + n) / data->samplesPerBin)];
                    const auto v = buffer.getSample(ch, n);
                    if (std::isfinite(v)) { peak.first = std::min(peak.first, v); peak.second = std::max(peak.second, v); }
                }
        }
        return data;
    }
    static double sourcePosition(const jaras::AudioClip &clip, double local) {
        const double source = clip.sourceOffset + std::max(0., local) * std::max(.001, clip.playbackRate);
        const double loop = clip.loopLength.value_or(0), start = clip.loopStart.value_or(0);
        return loop > 0 && source >= start ? start + std::fmod(source - start, loop) : source;
    }
    uint64 revision() const { return generation.load(); }
    var diagnostics() const {
        auto result = object(); int ready = 0, pending = 0;
        for (const auto &entry : entries) { ready += std::atomic_load(&entry.second->data) != nullptr; pending += entry.second->pending.load(); }
        Array<var> details;
        for (const auto &entry : entries) if (auto data = std::atomic_load(&entry.second->data)) {
            auto item = object(); put(item, "file", File(entry.first).getFileName()); put(item, "duration", data->duration);
            double peak = 0; for (auto &channel : data->channels) for (auto value : channel) peak = std::max(peak, (double)std::max(std::abs(value.first), std::abs(value.second)));
            put(item, "peak", peak); details.add(item);
        }
        put(result, "details", details);
        put(result, "sources", (int)entries.size()); put(result, "ready", ready); put(result, "pending", pending);
        return result;
    }
  private:
    struct Entry {
        uint64 used = 0; double checkAfter = 0;
        int64 modified = -1, size = -1;
        std::atomic<bool> pending{false};
        std::shared_ptr<const Data> data;
    };
    std::map<String, std::shared_ptr<Entry>> entries;
    uint64 clock = 0;
    std::atomic<uint64> generation{0};
    std::atomic<bool> cancelled{false};
    ThreadPool worker{1};
};
}
