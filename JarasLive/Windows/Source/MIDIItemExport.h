#pragma once
#include "MIDIPlayback.h"
namespace catlive {
inline void exportMIDIItem(const jaras::AudioClip &source, const File &destination) {
    if(!source.midi)throw std::runtime_error("Expected a MIDI item.");
    auto clip=source;clip.muted=false;clip.gain=1;clip.fadeIn=0;clip.fadeOut=0;
    jaras::Track track;track.clips={clip};
    const double bpm=clip.midi->sourceBPM, ticksPerSecond=960*bpm/60;
    MidiMessageSequence sequence;
    sequence.addEvent(MidiMessage::tempoMetaEvent(roundToInt(60000000/bpm)));
    sequence.addEvent(MidiMessage::textMetaEvent(3,text(clip.name)));
    for(const auto &note:playbackNotes(track,nullptr,true)) {
        auto on=MidiMessage::noteOn(note.channel,note.pitch,(uint8)note.velocity);
        auto off=MidiMessage::noteOff(note.channel,note.pitch);
        on.setTimeStamp(std::round((note.start-clip.startTime)*ticksPerSecond));
        off.setTimeStamp(std::max(on.getTimeStamp()+1,std::round((note.end-clip.startTime)*ticksPerSecond)));
        sequence.addEvent(on);sequence.addEvent(off);
    }
    sequence.updateMatchedPairs();
    auto end=MidiMessage::endOfTrack();end.setTimeStamp(std::max(sequence.getEndTime(),std::round(clip.duration*ticksPerSecond)));sequence.addEvent(end);
    MidiFile file;file.setTicksPerQuarterNote(960);file.addTrack(sequence);
    MemoryOutputStream encoded;
    if(!file.writeTo(encoded,0)||!destination.replaceWithData(encoded.getData(),encoded.getDataSize()))
        throw std::runtime_error("Unable to export MIDI file.");
}
}
