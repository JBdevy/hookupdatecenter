#pragma once
#include "Appearance.h"
namespace catlive {
inline const jaras::Track *actionTrack(const jaras::Song &song, const ID &selected, int number) {
    auto standard = [](const auto &track) {
        return jaras::fixedTrackName(track.role).empty() && track.role.id != "group";
    };
    if (number > 0) {
        if (number > (int)song.tracks.size())
            return nullptr;
        const auto &track = song.tracks[(size_t)number - 1];
        return standard(track) ? &track : nullptr;
    }
    for (const auto &track : song.tracks)
        if (track.id == selected && standard(track))
            return &track;
    for (const auto &track : song.tracks)
        if (standard(track))
            return &track;
    return nullptr;
}
inline double midiFaderGain(float value) {
    return value > 0 && std::isfinite(value)
               ? std::pow(10., (-60 + jlimit(0.f, 1.f, value) * 72) / 20.)
               : 0;
}
struct ActionDefinition {
    const char *id, *title;
    int category;
    const char *defaultKey;
    bool track = false, continuous = false;
    bool supportsMIDI() const {
        return String(id) != "normalizeItems" && String(id) != "createTempoMarker";
    }
    bool fixedKeyboard() const { return String(id) == "setlistUp" || String(id) == "setlistDown"; }
    bool repeats() const {
        const String action(id);
        return action == "tempoDown" || action == "tempoUp" || action == "nextRegion" ||
               action == "previousRegion" || action == "nextTimelinePoint" ||
               action == "previousTimelinePoint" || fixedKeyboard();
    }
};
inline const std::vector<ActionDefinition> &actionDefinitions() {
    static const std::vector<ActionDefinition> definitions{
        {"tempoDown", "BPM −", 0, "-"},
        {"tempoUp", "BPM +", 0, "shift + +"},
        {"tapTempo", "Tap Tempo", 0, ""},
        {"playStop", "Play/Stop", 0, "spacebar"},
        {"play", "Play", 0, ""},
        {"stop", "Stop", 0, ""},
        {"pause", "Pause", 0, ""},
        {"transportFadeout", "Fadeout", 0, ""},
        {"repeatPlayback", "Repeat", 0, "R"},
        {"subPlayStop", "SubPlay/Stop", 0, "shift + spacebar"},
        {"subPlay", "Sub Play", 0, ""},
        {"tunerDown", "Tuner −", 0, ""},
        {"tunerUp", "Tuner +", 0, ""},
        {"volumeTrack", "Volume Track", 1, "", true, true},
        {"panTrack", "Pan Track", 1, "", true, true},
        {"volumeMaster", "Volume Master", 1, "", false, true},
        {"muteTrack", "Mute Track", 2, "M", true},
        {"muteMaster", "Mute Master", 2, ""},
        {"soloTrack", "Solo Track", 3, "shift + S", true},
        {"soloMaster", "Solo Master", 3, ""},
        {"partsUp", "Parts Up", 4, ""},
        {"partsDown", "Parts Down", 4, ""},
        {"toggleParts", "Parts show/hide", 4, ""},
        {"setlistUp", "Setlist Up", 4, "cursor up"},
        {"setlistDown", "Setlist Down", 4, "cursor down"},
        {"toggleAuto", "Setlist Auto on/off", 4, ""},
        {"ignoreNext", "Ignore Next", 4, "0"},
        {"toggleSetlist", "Setlist show/hide", 4, "F2"},
        {"toggleMultiLoopBypass", "Multiloops BYPASS on/off", 4, ""},
        {"selectTrack", "Select Track", 5, "", true},
        {"addTrack", "Add Track", 5, "ctrl + T"},
        {"splitItems", "Split stems", 5, "S"},
        {"projectStart", "Go to project start", 5, "Q"},
        {"projectEnd", "Go to project end", 5, "["},
        {"nextRegion", "Go to next region", 5, "D"},
        {"previousRegion", "Go to previous region", 5, "A"},
        {"nextTimelinePoint", "Next marker or region boundary", 5, "W"},
        {"previousTimelinePoint", "Previous marker or region boundary", 5, "E"},
        {"toggleVideo", "Video window on/off", 5, "alt + shift + V"},
        {"toggleTeleprompter", "Teleprompter window on/off", 5, "alt + shift + T"},
        {"normalizeItems", "Normalize selected items", 5, "N"},
        {"createTempoMarker", "Create tempo marker", 5, "ctrl + shift + T"},
        {"toggleTracks", "Tracks show/hide", 5, "F1"}};
    return definitions;
}
inline KeyPress normalizedActionKey(const KeyPress &key) {
    auto code = key.getKeyCode();
    if (key.getModifiers().isCtrlDown() && code > 0 && code <= 26)
        code = 'A' + code - 1;
    if (code >= 'a' && code <= 'z') code -= 'a' - 'A';
    return KeyPress(code, key.getModifiers(), key.getTextCharacter());
}
inline bool transportFadeoutReservedKey(const KeyPress &pressed) {
    const auto raw = pressed.getKeyCode();
    // Space belongs to transport under every modifier combination. Focus,
    // dismissal and deletion keys must keep their normal editor behaviour.
    if (raw == KeyPress::spaceKey || raw == KeyPress::tabKey || raw == KeyPress::returnKey ||
        raw == KeyPress::escapeKey || raw == KeyPress::deleteKey || raw == KeyPress::backspaceKey)
        return true;
    const auto key = normalizedActionKey(pressed);
    const auto code = key.getKeyCode();
    const auto mods = key.getModifiers();
    if ((code == KeyPress::F4Key && mods.isAltDown()) || code == KeyPress::F12Key) return true;
    if (mods.isCtrlDown() && !mods.isAltDown()) {
        if (code == 'S' || code == 'Z' || code == 'Y') return true;
        if (!mods.isShiftDown() && String("ACVDXNOIQ,").containsChar((juce_wchar)code)) return true;
    }
    if (code == 'M' && mods.isShiftDown() && !mods.isCtrlDown() && !mods.isAltDown()) return true;
    // Protect original defaults even when users removed/reassigned them.
    for (const auto &definition : actionDefinitions())
        if (String(definition.defaultKey).isNotEmpty() &&
            normalizedActionKey(KeyPress::createFromDescription(definition.defaultKey)) == key)
            return true;
    return false;
}
// Device callbacks enqueue only three MIDI bytes. Learning, persistence and project
// commands run on the message thread, never in the audio/MIDI callback.
class ActionBindings final : public ChangeBroadcaster,
                             private MidiInputCallback,
                             private AsyncUpdater {
  public:
    ActionBindings(Appearance &preferences, AudioDeviceManager &manager)
        : settings(preferences), devices(manager) {
        devices.addMidiInputDeviceCallback({}, this);
    }
    ~ActionBindings() override {
        devices.removeMidiInputDeviceCallback({}, this);
        cancelPendingUpdate();
    }
    std::function<void(const String &, float, int)> invoke;
    String learning, learningKind, error;
    bool hasCustomInput(const ActionDefinition &definition, const String &kind) const {
        if ((kind == "keyboard" && (definition.fixedKeyboard() || definition.continuous)) ||
            (kind == "midi" && !definition.supportsMIDI()))
            return false;
        const auto saved =
            get(settings.value("catlive.actions", object()), Identifier(definition.id), object());
        return saved.hasProperty(Identifier(kind)) &&
               (kind == "midi" ? get(saved, "midi").isObject()
                               : str(saved, "keyboard").isNotEmpty());
    }
    var binding(const ActionDefinition &definition) const {
        auto value =
            get(settings.value("catlive.actions", object()), Identifier(definition.id), object())
                .clone();
        if (!value.hasProperty("keyboard") && String(definition.defaultKey).isNotEmpty())
            put(value, "keyboard",
                KeyPress::createFromDescription(definition.defaultKey).getTextDescription());
        if (definition.fixedKeyboard())
            put(value, "keyboard",
                KeyPress::createFromDescription(definition.defaultKey).getTextDescription());
        if (definition.continuous)
            put(value, "keyboard", {});
        if (!definition.supportsMIDI())
            put(value, "midi", {});
        return value;
    }
    String inputLabel(const ActionDefinition &definition, const String &kind) const {
        const auto value = binding(definition);
        if (kind == "keyboard")
            return str(value, "keyboard");
        auto midi = get(value, "midi");
        if (!midi.isObject())
            return {};
        return String((int)num(midi, "status") == 0xb0 ? "CC " : "Note ") +
               String((int)num(midi, "number")) + " / Ch " + String((int)num(midi, "channel"));
    }
    String inputLabel(const String &id, const String &kind) const {
        for (const auto &definition : actionDefinitions())
            if (id == definition.id) return inputLabel(definition, kind);
        return {};
    }
    void begin(const String &action, const String &kind) {
        learning = action;
        learningKind = kind;
        error.clear();
        sendChangeMessage();
    }
    void cancel() {
        learning.clear();
        learningKind.clear();
        sendChangeMessage();
    }
    bool captureKey(const KeyPress &key) {
        if (learning.isEmpty() || learningKind != "keyboard")
            return false;
        if (key == KeyPress::escapeKey) {
            cancel();
            return true;
        }
        assign(learning, "keyboard", key.getTextDescription());
        return true;
    }
    bool key(const KeyPress &pressed, bool isRepeat = false) {
        if (captureKey(pressed))
            return true;
        for (const auto &definition : actionDefinitions()) {
            const auto b = binding(definition);
            const auto description = str(b, "keyboard");
            if (description.isNotEmpty() &&
                KeyPress::createFromDescription(description) == pressed) {
                if (invoke && (!isRepeat || definition.repeats()))
                    invoke(definition.id, 1.f, (int)num(b, "track"));
                return true;
            }
        }
        // A removed/reassigned default must not fall through to a legacy shortcut.
        for (const auto &definition : actionDefinitions())
            if (String(definition.defaultKey).isNotEmpty() &&
                KeyPress::createFromDescription(definition.defaultKey) == pressed)
                return true;
        return false;
    }
    bool assign(const String &id, const String &kind, var input) {
        const auto definition = std::find_if(actionDefinitions().begin(), actionDefinitions().end(),
                                             [&](const auto &entry) { return id == entry.id; });
        if (definition == actionDefinitions().end() ||
            (kind == "keyboard" && (definition->continuous || definition->fixedKeyboard())) ||
            (kind == "midi" &&
             (!definition->supportsMIDI() ||
              (definition->continuous && input.isObject() && (int)num(input, "status") != 0xb0))) ||
            (kind != "keyboard" && kind != "midi")) {
            error = String::fromUTF8("Este tipo de controle não pode ser atribuído à ação.");
            sendChangeMessage();
            return false;
        }
        if (kind == "keyboard" && input.toString().isNotEmpty()) {
            const auto parsed = KeyPress::createFromDescription(input.toString());
            if (!parsed.isValid()) {
                error = String::fromUTF8("Escolha uma tecla ou combinação válida.");
                sendChangeMessage();
                return false;
            }
            if (id == "transportFadeout" && transportFadeoutReservedKey(parsed)) {
                error = String::fromUTF8("Este atalho é reservado pelo CatLive e não pode acionar o Fadeout.");
                sendChangeMessage();
                return false;
            }
            const auto key = normalizedActionKey(parsed);
            if (key.getModifiers().isCtrlDown() &&
                String("QONSIYZ,").containsChar((juce_wchar)key.getKeyCode())) {
                error = String::fromUTF8("Este atalho pertence ao menu de projetos e edição.");
                sendChangeMessage();
                return false;
            }
            input = key.getTextDescription();
        }
        for (const auto &definition : actionDefinitions()) {
            if (id == definition.id)
                continue;
            const auto b = binding(definition);
            const auto existing = get(b, Identifier(kind));
            const bool same = kind == "keyboard" && existing.isString() && input.isString()
                ? normalizedActionKey(KeyPress::createFromDescription(existing.toString())) ==
                    normalizedActionKey(KeyPress::createFromDescription(input.toString()))
                : JSON::toString(existing) == JSON::toString(input);
            if (!input.isVoid() && input.toString().isNotEmpty() && same) {
                error = String::fromUTF8("Já está atribuído a ") + definition.title;
                sendChangeMessage();
                return false;
            }
        }
        auto values = settings.value("catlive.actions", object()).clone();
        auto entry = get(values, Identifier(id), object()).clone();
        put(entry, Identifier(kind), std::move(input));
        put(values, Identifier(id), entry);
        auto result = settings.set("catlive.actions", values);
        error = result.getErrorMessage();
        if (result.wasOk()) {
            learning.clear();
            learningKind.clear();
        }
        sendChangeMessage();
        return result.wasOk();
    }
    void setTrack(const String &id, int number) {
        auto values = settings.value("catlive.actions", object()).clone();
        auto entry = get(values, Identifier(id), object()).clone();
        if ((int)num(entry, "track") == std::max(0, number))
            return;
        put(entry, "track", std::max(0, number));
        put(values, Identifier(id), entry);
        error = settings.set("catlive.actions", values).getErrorMessage();
        sendChangeMessage();
    }

  private:
    Appearance &settings;
    AudioDeviceManager &devices;
    struct Input {
        int status = 0, number = 0, value = 0, channel = 0;
    };
    AbstractFifo queue{256};
    CriticalSection producers;
    std::array<Input, 256> pending;
    void handleIncomingMidiMessage(MidiInput *, const MidiMessage &message) override {
        if (!message.isNoteOn() && !message.isController())
            return;
        const ScopedLock lock(producers);
        int start, count, other, unused;
        queue.prepareToWrite(1, start, count, other, unused);
        if (count) {
            const auto *bytes = message.getRawData();
            pending[(size_t)start] = {bytes[0] & 0xf0, bytes[1], bytes[2], message.getChannel()};
            queue.finishedWrite(1);
            triggerAsyncUpdate();
        }
    }
    void handleAsyncUpdate() override {
        while (queue.getNumReady() > 0) {
            int start, count, other, unused;
            queue.prepareToRead(1, start, count, other, unused);
            if (!count)
                break;
            const auto input = pending[(size_t)start];
            queue.finishedRead(1);
            if (learningKind == "midi" && learning.isNotEmpty()) {
                auto def = std::find_if(actionDefinitions().begin(), actionDefinitions().end(),
                                        [&](const auto &d) { return learning == d.id; });
                if (def != actionDefinitions().end() && def->continuous && input.status != 0xb0) {
                    error = "Use um controle CC para volume ou pan.";
                    sendChangeMessage();
                    continue;
                }
                auto value = object();
                put(value, "status", input.status);
                put(value, "number", input.number);
                put(value, "channel", input.channel);
                assign(learning, "midi", value);
                continue;
            }
            for (const auto &definition : actionDefinitions()) {
                const auto b = binding(definition), midi = get(b, "midi");
                if (midi.isObject() && (int)num(midi, "status") == input.status &&
                    (int)num(midi, "number") == input.number &&
                    (int)num(midi, "channel") == input.channel) {
                    if (invoke && (definition.continuous || input.value > 0))
                        invoke(definition.id, input.value / 127.f, (int)num(b, "track"));
                    break;
                }
            }
        }
    }
};
} // namespace catlive
