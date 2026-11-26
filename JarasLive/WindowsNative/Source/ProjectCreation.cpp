#include "ProjectCreation.h"
#include "ProjectCodec.h"
#include <algorithm>
#include <cctype>
#include <ctime>
#include <iomanip>
#include <locale>
#include <set>
#include <sstream>
#include <stdexcept>

namespace catlive::native {
namespace {
std::string creationTime() {
    const auto now = std::time(nullptr);
    std::tm utc{};
#ifdef _WIN32
    if (gmtime_s(&utc, &now) != 0) throw std::runtime_error("Could not determine project creation time.");
#else
    if (!gmtime_r(&now, &utc)) throw std::runtime_error("Could not determine project creation time.");
#endif
    std::ostringstream value;
    value.imbue(std::locale::classic());
    value << std::put_time(&utc, "%Y-%m-%dT%H:%M:%SZ");
    return value.str();
}
bool validName(const std::string& value) {
    return value.find('\0') == std::string::npos && value.find_first_not_of(" \t\r\n") != std::string::npos;
}
std::string identityKey(const std::string& value) {
    std::string compact;
    for (const auto ch : value) if (ch != '-') compact.push_back(ch);
    if (compact.size() != 32 || !std::all_of(compact.begin(), compact.end(), [](unsigned char c) { return std::isxdigit(c); })) return value;
    for (auto& ch : compact) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    return compact;
}
} // namespace

ProjectCreationResult createRecordingProject(const std::string& projectName,
    std::size_t channels, const std::function<std::string()>& makeID,
    const std::string& trackNamePrefix) {
    if (channels < 1 || channels > maximumRecordingChannels)
        throw std::invalid_argument("REC Multitrack requires between 1 and 128 input channels.");
    if (!validName(projectName) || !validName(trackNamePrefix))
        throw std::invalid_argument("Choose a project name and a track name prefix.");
    if (!makeID) throw std::invalid_argument("Project creation requires an ID factory.");
    std::set<std::string> identifiers;
    const auto nextID = [&] {
        auto value = makeID();
        if (value.empty() || !identifiers.insert(identityKey(value)).second)
            throw std::invalid_argument("Project creation received an empty or duplicate new ID.");
        return value;
    };
    jaras::Project project;
    project.id = nextID(); project.name = projectName;
    project.createdAt = creationTime(); project.updatedAt = project.createdAt;
    project.masterColor = 0x414141;
    jaras::Song song;
    song.id = nextID(); song.name = projectName; song.duration = 300; song.bpm = 120;
    song.timeSettings = jaras::ProjectTimeSettings{};
    song.timeSettings->timebase = jaras::ProjectTimebase::relative;
    ProjectCreationResult result;
    result.armedTrackIDs.reserve(channels);
    song.tracks.reserve(channels);
    for (std::size_t index = 0; index < channels; ++index) {
        jaras::Track track;
        track.id = nextID();
        std::ostringstream name;
        name.imbue(std::locale::classic());
        name << trackNamePrefix << ' ' << std::setw(2) << std::setfill('0') << index + 1;
        track.name = name.str(); track.role.id = "other";
        track.color = 0x828282;
        track.inputPatch = jaras::OutputPatch{static_cast<int>(index + 1), 1};
        track.recordingChannels = 1;
        track.inputMonitoring = false;
        track.output = 1;
        track.outputs = std::vector<jaras::OutputPatch>{{0, 2}};
        // No per-track recordingFormat: use the existing Advanced preference.
        result.armedTrackIDs.push_back(track.id);
        song.tracks.push_back(std::move(track));
    }
    project.setlists.push_back({nextID(), projectName, {song.id}});
    project.songs.push_back(std::move(song));
    result.document = ProjectCodec::encode(project);
    (void)ProjectCodec::decode(result.document);
    return result;
}

} // namespace catlive::native
