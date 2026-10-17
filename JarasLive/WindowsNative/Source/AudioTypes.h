#pragma once

#include <cstddef>
#include <cstdint>

namespace catlive::native {

// Borrowed planar output. The host owns the memory and its lifetime. A null
// right channel selects the left-channel output, matching the existing mixer.
struct StereoAudioView {
    float* left = nullptr;
    float* right = nullptr;
    std::size_t frames = 0;
};

// Short channel messages use the wire representation. Channels are zero-based
// in the status byte; the factory functions accept the usual MIDI range 1..16.
struct MidiMessage {
    std::uint8_t status = 0;
    std::uint8_t data1 = 0;
    std::uint8_t data2 = 0;

    static constexpr MidiMessage noteOn(int channel, int note, int velocity) noexcept {
        return channelMessage(0x90, channel, note, velocity);
    }
    static constexpr MidiMessage noteOff(int channel, int note) noexcept {
        return channelMessage(0x80, channel, note, 0);
    }
    static constexpr MidiMessage controller(int channel, int control, int value) noexcept {
        return channelMessage(0xb0, channel, control, value);
    }
    static constexpr MidiMessage pitchWheel(int channel, int value) noexcept {
        return value < 0 || value > 16383 ? MidiMessage{}
            : channelMessage(0xe0, channel, value & 127, (value >> 7) & 127);
    }
    static constexpr MidiMessage program(int channel, int value) noexcept {
        return channelMessage(0xc0, channel, value, 0);
    }
    constexpr bool isChannelMessage() const noexcept {
        return status >= 0x80 && status < 0xf0 && data1 < 128 && data2 < 128;
    }

  private:
    static constexpr MidiMessage channelMessage(int type, int channel, int a, int b) noexcept {
        return channel < 1 || channel > 16 || a < 0 || a > 127 || b < 0 || b > 127
            ? MidiMessage{}
            : MidiMessage{static_cast<std::uint8_t>(type | (channel - 1)),
                          static_cast<std::uint8_t>(a), static_cast<std::uint8_t>(b)};
    }
};

struct MidiEvent {
    std::size_t sampleOffset = 0;
    MidiMessage message;
};

// Events are ordered by sampleOffset, retaining the caller's order for ties.
// Offset == frames is valid and affects the following audio block.
struct MidiEventSpan {
    const MidiEvent* data = nullptr;
    std::size_t size = 0;
};

} // namespace catlive::native
