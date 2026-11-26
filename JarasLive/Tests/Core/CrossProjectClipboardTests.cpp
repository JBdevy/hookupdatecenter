#include "clipboard-under-test.hpp"
#include <cassert>
#include <iostream>

int main() {
    jaras::Project source; source.id = "source";
    jaras::Song song; song.id = "source-song";
    for (int i = 0; i < 3; ++i) {
        jaras::Track track; track.id = "source-track-" + std::to_string(i); track.role.id = "other";
        if (i != 1) {
            jaras::AudioClip clip; clip.id = "clip-" + std::to_string(i); clip.startTime = 10 + i * 5; clip.duration = 5;
            clip.sourceOffset = 1.25; clip.playbackRate = 1.2; clip.pan = -.3; clip.gain = .5; clip.muted = true;
            clip.audioFile = jaras::AudioFile{"Stems/original.wav", {}}; clip.waveform = {.1, .3};
            clip.fxJSON = "{\"inserted\":[\"EQ\"]}"; clip.regionOwnerID = "old-region"; clip.separatedStemTracks = {"old-stem"};
            track.clips.push_back(clip);
        }
        song.tracks.push_back(track);
    }
    source.songs.push_back(song);
    auto copied = catlive::GridItemClipboard::copy(source, song.id, {"clip-0", "clip-2"}); assert(copied);
    jaras::Song destination; destination.id = "destination-song";
    for (int i = 0; i < 4; ++i) {
        jaras::Track track; track.id = "dest-" + std::to_string(i); track.role.id = "other";
        destination.tracks.push_back(track);
    }
    const auto entries = copied->copiedItems(destination, 73.125, {"dest-3", "dest-1"});
    assert(entries.size() == 2 && entries[0].id == "dest-1" && entries[1].id == "dest-3");
    assert(entries[0].clips[0].startTime == 73.125 && entries[1].clips[0].startTime == 83.125);
    const auto &clip = entries[0].clips[0], &original = song.tracks[0].clips[0];
    assert(clip.id != original.id && !clip.regionOwnerID && clip.separatedStemTracks.empty());
    assert(clip.sourceOffset == original.sourceOffset && clip.playbackRate == original.playbackRate);
    assert(clip.pan == original.pan && clip.gain == original.gain && clip.muted == original.muted);
    assert(clip.fxJSON == original.fxJSON && clip.waveform == original.waveform && clip.audioFile->path == original.audioFile->path);
    const auto repeated = copied->copiedItems(destination, 100, {"dest-1"});
    assert(repeated[0].clips[0].id != clip.id);
    jaras::Song empty; empty.id = "empty";
    const auto emptyPlan = copied->copyPlan(empty, 42.25, {});
    assert(emptyPlan.newTracks.size() == 3 && emptyPlan.entries.size() == 2);
    assert(emptyPlan.entries[0].id == emptyPlan.newTracks[0].id && emptyPlan.entries[1].id == emptyPlan.newTracks[2].id);
    assert(emptyPlan.entries[0].clips[0].startTime == 42.25 && emptyPlan.entries[1].clips[0].startTime == 52.25);
    const auto extension = copied->copyPlan(destination, 50, {"dest-3"});
    assert(extension.newTracks.size() == 2 && extension.entries[0].id == "dest-3" && extension.entries[1].id == extension.newTracks[1].id);
    bool failed = false;
    try { copied->copiedItems(destination, 0, {"dest-3"}); } catch (...) { failed = true; }
    assert(failed);
    copied->moving = true; failed = false;
    try { copied->copiedItems(destination, 0, {"dest-1"}); } catch (...) { failed = true; }
    assert(failed);
    assert(source.songs[0].tracks[0].clips[0].startTime == 10);
    std::cout << "WINDOWS_CROSS_PROJECT_CLIPBOARD_POSITION_TRACK_GAPS_METADATA_AND_SOURCE_PRESERVED_OK\n";
}
