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
    // Large device pulls are split by the source renderer. Keep scratch per voice
    // and history bounded to a single render batch, including inactive transition voices.
    static constexpr int maximumFrames = 4096;
    std::array<std::array<float, maximumFrames>, 2> output{};
    PreparedStretchKey key;
    uint64_t owner = 0, run = 0;
    bool complete = true;
    explicit PreparedStretchState(double sampleRate) {
        pitch.presetDefault(2, float(sampleRate), true);
        PreparedAudioMemory::stretchStates.fetch_add(1, std::memory_order_relaxed);
    }
    ~PreparedStretchState() { PreparedAudioMemory::stretchStates.fetch_sub(1, std::memory_order_relaxed); }
    void copyStateFrom(const PreparedStretchState &other) { pitch.copyStateFrom(other.pitch); }
};
struct PreparedStretchGroup {
    using Pool = catlive::audio::SharedRenderPool<PreparedStretchState>;
    const std::shared_ptr<PreparedPCMReader> reader;
    Pool pool;
    std::mutex preparation;
    uint32_t registeredVoices = 0, activeVoices = 0, reservedStates = 0;
    std::array<uint64_t, 16> seeds{};
    size_t nextSeed = 0;
    explicit PreparedStretchGroup(std::shared_ptr<PreparedPCMReader> value) : reader(std::move(value)) {}
    bool reserveStates(uint32_t count, double rate) {
        if (count > reservedStates) {
            if (!pool.reserve(count - reservedStates, rate)) return false;
            reservedStates = count;
        }
        pool.restoreUnused(count, rate);
        return true;
    }
    void trimStoppedTransitionStorage() {
        std::vector<std::unique_ptr<PreparedStretchState>> retired;
        {
            std::lock_guard<std::mutex> lock(preparation);
            if (registeredVoices <= 2 && activeVoices <= 1)
                retired = pool.trimUnusedIfUnshared(activeVoices == 0);
        }
        // Large FFT allocations are freed after releasing the preparation lock.
    }
    bool prepareActivation(double rate) {
        std::lock_guard<std::mutex> lock(preparation);
        const auto required = registeredVoices <= 2 && activeVoices == 0
            ? registeredVoices : registeredVoices * 2 - 1;
        return reserveStates(required, rate);
    }
    bool activate(double rate) {
        std::lock_guard<std::mutex> lock(preparation);
        const auto count = activeVoices + 1;
        // One sounding voice plus its stopped transition needs one pinned
        // seed and one working history. Concurrent voices can fork converter
        // prefixes independently, so reserve their full pool before starting.
        const auto required = registeredVoices <= 2 && count <= 1
            ? registeredVoices : registeredVoices * 2 - 1;
        if (!reserveStates(required, rate)) return false;
        activeVoices = count;
        return true;
    }
    void deactivate() {
        std::lock_guard<std::mutex> lock(preparation);
        assert(activeVoices); --activeVoices;
    }
    static std::shared_ptr<PreparedStretchGroup> open(const std::shared_ptr<PreparedPCMReader> &reader, double rate, bool deferInactive = false) {
        static std::mutex mutex;
        using Key = std::pair<PreparedPCMReader *, double>;
        static std::map<Key, std::weak_ptr<PreparedStretchGroup>> groups;
        std::lock_guard<std::mutex> lock(mutex);
        for (auto it = groups.begin(); it != groups.end();) {
            if (it->second.expired()) it = groups.erase(it); else ++it;
        }
        const Key key{reader.get(), rate};
        auto group = groups[key].lock();
        auto registerVoice = [&](const std::shared_ptr<PreparedStretchGroup> &value) {
            std::lock_guard<std::mutex> lock(value->preparation);
            const auto members = value->registeredVoices + 1;
            const auto count = deferInactive && members <= 2 && value->activeVoices <= 1
                ? members : members * 2 - 1;
            if (!value->reserveStates(count, rate)) return false;
            value->registeredVoices = members;
            return true;
        };
        if (!group || !registerVoice(group)) {
            group = std::make_shared<PreparedStretchGroup>(reader);
            // The first independent voice advances its history in place and
            // cannot fork. Further voices reserve two states above before
            // sharing it. Reserving four here tripled the DSP storage of a
            // source plus its idle transition voice (six states versus three).
            registerVoice(group);
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
