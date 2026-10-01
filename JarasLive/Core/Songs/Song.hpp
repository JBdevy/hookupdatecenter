#pragma once
#include "../Tracks/Track.hpp"
#include "../Parts/Part.hpp"
namespace jaras { struct TimelineMarker { ID id; std::string name; double position = 0; unsigned color = 0; std::optional<ID> unifiedRegionID; std::optional<ID> sourceRegionID; std::optional<double> tempoBPM; std::optional<int> tempoBeats, tempoUnit; std::optional<std::string> tempoTimebase; std::optional<double> tempoReferenceBPM; };
enum class ProjectTimebase { free, relative };
struct ProjectTimeSettings { int divisions = 4; ProjectTimebase timebase = ProjectTimebase::free; bool affectsMIDIItems = false, affectsAutomationLength = true; };
inline bool validProjectTimeSettings(const ProjectTimeSettings& settings) {
    return (settings.divisions == 0 || settings.divisions == 2 || settings.divisions == 4 || settings.divisions == 8) &&
        (settings.timebase == ProjectTimebase::free || settings.timebase == ProjectTimebase::relative);
}
struct Song { ID id; std::string name; double duration = 0, bpm = 120; std::vector<Track> tracks; std::vector<Part> parts; std::optional<std::vector<TimelineMarker>> markers; int beatsPerBar = 4, beatUnit = 4; std::optional<ProjectTimeSettings> timeSettings; }; }
