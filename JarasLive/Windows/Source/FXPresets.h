#pragma once
#include "Common.h"
namespace catlive::fxpresets {
inline void erase(var &value, const Identifier &key) {
    if (auto *object = value.getDynamicObject()) object->removeProperty(key);
}
inline const StringArray &fields(const String &kind) {
    static const std::map<String, StringArray> values{
        {"CatStemSeparation 5", {"stemSeparatorEnabled", "stemMix"}},
        {"EQ", {"eqEnabled", "bands"}},
        {"Compressor", {"compressorEnabled", "threshold", "ratio", "attack", "release", "makeup"}},
        {"Limiter", {"limiterEnabled", "limiter"}}, {"Pitch", {"pitchEnabled", "pitchSemitones"}},
        {"Delay", {"delayEnabled", "delayTime", "feedback", "delayMix"}},
        {"Reverb", {"reverbEnabled", "reverbRoom", "reverbMix", "reverbDecay", "reverbLowCut", "reverbHighCut"}},
        {"Instruments", {"instrumentID", "instrumentParameters", "instrumentBypassed"}}};
    static const StringArray empty;
    const auto found = values.find(kind);
    return found == values.end() ? empty : found->second;
}
inline bool parameter(const String &key) { return !key.endsWith("Enabled") && key != "instrumentBypassed"; }
inline String identity(const String &kind, const var &settings) {
    return "native:" + kind + (kind == "Instruments" ? ":" + str(settings, "instrumentID") : String());
}
inline var parameters(const String &kind, const var &settings) {
    auto value = object();
    for (const auto &key : fields(kind)) if (parameter(key) && !get(settings, Identifier(key)).isVoid())
        put(value, Identifier(key), get(settings, Identifier(key)).clone());
    return value;
}
inline void apply(const String &kind, var &settings, const var &preset) {
    if (str(preset, "plugin") != identity(kind, settings) || !get(preset, "native").isObject())
        throw std::runtime_error("This preset belongs to another plugin.");
    auto value = get(preset, "native");
    for (const auto &key : fields(kind)) if (parameter(key)) {
        erase(settings, Identifier(key));
        if (!get(value, Identifier(key)).isVoid()) put(settings, Identifier(key), get(value, Identifier(key)).clone());
    }
}
inline bool matches(const String &kind, const var &settings, const var &preset) {
    if (str(preset, "plugin") != identity(kind, settings)) return false;
    auto a = parameters(kind, settings), b = parameters(kind, get(preset, "native"));
    for (auto *value : {&a, &b}) for (auto band : list(get(*value, "bands"))) erase(band, "id");
    return JSON::toString(a, true) == JSON::toString(b, true);
}
inline var capture(const String &kind, const var &settings, String name) {
    name = name.trim();
    if (name.isEmpty() || name.length() > 80 || name.equalsIgnoreCase("Default"))
        throw std::runtime_error("Choose a preset name other than Default (1-80 characters).");
    auto preset = object(); put(preset, "id", text(uuid())); put(preset, "name", name);
    put(preset, "plugin", identity(kind, settings)); put(preset, "native", parameters(kind, settings));
    return preset;
}
class Store {
  public:
    explicit Store(File file = File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("CatLive/FXPresets.json")) : file(std::move(file)) {}
    int64 revision() const { return file.getLastModificationTime().toMilliseconds(); }
    var read() const {
        if (!file.existsAsFile()) { auto value = object(); put(value, "version", 1); put(value, "presets", Array<var>{}); put(value, "defaults", object()); return value; }
        var value; auto result = JSON::parse(file.loadFileAsString(), value);
        if (result.failed() || (int)num(value, "version") != 1 || !get(value, "presets").isArray() || !get(value, "defaults").isObject())
            throw std::runtime_error("Could not read the preset library.");
        return value;
    }
    void write(const var &library) const {
        if (file.getParentDirectory().createDirectory().failed()) throw std::runtime_error("Could not create the preset directory.");
        TemporaryFile temporary(file);
        if (!temporary.getFile().replaceWithText(JSON::toString(library)) || !temporary.overwriteTargetFileWithTemporary())
            throw std::runtime_error("Could not save the preset library.");
    }
    static Array<var> entries(const var &library, const String &plugin) {
        Array<var> result; for (const auto &preset : list(get(library, "presets"))) if (str(preset, "plugin") == plugin) result.add(preset);
        std::sort(result.begin(), result.end(), [](const var &a, const var &b) { return str(a,"name").compareNatural(str(b,"name")) < 0; });
        return result;
    }
    static void save(var &library, const var &preset) {
        auto all = list(get(library, "presets"));
        for (const auto &entry : all) if (str(entry, "plugin") == str(preset, "plugin") && str(entry, "name").equalsIgnoreCase(str(preset, "name")))
            throw std::runtime_error("A preset with this name already exists.");
        all.add(preset); put(library, "presets", all);
    }
    static void setDefault(var &library, const String &plugin, const String &id) {
        if (id.isNotEmpty()) {
            bool found = false; for (const auto &preset : entries(library, plugin)) found |= str(preset, "id") == id;
            if (!found) throw std::runtime_error("Preset not found for this plugin.");
        }
        auto defaults = get(library, "defaults");
        if (id.isEmpty()) erase(defaults, Identifier(plugin)); else put(defaults, Identifier(plugin), id);
    }
    void applyDefault(const String &kind, var &settings) const {
        const auto library = read();
        const auto plugin = identity(kind, settings);
        const auto id = str(get(library, "defaults"), Identifier(plugin));
        if (id.isEmpty()) return;
        for (const auto &preset : entries(library, plugin)) if (str(preset, "id") == id) { apply(kind, settings, preset); return; }
        throw std::runtime_error("Default preset not found.");
    }
  private:
    File file;
};
} // namespace catlive::fxpresets
