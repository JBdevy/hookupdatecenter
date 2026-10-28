#pragma once
#include "Common.h"
#include "../../Core/Timecode/TimecodePlayback.hpp"
#include "../../Core/MIDI/ProgramChangePlayback.hpp"
namespace catlive {
// MIDI driver calls and endpoint enumeration stay off the audio callback.
class TimecodeMIDI final : private Thread {
public:
    TimecodeMIDI() : Thread("CatLive track MTC") { startThread(); }
    ~TimecodeMIDI() override { signalThreadShouldExit(); notify(); stopThread(3000); }
    static int destinationID(const String& identifier) {
        return static_cast<int>(static_cast<uint32>(identifier.hashCode()) & 0x7fffffffu) | 1;
    }
    static int outputSlotID(int slot) { return -1000001-slot; }
    void programChanges(const jaras::Song &song) {
        const ScopedLock guard(lock);pcMarkers.clear();pcSlot=0;pcMuted=false;
        const bool solo=std::any_of(song.tracks.begin(),song.tracks.end(),[](const auto&t){return t.solo;});
        for(const auto &t:song.tracks)if(t.role.id=="programChange") {
            pcMarkers=t.programChanges;pcSlot=t.midiOutput.value_or(0);pcMuted=t.mute||(solo&&!t.solo);break;
        }
        std::stable_sort(pcMarkers.begin(),pcMarkers.end(),[](const auto&a,const auto&b){return a.position<b.position;});
        ++pcGeneration;notify();
    }
    void publishProgramClocks(const std::array<double,2> &at,const std::array<bool,2> &play,
                              bool permitted,double blockSeconds,uint64 promotion)noexcept {
        pcClockSequence.fetch_add(1,std::memory_order_acq_rel);
        for(size_t head=0;head<2;++head) {
            auto &clock=pcClocks[head];
            const bool jump=play[head]!=clock.play.load(std::memory_order_relaxed) || std::abs(at[head]-clock.last-(play[head]?blockSeconds:0))>.002;
            clock.last=at[head];clock.at.store(at[head],std::memory_order_relaxed);
            clock.host.store(Time::getMillisecondCounterHiRes()*.001,std::memory_order_relaxed);
            clock.play.store(play[head],std::memory_order_relaxed);clock.allowed.store(permitted,std::memory_order_relaxed);
            if(jump){clock.jumpAt.store(at[head],std::memory_order_relaxed);clock.jump.fetch_add(1,std::memory_order_relaxed);}
        }
        pcPromotion.store(promotion,std::memory_order_relaxed);
        pcClockSequence.fetch_add(1,std::memory_order_release);
    }
    void setOutputSlot(int slot, const String &identifier) {
        if (slot < 0 || slot >= 6) return;
        const ScopedLock guard(lock); outputs[size_t(slot)] = identifier.isEmpty() ? 0 : destinationID(identifier); ++generation; notify();
    }
    void prepare(jaras::TimecodeProgram program, double end, bool mute) {
        const ScopedLock guard(lock);
        prepared = std::move(program); duration = end; muted = mute; running = false; ++generation;
    }
    void updateProgram(jaras::TimecodeProgram program, double end, bool mute) {
        // Item edge edits retain the running transport and its current anchor.
        const ScopedLock guard(lock);
        std::swap(prepared, program); duration = end; muted = mute; ++generation;
        notify();
    }
    void transport(double at, bool play, bool loop, double begin, double end,
                   double stop, int preferred, bool permitted) {
        const ScopedLock guard(lock);
        position = at; running = play; looping = loop && end > begin;
        loopStart = begin; loopEnd = end; stopAt = stop; selected = preferred;
        allowed = permitted; anchor = Time::getMillisecondCounterHiRes() * .001; ++generation;
        notify();
    }
    void updateRouting(bool loop, double begin, double end, double stop, int preferred) {
        const ScopedLock guard(lock);
        looping=loop && end>begin; loopStart=begin; loopEnd=end; stopAt=stop; selected=preferred;
        ++generation; notify();
    }
    // The render thread only publishes atomics. Device enumeration and MIDI
    // transmission remain on this worker, following the compensated timeline.
    void publishAudioClock(double at,bool play,bool enabled,double blockSeconds)noexcept {
        if(play!=audioPlaying.load(std::memory_order_relaxed)||std::abs(at-(lastAudioPosition+(play?blockSeconds:0)))>.002)audioGeneration.fetch_add(1,std::memory_order_relaxed);
        lastAudioPosition=at;audioPosition.store(at,std::memory_order_relaxed);
        audioAnchor.store(Time::getMillisecondCounterHiRes()*.001,std::memory_order_relaxed);
        audioPlaying.store(play,std::memory_order_relaxed);audioClockEnabled.store(enabled,std::memory_order_release);
    }
    void mute(bool value) { const ScopedLock guard(lock); if (muted != value) { muted = value; ++generation; notify(); } }
    void stop() { const ScopedLock guard(lock); allowed = false; running = false; ++generation; notify(); }
private:
    std::atomic<double> audioPosition{0},audioAnchor{0};
    std::atomic<bool> audioPlaying{false},audioClockEnabled{false};
    std::atomic<uint64> audioGeneration{0};
    double lastAudioPosition=0;
    struct PCClock { std::atomic<double> at{0},host{0},jumpAt{0}; std::atomic<bool> play{false},allowed{false}; std::atomic<uint64> jump{0}; double last=0; };
    std::array<PCClock,2> pcClocks;
    std::atomic<uint64> pcClockSequence{0},pcPromotion{0};
    std::vector<jaras::ProgramChangeMarker> pcMarkers;
    int pcSlot=0;bool pcMuted=false;uint64 pcGeneration=0;
    CriticalSection lock;
    std::array<int,6> outputs{};
    jaras::TimecodeProgram prepared;
    double position = 0, anchor = 0, duration = 0, loopStart = 0, loopEnd = 0;
    double stopAt = std::numeric_limits<double>::infinity();
    bool running = false, looping = false, muted = false, allowed = false;
    int selected = -1;
    uint64 generation = 0;
    void run() override {
        std::unique_ptr<MidiOutput> output;
        int destination = 0,previousMTCDestination=0;
        std::map<int,std::unique_ptr<MidiOutput>> pcOutputs;
        jaras::ProgramChangeCursor pcCursor[2];
        uint64 seenPromotion=0,seenPC=~uint64(0),pcJump[2]{~uint64(0),~uint64(0)};
        uint64 seen = ~uint64(0),seenAudio=~uint64(0);
        const jaras::TimecodeProgram::Span* previous = nullptr;
        double baseHost = 0, baseTime = 0, lastPosition = -1;
        int64 quarter = -1;
        jaras::NativeMtcTimeFields fields;
        while (!threadShouldExit()) {
            {
                const ScopedLock guard(lock);
                const auto now = Time::getMillisecondCounterHiRes() * .001;
                const bool compensated=audioClockEnabled.load(std::memory_order_acquire);
                const bool advancing=compensated?audioPlaying.load(std::memory_order_relaxed):running;
                const auto audioSerial=audioGeneration.load(std::memory_order_relaxed);
                double at = compensated?audioPosition.load(std::memory_order_relaxed)+(advancing?std::max(0.,now-audioAnchor.load(std::memory_order_relaxed)):0):position + (running ? std::max(0., now - anchor) : 0);
                if (!compensated&&looping && at >= loopEnd) at = loopStart + std::fmod(at - loopStart, loopEnd - loopStart);
                const auto* span = allowed && !muted ? prepared.at(at, selected) : nullptr;
                if (at >= duration || (!looping && at >= stopAt) ||
                    !span || span->muted || span->settings.mode != "mtc") {
                    previous = nullptr; quarter = -1;
                } else {
                    const int saved = span->settings.midiDestination;
                    const auto slot = int64(-1000001) - saved;
                    const int requested = saved == 0 ? outputs[0] : slot >= 0 && slot < 6 ? outputs[size_t(slot)] : saved;
                    if (requested != destination || (!output && seen != generation)) {
                        output.reset(); destination = requested;
                        if (destination != 0) {
                            const auto devices = MidiOutput::getAvailableDevices();
                            int matches = 0; String identifier;
                            for (const auto& device : devices)
                                if (destinationID(device.identifier) == destination) { ++matches; identifier = device.identifier; }
                            if (matches == 1) output = MidiOutput::openDevice(identifier);
                        }
                    }
                    if (output) {
                        const double fps = span->settings.frameRate;
                        const double rate = fps == 29.97 ? 30000.0 / 1001.0 : fps;
                        if (seen != generation || (compensated&&seenAudio!=audioSerial) || span != previous || at < lastPosition) {
                            baseHost = now; baseTime = span->time(at); quarter = -1;
                            const auto f = jaras::nativeMtcTimeFields(baseTime, fps, fps == 29.97, true);
                            const uint8 bytes[]{0xf0, 0x7f, 0x7f, 1, 1, uint8(f.hour | (f.rateCode << 5)),
                                uint8(f.minute), uint8(f.second), uint8(f.frame), 0xf7};
                            output->sendMessageNow(MidiMessage(bytes, 10));
                        }
                        if (advancing) {
                            const auto target = static_cast<int64>(std::floor((now - baseHost) * rate * 4));
                            if (target - quarter > 8) quarter = (target / 8) * 8 - 1;
                            while (quarter < target) {
                                ++quarter;
                                if ((quarter & 7) == 0)
                                    fields = jaras::nativeMtcTimeFields(baseTime + double(quarter)/(rate*4), fps, fps == 29.97);
                                const uint8 bytes[]{0xf1, uint8(jaras::nativeMtcQuarterFrameData(fields, int(quarter)))};
                                output->sendMessageNow(MidiMessage(bytes, 2));
                            }
                        }
                    }
                    previous = span;
                }
                if(seenPC!=pcGeneration || seen!=generation || previousMTCDestination!=destination) {
                    std::set<int> required;
                    for(const auto &marker:pcMarkers){const auto slot=marker.output.value_or(pcSlot);if(slot>=1&&slot<=6 && outputs[size_t(slot-1)])required.insert(outputs[size_t(slot-1)]);}
                    for(auto it=pcOutputs.begin();it!=pcOutputs.end();)if(!required.count(it->first)||it->first==destination)it=pcOutputs.erase(it);else ++it;
                    const auto devices=MidiOutput::getAvailableDevices();
                    for(int id:required)if(id!=destination && !pcOutputs.count(id))for(const auto &device:devices)
                        if(destinationID(device.identifier)==id){pcOutputs[id]=MidiOutput::openDevice(device.identifier);break;}
                    previousMTCDestination=destination;
                }
                struct ClockRead { double anchor,host,jumpAt; bool play,allowed;uint64 jump; } clocks[2];
                const auto sequence=pcClockSequence.load(std::memory_order_acquire);
                const auto promotion=pcPromotion.load(std::memory_order_relaxed);
                for(size_t head=0;head<2;++head) {
                    const auto &clock=pcClocks[head];
                    clocks[head]={clock.at.load(),clock.host.load(),clock.jumpAt.load(),clock.play.load(),clock.allowed.load(),clock.jump.load()};
                }
                if(!(sequence&1) && sequence==pcClockSequence.load(std::memory_order_acquire)) {
                    if(promotion!=seenPromotion && clocks[0].play && !clocks[1].play) {
                        pcCursor[0]=pcCursor[1];pcJump[0]=clocks[0].jump;
                    }
                    seenPromotion=promotion;
                    for(int head=0;head<2;++head) {
                        const auto &clock=clocks[head];
                        auto send=[&](const auto &marker){
                            const auto slot=marker.output.value_or(pcSlot);if(slot<1||slot>6)return;
                            const auto target=outputs[size_t(slot-1)];const auto found=pcOutputs.find(target);
                            auto *sender=target==destination?output.get():found==pcOutputs.end()?nullptr:found->second.get();
                            if(sender&&!pcMuted&&clock.allowed)sender->sendMessageNow(MidiMessage::programChange(marker.channel,marker.program));
                        };
                        // Keep the exact jump anchor even if several callbacks elapsed before the worker woke.
                        if(clock.jump!=pcJump[head])pcCursor[head].advance(pcMarkers,clock.jumpAt,clock.play&&clock.allowed,true,send);
                        pcCursor[head].advance(pcMarkers,clock.anchor+(clock.play?std::max(0.,now-clock.host):0),clock.play&&clock.allowed,false,send);
                        pcJump[head]=clock.jump;
                    }
                }
                seenPC=pcGeneration;
                seen = generation;seenAudio=audioSerial; lastPosition = at;
            }
            wait(1);
        }
    }
};
}
