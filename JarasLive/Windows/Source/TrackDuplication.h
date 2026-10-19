#pragma once
#include "ProjectCodec.h"
#include <cctype>
namespace catlive::trackEditing {
struct TrackDuplicationResult {
    var document;
    std::vector<ID> trackIDs;
    std::map<ID, ID> trackIDMap;
};
namespace duplication {
using IDs = std::map<ID, ID>;
inline ID id(const var &value) { return utf8(str(value, "id")); }
inline ID mapped(const ID &value, const IDs &ids) {
    const auto found = ids.find(value); return found == ids.end() ? value : found->second;
}
inline void remapField(var &owner, const Identifier &key, const IDs &ids) {
    const auto value = get(owner, key);
    if (value.isString()) put(owner, key, text(mapped(utf8(value.toString()), ids)));
}
inline void remapArray(var &owner, const Identifier &key, const IDs &ids) {
    if (!get(owner, key).isArray()) return;
    auto values = list(get(owner, key));
    for (int i = 0; i < values.size(); ++i)
        if (values[i].isString()) values.set(i, text(mapped(utf8(values[i].toString()), ids)));
    put(owner, key, values);
}
inline bool standard(const var &track) {
    static const std::set<ID> special{"generatedClick", "timecode", "video", "teleprompt", "teleprompt2", "chords"};
    return !special.count(utf8(str(track, "role")));
}
inline ID identityKey(const ID &value) {
    ID compact; for (auto c : value) if (c != '-') compact.push_back(c);
    if (compact.size() != 32 || !std::all_of(compact.begin(), compact.end(), [](unsigned char c) { return std::isxdigit(c); })) return value;
    for (auto &c : compact) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return compact;
}
class FreshIDs {
    std::set<ID> occupied;
    const std::function<ID()> &factory;
    void reserve(const var &value) {
        if (auto *node = value.getDynamicObject()) {
            if (!id(value).empty()) occupied.insert(identityKey(id(value)));
            if (auto *plugins = get(value, "externalPlugins").getDynamicObject())
                for (const auto &entry : plugins->getProperties()) occupied.insert(identityKey(utf8(entry.name.toString())));
            for (const auto &entry : node->getProperties()) reserve(entry.value);
        } else if (auto *values = value.getArray()) for (const auto &entry : *values) reserve(entry);
    }
  public:
    FreshIDs(const var &document, const std::function<ID()> &makeID) : factory(makeID) { reserve(document); }
    ID next() {
        if (!factory) throw std::invalid_argument("A duplicação precisa de novos identificadores.");
        auto result = factory();
        if (result.empty() || !occupied.insert(identityKey(result)).second)
            throw std::invalid_argument("A duplicação recebeu um identificador repetido.");
        return result;
    }
    ID replace(var &value, bool allowMissing = false) {
        const auto old = id(value);
        if (!value.isObject() || (!allowMissing && old.empty())) throw std::invalid_argument("Objeto sem identificador para duplicar.");
        put(value, "id", text(next())); return old;
    }
};
struct FXIdentities {
    IDs effects, plugins;
    std::map<ID, IDs> bands;
    void copyBands(var &settings, const ID &effect, FreshIDs &fresh) {
        for (auto band : list(get(settings, "bands"))) {
            const auto old = fresh.replace(band, true);
            if (!old.empty()) bands[effect][old] = id(band);
        }
    }
    void copy(var &settings, FreshIDs &fresh) {
        if (!settings.isObject()) return;
        copyBands(settings, "EQ", fresh);
        for (auto instance : list(get(settings, "instances"))) {
            const auto old = fresh.replace(instance);
            effects["Native:" + old] = "Native:" + id(instance);
            effects["Instance:" + old] = "Instance:" + id(instance);
            auto nested = get(instance, "settings");
            if (nested.isObject()) {
                copyBands(nested, "Native:" + old, fresh);
                bands["Instance:" + old] = bands["Native:" + old];
            }
        }
        const auto copyPlugin = [&](var &plugin, const ID &old) {
            if (!plugin.isObject() || old.empty()) throw std::invalid_argument("Plugin sem identificador para duplicar.");
            const auto replacement = fresh.next();
            plugins[old] = replacement; effects["External:" + old] = "External:" + replacement;
            if (!get(plugin, "id").isVoid()) put(plugin, "id", text(replacement));
            return replacement;
        };
        auto external = get(settings, "externalPlugins");
        if (external.isArray()) {
            for (auto plugin : list(external)) copyPlugin(plugin, id(plugin));
        } else if (auto *values = external.getDynamicObject()) {
            auto copies = object();
            for (const auto &entry : values->getProperties()) {
                auto plugin = entry.value; const auto replacement = copyPlugin(plugin, utf8(entry.name.toString()));
                put(copies, Identifier(text(replacement)), plugin);
            }
            put(settings, "externalPlugins", copies);
        }
        remapArray(settings, "inserted", effects);
    }
    void copyAutomation(var &automation, FreshIDs &fresh) const {
        for (auto envelope : list(get(automation, "envelopes"))) {
            fresh.replace(envelope);
            for (auto point : list(get(envelope, "points"))) fresh.replace(point);
            auto target = get(envelope, "target");
            if (!target.isObject()) continue;
            remapField(target, "plugin", plugins);
            auto native = get(target, "native");
            if (!native.isObject()) continue;
            const auto found = bands.find(utf8(str(native, "effect")));
            if (found != bands.end()) remapField(native, "band", found->second);
            remapField(native, "effect", effects);
        }
    }
};
inline void copyFXAndAutomation(var &owner, FreshIDs &fresh) {
    FXIdentities ids;
    auto fx = get(owner, "fx"), automation = get(owner, "automation");
    ids.copy(fx, fresh); ids.copyAutomation(automation, fresh);
}
inline void remapRouting(var &routing, const IDs &ids) {
    if (!routing.isObject()) return;
    remapArray(routing, "receives", ids); remapArray(routing, "transmitters", ids);
}
inline void appendRoute(var &track, const char *direction, const ID &destination) {
    auto routing = get(track, "routing"); if (!routing.isObject()) routing = object();
    auto slots = list(get(routing, Identifier(direction)));
    const var endpoint(text(destination));
    if (!slots.contains(endpoint)) slots.add(endpoint);
    put(routing, Identifier(direction), slots); put(track, "routing", routing);
}
inline bool sendsToGroup(const var &track) {
    const auto group = [](const var &patch) { return num(patch, "firstChannel") == -2; };
    const auto outputs = get(track, "outputs");
    if (outputs.isArray()) { const auto values = list(outputs); return std::any_of(values.begin(), values.end(), group); }
    const auto primary = get(track, "patch");
    return (primary.isObject() ? group(primary) : get(track, "parentTrackID").isString()) || group(get(track, "secondaryPatch"));
}
inline void appendMapped(var &owner, const char *key, const IDs &ids) {
    if (!get(owner, Identifier(key)).isArray()) return;
    auto values = list(get(owner, Identifier(key))); const auto original = values;
    for (const auto &value : original) {
        const auto found = ids.find(utf8(value.toString())); if (found != ids.end()) values.add(text(found->second));
    }
    put(owner, Identifier(key), values);
}
} // namespace duplication

// One document edit, with independent object identities and unchanged media and
// plugin payloads. The caller commits document + model atomically in one Undo.
inline TrackDuplicationResult duplicateDocument(const var &document, const ID &songID,
    const std::set<ID> &selectedIDs, const std::function<ID()> &makeID = uuid) {
    using namespace duplication;
    TrackDuplicationResult result{document.clone(), {}, {}};
    var song;
    for (const auto &candidate : list(get(result.document, "songs"))) if (id(candidate) == songID) { song = candidate; break; }
    if (!song.isObject()) return result;
    const auto tracks = list(get(song, "tracks"));
    std::map<ID, int> positions; IDs parents; std::set<ID> eligible, selected;
    for (int i = 0; i < tracks.size(); ++i) {
        const auto identity = id(tracks[i]); positions[identity] = i;
        if (standard(tracks[i])) eligible.insert(identity);
        if (get(tracks[i], "parentTrackID").isString()) parents[identity] = utf8(str(tracks[i], "parentTrackID"));
    }
    for (const auto &identity : selectedIDs) if (eligible.count(identity)) selected.insert(identity);
    if (selected.empty()) return result;
    (void)ProjectCodec::decode(document);
    for (;;) {
        const auto before = selected;
        for (const auto &track : tracks) {
            const auto identity = id(track); if (!eligible.count(identity)) continue;
            if (selected.count(utf8(str(track, "parentTrackID")))) selected.insert(identity);
            if (selected.count(identity)) {
                const auto partner = utf8(str(get(track, "stereoLink"), "partner"));
                if (eligible.count(partner)) selected.insert(partner);
            }
        }
        if (before == selected) break;
    }
    FreshIDs fresh(document, makeID);
    for (const auto &track : tracks) if (selected.count(id(track))) result.trackIDMap[id(track)] = fresh.next();
    const auto &mapping = result.trackIDMap;
    std::set<std::pair<ID, ID>> connections;
    for (const auto &track : tracks) {
        const auto identity = id(track); const auto routing = get(track, "routing");
        for (const auto &endpoint : list(get(routing, "receives"))) if (endpoint.isString()) connections.emplace(utf8(endpoint.toString()), identity);
        for (const auto &endpoint : list(get(routing, "transmitters"))) if (endpoint.isString()) connections.emplace(identity, utf8(endpoint.toString()));
    }
    for (auto edge = connections.begin(); edge != connections.end();) {
        const auto at = positions.find(edge->first);
        const bool implicit = at != positions.end() && utf8(str(tracks[at->second], "parentTrackID")) == edge->second && sendsToGroup(tracks[at->second]);
        if (implicit) edge = connections.erase(edge); else ++edge;
    }
    std::map<ID, var> copies;
    for (const auto &original : tracks) {
        const auto originalID = id(original); if (!selected.count(originalID)) continue;
        auto copy = original.clone(); put(copy, "id", text(mapping.at(originalID)));
        remapField(copy, "parentTrackID", mapping);
        auto routing = get(copy, "routing"); remapRouting(routing, mapping);
        auto link = get(copy, "stereoLink");
        if (link.isObject()) {
            remapField(link, "partner", mapping);
            auto restoredRouting = get(get(link, "original"), "routing"); remapRouting(restoredRouting, mapping);
        }
        for (const auto &edge : connections) {
            if (edge.first == originalID) appendRoute(copy, "transmitters", mapped(edge.second, mapping));
            if (edge.second == originalID) appendRoute(copy, "receives", mapped(edge.first, mapping));
        }
        copyFXAndAutomation(copy, fresh);
        for (auto clip : list(get(copy, "clips"))) {
            fresh.replace(clip); remapArray(clip, "separatedStemTracks", mapping);
            for (auto note : list(get(get(clip, "midi"), "notes"))) fresh.replace(note);
            copyFXAndAutomation(clip, fresh);
        }
        copies.emplace(originalID, std::move(copy));
    }
    const auto descendant = [&](const ID &child, const ID &ancestor) {
        auto current = child; std::set<ID> visited;
        while (parents.count(current) && visited.insert(current).second) {
            current = parents.at(current); if (current == ancestor) return true;
        }
        return false;
    };
    std::set<ID> roots;
    for (const auto &identity : selected)
        if (std::none_of(selected.begin(), selected.end(), [&](const ID &other) { return descendant(identity, other); })) roots.insert(identity);
    std::map<int, std::vector<ID>> insertions; std::set<ID> handled;
    for (const auto &root : tracks) {
        const auto rootID = id(root); if (!roots.count(rootID) || handled.count(rootID)) continue;
        std::set<ID> blockRoots{rootID}; const auto partner = utf8(str(get(root, "stereoLink"), "partner"));
        if (roots.count(partner) && get(tracks[positions.at(partner)], "parentTrackID") == get(root, "parentTrackID")) blockRoots.insert(partner);
        handled.insert(blockRoots.begin(), blockRoots.end());
        std::vector<ID> block; int last = 0;
        for (int i = 0; i < tracks.size(); ++i) {
            const auto identity = id(tracks[i]);
            if (std::any_of(blockRoots.begin(), blockRoots.end(), [&](const ID &r) { return identity == r || descendant(identity, r); })) {
                last = i; if (copies.count(identity)) block.push_back(identity);
            }
        }
        auto &insertion = insertions[last]; insertion.insert(insertion.end(), block.begin(), block.end());
    }
    Array<var> output;
    for (int i = 0; i < tracks.size(); ++i) {
        output.add(tracks[i]);
        for (const auto &originalID : insertions[i]) { result.trackIDs.push_back(mapping.at(originalID)); output.add(copies.at(originalID)); }
    }
    put(song, "tracks", output);
    for (auto part : list(get(song, "parts"))) {
        appendMapped(part, "pitchTrackIDs", mapping); appendMapped(part, "pitchGroupIDs", mapping);
        for (auto loop : list(get(part, "multiLoops"))) {
            if (!get(loop, "tracks").isArray()) continue;
            auto rules = list(get(loop, "tracks")); const auto original = rules;
            for (const auto &rule : original) {
                const auto found = mapping.find(id(rule));
                if (found != mapping.end()) { auto copy = rule.clone(); put(copy, "id", text(found->second)); rules.add(copy); }
            }
            put(loop, "tracks", rules);
        }
    }
    (void)ProjectCodec::decode(result.document);
    return result;
}
} // namespace catlive::trackEditing
