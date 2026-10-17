#pragma once
#include "Common.h"

namespace catlive {
// Like macOS AppStorage, appearance belongs to this computer, not the .jl document.
class Appearance final : public ChangeBroadcaster {
  public:
    explicit Appearance(File file = {})
        : location(file == File() ? File::getSpecialLocation(File::userApplicationDataDirectory)
                                       .getChildFile("Hook Developer/CatLive/appearance.json") : std::move(file)) {
        auto loaded = JSON::parse(location);
        values = loaded.isObject() ? loaded : object();
    }
    float interfaceScale() const {
        const auto scale = (double)get(values, "jaras.interface.scale", 1.0);
        return std::isfinite(scale) ? (float)(std::round(jlimit(.6, 1.2, scale) * 10) / 10) : 1.f;
    }
    bool continuousScroll() const { return (bool)get(values, "jaras.timeline.continuousScroll", false); }
    int fontStyle() const { return jlimit(0, 2, (int)get(values, "jaras.setlist.fontStyle", 0)); }
    bool regionIDs() const { return str(values, "jaras.setlist.idMode", "playlist") == "region"; }
    Font setlistFont() const { return theme::font(13, fontStyle() != 0, fontStyle() == 2); }
    Colour colour(const String &key, uint32 defaultRGB) const {
        auto value = get(values, Identifier(key));
        return Colour(0xff000000u | ((value.isInt() || value.isInt64())
                                      ? ((uint32)(int64)value & 0xffffffu) : defaultRGB));
    }
    Colour setlistColour(bool playlist, bool child) const {
        return child ? colour("jaras.setlist.unifiedTextColor", 0xffeb3b)
                     : playlist ? colour("jaras.setlist.playlistTextColor", 0x00ff9a)
                                : colour("jaras.setlist.allRegionsTextColor", 0xffffff);
    }
    bool gridlines() const { return flag(values, "jaras.timeline.gridlines", true); }
    var value(const String &key, var fallback = {}) const { return get(values, Identifier(key), fallback); }
    Result set(const String &key, var value) {
        auto next = values.clone();
        put(next, Identifier(key), std::move(value));
        auto result = location.getParentDirectory().createDirectory();
        if (result.failed()) return result;
        if (!location.replaceWithText(JSON::toString(next)))
            return Result::fail("Could not save appearance settings: " + location.getFullPathName());
        values = std::move(next);
        sendChangeMessage();
        return Result::ok();
    }
  private:
    File location;
    var values;
};
}
