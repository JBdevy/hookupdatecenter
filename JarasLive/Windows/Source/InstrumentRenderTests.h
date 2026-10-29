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
inline void loadTestBank(Instrument& instrument) {
    // An explicit, generated SF2 fixture keeps the sustain/retrigger checks
    // independent of the removed automatic piano and of downloaded banks.
    const auto chunk=[](MemoryOutputStream& out,const char* id,const MemoryOutputStream& data) {
        out.write(id,4);out.writeInt((int)data.getDataSize());out.write(data.getData(),data.getDataSize());
        if(data.getDataSize()%2)out.writeByte(0);
    };
    const auto name=[](MemoryOutputStream& out,const char* value) {
        char padded[20]{};std::memcpy(padded,value,std::min<size_t>(20,std::strlen(value)));out.write(padded,20);
    };
    MemoryOutputStream pcm,sdta,pdta,phdr,pbag,pmod,pgen,inst,ibag,imod,igen,shdr;
    for(int i=0;i<512;++i)pcm.writeShort((short)std::lround(std::sin(i*MathConstants<double>::twoPi/512)*12000));
    pcm.writeRepeatedByte(0,46*2);
    sdta.write("sdta",4);chunk(sdta,"smpl",pcm);
    for(int i=0;i<2;++i) {
        name(phdr,i?"EOP":"Test tone");phdr.writeShort(0);phdr.writeShort(0);phdr.writeShort((short)i);
        phdr.writeInt(0);phdr.writeInt(0);phdr.writeInt(0);
        pbag.writeShort((short)i);pbag.writeShort(0);
        name(inst,i?"EOI":"Test tone");inst.writeShort((short)i);
        ibag.writeShort((short)(i?2:0));ibag.writeShort(0);
    }
    pmod.writeRepeatedByte(0,10);imod.writeRepeatedByte(0,10);
    pgen.writeShort(41);pgen.writeShort(0);pgen.writeInt(0);
    igen.writeShort(54);igen.writeShort(1); // Loop until the envelope finishes.
    igen.writeShort(53);igen.writeShort(0);igen.writeInt(0);
    name(shdr,"Test sample");shdr.writeInt(0);shdr.writeInt(512);shdr.writeInt(0);shdr.writeInt(512);
    shdr.writeInt(48000);shdr.writeByte(60);shdr.writeByte(0);shdr.writeShort(0);shdr.writeShort(1);
    name(shdr,"EOS");shdr.writeRepeatedByte(0,26);
    pdta.write("pdta",4);chunk(pdta,"phdr",phdr);chunk(pdta,"pbag",pbag);chunk(pdta,"pmod",pmod);
    chunk(pdta,"pgen",pgen);chunk(pdta,"inst",inst);chunk(pdta,"ibag",ibag);chunk(pdta,"imod",imod);
    chunk(pdta,"igen",igen);chunk(pdta,"shdr",shdr);
    MemoryOutputStream body,bank;body.write("sfbk",4);chunk(body,"LIST",sdta);chunk(body,"LIST",pdta);chunk(bank,"RIFF",body);
    TemporaryFile file(".sf2");
    require(file.getFile().replaceWithData(bank.getData(),bank.getDataSize()),"Cannot write explicit instrument fixture");
    instrument.prepare(48000);instrument.loadSoundFont(file.getFile());
}
inline void idleAndRetrigger() {
    Instrument instrument;
    loadTestBank(instrument);
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
    loadTestBank(fresh);
    // Match the silent block rendered after stop(): the SF2 gain smoother
    // advances even while no voice is sounding.
    require(block(fresh) == 0, "Fresh explicit instrument sounded without MIDI");
    AudioBuffer<float> expected(2, 512); expected.clear(); output.clear();
    fresh.render(expected, notes, 512); instrument.render(output, notes, 512);
    for (int channel = 0; channel < 2; ++channel)
        for (int frame = 0; frame < 512; ++frame)
            require(output.getSample(channel, frame) == expected.getSample(channel, frame),
                    "Retriggering a stopped instrument changed its PCM");
}
inline void sustainAndRelease() {
    Instrument instrument;
    loadTestBank(instrument);
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
