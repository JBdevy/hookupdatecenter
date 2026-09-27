#include "Models.hpp"
#include <cmath>
#include <set>
#include <stdexcept>
namespace jaras {
void validate(const Project& p) {
    auto require = [](bool valid, const char* message) { if (!valid) throw std::invalid_argument(message); };
    auto finite = [](double x) { return std::isfinite(x); };
    require(p.projectFormatVersion == 1 && p.minimumJarasVersion == "1.0.0", "Unsupported project version");
    require(!p.id.empty() && !p.name.empty(), "Missing project identity");
    std::set<ID> ids{p.id}, songIds;
    auto unique = [&](const ID& id) { require(!id.empty() && ids.insert(id).second, "Duplicate or empty UUID"); };
    for (const auto& s : p.songs) {
        unique(s.id); songIds.insert(s.id);
        require(finite(s.duration) && s.duration > 0 && finite(s.bpm) && s.bpm > 0, "Invalid song timing");
        for (const auto& t : s.tracks) {
            unique(t.id);
            require(finite(t.volume) && t.volume >= 0 && t.volume <= 1, "Invalid volume");
            require(finite(t.pan) && t.pan >= -1 && t.pan <= 1 && t.output > 0, "Invalid routing");
            for (const auto& clip : t.clips) {
                unique(clip.id);
                require(finite(clip.startTime) && finite(clip.duration) && clip.startTime >= 0 && clip.duration > 0 && clip.startTime + clip.duration <= s.duration, "Invalid clip interval");
                require(finite(clip.sourceOffset) && clip.sourceOffset >= 0, "Invalid source offset");
                for (double peak : clip.waveform) require(finite(peak) && peak >= 0 && peak <= 1, "Invalid waveform peak");
            }
            if (t.audioFile) {
                const auto& path = t.audioFile->path;
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
        for (const auto& part : s.parts) {
            unique(part.id);
            require(finite(part.startTime) && finite(part.endTime) && part.startTime >= 0 && part.endTime > part.startTime && part.endTime <= s.duration, "Invalid part interval");
        }
    }
    for (const auto& setlist : p.setlists) {
        unique(setlist.id);
        std::set<ID> seen;
        for (const auto& id : setlist.songIds) require(songIds.count(id) && seen.insert(id).second, "Invalid setlist reference");
    }
}
}
