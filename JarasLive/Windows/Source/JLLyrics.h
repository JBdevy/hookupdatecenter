#pragma once
#include "ProjectCodec.h"

namespace catlive::jlLyrics {
struct Document {
    int teleprompter = 1;
    std::vector<jaras::AudioClip> items;
    double end() const {
        double result = 0;
        for (const auto &item : items) result = std::max(result, item.startTime + item.duration);
        return result;
    }
};

inline Document read(const File &file) {
    auto value = JSON::parse(file);
    Document doc;
    const auto track = num(value, "teleprompter");
    if (num(value, "version") != 1 || (track != 1 && track != 2))
        throw std::runtime_error("Invalid .jllyrics file.");
    doc.teleprompter = int(track);
    for (const auto &valueItem : list(get(value, "items"))) {
        auto offset = get(valueItem, "offset"), duration = get(valueItem, "duration"), lyrics = get(valueItem, "text");
        jaras::AudioClip item;
        item.startTime = double(offset); item.duration = double(duration);
        if ((!offset.isDouble() && !offset.isInt() && !offset.isInt64()) ||
            (!duration.isDouble() && !duration.isInt() && !duration.isInt64()) || !lyrics.isString() ||
            !std::isfinite(item.startTime) || !std::isfinite(item.duration) || item.duration < .01 ||
            !std::isfinite(item.startTime + item.duration))
            throw std::runtime_error("Invalid .jllyrics item.");
        item.name = utf8(get(valueItem, "name").toString()); item.text = utf8(lyrics.toString());
        doc.items.push_back(std::move(item));
    }
    if (doc.items.empty()) throw std::runtime_error("No items in .jllyrics file.");
    return doc;
}

inline void write(const File &destination, int teleprompter, const std::vector<jaras::AudioClip> &clips,
                  double origin) {
    Array<var> items;
    for (const auto &clip : clips) if (clip.text) {
        const auto duration = clip.duration;
        if (duration < .01) continue;
        auto item = object();
        put(item, "offset", clip.startTime - origin);
        put(item, "duration", duration);
        put(item, "name", text(clip.name));
        put(item, "text", text(*clip.text));
        items.add(item);
    }
    if (items.isEmpty()) return;
    auto document = object();
    put(document, "version", 1);
    put(document, "teleprompter", teleprompter);
    put(document, "items", var(items));
    if (!destination.replaceWithText(JSON::toString(document, true)))
        throw std::runtime_error("Could not save .jllyrics file.");
}

inline jaras::Track &track(jaras::Song &song, int teleprompter) {
    const std::string role = teleprompter == 2 ? "teleprompt2" : "teleprompt";
    auto found = std::find_if(song.tracks.begin(), song.tracks.end(), [&](const auto &t) { return t.role.id == role; });
    if (found != song.tracks.end()) return *found;
    jaras::Track created;
    created.id = uuid();
    created.role.id = role;
    created.name = jaras::fixedTrackName(created.role);
    created.color = 0x54ff93;
    const auto before = std::find_if(song.tracks.begin(), song.tracks.end(), [](const auto &t) { return jaras::fixedTrackName(t.role).empty(); });
    return *song.tracks.insert(before, std::move(created));
}

inline void insert(jaras::Song &song, const Document &doc, double position, std::optional<ID> region = {}) {
    auto &channel = track(song, doc.teleprompter);
    for (auto clip : doc.items) {
        clip.startTime += position;
        if (clip.startTime < 0 || !std::isfinite(clip.startTime + clip.duration))
            throw std::runtime_error("The lyrics extend before the start of the project.");
        clip.id = uuid();
        clip.regionOwnerID = region;
        song.duration = std::max(song.duration, clip.startTime + clip.duration);
        channel.clips.push_back(std::move(clip));
    }
}
} // namespace catlive::jlLyrics
