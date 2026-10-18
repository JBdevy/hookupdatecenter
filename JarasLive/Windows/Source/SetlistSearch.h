#pragma once
#include "Common.h"

namespace catlive::setlistSearch {
inline std::optional<size_t> regionNumber(const String &query, size_t count) {
    if (query.isEmpty() || !query.containsOnly("0123456789")) return {};
    size_t value=0;
    for (auto character : query) {
        const auto digit=(size_t)(character-'0');
        if (value>count/10 || (value==count/10 && digit>count%10)) return {};
        value=value*10+digit;
    }
    return value>0 ? std::optional<size_t>(value) : std::nullopt;
}
inline bool nameContains(const String &name, const String &query) {
    if (query.isEmpty()) return true;
    return FindNLSStringEx(LOCALE_NAME_USER_DEFAULT,FIND_FROMSTART|NORM_IGNORECASE|NORM_IGNORENONSPACE,
        name.toWideCharPointer(),-1,query.toWideCharPointer(),-1,nullptr,nullptr,nullptr,0)>=0;
}
inline std::vector<const jaras::Part *> results(const jaras::Song &song, const String &query, bool byRegionID) {
    const auto term=query.trim();
    const auto number=byRegionID ? regionNumber(term,song.parts.size()) : std::nullopt;
    std::vector<const jaras::Part *> matches;
    for (size_t index=0;index<song.parts.size();++index)
        if (number==index+1 || nameContains(text(song.parts[index].name),term))
            matches.push_back(&song.parts[index]);
    std::stable_sort(matches.begin(),matches.end(),[](auto *a,auto *b){return a->startTime<b->startTime;});
    return matches;
}
}
