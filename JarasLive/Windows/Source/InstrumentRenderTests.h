#pragma once
#include "Instrument.h"

namespace catlive::instrumentRenderTests {
inline void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
inline float block(Instrument& instrument, const MidiBuffer& midi = {}) {
    AudioBuffer<float> audio(2, 512); audio.clear();
    instrument.render(audio, midi, 512);
    return audio.getMagnitude(0, 512);
}
inline void idleAndRetrigger() {
    Instrument instrument;
    AudioBuffer<float> output(2, 512);
    for (int iteration = 0; iteration < 32; ++iteration) {
        for (int channel = 0; channel < 2; ++channel)
            FloatVectorOperations::fill(output.getWritePointer(channel), .125f, 512);
        instrument.render(output, {}, 512);
        for (int channel = 0; channel < 2; ++channel)
            for (int frame = 0; frame < 512; ++frame)
                require(output.getSample(channel, frame) == .125f,
                        "Idle instrument modified an existing audio mix");
    }
    MidiBuffer notes; notes.addEvent(MidiMessage::noteOn(1, 60, uint8(100)), 31);
    output.clear(); instrument.render(output, notes, 512);
    require(output.getMagnitude(0, 31) == 0 && output.getMagnitude(31, 481) > .001f,
            "Instrument lost the note's sample offset after idle");
    instrument.stop();
    require(block(instrument) == 0, "Hard stop left a sounding voice");
    Instrument fresh;
    AudioBuffer<float> expected(2, 512); expected.clear(); output.clear();
    fresh.render(expected, notes, 512); instrument.render(output, notes, 512);
    for (int channel = 0; channel < 2; ++channel)
        for (int frame = 0; frame < 512; ++frame)
            require(output.getSample(channel, frame) == expected.getSample(channel, frame),
                    "Retriggering a stopped instrument changed its PCM");
}
inline void sustainAndRelease() {
    Instrument instrument;
    MidiBuffer midi; midi.addEvent(MidiMessage::noteOn(1, 64, uint8(100)), 0);
    require(block(instrument, midi) > .001f, "Instrument did not start its note");
    midi.clear(); midi.addEvent(MidiMessage::controllerEvent(1, 64, 127), 0);
    midi.addEvent(MidiMessage::noteOff(1, 64), 17);
    block(instrument, midi);
    float held = 0;
    for (int iteration = 0; iteration < 80; ++iteration) held = block(instrument);
    require(held > .001f, "Idle optimization cut a note held by sustain");
    midi.clear(); midi.addEvent(MidiMessage::controllerEvent(1, 64, 0), 19);
    require(block(instrument, midi) > .0001f, "Sustain release was cut immediately");
    float tail = 0;
    for (int iteration = 0; iteration < 64; ++iteration) tail = block(instrument);
    require(tail == 0 && block(instrument) == 0, "Released voice did not return to silence");
    midi.clear(); midi.addEvent(MidiMessage::noteOn(2, 67, uint8(110)), 7);
    require(block(instrument, midi) > .001f, "Instrument could not play after releasing sustain");
}
template <typename Register>
void registerTests(Register&& test) {
    test("Idle instrument preserves the mix and restarts with identical PCM", [] { idleAndRetrigger(); });
    test("Instrument idle optimization preserves sustain and release tails", [] { sustainAndRelease(); });
}
} // namespace catlive::instrumentRenderTests
