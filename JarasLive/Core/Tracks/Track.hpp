#pragma once
#include "../Utils/Identity.hpp"
#include <vector>
#include <optional>
namespace jaras {
struct TrackRole { std::string id = "other"; };
struct AudioFile { std::string path; std::optional<std::string> sha256; };
struct AudioClip { ID id; std::string name; double startTime = 0, duration = 0, sourceOffset = 0; std::vector<double> waveform; };
struct Track {
    ID id; std::string name; TrackRole role;
    double volume = 1, pan = 0;
    bool mute = false, solo = false;
    int output = 1;
    std::optional<AudioFile> audioFile;
    std::vector<AudioClip> clips;
};
}
