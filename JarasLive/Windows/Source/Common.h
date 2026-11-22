#pragma once
#include "Import/TrackTaxonomy.hpp"
#include "Transport/Engine.hpp"
#include <JuceHeader.h>
#include "AudioFormats.h"
#include <windows.h>
#include <atomic>
#include <functional>
#include <map>
#include <set>
#include <unordered_map>

namespace catlive {
using namespace juce;
using jaras::ID;
inline String mixerPanText(double value) {
    const int percent = roundToInt(100 * jlimit(0., 1., std::abs(std::isfinite(value) ? value : 0.)));
    return percent == 0 ? String("Center") : String(percent) + (value < 0 ? "%L" : "%R");
}
// Mac parameter controls change by click/drag or keyboard. Wheel input belongs
// to the containing scroll view and never enters Slider's value-editing path.
class ParameterSlider : public Slider {
  public:
    std::function<void(const MouseEvent &)> backgroundDown, backgroundDrag, backgroundUp;
    bool backgroundGesture=false;
    ParameterSlider() = default;
    ParameterSlider(SliderStyle style, TextEntryBoxPosition text) : Slider(style, text) {}
    String getTooltip() override {
        return (bool)getProperties()["panValueTooltip"] ? mixerPanText(getValue()) : Slider::getTooltip();
    }
    void mouseDown(const MouseEvent &event) override {
        const bool onReadout = getComponentID() == "trackVolume" ? event.x >= getWidth() - 42 : event.x < 42;
        backgroundGesture=backgroundDown && getSliderStyle()!=Slider::RotaryVerticalDrag && onReadout;
        if(backgroundGesture){backgroundDown(event);return;}
        dragging = event.mods.isLeftButtonDown() && !event.mods.isPopupMenu();
        if (dragging) Slider::mouseDown(event);
    }
    void mouseDrag(const MouseEvent &event) override {
        if(backgroundGesture){if(backgroundDrag)backgroundDrag(event);return;}
        if (dragging) Slider::mouseDrag(event);
    }
    void mouseUp(const MouseEvent &event) override {
        if(backgroundGesture){if(backgroundUp)backgroundUp(event);backgroundGesture=false;return;}
        if (dragging) Slider::mouseUp(event);
        dragging = false;
    }
    void mouseDoubleClick(const MouseEvent &event) override {
        if (event.mods.isLeftButtonDown() && !event.mods.isPopupMenu()) Slider::mouseDoubleClick(event);
    }
    void mouseWheelMove(const MouseEvent &event, const MouseWheelDetails &wheel) override {
        Component::mouseWheelMove(event, wheel);
    }
  private:
    bool dragging = false;
};
class QuietButton : public TextButton {
  public:
    explicit QuietButton(const String &title = {}) : TextButton(title) {}
    std::function<void(Point<int>)> context;
    std::function<bool(ModifierKeys)> modifiedClick;
    void mouseDown(const MouseEvent &e) override {
        right = e.mods.isPopupMenu();
        if (right) {
            if (context)
                context(e.getScreenPosition());
            return;
        }
        if (e.mods.isLeftButtonDown() && modifiedClick && modifiedClick(e.mods)) {
            right = true; // consume the matching mouse-up as well
            return;
        }
        TextButton::mouseDown(e);
    }
    void mouseUp(const MouseEvent &e) override {
        if (right) {
            right = false;
            return;
        }
        TextButton::mouseUp(e);
    }

