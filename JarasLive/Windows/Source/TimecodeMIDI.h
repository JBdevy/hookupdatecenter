#pragma once
#include "Common.h"
#include "../../Core/Timecode/TimecodePlayback.hpp"
namespace catlive {
// MIDI driver calls and endpoint enumeration stay off the audio callback.
class TimecodeMIDI final : private Thread {
public:
    TimecodeMIDI() : Thread("CatLive track MTC") { startThread(); }
    ~TimecodeMIDI() override { signalThreadShouldExit(); notify(); stopThread(3000); }
    static int destinationID(const String& identifier) {
        return static_cast<int>(static_cast<uint32>(identifier.hashCode()) & 0x7fffffffu) | 1;
    }
    void prepare(jaras::TimecodeProgram program, double end, bool mute) {
        const ScopedLock guard(lock);
        prepared = std::move(program); duration = end; muted = mute; running = false; ++generation;
    }
    void transport(double at, bool play, bool loop, double begin, double end,
                   double stop, int preferred, bool permitted) {
        const ScopedLock guard(lock);
        position = at; running = play; looping = loop && end > begin;
        loopStart = begin; loopEnd = end; stopAt = stop; selected = preferred;
        allowed = permitted; anchor = Time::getMillisecondCounterHiRes() * .001; ++generation;
        notify();
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
    CriticalSection lock;
    jaras::TimecodeProgram prepared;
    double position = 0, anchor = 0, duration = 0, loopStart = 0, loopEnd = 0;
    double stopAt = std::numeric_limits<double>::infinity();
    bool running = false, looping = false, muted = false, allowed = false;
    int selected = -1;
    uint64 generation = 0;
    void run() override {
        std::unique_ptr<MidiOutput> output;
        int destination = 0;
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
                    const int requested = span->settings.midiDestination;
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
                seen = generation;seenAudio=audioSerial; lastPosition = at;
            }
            wait(1);
        }
    }
};
}
