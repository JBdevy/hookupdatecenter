#pragma once
#include "Common.h"
#include "ClipTempo.h"
namespace catlive::midiEditing {
constexpr double minimum = 1. / 960.;
inline double step(const jaras::MIDIItem &midi) {
    return 4. / std::max(1, midi.division) *
           (midi.mode == "triplet"  ? 2. / 3.
            : midi.mode == "dotted" ? 1.5
                                    : 1.);
}
inline double line(const jaras::MIDIItem &midi, int index) {
    return index * step(midi) +
           (midi.mode == "swing" && index % 2 ? step(midi) * jlimit(0., .95, midi.swing) : 0.);
}
inline double snap(const jaras::MIDIItem &midi, double beat, bool bypass = false) {
    if (!std::isfinite(beat))
        return 0;
    beat = jlimit(0., 10000000., beat);
    if (bypass)
        return beat;
    const auto center = (int)(beat / step(midi));
    double closest = line(midi, std::max(0, center - 2));
    for (int i = std::max(0, center - 1); i <= center + 2; ++i) {
        const auto candidate = line(midi, i);
        if (std::abs(candidate - beat) < std::abs(closest - beat))
            closest = candidate;
    }
    return closest;
}
inline bool equal(const jaras::MIDINote &a, const jaras::MIDINote &b) {
    return a.id == b.id && a.start == b.start && a.length == b.length && a.pitch == b.pitch &&
           a.velocity == b.velocity && a.channel == b.channel;
}
inline void quantize(jaras::MIDIItem &midi, const std::set<ID> &chosen, double strength,
                     bool ends) {
    strength = jlimit(0., 1., strength);
    for (auto &note : midi.notes)
        if (chosen.count(note.id)) {
            const double end = note.start + note.length;
            note.start += (snap(midi, note.start) - note.start) * strength;
            if (ends)
                note.length =
                    std::max(minimum, end + (snap(midi, end) - end) * strength - note.start);
        }
}
// A gesture moves every selected note by the same bounded amount, preserving chords.
inline void transform(jaras::MIDIItem &midi, const std::set<ID> &chosen, double delta, int pitches,
                      int edge) {
    double first = 10000000., shortest = 10000000.;
    int low = 127, high = 0;
    bool found = false;
    for (const auto &note : midi.notes)
        if (chosen.count(note.id)) {
            found = true;
            first = std::min(first, note.start);
            shortest = std::min(shortest, note.length);
            low = std::min(low, note.pitch);
            high = std::max(high, note.pitch);
        }
    if (!found)
        return;
    if (edge < 0)
        delta = jlimit(-first, shortest - minimum, delta);
    else if (edge > 0)
        delta = std::max(minimum - shortest, delta);
    else {
        delta = std::max(-first, delta);
        pitches = jlimit(-low, 127 - high, pitches);
    }
    for (auto &note : midi.notes)
        if (chosen.count(note.id)) {
            if (edge <= 0)
                note.start += delta;
            if (edge != 0)
                note.length += edge > 0 ? delta : -delta;
            else
                note.pitch += pitches;
        }
}
inline void replace(jaras::Project &project, const ID &id, const jaras::MIDIItem &next) {
    for (auto &song : project.songs)
        for (auto &track : song.tracks)
            for (auto &clip : track.clips)
                if (clip.id == id && clip.midi) {
                    if (clip.frozenMIDI.value_or(false))
                        throw std::runtime_error(
                            "Descongele o item MIDI antes de editar suas notas.");
                    std::map<ID, jaras::MIDINote> previous;
                    for (const auto &note : clip.midi->notes)
                        previous.emplace(note.id, note);
                    for (const auto &note : next.notes) {
                        auto old = previous.find(note.id);
                        if (old == previous.end() || !equal(old->second, note)) {
                            const double end = (note.start + note.length) * 60. / next.sourceBPM;
                            auto probe = clip;
                            // Tempo references and markers are bounded to 60...300 BPM.
                            // Include later sections when a note extends past the old trim.
                            probe.duration = std::max(clip.duration,
                                (end - clip.sourceOffset) / clip.playbackRate * 5);
                            const ClipTempo timing(probe, &song);
                            clip.duration = std::max(clip.duration, timing.timeAt(end, false) - clip.startTime);
                        }
                    }
                    clip.midi = next;
                    song.duration = std::max(song.duration, clip.startTime + clip.duration);
                    return;
                }
    throw std::runtime_error("O item MIDI não existe mais.");
}
} // namespace catlive::midiEditing
