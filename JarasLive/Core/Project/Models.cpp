#include <map>
#include <functional>
#include "Models.hpp"
#include <cmath>
#include <set>
#include <algorithm>
#include <stdexcept>
#include <unordered_map>
namespace jaras {
void orderSpecialTracks(Project& project) {
    const auto rank = [](const Track& track) {
        return track.role.id == "timecode" ? 0 : track.role.id == "chords" ? 1 : track.role.id == "teleprompt" ? 2 : track.role.id == "teleprompt2" ? 3 : track.role.id == "video" ? 4 : 5;
    };
    for (auto& song : project.songs) {
        const auto earlier = [&](const Track& a, const Track& b) { return rank(a) < rank(b); };
        if (!std::is_sorted(song.tracks.begin(), song.tracks.end(), earlier))
            std::stable_sort(song.tracks.begin(), song.tracks.end(), earlier);
    }
}
void validateClipText(const std::string& text, size_t maximum) {
    // Count Unicode scalars rather than UTF-8 bytes; portable on macOS and Windows.
    size_t characters = 0;
    for (size_t index = 0; index < text.size();) {
        const auto first = static_cast<unsigned char>(text[index++]);
        unsigned value = first, continuation = 0, minimum = 0;
        if (first < 0x80) {}
        else if (first >= 0xc2 && first <= 0xdf) { value = first & 0x1f; continuation = 1; minimum = 0x80; }
        else if (first >= 0xe0 && first <= 0xef) { value = first & 0x0f; continuation = 2; minimum = 0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { value = first & 0x07; continuation = 3; minimum = 0x10000; }
        else throw std::invalid_argument("Invalid text encoding");
        if (text.size() - index < continuation) throw std::invalid_argument("Invalid text encoding");
        for (unsigned byte = 0; byte < continuation; ++byte) {
            const auto next = static_cast<unsigned char>(text[index++]);
            if ((next & 0xc0) != 0x80) throw std::invalid_argument("Invalid text encoding");
            value = (value << 6) | (next & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) throw std::invalid_argument("Invalid text encoding");
        if (++characters > maximum) throw std::invalid_argument(maximum == 30 ? "Chords text must contain at most 30 characters" : "Teleprompter text must contain at most 400 characters");
    }
}
void validateClipFXJSON(const std::string& json) {
    const auto first = json.find_first_not_of(" \t\r\n"), last = json.find_last_not_of(" \t\r\n");
    if (json.empty() || json.size() > 65536 || first == std::string::npos || json[first] != '{' || json[last] != '}')
        throw std::invalid_argument("Invalid item FX data");
    // The native bridge parses and canonicalizes JSON before it reaches the core.
    for (const auto* instrument : {"\"Instruments\"", "\"instrumentID\"", "\"instrumentParameters\"", "\"instrumentBypassed\""})
        if (json.find(instrument) != std::string::npos) throw std::invalid_argument("Items cannot contain instruments");
    const auto key = json.find("\"inserted\"");
    if (key == std::string::npos) throw std::invalid_argument("Missing item FX selection");
    auto position = json.find_first_not_of(" \t\r\n", key + 10);
    if (position == std::string::npos || json[position] != ':') throw std::invalid_argument("Invalid item FX selection");
    position = json.find_first_not_of(" \t\r\n", position + 1);
    if (position == std::string::npos || json[position] != '[') throw std::invalid_argument("Invalid item FX selection");
    position = json.find_first_not_of(" \t\r\n", position + 1);
    std::set<std::string> effects;
    const std::set<std::string> allowed{"EQ", "Compressor", "Pitch", "Delay", "Reverb"};
    while (position != std::string::npos && json[position] != ']') {
        if (json[position] != '"') throw std::invalid_argument("Invalid item FX selection");
        const auto end = json.find('"', position + 1);
        if (end == std::string::npos) throw std::invalid_argument("Invalid item FX selection");
        const auto effect = json.substr(position + 1, end - position - 1);
        if (!allowed.count(effect) || !effects.insert(effect).second) throw std::invalid_argument("Invalid item FX selection");
        position = json.find_first_not_of(" \t\r\n", end + 1);
        if (position == std::string::npos || (json[position] != ',' && json[position] != ']')) throw std::invalid_argument("Invalid item FX selection");
        if (json[position] == ',') {
            position = json.find_first_not_of(" \t\r\n", position + 1);
            if (position == std::string::npos || json[position] == ']') throw std::invalid_argument("Invalid item FX selection");
        }
    }
    if (position == std::string::npos) throw std::invalid_argument("Invalid item FX selection");
}
void validateRegionSetlist(const Project& p, const RegionSetlist& state) {
    auto require = [](bool valid, const char* message) { if (!valid) throw std::invalid_argument(message); };
    require(!state.automaticSubplaySeconds || (std::isfinite(*state.automaticSubplaySeconds) && *state.automaticSubplaySeconds >= 1 && *state.automaticSubplaySeconds <= 5), "Automatic Subplay time must be between 1 and 5 seconds");
    std::set<ID> ids{p.id};
    for (const auto& song : p.songs) {
        ids.insert(song.id);
        for (const auto& track : song.tracks) {
            ids.insert(track.id);
            for (const auto& clip : track.clips) ids.insert(clip.id);
        }
        for (const auto& part : song.parts) ids.insert(part.id);
        if (song.markers) for (const auto& marker : *song.markers) ids.insert(marker.id);
    }
    for (const auto& list : p.setlists) ids.insert(list.id);
    auto unique = [&](const ID& id) { require(!id.empty() && ids.insert(id).second, "Duplicate or empty UUID"); };
        for (const auto& list : state.playlists) {
            unique(list.id);
            require(list.name.find_first_not_of(" \t\r\n") != std::string::npos, "Playlist needs a name and regions");
            auto song = std::find_if(p.songs.begin(), p.songs.end(), [&](const auto& s) { return s.id == list.songId; });
            require(song != p.songs.end(), "Unknown playlist grid");
            std::set<ID> seen;
            for (const auto& id : list.regionIds)
                require(seen.insert(id).second && std::any_of(song->parts.begin(), song->parts.end(), [&](const auto& r) { return r.id == id; }), "Invalid playlist region");
        }
        if (state.blocks) for (const auto& block : *state.blocks) {
            unique(block.id);
            require(block.name.find_first_not_of(" \t\r\n") != std::string::npos && block.color <= 0xffffff, "Invalid setlist block");
            auto song = std::find_if(p.songs.begin(),p.songs.end(),[&](const auto& s) { return s.id == block.songId; });
            require(song != p.songs.end(), "Unknown block grid");
            if (block.playlistId) {
                auto list = std::find_if(state.playlists.begin(),state.playlists.end(),[&](const auto& l) { return l.id == *block.playlistId && l.songId == block.songId; });
                require(list != state.playlists.end(), "Unknown block playlist");
                require(!block.beforeRegionId || std::find(list->regionIds.begin(),list->regionIds.end(),*block.beforeRegionId) != list->regionIds.end(), "Unknown block region");
            } else require(!block.beforeRegionId || std::any_of(song->parts.begin(),song->parts.end(),[&](const auto& part) { return part.id == *block.beforeRegionId; }), "Unknown block region");
        }
        require(!state.selectedId || std::any_of(state.playlists.begin(), state.playlists.end(), [&](const auto& l) { return l.id == *state.selectedId; }), "Unknown selected playlist");
}
void validateRouting(const Song& song) {
    std::set<ID> audio;
    for (const auto& t : song.tracks) if (fixedTrackName(t.role).empty()) audio.insert(t.id);
    std::map<ID, std::set<ID>> edges;
    auto link = [&](const ID& from, const ID& to) {
        if (from == to || !audio.count(from) || !audio.count(to)) throw std::invalid_argument("Invalid track routing");
        edges[from].insert(to);
    };
    for (const auto& t : song.tracks) {
        if (t.routing) {
            if (!audio.count(t.id)) throw std::invalid_argument("Invalid track routing");
            for (const auto& id : t.routing->receives) if (id) link(*id,t.id);
            for (const auto& id : t.routing->transmitters) if (id) link(t.id,*id);
        }
        if (t.parentTrackID) for (const auto& patch : t.outputPatches()) if (patch.firstChannel == -2) link(t.id,*t.parentTrackID);
    }
    std::set<ID> visiting, done;
    std::function<void(const ID&)> visit = [&](const ID& id) {
        if (done.count(id)) return;
        if (!visiting.insert(id).second) throw std::invalid_argument("This routing would create an audio feedback loop.");
        for (const auto& next : edges[id]) visit(next);
        visiting.erase(id);done.insert(id);
    };
    for (const auto& id : audio) visit(id);
}
void validate(const Project& p) {
    auto require = [](bool valid, const char* message) { if (!valid) throw std::invalid_argument(message); };
    auto finite = [](double x) { return std::isfinite(x); };
    require(p.projectFormatVersion == 1 && p.minimumJarasVersion == "1.0.0", "Unsupported project version");
    require(!p.id.empty() && !p.name.empty(), "Missing project identity");
    size_t trackCount = 0;
    for (const auto& song : p.songs) {
        trackCount += song.tracks.size();
        require(trackCount <= 400, "A project supports at most 400 tracks");
    }
    auto validatePatch = [&](const OutputPatch& patch, bool masterAllowed, bool groupAllowed = false, bool noneAllowed = false) {
        if (patch.channelCount == 2 && ((noneAllowed && patch.firstChannel == -1) || (groupAllowed && patch.firstChannel == -2))) return;
        require(patch.firstChannel >= (masterAllowed ? 0 : 1) && patch.firstChannel <= 1024 &&
                patch.channelCount >= 1 && patch.channelCount <= 2 &&
                (patch.firstChannel != 0 || patch.channelCount == 2), "Invalid output patch");
    };
    require(!p.masterColor || *p.masterColor <= 0xffffff, "Invalid master color");
    require(finite(p.masterVolume) && p.masterVolume >= 0 && p.masterVolume <= std::pow(10.0, 12.0 / 20.0), "Invalid master volume");
    if (p.masterPatch) validatePatch(*p.masterPatch, false, false, true);
    if (p.masterSecondaryPatch) validatePatch(*p.masterSecondaryPatch, false, false, true);
    if (p.masterOutputs) for (const auto& patch : *p.masterOutputs) validatePatch(patch, false, false, true);
    std::set<ID> ids{p.id}, songIds;
    int timecodeTracks = 0;
    auto unique = [&](const ID& id) { require(!id.empty() && ids.insert(id).second, "Duplicate or empty UUID"); };
    for (const auto& s : p.songs) {
        validateRouting(s);
        unique(s.id); songIds.insert(s.id);
        require(finite(s.duration) && s.duration > 0 && finite(s.bpm) && s.bpm > 0, "Invalid song timing");
        require(s.beatsPerBar >= 1 && s.beatsPerBar <= 32 && s.beatUnit >= 1 && s.beatUnit <= 64 && (s.beatUnit & (s.beatUnit - 1)) == 0, "Invalid time signature");
        require(!s.timeSettings || validProjectTimeSettings(*s.timeSettings), "Invalid project timebase");
        std::optional<ID> folder;
        for (const auto& t : s.tracks) {
            if (t.parentTrackID) require(folder && *folder == *t.parentTrackID && t.id != *folder, "Invalid track group");
            else folder = t.id;
            unique(t.id);
            const auto fixed = fixedTrackName(t.role);
            require(fixed.empty() || ((t.name == fixed || (t.role.id == "teleprompt" && t.name == "Teleprompter")) && (!t.solo || t.role.id == "video") && !t.parentTrackID), "Invalid special track");
            const bool textTrack = isTeleprompterRole(t.role) || t.role.id == "chords";
            if (textTrack || t.role.id == "video") {
                std::vector<const AudioClip*> ordered;
                for (int layer = 0; layer < (isTeleprompterRole(t.role) ? 2 : 1); ++layer) {
                ordered.clear();
                for (const auto& clip : t.clips) {
                    const bool media = clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0;
                    if (!isTeleprompterRole(t.role) || media == (layer == 1)) ordered.push_back(&clip);
                }
                std::sort(ordered.begin(), ordered.end(), [](const auto* a, const auto* b) { return a->startTime < b->startTime; });
                for (size_t index = 1; index < ordered.size(); ++index)
                    require(ordered[index-1]->startTime + ordered[index-1]->duration <= ordered[index]->startTime + 0.0000001,
                            "Teleprompter, Video and Chords items cannot overlap");
                }
            }
            require(!textTrack || (!t.mute && !t.fxJSON && !t.audioFile && !t.midiInput && !t.midiChannel && !t.recordingFormat && !t.recordingChannels), "Text tracks cannot contain audio controls");
            if (t.role.id == "timecode") require(++timecodeTracks <= 1, "Only one Timecode track is allowed");
            if (t.timecode) {
                const auto& tc = *t.timecode;
                require((tc.mode == "mtc" || tc.mode == "ltc") && (tc.frameRate == 24 || tc.frameRate == 25 || tc.frameRate == 29.97 || tc.frameRate == 30) && finite(tc.offset) && tc.offset >= 0 && tc.offset < 86400, "Invalid timecode settings");
            }
            require(!t.color || *t.color <= 0xffffff, "Invalid track color");
            require(!t.midiChannel || (*t.midiChannel >= 1 && *t.midiChannel <= 16), "Invalid MIDI channel");
            require(!t.midiInput || (*t.midiInput >= 1 && *t.midiInput <= 3), "Invalid MIDI input");
            if (t.inputPatch) validatePatch(*t.inputPatch, false);
            if (t.stereoLinkPartner) {
                const auto partner = std::find_if(s.tracks.begin(), s.tracks.end(), [&](const auto& other) { return other.id == *t.stereoLinkPartner; });
                require(fixed.empty() && partner != s.tracks.end() && partner->id != t.id && partner->stereoLinkPartner == t.id && partner->stereoLinkLeft != t.stereoLinkLeft, "Invalid linked tracks");
                require(std::none_of(s.tracks.begin(), s.tracks.end(), [&](const auto& child) { return child.parentTrackID == t.id; }), "Folder tracks cannot be linked");
                require(t.inputPatch && partner->inputPatch && t.inputPatch->channelCount == 1 && partner->inputPatch->channelCount == 1 && partner->inputPatch->firstChannel == t.inputPatch->firstChannel + (t.stereoLinkLeft ? 1 : -1), "Linked tracks require consecutive mono inputs");
                require(t.volume == partner->volume && t.pan == -partner->pan, "Linked track controls must match");
            }
            require(!t.recordingChannels || *t.recordingChannels == 1 || *t.recordingChannels == 2, "Invalid recording channel mode");
            require(!t.recordingFormat || *t.recordingFormat == "wav" || *t.recordingFormat == "wav32" || *t.recordingFormat == "mp3", "Invalid recording format");
            if (t.patch) validatePatch(*t.patch, true, t.parentTrackID.has_value(), true);
            if (t.secondaryPatch) validatePatch(*t.secondaryPatch, true, t.parentTrackID.has_value(), true);
            for (const auto& patch : t.outputPatches()) validatePatch(patch, true, t.parentTrackID.has_value(), true);
            require(finite(t.volume) && t.volume >= 0 && t.volume <= std::pow(10.0, 12.0 / 20.0), "Invalid volume");
            require(finite(t.pan) && t.pan >= -1 && t.pan <= 1 && t.output > 0, "Invalid routing");
            std::vector<AudioFile> files;
            if (t.audioFile) files.push_back(*t.audioFile);
            for (const auto& clip : t.clips) {
                require(!clip.text || textTrack, "Text items require a Teleprompter or Chords track");
                if (clip.text) validateClipText(*clip.text, t.role.id == "chords" ? 30 : 400);
                const bool media = clip.audioFile && clip.audioFile->path.rfind("Videos/", 0) == 0;
                require(!media || t.role.id == "video" || isTeleprompterRole(t.role), "Videos require a Video or Teleprompter track");
                if (isTeleprompterRole(t.role) && media) require(!clip.text && !clip.gain && !clip.muted && clip.waveform.empty() && clip.waveformChannels.empty() && !clip.loopStart && !clip.loopLength, "Teleprompter media cannot contain audio controls");
                else require(!textTrack || (!clip.audioFile && !clip.gain && !clip.muted && clip.waveform.empty() && clip.waveformChannels.empty() && clip.sourceOffset == 0 && !clip.loopStart && !clip.loopLength), "Text items cannot contain audio");
                require(!clip.fxJSON || fixed.empty(), "Item FX requires an audio track");
                require(!clip.fxBypassed || fixed.empty(), "Item FX requires an audio track");
                if (clip.fxJSON) validateClipFXJSON(*clip.fxJSON);
                require(!clip.timecodeStartOffset || (finite(*clip.timecodeStartOffset) && t.role.id == "timecode"), "Invalid Timecode start span");
                require(!clip.timecodeEndOffset || (finite(*clip.timecodeEndOffset) && t.role.id == "timecode"), "Invalid Timecode end span");
                require(t.role.id != "timecode" || (!clip.loopStart && !clip.loopLength), "Timecode items cannot repeat their source");
                if (clip.audioFile) files.push_back(*clip.audioFile);
                require(!clip.loopStart || (finite(*clip.loopStart) && *clip.loopStart >= 0), "Invalid loop start");
                require(!clip.loopLength || (finite(*clip.loopLength) && *clip.loopLength > 0), "Invalid loop length");
                require(!clip.gain || (finite(*clip.gain) && *clip.gain >= 0), "Invalid clip gain");
                require(!clip.channelMode || (*clip.channelMode >= 0 && *clip.channelMode <= 3), "Invalid item channel mode");
                require(!clip.normalizationGain || (finite(*clip.normalizationGain) && *clip.normalizationGain >= 0 && *clip.normalizationGain <= std::pow(10.0, 24.0 / 20.0)), "Invalid normalization gain");
                unique(clip.id);
                require(finite(clip.startTime) && finite(clip.duration) && clip.startTime >= 0 && clip.duration > 0 && clip.startTime + clip.duration <= s.duration, "Invalid clip interval");
                require(finite(clip.playbackRate) && clip.playbackRate >= 1.0/32 && clip.playbackRate <= 32, "Invalid clip playback rate");
                require(finite(clip.sourceOffset) && clip.sourceOffset >= 0, "Invalid source offset");
                for (const auto& channel : clip.waveformChannels) for (double peak : channel) require(finite(peak) && peak >= 0 && peak <= 1, "Invalid channel waveform");
                for (double peak : clip.waveform) require(finite(peak) && peak >= 0 && peak <= 1, "Invalid waveform peak");
            }
            for (const auto& file : files) {
                const auto& path = file.path;
                require(!path.empty() && path.front() != '/' && path.find('\\') == std::string::npos && path.find(':') == std::string::npos, "Audio path must be relative");
                size_t start = 0;
                while (start <= path.size()) {
                    auto end = path.find('/', start);
                    auto component = path.substr(start, end == std::string::npos ? end : end - start);
                    require(component != ".." && component != "." && !component.empty(), "Unsafe audio path");
                    if (end == std::string::npos) break;
                    start = end + 1;
                }
            }
        }
        if (s.markers) for (const auto& marker : *s.markers) {
            if (marker.tempoBPM) {
                const int unit = marker.tempoUnit.value_or(4);
                require(finite(*marker.tempoBPM) && *marker.tempoBPM >= 60 && *marker.tempoBPM <= 300 && marker.tempoBeats.value_or(4) >= 1 && marker.tempoBeats.value_or(4) <= 32 && (unit == 1 || unit == 2 || unit == 4 || unit == 8 || unit == 16 || unit == 32 || unit == 64) && !marker.unifiedRegionID && !marker.sourceRegionID, "Invalid tempo marker");
                require(!marker.tempoTimebase || *marker.tempoTimebase == "global" || *marker.tempoTimebase == "free" || *marker.tempoTimebase == "relative", "Invalid tempo marker timebase");
            } else require(!marker.tempoBeats && !marker.tempoUnit && !marker.tempoTimebase, "Invalid tempo marker");
            unique(marker.id);
            require(marker.name.find_first_not_of(" \t\r\n") != std::string::npos && marker.color <= 0xffffff && finite(marker.position) && marker.position >= 0 && marker.position <= s.duration, "Invalid marker");
        }
        std::vector<std::pair<double, int>> regionEdges;
        for (const auto& part : s.parts) {
            for (const auto& loop : part.multiLoops) {
                unique(loop.id);
                require(loop.name.find_first_not_of(" \t\r\n") != std::string::npos && loop.marker1 != loop.marker2 && finite(loop.fadeSeconds) && loop.fadeSeconds >= 1 && loop.fadeSeconds <= 5, "Invalid multiloop");
                std::set<ID> targets;
                for (const auto& track : loop.tracks) require(targets.insert(track.id).second && finite(track.gain) && track.gain >= 0 && track.gain <= std::pow(10.0, 12.0 / 20.0), "Invalid multiloop track");
            }
            require(!part.pitchSemitones || (*part.pitchSemitones >= -6 && *part.pitchSemitones <= 6), "Invalid region pitch");
            unique(part.id);
            if (!part.parentRegionID) { regionEdges.emplace_back(part.startTime, 1); regionEdges.emplace_back(part.endTime, -1); }
            else {
                const auto parent = std::find_if(s.parts.begin(), s.parts.end(), [&](const auto& candidate) { return candidate.id == *part.parentRegionID; });
                require(parent != s.parts.end() && !parent->parentRegionID && parent->id != part.id && part.startTime >= parent->startTime && part.endTime <= parent->endTime, "Invalid unified region");
            }
            require(!part.color || *part.color <= 0xFFFFFF, "Invalid region color");
            require(finite(part.startTime) && finite(part.endTime) && part.startTime >= 0 && part.endTime > part.startTime && part.endTime <= s.duration, "Invalid part interval");
        }
        std::sort(regionEdges.begin(), regionEdges.end());
        int regionOverlap = 0;
        for (const auto& edge : regionEdges) { regionOverlap += edge.second; require(regionOverlap <= 2, "At most two regions may overlap"); }
    }
    if (p.regionSetlist) validateRegionSetlist(p, *p.regionSetlist);
    for (const auto& setlist : p.setlists) {
        unique(setlist.id);
        std::set<ID> seen;
        for (const auto& id : setlist.songIds) require(songIds.count(id) && seen.insert(id).second, "Invalid setlist reference");
    }
}
void synchronizeTimecode(Project& project) {
    for (auto& song : project.songs) for (auto& track : song.tracks) if (track.role.id == "timecode") {
        std::unordered_map<ID, AudioClip> previous;
        previous.reserve(track.clips.size());
        for (auto& clip : track.clips) { const auto id = clip.id; previous.emplace(id, std::move(clip)); }
        track.clips.clear();
        track.clips.reserve(song.parts.size());
        for (const auto& part : song.parts) {
            if (part.parentRegionID) continue;
            ID id = part.id;
            // Stable UUID namespace distinct from its owning region.
            if (id.size() == 36) {
                const auto value = std::stoi(id.substr(0, 1), nullptr, 16) ^ 8;
                id[0] = "0123456789ABCDEF"[value];
            } else id += "-timecode";
            AudioClip clip;
            if (auto existing = previous.find(id); existing != previous.end()) clip = std::move(existing->second);
            clip.id = std::move(id);
            clip.name = "TIMECODE";
            clip.startTime = std::max(0.0, part.startTime + clip.timecodeStartOffset.value_or(0));
            const double end = std::max(clip.startTime + 0.01, part.endTime + clip.timecodeEndOffset.value_or(0));
            clip.duration = end - clip.startTime;
            song.duration = std::max(song.duration, end);
            track.clips.push_back(std::move(clip));
        }
    }
}

}
