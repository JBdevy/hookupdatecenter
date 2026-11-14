#pragma once
#include "Common.h"
// All Windows users of Signalsmith include this header, including NativeFX.
#ifndef CATLIVE_SIGNALSMITH_STATE_COPY
#define CATLIVE_SIGNALSMITH_STATE_COPY 1
#endif
#ifndef CATLIVE_SIGNALSMITH_BATCH_OUTPUT
#define CATLIVE_SIGNALSMITH_BATCH_OUTPUT 1
#endif
#include "../ThirdParty/Signalsmith/signalsmith-stretch.h"
#include "../../Core/Audio/SharedRenderPool.hpp"

namespace catlive {
// Exact, interned timing identity. Interning runs on control, never in render.
// The monotonically increasing ID prevents an expired mapping from aliasing a
// cached result even when its allocation address is reused.
struct ClipAudioMapping {
    uint64_t id;
    static std::shared_ptr<const ClipAudioMapping> intern(std::vector<double> values) {
        static std::mutex mutex;
        static uint64_t next = 0;
        static std::map<std::vector<double>, std::weak_ptr<const ClipAudioMapping>> mappings;
        std::lock_guard<std::mutex> lock(mutex);
        for(auto it=mappings.begin();it!=mappings.end();)
            if(it->second.expired())it=mappings.erase(it);else ++it;
        auto& weak=mappings[std::move(values)];
        if(auto found=weak.lock())return found;
        auto value=std::make_shared<ClipAudioMapping>();value->id=++next;weak=value;return value;
    }
};
struct ClipAudioRenderKey {
    uint64_t mapping=0;
    const AudioFormatReader* reader=nullptr;
    double local=0,next=-1,ahead=0,semitones=0;
    int count=0;
    bool operator==(const ClipAudioRenderKey& b) const noexcept {
        return mapping==b.mapping && reader==b.reader && local==b.local && next==b.next &&
            ahead==b.ahead && semitones==b.semitones && count==b.count;
    }
};
struct ClipAudioRenderState {
    static constexpr int maximumFrames=4096;
    signalsmith::stretch::SignalsmithStretch<float> pitch{0};
    AudioBuffer<float> input,output;
    ClipAudioRenderKey key;
    double next=-1,ahead=0,semitones=0;
    bool ok=false;
    explicit ClipAudioRenderState(double rate) {
        pitch.presetDefault(2,float(rate),true);
        input.setSize(2,std::max(maximumFrames,pitch.outputSeekLength(1.f)));input.clear();
        output.setSize(2,maximumFrames);output.clear();
    }
};
struct ClipAudioRenderGroup {
    using Pool=audio::SharedRenderPool<ClipAudioRenderState>;
    const std::shared_ptr<void> source;
    Pool pool;
    std::array<uint64_t,16> seeds{};
    size_t nextSeed=0;
    explicit ClipAudioRenderGroup(std::shared_ptr<void> owner):source(std::move(owner)){}
    static std::shared_ptr<ClipAudioRenderGroup> open(const std::shared_ptr<void>& source,double rate) {
        static std::mutex mutex;
        static std::map<std::pair<void*,double>,std::weak_ptr<ClipAudioRenderGroup>> groups;
        std::lock_guard<std::mutex> lock(mutex);
        for(auto it=groups.begin();it!=groups.end();)
            if(it->second.expired())it=groups.erase(it);else ++it;
        auto& weak=groups[{source.get(),rate}];auto group=weak.lock();
        if(!group || !group->pool.reserve(2,rate)) {
            group=std::make_shared<ClipAudioRenderGroup>(source);
            // Two heads per voice, plus space to fork a shared history.
            group->pool.reserve(4,rate);weak=group;
        }
        return group;
    }
    Pool::Lease seed() {
        for(auto handle:seeds) {
            auto state=pool.retain(handle);
            if(state && state->key.mapping==0)return state;
        }
        auto state=pool.acquire();
        jassert(state);
        state->pitch.reset();state->key={};state->ok=false;
        seeds[nextSeed++%seeds.size()]=state.handle();return state;
    }
};
}
