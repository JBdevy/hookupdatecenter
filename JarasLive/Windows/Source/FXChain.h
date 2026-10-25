#pragma once
#include "Session.h"
namespace catlive::fxchain {
inline var settings(const Session &session, const ID &id) {
    if (id.empty()) return session.project().masterFXJSON ? JSON::parse(text(*session.project().masterFXJSON)) : var();
    for (const auto &song : session.project().songs) for (const auto &track : song.tracks)
        if (track.id == id) return track.fxJSON ? JSON::parse(text(*track.fxJSON)) : var();
    return {};
}
inline String enabledKey(const String &kind) {
    if (kind == "CatLive Trigger") return "triggerEnabled";
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
