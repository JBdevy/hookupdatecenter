#pragma once
#include "Common.h"
namespace catlive {
inline jaras::Project makeRecordingProject(String name, int channels) {
    if (channels < 1 || channels > 128 || name.trim().isEmpty())
        throw std::runtime_error("Escolha um nome e entre 1 e 128 canais.");
    jaras::Project project;
    project.id = uuid();
    project.name = utf8(name.trim());
    project.createdAt = project.updatedAt = utf8(Time::getCurrentTime().toISO8601(true));
    project.masterColor = 0x414141;
    jaras::Song song;
    song.id = uuid(); song.name = project.name; song.duration = 300; song.bpm = 120;
    song.timeSettings = jaras::ProjectTimeSettings{};
    song.timeSettings->timebase = jaras::ProjectTimebase::relative;
    for (int channel = 1; channel <= channels; ++channel) {
        jaras::Track track;
        track.id = uuid(); track.name = utf8("Track " + String(channel).paddedLeft('0', 2));
        track.role.id = "other"; track.color = 0x828282;
        track.inputPatch = jaras::OutputPatch{channel, 1};
        track.recordingChannels = 1; track.inputMonitoring = false;
        track.output = 1; track.outputs = std::vector<jaras::OutputPatch>{{0, 2}};
        song.tracks.push_back(std::move(track));
    }
    project.setlists.push_back({uuid(), project.name, {song.id}});
    project.songs.push_back(std::move(song));
    jaras::validate(project);
    return project;
}
}
