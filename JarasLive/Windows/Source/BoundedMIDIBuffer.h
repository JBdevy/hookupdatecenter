#pragma once
#include "../../Core/MIDI/BoundedMIDIBuilder.hpp"
#include <juce_audio_basics/juce_audio_basics.h>

namespace catlive {
class BoundedMIDIBuffer {
    using Budget = jaras::BoundedMIDIBuilder<>;
    struct Sink {
        juce::MidiBuffer& buffer;
        void clear() noexcept { buffer.clear(); }
        void add(const std::uint8_t* bytes, std::size_t size, int offset) noexcept {
            buffer.addEvent(bytes, int(size), offset);
        }
    };
public:
    static constexpr std::size_t maximumEvents = Budget::maximumEvents;
    static constexpr std::size_t maximumVisits = Budget::maximumVisits;
    static constexpr std::size_t panicEvents = Budget::panicEvents;
    explicit BoundedMIDIBuffer(bool allocate = true) { if (allocate) prepare(); }
    void prepare() {
        // NativeFX accepts 4096 events, so the builder must not exceed it.
        // JUCE 8 encodes short events in at most 9 bytes. Reserve 16/event once,
        // before the owner is published; render methods never reserve or grow.
        messages.ensureSize(maximumEvents * 16);
        prepared = true;
    }
    void clear() noexcept { messages.clear(); budget.beginBlock(); }
    bool overflowed() const noexcept { return budget.overflowed(); }
    std::uint64_t overflows() const noexcept { return budget.overflows(); }
    bool inspect() noexcept { jassert(prepared); if (!prepared) return false; Sink sink{messages}; return budget.inspect(sink); }
    void panic(bool report = true) noexcept { jassert(prepared); if (!prepared) return; Sink sink{messages}; budget.panic(sink, report); }
    bool addEvent(const juce::MidiMessage& message, int offset) noexcept {
        jassert(prepared); if (!prepared) return false;
        Sink sink{messages};
        return budget.append(sink, message.getRawData(), std::size_t(message.getRawDataSize()), offset);
    }
    void addEvents(const BoundedMIDIBuffer& other, int first, int count, int offset) noexcept {
        if (other.overflowed()) { panic(false); return; }
        for (const auto event : other.messages) {
            if (!inspect()) break;
            if (event.samplePosition >= first && event.samplePosition - first < count &&
                !addEvent(event.getMessage(), event.samplePosition + offset)) break;
        }
    }
    const juce::MidiBuffer& buffer() const noexcept { return messages; }
    operator const juce::MidiBuffer&() const noexcept { return messages; }
    auto begin() const noexcept { return messages.begin(); }
    auto end() const noexcept { return messages.end(); }
    bool isEmpty() const noexcept { return budget.size() == 0; }
    int getNumEvents() const noexcept { return int(budget.size()); }
private:
    juce::MidiBuffer messages;
    Budget budget;
    bool prepared = false;
};
} // namespace catlive
