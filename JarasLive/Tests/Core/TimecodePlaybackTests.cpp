#include "../../Core/Timecode/TimecodePlayback.hpp"
#include <cassert>
#include <iostream>
using namespace jaras;
int main() {
    Song song; song.parts = {{"parent", "Unified", 10, 30}, {"child", "B", 20, 30}};
    song.parts[1].parentRegionID = "parent";
    Track track; track.timecode = TimecodeSettings{}; track.timecode->mode = "ltc";
    track.timecode->offset = 3600;
    AudioClip clip; clip.id = "parent-timecode"; clip.startTime = 9; clip.duration = 22;
    track.clips = {clip};
    TimecodeProgram program(song, track);
    assert(program.at(8) == nullptr);
    const auto* span = program.at(9); assert(span && span->time(9) == 3599);
    assert(program.at(30.5) && !program.at(31));
    assert(program.at(20.5, program.preferred(std::optional<ID>{"child"}))->time(20.5) == 3610.5);
    assert(program.preferred(std::optional<ID>{"parent"}) == 0);
    track.clips[0].id = "imported"; track.clips[0].timecode = *track.timecode;
    track.clips[0].timecode->offset = 100;
    program = TimecodeProgram(song, track);
    assert(program.at(9)->time(9) == 100);
    track.clips[0].timecode->regionRelative = false;
    program = TimecodeProgram(song, track);
    assert(program.at(9)->time(9) == 109);
    for (double sampleRate : {44100., 48000.}) for (double fps : {24., 25., 29.97, 30.}) {
        LTCWaveform ltc;
        const double rate = fps == 29.97 ? 30000./1001. : fps;
        std::vector<int> edges;
        float previous = ltc.sample(3600, fps);
        for (int i = 1; i < int(sampleRate); ++i) {
            const float value = ltc.sample(3600 + i/sampleRate, fps);
            assert(std::abs(value) == .25f);
            if ((value > 0) != (previous > 0)) edges.push_back(i);
            previous = value;
        }
        std::vector<int> bits;
        const double half = sampleRate/(rate*160);
        for (size_t i = 0; i + 1 < edges.size();) {
            const double interval = (edges[i+1]-edges[i])/half;
            assert(std::abs(interval-1) < .13 || std::abs(interval-2) < .13);
            if (interval > 1.5) { bits.push_back(0); ++i; }
            else if (i+2 < edges.size() && (edges[i+2]-edges[i+1])/half < 1.5) { bits.push_back(1); i+=2; }
            else if (i+2 >= edges.size()) break;
            else { bits.clear(); ++i; }
        }
        int decoded = 0, prior = -1;
        for (size_t at = 64; at+16 <= bits.size(); ++at) {
            auto value = [&](size_t p, size_t n) { int v = 0; for(size_t j=0;j<n;++j) v |= bits[p+j] << j; return v; };
            if (value(at, 16) != 0xbffc) continue;
            const auto base = at-64;
            const int frame = value(base,4)+10*value(base+8,2);
            assert(value(base+48,4)+10*value(base+56,2) == 1);
            assert(value(base+32,4)+10*value(base+40,3) == 0);
            assert(value(base+16,4)+10*value(base+24,3) == 0);
            assert(bits[base+10] == (fps == 29.97));
            int parity = 0; for(size_t j=0;j<80;++j) parity += bits[base+j];
            assert(parity%2 == 0);
            if (prior >= 0) assert(frame == prior+1);
            prior = frame; ++decoded;
        }
        assert(decoded >= int(fps)-3);
        assert(ltc.sample(-1, fps) == 0);
    }
    std::cout << "TIMECODE_PLAYBACK_SPANS_OFFSETS_UNIFIED_ORIGIN_AND_DECODED_LTC_ALL_RATES_OK\n";
}
