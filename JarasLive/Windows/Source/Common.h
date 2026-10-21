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
// Mac parameter controls change by click/drag or keyboard. Wheel input belongs
// to the containing scroll view and never enters Slider's value-editing path.
class ParameterSlider : public Slider {
  public:
    ParameterSlider() = default;
    ParameterSlider(SliderStyle style, TextEntryBoxPosition text) : Slider(style, text) {}
    void mouseDown(const MouseEvent &event) override {
        dragging = event.mods.isLeftButtonDown() && !event.mods.isPopupMenu();
        if (dragging) Slider::mouseDown(event);
    }
    void mouseDrag(const MouseEvent &event) override {
        if (dragging) Slider::mouseDrag(event);
    }
    void mouseUp(const MouseEvent &event) override {
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
inline const Colour background{0xff161616}, panel{0xff1d1d1d}, line{0xff444444},
    secondary{0xffb9b9b9}, display{0xff101010}, titlebar{0xff222222}, green{0xff69ed91},
    yellow{0xffffdc52}, accent{0xff79f59a}, transportPlay{0xff24f06a}, transportRed{0xff8f2847};
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
} // namespace theme
int runTests(const File &directory);
} // namespace catlive
