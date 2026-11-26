#pragma once
#include "../Transport/PlaybackScope.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace jaras::fullLyrics {
inline std::vector<std::string> stanzas(const std::string &text) {
    std::vector<std::string> result;
    std::string stanza, line;
    int blanks = 0;
    auto accept = [&] {
        const bool blank = line.find_first_not_of(" \t\v\f") == std::string::npos;
        if (blank) ++blanks;
        else {
            if (blanks >= 2 && !stanza.empty()) { result.push_back(stanza); stanza.clear(); }
            else if (blanks == 1 && !stanza.empty()) stanza += '\n';
            if (!stanza.empty()) stanza += '\n';
            stanza += line; blanks = 0;
        }
        line.clear();
    };
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '\r' || text[i] == '\n') {
            accept();
            if (text[i] == '\r' && i + 1 < text.size() && text[i + 1] == '\n') ++i;
        } else line += text[i];
    }
    accept();
    if (!stanza.empty()) result.push_back(stanza);
    return result;
}
struct Range { ID region; std::string name; double start = 0, end = 0; };
inline Range range(const Song &song, double position) {
    const Part *root = nullptr;
    if (std::isfinite(position)) for (const auto &part : song.parts)
        if (!part.parentRegionID && part.startTime <= position && position < part.endTime &&
            (!root || part.endTime - part.startTime < root->endTime - root->startTime)) root = &part;
    if (!root) throw std::runtime_error("Posicione o cursor de edição dentro de uma música.");
    std::vector<const Part *> children;
    for (const auto &part : song.parts) if (part.parentRegionID == root->id) children.push_back(&part);
    std::sort(children.begin(), children.end(), [&](auto a, auto b) { return playbackRegionStart(song, *a) < playbackRegionStart(song, *b); });
    Range result{root->id, root->name, root->startTime, root->endTime};
    if (!children.empty()) {
        const Part *child = nullptr;
        double end = root->endTime;
        for (const auto *part : children) {
            if (playbackRegionStart(song, *part) <= position) child = part;
            else { end = playbackRegionStart(song, *part); break; }
        }
        if (!child) throw std::runtime_error("Posicione o cursor de edição dentro de uma música.");
        result = {child->id, child->name, std::max(root->startTime, playbackRegionStart(song, *child)), std::min({root->endTime, child->endTime, end})};
    }
    if (!std::isfinite(result.start) || !std::isfinite(result.end) || result.start < 0 || result.end <= result.start || position >= result.end)
        throw std::runtime_error("Posicione o cursor de edição dentro de uma música.");
    return result;
}
template <typename MakeID>
std::vector<AudioClip> items(const Range &range, const std::string &text, MakeID makeID) {
    const auto verses = stanzas(text);
    if (verses.size() < 2) throw std::runtime_error("Separe pelo menos uma estrofe com duas linhas em branco.");
    const double length = (range.end - range.start) / double(verses.size());
    if (!std::isfinite(length) || length < .01) throw std::runtime_error("Há estrofes demais para a duração desta música.");
    std::vector<AudioClip> result;
    for (size_t i = 0; i < verses.size(); ++i) {
        AudioClip item; item.id = makeID(); item.text = verses[i];
        item.name = verses[i].substr(0, verses[i].find('\n'));
        item.startTime = range.start + double(i) * length;
        item.duration = (i + 1 == verses.size() ? range.end : range.start + double(i + 1) * length) - item.startTime;
        item.regionOwnerID = range.region; result.push_back(std::move(item));
    }
    return result;
}
}
