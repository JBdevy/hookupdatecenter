#pragma once
#include "Common.h"

namespace catlive {
inline jaras::AudioClip readMIDIItem(const File &file) {
    FileInputStream stream(file);
    MidiFile source;
    if (!stream.openedOk() || !source.readFrom(stream))
        throw std::runtime_error("Could not read the MIDI file.");
    source.convertTimestampTicksToSeconds();
    jaras::AudioClip clip;
    clip.id = uuid(); clip.name = utf8(file.getFileNameWithoutExtension());
    clip.midi.emplace();
    for (int i = 0; i < source.getNumTracks(); ++i) {
        auto sequence = *source.getTrack(i);
        sequence.updateMatchedPairs();
        for (int j = 0; j < sequence.getNumEvents(); ++j) {
            const auto *event = sequence.getEventPointer(j);
            if (!event->message.isNoteOn() || !event->noteOffObject) continue;
            const auto start = event->message.getTimeStamp();
            const auto end = event->noteOffObject->message.getTimeStamp();
            if (!std::isfinite(start) || !std::isfinite(end) || start < 0 || end <= start) continue;
            clip.midi->notes.push_back({uuid(), start * 2, (end - start) * 2,
                event->message.getNoteNumber(), event->message.getVelocity(), event->message.getChannel()});
            clip.duration = std::max(clip.duration, end);
        }
    }
    if (clip.midi->notes.empty()) throw std::runtime_error("The MIDI file contains no notes.");
    return clip;
}
}
