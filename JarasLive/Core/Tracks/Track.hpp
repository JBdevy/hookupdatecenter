#pragma once
#include "../Utils/Identity.hpp"
#include <vector>
#include <optional>
namespace jaras {
struct OutputPatch { int firstChannel = 0; int channelCount = 2; };
struct TrackRouting { std::vector<std::optional<ID>> receives{std::nullopt, std::nullopt}, transmitters{std::nullopt, std::nullopt}; };
struct TrackRole { std::string id = "other"; };
struct TimecodeSettings { std::string mode = "mtc"; double frameRate = 30, offset = 0; bool regionRelative = true; int midiDestination = 0; };
inline std::string fixedTrackName(const TrackRole& role) { return role.id == "timecode" ? "Timecode" : role.id == "video" ? "Video" : role.id == "teleprompt" ? "Teleprompter" : role.id == "chords" ? "Chords" : ""; }
struct AudioFile { std::string path; std::optional<std::string> sha256; };
struct AudioClip { ID id; std::string name; double startTime = 0, duration = 0, sourceOffset = 0; std::vector<double> waveform; std::optional<AudioFile> audioFile; std::optional<double> gain; std::vector<std::vector<double>> waveformChannels; bool muted = false; double playbackRate = 1; std::optional<int> recordingLane; std::optional<double> loopStart, loopLength; std::optional<std::string> fxJSON; std::optional<double> timecodeStartOffset, timecodeEndOffset; std::optional<bool> fxBypassed; std::optional<std::string> text; };
struct Track {
    ID id; std::string name; TrackRole role;
    double volume = 1, pan = 0;
    bool mute = false, solo = false;
    int output = 1;
    std::optional<AudioFile> audioFile;
    std::vector<AudioClip> clips;
    std::optional<OutputPatch> patch;
    std::optional<unsigned> color;
    std::optional<OutputPatch> inputPatch;
    std::optional<std::string> recordingFormat;
    std::optional<std::string> fxJSON;
    std::optional<int> midiInput;
    std::optional<ID> parentTrackID;
    std::optional<OutputPatch> secondaryPatch;
    std::optional<std::vector<OutputPatch>> outputs;
    std::vector<OutputPatch> outputPatches() const {
        if (outputs) return *outputs;
        std::vector<OutputPatch> result{patch.value_or(OutputPatch{parentTrackID ? -2 : 0, 2})};
        if (secondaryPatch) result.push_back(*secondaryPatch);
        return result;
    }
    std::optional<TimecodeSettings> timecode;
    std::optional<TrackRouting> routing;
};
}
