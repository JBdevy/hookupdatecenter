#pragma once
#include <cmath>

namespace jaras::audio::libraryDrumPreview {
// Four bars of the recorded Drum Kit performance, in quarter-note beats at 140 BPM.
struct Note { double start, end; int pitch, velocity, channel; };
inline constexpr Note notes[] = {
    {0, 0.25, 36, 120, 1},
    {0, 0.25, 49, 120, 1},
    {1, 1.5, 40, 127, 1},
    {1, 1.25, 42, 127, 1},
    {2, 2.25, 36, 120, 1},
    {2, 2.25, 42, 127, 1},
    {2.5, 2.75, 36, 111, 1},
    {3, 3.25, 40, 127, 1},
    {3, 3.5, 42, 127, 1},
    {3.5, 3.75, 46, 127, 1},
    {4, 4.25, 36, 120, 1},
    {4, 4.25, 42, 127, 1},
    {5, 5.25, 42, 127, 1},
    {5, 5.25, 40, 127, 1},
    {6, 6.25, 42, 127, 1},
    {6.5, 6.75, 36, 111, 1},
    {7, 7.25, 40, 127, 1},
    {7, 7.5, 42, 127, 1},
    {7.5, 7.75, 46, 120, 1},
    {8, 8.25, 36, 127, 1},
    {8, 8.25, 42, 127, 1},
    {9, 9.25, 40, 127, 1},
    {9, 9.25, 42, 127, 1},
    {10, 10.25, 36, 120, 1},
    {10, 10.25, 42, 127, 1},
    {10.5, 10.75, 36, 111, 1},
    {11, 11.25, 40, 127, 1},
    {11, 11.5, 42, 127, 1},
    {11.5, 11.75, 46, 127, 1},
    {12, 12.25, 42, 127, 1},
    {12, 12.25, 36, 127, 1},
    {13, 13.25, 42, 127, 1},
    {13, 13.25, 40, 127, 1},
    {14, 14.25, 42, 127, 1},
    {14.5, 14.75, 36, 120, 1},
    {15, 15.25, 40, 127, 1},
    {15, 15.5, 42, 127, 1},
    {15.5, 15.75, 46, 127, 1},
};
inline int frame(double beat, double rate) { return (int)std::lround(beat * 60 / 140 * rate); }
inline int length(double rate) { return frame(16, rate) + (int)rate; }
// A kit preview plays one-shot hits. The recorded key releases would
// attenuate drum and cymbal tails well before their samples end.
template<class Callback> void hits(double rate, Callback emit) {
    for (const auto &note : notes) emit(frame(note.start, rate), note.pitch, note.channel, note.velocity);
}
}
