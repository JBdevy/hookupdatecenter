#pragma once
#include "ActionBindings.h"

namespace catlive {
// Register with the actual Windows runTests(directory, test) harness. These use
// real KeyPress parsing, preferences persistence and ActionBindings dispatch.
template <typename Register>
void addActionBindingsTests(const File &directory, Register &&test) {
    const auto require = [](bool okay, const char *message) {
        if (!okay) throw std::runtime_error(message);
    };
    test("Panel shortcuts toggle once and preserve customized bindings", [&, require] {
        const auto file = directory.getChildFile("panel-shortcuts.json");
        require(file.replaceWithText("{}"), "Could not create panel preferences fixture");
        Appearance settings(file); AudioDeviceManager devices; ActionBindings bindings(settings, devices);
        for (const auto &pair : std::vector<std::pair<String, String>>{{"toggleTracks", "alt + T"}, {"toggleBarMixer", "alt + H"}, {"toggleSetlist", "alt + S"}}) {
            int calls = 0;
            bindings.invoke = [&](const String &id, float, int) { require(id == pair.first, "Wrong panel dispatch"); ++calls; };
            require(bindings.key(KeyPress::createFromDescription(pair.second)), "Default panel key did not dispatch");
            require(bindings.key(KeyPress::createFromDescription(pair.second), true) && calls == 1, "Held panel key toggled repeatedly");
        }
        auto saved = object(), tracks = object(), setlist = object();
        put(tracks, "keyboard", "F1"); put(setlist, "keyboard", "F2");
        put(saved, "toggleTracks", tracks); put(saved, "toggleSetlist", setlist);
        require(settings.set("catlive.actions", saved).wasOk(), "Could not set legacy defaults");
        require(KeyPress::createFromDescription(bindings.inputLabel("toggleTracks", "keyboard")) == KeyPress::createFromDescription("alt + T"), "F1 was not migrated");
        require(KeyPress::createFromDescription(bindings.inputLabel("toggleSetlist", "keyboard")) == KeyPress::createFromDescription("alt + S"), "F2 was not migrated");
        auto pause = object(); put(pause, "keyboard", "alt + T"); put(saved, "pause", pause);
        require(settings.set("catlive.actions", saved).wasOk(), "Could not set migration conflict");
        require(KeyPress::createFromDescription(bindings.inputLabel("toggleTracks", "keyboard")) == KeyPress(KeyPress::F1Key), "Migration overwrote custom shortcut");
        require(bindings.assign("toggleBarMixer", "keyboard", "F9"), "Could not remap Hoz-Mixer");
        Appearance restored(file); ActionBindings reopened(restored, devices);
        require(KeyPress::createFromDescription(reopened.inputLabel("toggleBarMixer", "keyboard")) == KeyPress(KeyPress::F9Key), "Custom panel binding was lost");
    });
    test("Hoz-Mixer migrates Alt B to Alt H without losing MIDI or custom shortcuts", [&, require] {
        const auto file = directory.getChildFile("hoz-mixer-shortcut-migration.json");
        require(file.replaceWithText("{}"), "Could not create migration fixture");
        Appearance settings(file); AudioDeviceManager devices; ActionBindings bindings(settings, devices);
        auto saved = object(), mixer = object(), midi = object();
        put(mixer, "keyboard", "alt + B");
        put(midi, "status", 0xb0); put(midi, "number", 77); put(midi, "channel", 1);
        put(mixer, "midi", midi); put(saved, "toggleBarMixer", mixer);
        require(settings.set("catlive.actions", saved).wasOk(), "Could not save legacy Hoz-Mixer shortcut");
        int calls = 0;
        bindings.invoke = [&](const String &id, float, int) { require(id == "toggleBarMixer", "Wrong migrated action"); ++calls; };
        require(bindings.key(KeyPress::createFromDescription("alt + H")) && calls == 1, "Alt H did not replace Alt B");
        require(!bindings.key(KeyPress::createFromDescription("alt + B")), "Old shortcut is still active");
        require(bindings.inputLabel("toggleBarMixer", "midi").contains("77"), "Migration lost MIDI mapping");
        auto pause = object(); put(pause, "keyboard", "alt + H"); put(saved, "pause", pause);
        require(settings.set("catlive.actions", saved).wasOk(), "Could not save conflict fixture");
        require(KeyPress::createFromDescription(bindings.inputLabel("toggleBarMixer", "keyboard")) == KeyPress::createFromDescription("alt + B"), "Migration replaced an occupied key");
        for (const auto &custom : {String(), String("F9")}) {
            put(mixer, "keyboard", custom); put(saved, "toggleBarMixer", mixer);
            require(settings.set("catlive.actions", saved).wasOk(), "Could not save custom fixture");
            Appearance restored(file); ActionBindings reopened(restored, devices);
            require(reopened.inputLabel("toggleBarMixer", "keyboard") == custom, "Custom or unbound key was replaced");
            require(reopened.inputLabel("toggleBarMixer", "midi").contains("77"), "Reload lost MIDI mapping");
        }
    });
    test("Transport Fadeout protects default and editor shortcuts", [&, require] {
        const auto file = directory.getChildFile("fadeout-reserved-actions.json");
        require(file.replaceWithText("{}"), "Could not create fadeout preferences fixture");
        Appearance settings(file);
        AudioDeviceManager devices;
        ActionBindings bindings(settings, devices);
        const auto at = std::find_if(actionDefinitions().begin(), actionDefinitions().end(),
            [](const auto &definition) { return String(definition.id) == "transportFadeout"; });
        require(at != actionDefinitions().end(), "Missing Fadeout action");
        require(at->category == 0 && String(at->defaultKey).isEmpty() && at->supportsMIDI() &&
                !at->track && !at->continuous && !at->repeats(), "Wrong Fadeout capabilities/default");
        require(bindings.inputLabel("transportFadeout", "keyboard").isEmpty(), "Fadeout installed a default shortcut");
        for (const auto &definition : actionDefinitions())
            if (String(definition.defaultKey).isNotEmpty())
                require(!bindings.assign("transportFadeout", "keyboard", definition.defaultKey), "Fadeout stole a standard shortcut");
        require(bindings.assign("playStop", "keyboard", "F6"), "Could not move transport shortcut fixture");
        require(bindings.assign("addTrack", "keyboard", "F7"), "Could not move track shortcut fixture");
        require(!bindings.assign("transportFadeout", "keyboard", "ctrl + T"), "Fadeout stole reassigned default");
        for (int modifiers = 0; modifiers < 8; ++modifiers) {
            const auto flags = ((modifiers & 1) ? ModifierKeys::ctrlModifier : 0) |
                               ((modifiers & 2) ? ModifierKeys::shiftModifier : 0) |
                               ((modifiers & 4) ? ModifierKeys::altModifier : 0);
            require(!bindings.assign("transportFadeout", "keyboard", KeyPress(KeyPress::spaceKey, flags, 0).getTextDescription()),
                    "Modified Space was assigned to Fadeout");
        }
        for (const auto *description : {"ctrl + A", "ctrl + C", "ctrl + V", "ctrl + D", "ctrl + X", "ctrl + Z",
             "ctrl + shift + Z", "ctrl + Y", "ctrl + N", "ctrl + O", "ctrl + S", "ctrl + shift + S",
             "ctrl + I", "ctrl + Q", "ctrl + ,", "shift + M", "alt + F4", "F12"})
            require(!bindings.assign("transportFadeout", "keyboard", description), "Fadeout stole an editor/menu shortcut");
        for (const auto code : {KeyPress::tabKey, KeyPress::returnKey, KeyPress::escapeKey,
                               KeyPress::deleteKey, KeyPress::backspaceKey})
            for (const auto mods : {0, (int)ModifierKeys::ctrlModifier, (int)ModifierKeys::shiftModifier})
                require(!bindings.assign("transportFadeout", "keyboard", KeyPress(code, mods, 0).getTextDescription()),
                        "Fadeout stole focus/dismissal/deletion key");
        for (const int code : {1, 3, 4, 14, 15, 17, 19, 22, 24, 25, 26})
            require(transportFadeoutReservedKey(KeyPress(code, ModifierKeys::ctrlModifier, 0)), "C0 editor shortcut was not reserved");
    });
    test("Transport Fadeout learning, conflicts, repeat suppression and MIDI persist", [&, require] {
        const auto file = directory.getChildFile("fadeout-assigned-actions.json");
        require(file.replaceWithText("{}"), "Could not create fadeout preferences fixture");
        Appearance settings(file);
        AudioDeviceManager devices;
        ActionBindings bindings(settings, devices);
        require(bindings.assign("tapTempo", "keyboard", "F9"), "Could not prepare existing custom binding");
        require(!bindings.assign("transportFadeout", "keyboard", "F9"), "Fadeout stole custom binding");
        bindings.begin("transportFadeout", "keyboard");
        require(bindings.captureKey(KeyPress(KeyPress::spaceKey)) && bindings.learning == "transportFadeout" && bindings.error.isNotEmpty(),
                "Rejected Fadeout shortcut ended capture or lost error");
        require(bindings.captureKey(KeyPress(KeyPress::F8Key)) && bindings.learning.isEmpty(), "Free Fadeout shortcut was not captured");
        require(KeyPress::createFromDescription(bindings.inputLabel("transportFadeout", "keyboard")) == KeyPress(KeyPress::F8Key),
                "Fadeout modal label differs from saved key");
        require(!bindings.assign("pause", "keyboard", "F8"), "Later action stole Fadeout shortcut");
        int invocationCount = 0;
        bindings.invoke = [&](const String &id, float value, int track) {
            require(id == "transportFadeout" && value == 1 && track == 0, "Wrong Fadeout dispatch payload");
            ++invocationCount;
        };
        require(bindings.key(KeyPress(KeyPress::F8Key)), "Fadeout shortcut did not dispatch");
        for (int repeat = 0; repeat < 5; ++repeat)
            require(bindings.key(KeyPress(KeyPress::F8Key), true), "Held Fadeout shortcut leaked");
        require(invocationCount == 1, "Held Fadeout shortcut triggered repeatedly");
        auto midi = object(); put(midi, "status", 0x90); put(midi, "number", 64); put(midi, "channel", 4);
        require(bindings.assign("transportFadeout", "midi", midi), "Fadeout did not accept MIDI note trigger");
        require(!bindings.assign("pause", "midi", midi), "Later action stole Fadeout MIDI trigger");
        require(bindings.inputLabel("transportFadeout", "midi").contains("64"), "Fadeout MIDI label missing");
        require(bindings.assign("transportFadeout", "keyboard", {}), "Could not remove optional Fadeout keyboard shortcut");
        Appearance reloaded(file);
        ActionBindings restored(reloaded, devices);
        require(restored.inputLabel("transportFadeout", "keyboard").isEmpty() &&
                restored.inputLabel("transportFadeout", "midi").contains("64"), "MIDI-only Fadeout binding did not survive reload");
        put(midi, "status", 0xb0);
        require(restored.assign("transportFadeout", "midi", midi), "Fadeout did not accept MIDI CC trigger");
        restored.begin("transportFadeout", "keyboard");
        require(restored.captureKey(KeyPress(KeyPress::escapeKey)) && restored.learning.isEmpty(), "Escape did not cancel Fadeout learning");
    });
}
} // namespace catlive
