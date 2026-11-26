#pragma once
#include "Common.h"

namespace catlive {
struct ArpeggioParameters {
    static constexpr std::array<int, 9> divisions{2, 4, 6, 8, 12, 16, 24, 32, 48};
    static constexpr std::array<const char *, 4> directions{"Up", "Down", "Up / Down", "As Played"};
    int division = 16;
    int direction = 0;
    int octaves = 1;
    int gate = 75;
    bool sync = true;
    int bpm = 120;
    bool operator==(const ArpeggioParameters &other) const {
        return division == other.division && direction == other.direction && octaves == other.octaves &&
               gate == other.gate && sync == other.sync && bpm == other.bpm;
    }
    bool operator!=(const ArpeggioParameters &other) const { return !(*this == other); }

    static ArpeggioParameters read(const var &settings) {
        const auto value = get(settings, "arpeggiator");
        ArpeggioParameters result;
        const auto division = int(jlimit(2., 48., num(value, "division", 16)));
        if (std::find(divisions.begin(), divisions.end(), division) != divisions.end())
            result.division = division;
        result.direction = int(jlimit(0., double(directions.size() - 1), num(value, "direction", 0)));
        result.octaves = int(jlimit(1., 4., num(value, "octaves", 1)));
        result.gate = int(jlimit(5., 100., num(value, "gate", 75)));
        result.sync = flag(value, "sync", true);
        result.bpm = int(jlimit(20., 400., num(value, "bpm", 120)));
        return result;
    }

    double interval(double transportBPM) const { return 240. / (division * std::max(20., sync ? transportBPM : double(bpm))); }
    double length() const { return gate / 100.; }

    // Notes are sorted by pitch or kept in input order. Values beyond MIDI's
    // top note are skipped, including when the sequence runs in reverse.
    template <typename Pitch>
    std::pair<size_t, int> step(size_t index, size_t count, Pitch pitchAt) const {
        if (count == 0) return {0, 0};
        size_t available = count;
        for (int octave = 1; octave < octaves; ++octave)
            for (size_t note = 0; note < count; ++note)
                if (pitchAt(note) + octave * 12 <= 127) ++available;
        if (direction == 2 && available > 1) {
            const auto period = available * 2 - 2;
            index %= period;
            if (index >= available) index = period - index;
        } else {
            index %= available;
            if (direction == 1) index = available - 1 - index;
        }
        if (index < count) return {index, 0};
        index -= count;
        for (int octave = 1; octave < octaves; ++octave)
            for (size_t note = 0; note < count; ++note)
                if (pitchAt(note) + octave * 12 <= 127 && index-- == 0) return {note, octave * 12};
        return {0, 0};
    }
};
}