  private:
    bool right = false;
};
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
inline constexpr uint32 darkBackgroundRGB = 0x0f0f0f;
inline const Colour darkBackground{0xff000000u | darkBackgroundRGB};
inline Colour background = darkBackground, panel = darkBackground, display = darkBackground, titlebar = darkBackground;
inline Colour scrollRail{0xff1f1f1f}, homeBackground{0xff0f0f0f}, line{0xff444444}, secondary{0xffb9b9b9};
inline const Colour transportPanelTop{0xff10291c}, transportPanelBottom{0xff07100b};
inline const Colour transportPanelBorder{0xff505050};
inline const Colour transportDetailTop{0xff1f1f1f}, transportDetailBottom{0xff1a1a1a}, transportDetailBorder{0xff3b3b3b};
inline const Colour lightDarkBackground{0xff242424}, lightDarkPanel{0xff2b2b2b}, lightDarkDisplay{0xff202020};
inline const Colour darkFaderRail{0xff0a0a0a};
inline Colour faderRail = darkFaderRail;
inline const Colour darkMixerStripeSurface{0xff262626};
inline const Colour lightDarkMixerStripeSurface{0xff000000u | jaras::Project::defaultMasterColor};
inline Colour mixerStripeSurface = darkMixerStripeSurface;
inline Colour trackStripeSurface(bool selected) {
    return selected ? mixerStripeSurface.interpolatedWith(Colours::white, .11f) : mixerStripeSurface;
}
inline constexpr int trackMixerMinHeight = 66, trackMixerStripeWidth = 5, hozMixerStripeHeight = 2;
inline constexpr int trackMixerMinWidth = 278;
inline constexpr auto trackMixerStyleKey = "jaras.trackMixer.trackStyle";
inline constexpr auto hozMixerStyleKey = "jaras.hozMixer.trackStyle";
inline constexpr auto interfaceThemeKey = "jaras.interface.theme";
inline constexpr auto defaultInterfaceTheme = "lightDark";
inline bool setInterfaceTheme(bool lightDark) {
    const auto next = lightDark ? lightDarkBackground : darkBackground;
    if (background == next) return false;
    background = next;
    faderRail = lightDark ? lightDarkBackground : darkFaderRail;
    mixerStripeSurface = lightDark ? lightDarkMixerStripeSurface : darkMixerStripeSurface;
    panel = lightDark ? lightDarkPanel : darkBackground;
    display = lightDark ? lightDarkDisplay : darkBackground;
    titlebar = next;
    scrollRail = Colour(lightDark ? 0xff1c1c1c : 0xff1f1f1f);
    homeBackground = Colour(lightDark ? 0xff242424 : 0xff0f0f0f);
    line = Colour(lightDark ? 0xff494949 : 0xff444444);
    secondary = Colour(lightDark ? 0xffd7d7d7 : 0xffb9b9b9);
    return true;
}
inline Colour mixerPanelBackground() { return background == darkBackground ? Colour(0xff181818) : lightDarkPanel; }
inline Colour libraryEntriesBackground() { return background == darkBackground ? Colour(0xff121212) : lightDarkDisplay; }
inline Colour timelineHeaderLine() { return line.withAlpha(.65f); }
inline const Colour green{0xff69ed91}, toolbarInactive{0xffc8c8c8},
    yellow{0xffffdc52}, accent{0xff79f59a}, transportPlay{0xff24f06a}, transportRed{0xff8f2847}, liveOffRed{0xffff3030};
inline constexpr auto timelineBackgroundKey = "jaras.timeline.backgroundOverride";
inline constexpr auto timelineVerticalGridKey = "jaras.timeline.primaryGridOverride";
inline constexpr auto timelineHorizontalGridKey = "jaras.timeline.horizontalGrid";
inline constexpr uint32 timelineBackgroundRGB = 0x222222;
inline constexpr uint32 timelinePrimaryGridRGB = 0x828282;
inline constexpr uint32 timelineHorizontalGridRGB = 0x000000;
inline bool isTimelineThemeColour(const String &key) {
    return key == timelineBackgroundKey || key == timelineVerticalGridKey || key == timelineHorizontalGridKey;
}
inline constexpr uint32 setlistQueuedYellowRGB = 0x807219;
inline constexpr uint32 timelinePlayCursorRGB = 0xf44336;
inline constexpr uint32 timelineEditCursorRGB = 0x00a65a;
inline const Colour trackButton{0xff414141}, trackControl{0xff141414}, trackMute{0xffff4444};
inline constexpr float trackButtonRadius = 4.f;
inline void progressBar(Graphics &g, juce::Rectangle<float> bounds, double fraction) {
    const auto bar = bounds.withSizeKeepingCentre(bounds.getWidth(), std::min(6.f, bounds.getHeight()));
    g.setColour(Colour(0xff121212)); g.fillRoundedRectangle(bar, 3.f);
    g.setColour(green);
    if (fraction >= 0 && fraction <= 1) g.fillRoundedRectangle(bar.withWidth(bar.getWidth() * (float)fraction), 3.f);
    else {
        const auto phase = std::fmod(Time::getMillisecondCounterHiRes() / 1400., 1.);
        Graphics::ScopedSaveState state(g); g.reduceClipRegion(bar.getSmallestIntegerContainer());
        g.fillRoundedRectangle(bar.withX(bar.getX() + (float)(phase * 1.3 - .3) * bar.getWidth()).withWidth(bar.getWidth() * .3f), 3.f);
    }
}
inline Colour role(const std::string &id) {
    static const std::map<std::string, uint32> colours{
        {"click", 0x77d18b}, {"generatedClick", 0x77d18b}, {"guide", 0x8ed2e1},
        {"timecode", 0xffdc52}, {"chords", 0x529eff}, {"video", 0xb47aff},
        {"teleprompt", 0x54ff93}, {"teleprompt2", 0x54ff93},
        {"drums", 0xd37365}, {"bass", 0xe9994d},           {"guitar", 0x80b760},
        {"keys", 0xb48acb},  {"accordion", 0xd9b45b},      {"backingVocal", 0x6fb4d5},
        {"fx", 0xc79e60}};
    auto i = colours.find(id);
    return Colour(0xff000000 | (i == colours.end() ? 0x969ed7 : i->second));
}
inline Colour track(const jaras::Track &t) {
    return t.color ? Colour(0xff000000 | *t.color) : role(t.role.id);
}
// Same colour treatment and text contrast as TrackNameContrast on macOS.
inline Colour trackSurface(Colour colour, bool emphasized, bool silenced) {
    if (emphasized) {
        const float peak = std::max({colour.getFloatRed(), colour.getFloatGreen(), colour.getFloatBlue()});
        const auto channel = [peak](float value) { return jlimit(0.f, 1.f, (peak - (peak - value) * 1.45f) * 1.15f); };
        colour = Colour::fromFloatRGBA(channel(colour.getFloatRed()), channel(colour.getFloatGreen()), channel(colour.getFloatBlue()), 1);
    }
    if (silenced) colour = Colour::greyLevel(.2126f * colour.getFloatRed() + .7152f * colour.getFloatGreen() + .0722f * colour.getFloatBlue());
    return colour.withAlpha(emphasized ? .65f : .5f);
}
inline Colour surfaceText(Colour surface, Colour backgroundColour = panel) {
    const auto colour = backgroundColour.overlaidWith(surface);
    const auto linear = [](float value) { return value <= .04045f ? value / 12.92f : std::pow((value + .055f) / 1.055f, 2.4f); };
    const auto luminance = .2126f * linear(colour.getFloatRed()) + .7152f * linear(colour.getFloatGreen()) + .0722f * linear(colour.getFloatBlue());
    return (luminance + .05f) / .05f >= 1.05f / (luminance + .05f) ? Colours::black : Colours::white;
}
Font font(float size, bool bold = false, bool italic = false);
Font mediumFont(float size);
Font semiboldFont(float size);
Font setlistFont(float size, int style);
} // namespace theme
int runTests(const File &directory);
} // namespace catlive
