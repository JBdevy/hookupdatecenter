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
        auto metro = JSON::parse(metronomeFile());
        metronomeValues = metro.isObject() ? metro : object();
        for (auto key : {"enabled","preset","mode","gainA","gainB","output","pathA","pathB"}) {
            const Identifier full("jaras.metronome." + String(key));
            if (get(metronomeValues,full).isVoid() && !get(values,full).isVoid())put(metronomeValues,full,get(values,full));
        }
    }
    // Legacy appearance files may contain 75%/125%. The workspace is now
    // always 100%; the native peer still follows the monitor's system DPI.
    float interfaceScale() const { return 1.f; }
    bool continuousScroll() const { return (bool)get(values, "jaras.timeline.continuousScroll", false); }
    int fontStyle() const {
        const int style = (int)get(values, "jaras.setlist.fontStyle", 0);
        return isPositiveAndBelow(style, 7) ? style : 0;
    }
    bool regionIDs() const { return str(values, "jaras.setlist.idMode", "playlist") == "region"; }
    Font setlistFont() const { return theme::setlistFont(13, fontStyle()); }
    Colour colour(const String &key, uint32 defaultRGB) const {
        auto stored = get(previews, Identifier(key), get(values, Identifier(key)));
        if (theme::isTimelineThemeColour(key)) {
            if (stored.isVoid() && key == theme::timelineBackgroundKey) {
                const auto legacy = value("jaras.timeline.background", -1);
                if ((int)legacy != 0x0f0f0f && (int)legacy != 0x222222) stored = legacy;
            }
            if (stored.isVoid() && key == theme::timelineVerticalGridKey) {
                const auto legacy = value("jaras.timeline.primaryGrid", -1);
                if ((int)legacy != 0xbdbdbd) stored = legacy;
            }
            if (value(theme::interfaceThemeKey, theme::defaultInterfaceTheme).toString() == "dark") {
                if (key == theme::timelineBackgroundKey) defaultRGB = theme::darkBackgroundRGB;
                else if (key == theme::timelineVerticalGridKey) defaultRGB = 0x5c5c5c;
            }
            if ((int64)stored < 0) stored = var();
        }
        return Colour(0xff000000u | ((stored.isInt() || stored.isInt64())
                                      ? ((uint32)(int64)stored & 0xffffffu) : defaultRGB));
    }
    Colour setlistColour(bool playlist, bool child) const {
        return child ? colour("jaras.setlist.unifiedTextColor", 0xffeb3b)
                     : playlist ? colour("jaras.setlist.playlistTextColor", 0x00ff9a)
                                : colour("jaras.setlist.allRegionsTextColor", 0xffffff);
    }
    bool invertWaveformColors() const { return flag(values, "jaras.timeline.invertWaveformColors", false); }
    bool mixerStripeOnly(const String &key) const { return value(key, "default").toString() == "stripeOnly"; }
    bool gridlines() const { return flag(values, "jaras.timeline.gridlines", true); }
    var value(const String &key, var fallback = {}) const {
        return get(key.startsWith("jaras.metronome.") ? metronomeValues : values, Identifier(key), fallback);
    }
    // Audio controls are not appearance changes. Persist on one worker without
    // reloading preferences or broadcasting a workspace-wide layout refresh.
    void setMetronome(const String &key, var value, std::function<void(String)> completion = {}) {
        jassert(key.startsWith("jaras.metronome."));
        put(metronomeValues,Identifier(key),std::move(value));
        const auto destination=metronomeFile();
        const auto snapshot=metronomeValues.clone();
        static ThreadPool writer(1);
        writer.addJob([destination,snapshot,key,completion=std::move(completion)] {
            auto merged=JSON::parse(destination);
            if(!merged.isObject())merged=snapshot.clone();
            put(merged,Identifier(key),get(snapshot,Identifier(key)));
            const auto result=destination.getParentDirectory().createDirectory();
            const auto error=result.failed()?result.getErrorMessage():destination.replaceWithText(JSON::toString(merged))?String():String("Could not save metronome settings");
            if(completion)MessageManager::callAsync([completion,error]{completion(error);});
        });
    }
    File storageFile() const { return location; }
    void preview(const String &key,var value) { put(previews,Identifier(key),value);sendChangeMessage(); }
    void clearPreview(const String &key) { if(auto *p=previews.getDynamicObject())p->removeProperty(Identifier(key));sendChangeMessage(); }
    void reload() { auto loaded = JSON::parse(location); if (loaded.isObject()) values = std::move(loaded); }
    Result set(const String &key, var value, bool notify = true) {
        reload();
        auto next = values.clone();
        put(next, Identifier(key), std::move(value));
        auto result = location.getParentDirectory().createDirectory();
        if (result.failed()) return result;
        if (!location.replaceWithText(JSON::toString(next)))
            return Result::fail("Could not save appearance settings: " + location.getFullPathName());
        values = std::move(next);
        if (notify) sendChangeMessage();
        return Result::ok();
    }
  private:
    File location;
    var values;
    var metronomeValues;
    File metronomeFile() const { return location.getSiblingFile(location.getFileNameWithoutExtension()+"-metronome.json"); }
    var previews=object();
};
}
