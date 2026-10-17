#include "TrackDuplication.h"
#include "ProjectCodec.h"
#include <algorithm>
#include <cctype>
#include <set>
#include <stdexcept>
#include <utility>

namespace catlive::native {
namespace {
using IDs = std::map<std::string, std::string>;
using IDSet = std::set<std::string>;
const json& field(const json& value, const char* key) {
    static const json none;
    if (!value.is_object()) return none;
    const auto found = value.find(key);
    return found == value.end() ? none : *found;
}
const json& array(const json& value) {
    static const json empty = json::array();
    return value.is_array() ? value : empty;
}
std::string string(const json& value) { return value.is_string() ? value.get<std::string>() : std::string(); }
std::string id(const json& value) { return string(field(value, "id")); }
std::string mapped(const std::string& value, const IDs& ids) {
    const auto found = ids.find(value);
    return found == ids.end() ? value : found->second;
}
void remap(json& value, const IDs& ids) {
    if (value.is_string()) value = mapped(value.get<std::string>(), ids);
}
void remapField(json& value, const char* key, const IDs& ids) {
    if (value.is_object() && value.contains(key)) remap(value[key], ids);
}
void remapArray(json& value, const IDs& ids) {
    if (value.is_array()) for (auto& entry : value) remap(entry, ids);
}
bool standard(const json& track) {
    static const IDSet special{"generatedClick", "timecode", "video", "teleprompt", "teleprompt2", "chords"};
    return !special.count(string(field(track, "role")));
}
std::string identityKey(const std::string& value) {
    // UUID case/dash spelling cannot make a newly generated identity unique.
    std::string compact;
    for (const auto ch : value) if (ch != '-') compact.push_back(ch);
    if (compact.size() != 32 || !std::all_of(compact.begin(), compact.end(), [](unsigned char c) { return std::isxdigit(c); })) return value;
    for (auto& ch : compact) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    return compact;
}
class FreshIDs {
    IDSet occupied;
    const std::function<std::string()>& factory;
    void reserve(const json& value) {
        if (value.is_object()) {
            const auto identity = id(value);
            if (!identity.empty()) occupied.insert(identityKey(identity));
            // Legacy Windows documents may use a dictionary of plugins.
            const auto& plugins = field(value, "externalPlugins");
            if (plugins.is_object()) for (const auto& entry : plugins.items()) occupied.insert(identityKey(entry.key()));
            for (const auto& entry : value.items()) reserve(entry.value());
        } else if (value.is_array()) for (const auto& entry : value) reserve(entry);
    }
  public:
    FreshIDs(const json& document, const std::function<std::string()>& makeID) : factory(makeID) { reserve(document); }
    std::string next() {
        if (!factory) throw std::invalid_argument("Track duplication requires an ID factory.");
        auto result = factory();
        if (result.empty() || !occupied.insert(identityKey(result)).second)
            throw std::invalid_argument("Track duplication received an empty or duplicate new ID.");
        return result;
    }
    std::string replace(json& value) {
        if (!value.is_object() || id(value).empty()) throw std::invalid_argument("Missing editable object identity.");
        const auto old = id(value);
        value["id"] = next();
        return old;
    }
};
struct FXIdentities {
    IDs effects, plugins;
    std::map<std::string, IDs> bands;
    void copyBands(json& settings, const std::string& effect, FreshIDs& fresh) {
        if (!field(settings, "bands").is_array()) return;
        for (auto& band : settings["bands"]) {
            const auto old = fresh.replace(band);
            bands[effect][old] = id(band);
        }
    }
    void copy(json& settings, FreshIDs& fresh) {
        if (!settings.is_object()) return;
        copyBands(settings, "EQ", fresh);
        if (field(settings, "instances").is_array()) {
            for (auto& instance : settings["instances"]) {
                const auto old = fresh.replace(instance);
                effects["Native:" + old] = "Native:" + id(instance);
                if (field(instance, "settings").is_object()) copyBands(instance["settings"], "Native:" + old, fresh);
            }
        }
        auto copyPlugin = [&](json& plugin, const std::string& originalID) {
            if (!plugin.is_object() || originalID.empty()) throw std::invalid_argument("Missing plugin identity.");
            const auto newID = fresh.next();
            plugins[originalID] = newID;
            effects["External:" + originalID] = "External:" + newID;
            if (plugin.contains("id")) plugin["id"] = newID;
            return newID;
        };
        if (field(settings, "externalPlugins").is_array()) {
            for (auto& plugin : settings["externalPlugins"]) copyPlugin(plugin, id(plugin));
        } else if (field(settings, "externalPlugins").is_object()) {
            json copies = json::object();
            for (const auto& entry : settings["externalPlugins"].items()) {
                auto plugin = entry.value();
                const auto newID = copyPlugin(plugin, entry.key());
                copies[newID] = std::move(plugin);
            }
            settings["externalPlugins"] = std::move(copies);
        }
        if (settings.contains("inserted")) remapArray(settings["inserted"], effects);
    }
    void copyAutomation(json& automation, FreshIDs& fresh) const {
        if (!field(automation, "envelopes").is_array()) return;
        for (auto& envelope : automation["envelopes"]) {
            fresh.replace(envelope);
            if (field(envelope, "points").is_array()) for (auto& point : envelope["points"]) fresh.replace(point);
            if (!field(envelope, "target").is_object()) continue;
            auto& target = envelope["target"];
            remapField(target, "plugin", plugins);
            if (!field(target, "native").is_object()) continue;
            auto& parameter = target["native"];
            const auto oldEffect = string(field(parameter, "effect"));
            const auto found = bands.find(oldEffect);
            if (found != bands.end()) remapField(parameter, "band", found->second);
            remapField(parameter, "effect", effects);
        }
    }
};
void copyFXAndAutomation(json& owner, FreshIDs& fresh) {
    FXIdentities identities;
    if (owner.contains("fx")) identities.copy(owner["fx"], fresh);
    if (owner.contains("automation")) identities.copyAutomation(owner["automation"], fresh);
}
void remapRouting(json& routing, const IDs& ids) {
    if (!routing.is_object()) return;
    if (routing.contains("receives")) remapArray(routing["receives"], ids);
    if (routing.contains("transmitters")) remapArray(routing["transmitters"], ids);
}
void appendRoute(json& track, const char* direction, const std::string& destination) {
    if (!field(track, "routing").is_object()) track["routing"] = json::object();
    auto& routes = track["routing"][direction];
    if (!routes.is_array()) routes = json::array();
    if (std::find(routes.begin(), routes.end(), destination) == routes.end()) routes.push_back(destination);
}
bool sendsToGroup(const json& track) {
    const auto group = [](const json& patch) { return field(patch, "firstChannel") == -2; };
    const auto& outputs = field(track, "outputs");
    if (outputs.is_array()) return std::any_of(outputs.begin(), outputs.end(), group);
    const auto& primary = field(track, "patch");
    return (primary.is_object() ? group(primary) : field(track, "parentTrackID").is_string()) || group(field(track, "secondaryPatch"));
}
void appendMapped(json& values, const IDs& ids) {
    if (!values.is_array()) return;
    const auto original = values;
    for (const auto& value : original) {
        const auto found = ids.find(string(value));
        if (found != ids.end()) values.push_back(found->second);
    }
}
} // namespace

TrackDuplicationResult duplicateTracks(const json& document, const std::string& songID,
    const std::vector<std::string>& selectedIDs, const std::function<std::string()>& makeID) {
    TrackDuplicationResult result{document, {}, {}};
    if (!field(document, "songs").is_array()) throw std::invalid_argument("Expected a project with songs.");
    const auto& songs = document["songs"];
    const auto sourceSong = std::find_if(songs.begin(), songs.end(), [&](const json& song) { return id(song) == songID; });
    if (sourceSong == songs.end()) return result;
    const auto& tracks = array(field(*sourceSong, "tracks"));
    std::map<std::string, std::size_t> positions;
    IDs parents;
    IDSet eligible, selected;
    for (std::size_t index = 0; index < tracks.size(); ++index) {
        const auto identity = id(tracks[index]);
        positions[identity] = index;
        if (standard(tracks[index])) eligible.insert(identity);
        if (field(tracks[index], "parentTrackID").is_string()) parents[identity] = string(tracks[index]["parentTrackID"]);
    }
    for (const auto& selectedID : selectedIDs) if (eligible.count(selectedID)) selected.insert(selectedID);
    if (selected.empty()) return result;
    (void)ProjectCodec::decode(document); // Reject malformed input before traversing its hierarchy.
    for (;;) {
        const auto before = selected;
        for (const auto& track : tracks) {
            const auto identity = id(track);
            if (!eligible.count(identity)) continue;
            if (selected.count(string(field(track, "parentTrackID")))) selected.insert(identity);
            if (selected.count(identity)) {
                const auto partner = string(field(field(track, "stereoLink"), "partner"));
                if (eligible.count(partner)) selected.insert(partner);
            }
        }
        if (before == selected) break;
    }
    if (tracks.size() + selected.size() > 512)
        throw std::invalid_argument("Track duplication would exceed the 512-track project limit.");
    FreshIDs fresh(document, makeID);
    for (const auto& track : tracks) if (selected.count(id(track))) result.trackIDMap[id(track)] = fresh.next();
    const auto& mapping = result.trackIDMap;
    std::set<std::pair<std::string, std::string>> connections;
    for (const auto& track : tracks) {
        const auto identity = id(track);
        const auto& routing = field(track, "routing");
        for (const auto& endpoint : array(field(routing, "receives"))) if (endpoint.is_string()) connections.emplace(string(endpoint), identity);
        for (const auto& endpoint : array(field(routing, "transmitters"))) if (endpoint.is_string()) connections.emplace(identity, string(endpoint));
    }
    for (auto edge = connections.begin(); edge != connections.end();) {
        const auto at = positions.find(edge->first);
        const bool implicitGroup = at != positions.end() && field(tracks[at->second], "parentTrackID") == edge->second && sendsToGroup(tracks[at->second]);
        if (implicitGroup) edge = connections.erase(edge); else ++edge;
    }
    std::map<std::string, json> copies;
    for (const auto& original : tracks) {
        const auto originalID = id(original);
        if (!selected.count(originalID)) continue;
        auto copy = original;
        copy["id"] = mapping.at(originalID);
        remapField(copy, "parentTrackID", mapping);
        if (copy.contains("routing")) remapRouting(copy["routing"], mapping);
        if (field(copy, "stereoLink").is_object()) {
            auto& link = copy["stereoLink"];
            remapField(link, "partner", mapping);
            if (field(field(link, "original"), "routing").is_object()) remapRouting(link["original"]["routing"], mapping);
        }
        // The other endpoint may be the only place a connection is persisted.
        // Record the corresponding connection on the copy, leaving originals intact.
        for (const auto& edge : connections) {
            if (edge.first == originalID) appendRoute(copy, "transmitters", mapped(edge.second, mapping));
            if (edge.second == originalID) appendRoute(copy, "receives", mapped(edge.first, mapping));
        }
        copyFXAndAutomation(copy, fresh);
        if (field(copy, "clips").is_array()) for (auto& clip : copy["clips"]) {
            fresh.replace(clip);
            if (clip.contains("separatedStemTracks")) remapArray(clip["separatedStemTracks"], mapping);
            if (field(field(clip, "midi"), "notes").is_array()) for (auto& note : clip["midi"]["notes"]) fresh.replace(note);
            copyFXAndAutomation(clip, fresh);
        }
        copies[originalID] = std::move(copy);
    }
    const auto descendant = [&](const std::string& child, const std::string& ancestor) {
        auto current = child;
        IDSet visited;
        while (parents.count(current) && visited.insert(current).second) {
            current = parents.at(current);
            if (current == ancestor) return true;
        }
        return false;
    };
    IDSet roots;
    for (const auto& identity : selected) {
        if (std::none_of(selected.begin(), selected.end(), [&](const std::string& other) { return descendant(identity, other); })) roots.insert(identity);
    }
    std::map<std::size_t, std::vector<std::string>> insertions;
    IDSet handled;
    for (const auto& root : tracks) {
        const auto rootID = id(root);
        if (!roots.count(rootID) || handled.count(rootID)) continue;
        IDSet blockRoots{rootID};
        const auto partner = string(field(field(root, "stereoLink"), "partner"));
        if (roots.count(partner) && field(tracks[positions.at(partner)], "parentTrackID") == field(root, "parentTrackID")) blockRoots.insert(partner);
        handled.insert(blockRoots.begin(), blockRoots.end());
        std::vector<std::string> block;
        std::size_t last = 0;
        for (std::size_t index = 0; index < tracks.size(); ++index) {
            const auto identity = id(tracks[index]);
            if (std::any_of(blockRoots.begin(), blockRoots.end(), [&](const std::string& r) { return identity == r || descendant(identity, r); })) {
                last = index;
                if (copies.count(identity)) block.push_back(identity);
            }
        }
        auto& insertion = insertions[last];
        insertion.insert(insertion.end(), block.begin(), block.end());
    }
    json output = json::array();
    for (std::size_t index = 0; index < tracks.size(); ++index) {
        output.push_back(tracks[index]);
        for (const auto& originalID : insertions[index]) {
            result.trackIDs.push_back(mapping.at(originalID));
            output.push_back(std::move(copies.at(originalID)));
        }
    }
    auto& song = result.document["songs"][static_cast<std::size_t>(sourceSong - songs.begin())];
    song["tracks"] = std::move(output);
    if (field(song, "parts").is_array()) for (auto& part : song["parts"]) {
        if (part.contains("pitchTrackIDs")) appendMapped(part["pitchTrackIDs"], mapping);
        if (part.contains("pitchGroupIDs")) appendMapped(part["pitchGroupIDs"], mapping);
        if (!field(part, "multiLoops").is_array()) continue;
        for (auto& loop : part["multiLoops"]) {
            if (!field(loop, "tracks").is_array()) continue;
            const auto rules = loop["tracks"];
            for (auto rule : rules) {
                const auto found = mapping.find(id(rule));
                if (found != mapping.end()) { rule["id"] = found->second; loop["tracks"].push_back(std::move(rule)); }
            }
        }
    }
    (void)ProjectCodec::decode(result.document); // Includes jaras::validate and routing-cycle checks.
    return result;
}
} // namespace catlive::native
