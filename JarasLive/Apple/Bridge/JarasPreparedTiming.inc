// One immutable set of source controls is borrowed for the whole graph pull.
// Publishing between two source pulls must not apply a BPM edit to only part
// of the project: those histories would diverge permanently after the edit.
#include "../../Core/Audio/SingleReaderSlots.hpp"
#include <mutex>
#include <optional>
#include <unordered_map>

namespace {
struct PreparedTimingValue {
    uint64_t run = 0;
    double rate = 1, pitch = 0;
};
struct PreparedTimingState {
    using Values = std::unordered_map<uint64_t, PreparedTimingValue>;
    using Slots = catlive::audio::SingleReaderSlots<Values, 1>;
    Slots snapshots;
    std::optional<Slots::Lease> renderLease;
    std::atomic<const Values *> rendering{nullptr};
    std::mutex control;
    Values draft;
    unsigned depth = 0;
    bool dirty = false;
    void publish() {
        if (dirty && !depth) {
            snapshots.publish(0, std::make_unique<Values>(draft));
            dirty = false;
        }
    }
    void beginUpdates() { std::lock_guard<std::mutex> lock(control); ++depth; }
    void endUpdates() {
        std::lock_guard<std::mutex> lock(control);
        assert(depth); --depth; publish();
    }
    void set(uint64_t id, PreparedTimingValue value) {
        std::lock_guard<std::mutex> lock(control);
        const auto prior = draft.find(id);
        if (prior != draft.end() && prior->second.run == value.run &&
            prior->second.rate == value.rate && prior->second.pitch == value.pitch) return;
        draft[id] = value; dirty = true; publish();
    }
    void remove(uint64_t id) {
        std::lock_guard<std::mutex> lock(control);
        if (draft.erase(id)) { dirty = true; publish(); }
    }
    void beginRender() {
        assert(!renderLease);
        renderLease.emplace(snapshots);
        rendering.store(renderLease->get(0), std::memory_order_release);
    }
    void endRender() {
        rendering.store(nullptr, std::memory_order_release);
        renderLease.reset();
    }
    bool read(uint64_t id, uint64_t run, double &rate, double &pitch) const {
        const auto *values = rendering.load(std::memory_order_acquire);
        if (!values) return false;
        const auto entry = values->find(id);
        if (entry == values->end() || entry->second.run != run) return false;
        rate = entry->second.rate; pitch = entry->second.pitch;
        return true;
    }
};
}

@interface JarasPreparedClipTiming ()
- (std::shared_ptr<PreparedTimingState>)preparedTimingState;
- (void)addRenderSource:(std::shared_ptr<PreparedRenderSource>)source;
- (void)removeRenderSource:(PreparedRenderSource *)source;
@end
@implementation JarasPreparedClipTiming {
    AUAudioUnit *_unit;
    NSInteger _observer;
    std::shared_ptr<PreparedTimingState> _state;
    std::shared_ptr<PreparedRenderSources> _sources;
}
- (instancetype)initWithEngine:(AVAudioEngine *)engine {
    if ((self = [super init])) {
        _state = std::make_shared<PreparedTimingState>();
        _sources = std::make_shared<PreparedRenderSources>();
        _unit = engine.mainMixerNode.AUAudioUnit;
        auto state = _state;
        auto sources = _sources;
        _observer = [_unit tokenByAddingRenderObserver:^(AudioUnitRenderActionFlags flags,
            const AudioTimeStamp *time, AVAudioFrameCount frames, NSInteger bus) {
            if (flags & kAudioUnitRenderAction_PreRender) {
                if(jaras::realtimeClock.host && (time->mFlags & kAudioTimeStampSampleTimeValid))
                    jaras::realtimeClock.sample=time->mSampleTime;
                sources->finish();
                state->endRender();
                state->beginRender(); sources->prepare(frames);
            }
            if (flags & (kAudioUnitRenderAction_PostRender | kAudioUnitRenderAction_PostRenderError)) { sources->finish(); state->endRender(); }
        }];
    }
    return self;
}
- (std::shared_ptr<PreparedTimingState>)preparedTimingState { return _state; }
- (void)addRenderSource:(std::shared_ptr<PreparedRenderSource>)source { _sources->add(std::move(source)); }
- (void)removeRenderSource:(PreparedRenderSource *)source { _sources->remove(source); }
- (void)beginUpdates { _state->beginUpdates(); }
- (void)endUpdates { _state->endUpdates(); }
- (void)dealloc { [_unit removeRenderObserver:_observer]; }
@end
