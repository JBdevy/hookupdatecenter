#pragma once
#include <cstdint>
#include <string>

namespace jaras::midi {
inline std::string chordName(std::uint16_t pitches, int bass) {
    if (bass < 0 || bass > 11 || (pitches & (pitches-1)) == 0) return {};
    struct Chord { unsigned intervals; const char *suffix; };
    constexpr Chord chords[] = {
        {0x891, "maj7"}, {0x491, "7"}, {0x489, "m7"}, {0x889, "m(maj7)"},
        {0x449, "m7♭5"}, {0x249, "dim7"}, {0x511, "7♯5"}, {0x451, "7♭5"},
        {0x291, "6"}, {0x289, "m6"}, {0x4a1, "7sus4"},
        {0x495, "9"}, {0x895, "maj9"}, {0x48d, "m9"},
        {0x95, "add9"}, {0x8d, "m(add9)"},
        {0x91, ""}, {0x89, "m"}, {0x49, "dim"}, {0x111, "aug"}, {0xa1, "sus4"}, {0x85, "sus2"},
        {0x415, "9"}, {0x815, "maj9"}, {0x40d, "m9"}, {0x615, "13"}
    };
    constexpr const char *names[] = {"C","C♯","D","E♭","E","F","F♯","G","A♭","A","B♭","B"};
    // Prefer the bass as root when the pitch set has multiple valid names.
    for (int offset = 0; offset < 12; ++offset) {
        const int root = (bass+offset)%12;
        const auto relative = ((pitches >> root) | (unsigned(pitches) << (12-root))) & 0xfff;
        for (const auto &chord : chords) if (relative == chord.intervals) {
            std::string name = names[root];
            name += chord.suffix;
            if (root != bass) { name += '/'; name += names[bass]; }
            return name;
        }
    }
    return {};
}
}
