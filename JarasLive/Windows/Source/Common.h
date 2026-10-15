#pragma once
#include "Import/TrackTaxonomy.hpp"
#include "Transport/Engine.hpp"
#include <JuceHeader.h>
#include <windows.h>
#include <atomic>
#include <functional>
#include <map>
#include <set>
#include <unordered_map>

namespace catlive {
using namespace juce;
using jaras::ID;
inline String text(const std::string &s) { return String::fromUTF8(s.data(), (int)s.size()); }
inline std::string utf8(const String &s) { return s.toStdString(); }
inline String unicodeCase(const String &value, bool upper = true) {
    if (value.isEmpty())
        return value;
    const auto flags = upper ? LCMAP_UPPERCASE : LCMAP_LOWERCASE;
    const int count = LCMapStringEx(LOCALE_NAME_INVARIANT, flags, value.toWideCharPointer(), -1,
                                    nullptr, 0, nullptr, nullptr, 0);
    if (count <= 0)
        return value;
    std::vector<wchar_t> mapped((size_t)count);
    if (LCMapStringEx(LOCALE_NAME_INVARIANT, flags, value.toWideCharPointer(), -1, mapped.data(),
                      count, nullptr, nullptr, 0) <= 0)
        return value;
    return String(mapped.data());
}
inline ID uuid() { return utf8(Uuid().toDashedString().toUpperCase()); }
inline var object() { return var(new DynamicObject()); }
inline void put(var &value, const Identifier &key, var data) {
    value.getDynamicObject()->setProperty(key, std::move(data));
}
inline var get(const var &value, const Identifier &key, var fallback = {}) {
    return value.getProperty(key, fallback);
}
inline double num(const var &value, const Identifier &key, double fallback = 0) {
    return (double)get(value, key, fallback);
}
inline String str(const var &value, const Identifier &key, String fallback = {}) {
    return get(value, key, fallback).toString();
}
inline bool flag(const var &value, const Identifier &key, bool fallback = false) {
    return (bool)get(value, key, fallback);
}
inline Array<var> list(const var &v) { return v.isArray() ? *v.getArray() : Array<var>{}; }
inline String clockText(double seconds, bool hours = false) {
    const auto t = (int64)std::max(0.0, seconds);
    return hours ? String::formatted("%02lld:%02lld:%02lld", t / 3600, t / 60 % 60, t % 60)
                 : String::formatted("%02lld:%02lld", t / 60, t % 60);
}
namespace theme {
inline const Colour background{0xff1e1e1e}, panel{0xff252525}, line{0xff444444},
    secondary{0xffb9b9b9}, display{0xff141414}, titlebar{0xff2b2b2b}, green{0xff69ed91},
    yellow{0xffffdc52}, accent{0xff79f59a};
inline Colour role(const std::string &id) {
    static const std::map<std::string, uint32> colours{
        {"click", 0x8ca4b0}, {"generatedClick", 0x8ca4b0}, {"guide", 0x8ed2e1},
        {"drums", 0xd37365}, {"bass", 0xe9994d},           {"guitar", 0x80b760},
        {"keys", 0xb48acb},  {"accordion", 0xd9b45b},      {"backingVocal", 0x6fb4d5},
        {"fx", 0xc79e60}};
    auto i = colours.find(id);
    return Colour(0xff000000 | (i == colours.end() ? 0x828282 : i->second));
}
inline Colour track(const jaras::Track &t) {
    return t.color ? Colour(0xff000000 | *t.color) : role(t.role.id);
}
Font font(float size, bool bold = false, bool italic = false);
Font mediumFont(float size);
Font semiboldFont(float size);
} // namespace theme
int runTests(const File &directory);
} // namespace catlive
