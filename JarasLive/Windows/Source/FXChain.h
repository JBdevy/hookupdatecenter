#pragma once
#include "Session.h"
#include "FXSchema.h"
#include "../../Core/Audio/CreativeEffects.hpp"
namespace catlive::fxchain {
inline var settings(const Session &session, const ID &id) {
    if (id.empty()) return session.project().masterFXJSON ? JSON::parse(text(*session.project().masterFXJSON)) : var();
    for (const auto &song : session.project().songs) for (const auto &track : song.tracks) {
        if (track.id == id) return track.fxJSON ? JSON::parse(text(*track.fxJSON)) : var();
        for (const auto &clip : track.clips)
            if (clip.id == id) return clip.fxJSON ? JSON::parse(text(*clip.fxJSON)) : var();
    }
    return {};
}
inline bool isInstrument(const var &settings, const String &key) {
    for (const auto &plugin : list(get(settings, "externalPlugins")))
        if (key == "External:" + str(plugin, "id")) return str(plugin, "category").containsIgnoreCase("Instrument");
    auto kind = key;
    for (const auto &instance : list(get(settings, "instances")))
        if (key == "Native:" + str(instance, "id") || key == "Instance:" + str(instance, "id")) {
            kind = str(instance, "kind");
            break;
        }
    return kind == "Instruments" || kind == "CatSynth" || kind == "Drummer Pad 16" || kind == "Drummer Pad 48";
}
inline bool addsInstrument(const var &previous, const var &next) {
    const auto old = list(get(previous, "inserted"));
    const auto added = list(get(next, "inserted"));
    return std::any_of(added.begin(), added.end(), [&](const auto &key) {
        return !old.contains(key) && isInstrument(next, key.toString());
    });
}
inline String enabledKey(const String &kind) {
    if (kind == "Wave LFO") return "waveLFOEnabled";
    if (const auto *spec = jaras::audio::creativeEffect(utf8(kind))) return spec->enabledField;
    if (kind == "CatLive Trigger") return "triggerEnabled";
    if (kind == "Drummer Pad 16") return "drummer16Enabled";
    if (kind == "Drummer Pad 48") return "drummer48Enabled";
    if (kind == "CatSynth") return "catSynthEnabled";
    if (kind == "Arpeggiator") return "arpeggiatorEnabled";
    if (kind == "Cat Gate") return "gateEnabled";
    if (kind == "CatStemSeparation 5") return "stemSeparatorEnabled";
    for (auto name : {"EQ", "Compressor", "Limiter", "Pitch", "Delay", "Reverb"})
        if (kind == name) return kind.toLowerCase() + "Enabled";
    return {};
}
inline bool enabled(const var &value, const String &key) {
    for (const auto &instance : list(get(value, "instances")))
        if (key == "Native:" + str(instance, "id") || key == "Instance:" + str(instance, "id"))
            return enabled(get(instance, "settings"), str(instance, "kind"));
    for (const auto &plugin : list(get(value, "externalPlugins")))
        if (key == "External:" + str(plugin, "id")) return !flag(plugin, "bypassed");
    if (key == "Instruments") return str(value, "instrumentID").isNotEmpty() && !flag(value, "instrumentBypassed");
    if (key == "CatStemSeparation 5") return false;
    const auto property = enabledKey(key);
    return property.isNotEmpty() && flag(value, Identifier(property));
}
inline bool allBypassed(const var &value) {
    const auto chain = list(get(value, "inserted"));
    return !chain.isEmpty() && std::none_of(chain.begin(), chain.end(), [&](const var &key) { return enabled(value, key.toString()); });
}
inline void setEnabled(var &value, const String &key, bool on) {
    for (auto instance : list(get(value, "instances")))
        if (key == "Native:" + str(instance, "id") || key == "Instance:" + str(instance, "id")) {
            auto nested = get(instance, "settings"); setEnabled(nested, str(instance, "kind"), on); return;
        }
    for (auto plugin : list(get(value, "externalPlugins")))
        if (key == "External:" + str(plugin, "id")) { put(plugin, "bypassed", !on); return; }
    if (key == "Instruments") { put(value, "instrumentBypassed", !on); return; }
    const auto property = enabledKey(key);
    if (property.isNotEmpty()) put(value, Identifier(property), on);
}
inline bool stripBypassed(const var &value) { return get(value, "mixerBypassRestore").isArray(); }
inline void maintainStripBypass(var &value) {
    if (!stripBypassed(value)) return;
    const auto previous = list(get(value, "mixerBypassRestore"));
    Array<var> restore;
    for (const auto &key : list(get(value, "inserted"))) {
        if (enabled(value, key.toString()) || previous.contains(key)) restore.add(key);
        if (enabled(value, key.toString())) setEnabled(value, key.toString(), false);
    }
    put(value, "mixerBypassRestore", restore);
}
inline void toggleStripBypass(Session &session, const ID &target, bool sessionWide) {
    if (session.busy || jaras::projectSync::readOnly()) return;
    const bool on = sessionWide ? !flag(settings(session, {}), "sessionFXBypassed")
                                : !stripBypassed(settings(session, target));
    std::set<ID> targets{target};
    if (sessionWide) for (const auto &song : session.project().songs)
        for (const auto &track : song.tracks) if (jaras::fixedTrackName(track.role).empty()) targets.insert(track.id);
    std::map<ID,var> changes;
    for (const auto &id : targets) {
        auto value = settings(session, id);
        if (!value.isObject()) value = fxschema::defaults();
        const bool existing = stripBypassed(value);
        const bool masterSwitch = sessionWide && id.empty();
        if (on && !existing) {
            put(value, "mixerBypassRestore", Array<var>{});
            if (sessionWide) put(value, "bypassAppliedBySession", true);
            maintainStripBypass(value);
        } else if (!on && existing && (!sessionWide || flag(value, "bypassAppliedBySession"))) {
            for (const auto &key : list(get(value, "mixerBypassRestore")))
                if (list(get(value, "inserted")).contains(key)) setEnabled(value, key.toString(), true);
            value.getDynamicObject()->removeProperty("mixerBypassRestore");
            value.getDynamicObject()->removeProperty("bypassAppliedBySession");
        } else if (!masterSwitch) continue;
        if (masterSwitch) {
            if (on) put(value, "sessionFXBypassed", true);
            else value.getDynamicObject()->removeProperty("sessionFXBypassed");
        }
        changes.emplace(id, std::move(value));
    }
    if (!changes.empty()) session.configureEffects(changes);
}
inline Colour colour(const var &value, bool master = false) {
    return list(get(value, "inserted")).isEmpty() ? Colours::white : allBypassed(value) ? Colour(master ? 0xffff4245 : 0xffff3b30) : theme::green;
}
inline void change(Session &session, const std::vector<ID> &targets, bool remove) {
    std::map<ID, var> changes;
    bool bypass = false;
    for (const auto &id : targets) {
        auto value = settings(session, id);
        if (list(get(value, "inserted")).isEmpty()) continue;
        bypass |= !allBypassed(value);
        changes.emplace(id, value);
    }
    for (auto &[id, value] : changes) {
        if (remove) value = var();
        else for (const auto &key : list(get(value, "inserted"))) setEnabled(value, key.toString(), !bypass);
    }
    session.configureEffects(changes);
}
inline void bind(QuietButton &button, Session &session, ID id,
                 std::function<void(bool)> action) {
    button.setTooltip(String::fromUTF8("FX · Shift+clique: bypass · Alt+clique: remover todos · Ctrl+Z: desfazer"));
    button.modifiedClick = [&session, id, action](ModifierKeys mods) {
        if (mods.isCtrlDown() || (!mods.isAltDown() && !mods.isShiftDown())) return false;
        if (!list(get(settings(session, id), "inserted")).isEmpty()) action(mods.isAltDown());
        return true;
    };
    button.context = [safe = Component::SafePointer<QuietButton>(&button), &session, id, action](Point<int>) {
        const auto value = settings(session, id);
        if (!safe || list(get(value, "inserted")).isEmpty()) return;
        PopupMenu menu; menu.addItem(1, "Bypass", true, allBypassed(value));
        menu.showMenuAsync(PopupMenu::Options().withTargetComponent(safe.getComponent()),
                          [safe, action](int result) { if (safe && result == 1) action(false); });
    };
}
} // namespace catlive::fxchain
