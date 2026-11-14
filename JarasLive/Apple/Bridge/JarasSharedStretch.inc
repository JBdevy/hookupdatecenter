// Included after PreparedPCMReader. Only source processing is shared. Each
// voice still owns its playhead, scheduling, end/ramp, gain and effects graph.
struct PreparedStretchKey {
    double frame = 0, speed = 1, tuning = 0, end = 0, loopStart = 0, loopEnd = 0;
    int count = 0;
    bool spectral = false;
    double source = 0;
    bool nativeTempo = false;
    bool operator==(const PreparedStretchKey &other) const {
        return frame == other.frame && speed == other.speed && tuning == other.tuning && end == other.end &&
            loopStart == other.loopStart && loopEnd == other.loopEnd && count == other.count && spectral == other.spectral && source == other.source && nativeTempo == other.nativeTempo;
    }
};
struct PreparedStretchState {
    signalsmith::stretch::SignalsmithStretch<float> pitch{0};
    static constexpr int maximumFrames = 16384;
    std::array<std::array<float, maximumFrames>, 2> output{};
    PreparedStretchKey key;
    uint64_t owner = 0, run = 0;
    bool complete = true;
    explicit PreparedStretchState(double sampleRate) { pitch.presetDefault(2, float(sampleRate), true); }
    void copyStateFrom(const PreparedStretchState &other) { pitch.copyStateFrom(other.pitch); }
};
struct PreparedStretchGroup {
    using Pool = catlive::audio::SharedRenderPool<PreparedStretchState>;
    const std::shared_ptr<PreparedPCMReader> reader;
    Pool pool;
    std::mutex preparation;
    std::array<uint64_t, 16> seeds{};
    size_t nextSeed = 0;
    explicit PreparedStretchGroup(std::shared_ptr<PreparedPCMReader> value) : reader(std::move(value)) {}
    static std::shared_ptr<PreparedStretchGroup> open(const std::shared_ptr<PreparedPCMReader> &reader, double rate) {
        static std::mutex mutex;
        using Key = std::pair<PreparedPCMReader *, double>;
        static std::map<Key, std::weak_ptr<PreparedStretchGroup>> groups;
        std::lock_guard<std::mutex> lock(mutex);
        for (auto it = groups.begin(); it != groups.end();) {
            if (it->second.expired()) it = groups.erase(it); else ++it;
        }
        const Key key{reader.get(), rate};
        auto group = groups[key].lock();
        if (!group || !group->pool.reserve(2, rate)) {
            group = std::make_shared<PreparedStretchGroup>(reader);
            // Two spare states cover simultaneous preparation while all voices
            // have a current state and render threads fork the next block.
            group->pool.reserve(4, rate);
            groups[key] = group;
        }
        return group;
    }
    Pool::Lease seed(const PreparedStretchKey &key) {
        // Control side only. A render advances by changing its generation, so
        // this weak table never revives an already consumed preparation.
        for (auto handle : seeds) {
            auto value = pool.retain(handle);
            if (value && value->key == key) return value;
        }
        return {};
    }
    void rememberSeed(const Pool::Lease &value) { seeds[nextSeed++ % seeds.size()] = value.handle(); }
};
