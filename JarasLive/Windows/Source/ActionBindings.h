#pragma once
#include "Appearance.h"
#include "Localization.h"
namespace catlive {
// These IDs describe a position among the current playlist's blocks, never a
// project UUID or a block name. The saved MIDI binding therefore works globally.
inline int setlistBlockActionNumber(const String &action) {
    if (!action.startsWith("setlistBlock:")) return 0;
    const auto suffix = action.substring(13);
    const auto number = suffix.getLargeIntValue();
    return number > 0 && number <= std::numeric_limits<int>::max() && suffix == String(number)
        ? (int)number : 0;
}
inline String setlistBlockAction(int number) { return "setlistBlock:" + String(number); }
inline String setlistBlockActionTitle(int number) {
    return String::formatted(localization::translate("Block ID %02d").toRawUTF8(), number);
}
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
        {"cancelSection", "Cancel queued section", 4, ""},
        {"setlistUp", "Setlist Up", 4, "cursor up"},
        {"setlistDown", "Setlist Down", 4, "cursor down"},
        {"toggleAuto", "Setlist Auto on/off", 4, ""},
        {"ignoreNext", "Ignore Next", 4, "0"},
        {"toggleSetlist", "Setlist show/hide", 4, "alt + S"},
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
        {"previousProjectTab", "Previous project tab", 5, ""},
        {"nextProjectTab", "Next project tab", 5, ""},
        {"toggleBarMixer", "Hoz-Mixer show/hide", 5, "alt + H"},
        {"toggleTracks", "Track Mixer show/hide", 5, "alt + T"}};
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
    std::atomic<bool> inputEnabled{true};
    ActionBindings(Appearance &preferences, AudioDeviceManager &manager)
        : settings(preferences), devices(manager) {
        devices.addMidiInputDeviceCallback({}, this);
    }
    ~ActionBindings() override {
        devices.removeMidiInputDeviceCallback({}, this);
        cancelPendingUpdate();
    }
    std::function<void(const String &, float, int)> invoke;
    std::function<bool(int,int,int,int)> rawMIDI;
    std::function<String(const var &)> externalMIDIConflict;
    std::function<Result(const var &)> transferExternalMIDI;
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
        const String action(definition.id);
        const auto legacy = action == "toggleTracks" ? KeyPress(KeyPress::F1Key)
                          : action == "toggleSetlist" ? KeyPress(KeyPress::F2Key)
                          : action == "toggleBarMixer" ? KeyPress::createFromDescription("alt + B") : KeyPress();
        if (legacy.isValid() && KeyPress::createFromDescription(str(value, "keyboard")) == legacy) {
            const auto replacement = KeyPress::createFromDescription(definition.defaultKey);
            const auto saved = settings.value("catlive.actions", object());
            bool conflict = false;
            for (const auto &other : actionDefinitions()) {
                if (action == other.id) continue;
                const auto key = str(get(saved, Identifier(other.id), object()), "keyboard");
                if (key.isNotEmpty() && KeyPress::createFromDescription(key) == replacement) { conflict = true; break; }
            }
            if (!conflict) put(value, "keyboard", replacement.getTextDescription());
        }
        if (!value.hasProperty("keyboard") && String(definition.defaultKey).isNotEmpty()) {
            const auto replacement = KeyPress::createFromDescription(definition.defaultKey);
            const auto saved = settings.value("catlive.actions", object());
            bool conflict = false;
            for (const auto &other : actionDefinitions()) {
                if (action == other.id) continue;
                const auto key = str(get(saved, Identifier(other.id), object()), "keyboard");
                if (key.isNotEmpty() && KeyPress::createFromDescription(key) == replacement) { conflict = true; break; }
            }
            if (!conflict) put(value, "keyboard", replacement.getTextDescription());
        }
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
        if (setlistBlockActionNumber(id) > 0 && kind == "midi") {
            return midiLabel(midiInput(id));
        }
        for (const auto &definition : actionDefinitions())
            if (id == definition.id) return inputLabel(definition, kind);
        return {};
    }
    var midiInput(const String &id) const {
        return get(get(settings.value("catlive.actions", object()), Identifier(id)), "midi");
    }
    static String midiLabel(const var &midi) {
        return !midi.isObject() ? String() : String((int)num(midi, "status") == 0xb0 ? "CC " : "Note ") +
            String((int)num(midi, "number")) + " / Ch " + String((int)num(midi, "channel"));
    }
    String midiConflict(const String &id, const var &input) const {
        StringArray conflicts;
        const auto saved = settings.value("catlive.actions", object());
        if (const auto *values = saved.getDynamicObject()) for (const auto &entry : values->getProperties()) {
            const auto other = entry.name.toString();
            if (id == other || !sameMIDI(get(entry.value, "midi"), input)) continue;
            if (const int number = setlistBlockActionNumber(other); number > 0) { conflicts.add(setlistBlockActionTitle(number)); continue; }
            for (const auto &definition : actionDefinitions()) if (other == definition.id)
                conflicts.add(localization::translate(String::fromUTF8(definition.title)));
        }
        if (setlistBlockActionNumber(id) > 0 && externalMIDIConflict)
            if (const auto conflict = externalMIDIConflict(input); conflict.isNotEmpty()) conflicts.add(conflict);
        return conflicts.joinIntoString(", ");
    }
    void resetMIDIState() { heldMIDI.clear(); }
    void begin(const String &action, const String &kind) {
        settings.reload();
        midiCandidate = {};
        learning = action;
        learningKind = kind;
        error.clear();
        sendChangeMessage();
    }
    void beginMIDICandidate(const String &action, std::function<void(var)> captured) {
        begin(action, "midi");
        midiCandidate = std::move(captured);
    }
    void cancel() {
        midiCandidate = {};
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
    bool assign(const String &id, const String &kind, var input, bool replaceMIDIConflicts = false) {
        settings.reload();
        const bool block = setlistBlockActionNumber(id) > 0;
        replaceMIDIConflicts = replaceMIDIConflicts && block && kind == "midi";
        const auto definition = std::find_if(actionDefinitions().begin(), actionDefinitions().end(),
                                             [&](const auto &entry) { return id == entry.id; });
        if ((block && (kind != "midi" || (!input.isVoid() && (!input.isObject() ||
                 ((int)num(input,"status") != 0x90 && (int)num(input,"status") != 0xb0) ||
                 num(input,"number",-1) < 0 || num(input,"number") > 127 ||
                 num(input,"channel") < 1 || num(input,"channel") > 16)))) ||
            (!block && (definition == actionDefinitions().end() ||
            (kind == "keyboard" && (definition->continuous || definition->fixedKeyboard())) ||
            (kind == "midi" &&
             (!definition->supportsMIDI() ||
              (definition->continuous && input.isObject() && (int)num(input, "status") != 0xb0))) ||
            (kind != "keyboard" && kind != "midi")))) {
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
                : kind == "midi" ? sameMIDI(existing, input) : JSON::toString(existing) == JSON::toString(input);
            if (!input.isVoid() && input.toString().isNotEmpty() && same) {
                if (replaceMIDIConflicts) continue;
                error = String::fromUTF8("Já está atribuído a ") + definition.title;
                sendChangeMessage();
                return false;
            }
        }
        if (kind == "midi" && input.isObject()) {
            const auto saved = settings.value("catlive.actions", object());
            if (const auto *values = saved.getDynamicObject()) for (const auto &entry : values->getProperties()) {
                const auto other = entry.name.toString();
                const int number = setlistBlockActionNumber(other);
                if (other != id && number > 0 && sameMIDI(get(entry.value, "midi"), input) && !replaceMIDIConflicts) {
                    error = String::fromUTF8("Já está atribuído a ") + setlistBlockActionTitle(number);
                    sendChangeMessage();
                    return false;
                }
            }
        }
        const auto externalConflict = block && kind == "midi" && input.isObject() && externalMIDIConflict
            ? externalMIDIConflict(input) : String();
        if (externalConflict.isNotEmpty() && (!replaceMIDIConflicts || !transferExternalMIDI)) {
            error = String::fromUTF8("Já está atribuído a ") + externalConflict;
            sendChangeMessage(); return false;
        }
        const auto previous = settings.value("catlive.actions", object()).clone();
        auto values = previous.clone();
        if (replaceMIDIConflicts) if (auto *saved = values.getDynamicObject())
            for (const auto &property : saved->getProperties()) if (property.name.toString() != id && sameMIDI(get(property.value,"midi"),input)) {
                auto entry = property.value.clone(); put(entry,"midi",{}); saved->setProperty(property.name, std::move(entry));
            }
        auto entry = get(values, Identifier(id), object()).clone();
        put(entry, Identifier(kind), input);
        put(values, Identifier(id), entry);
        auto result = settings.set("catlive.actions", values);
        if (result.wasOk() && externalConflict.isNotEmpty() && replaceMIDIConflicts) {
            result = transferExternalMIDI(input);
            if (result.failed()) settings.set("catlive.actions", previous);
        }
        error = result.getErrorMessage();
        if (result.wasOk()) {
            midiCandidate = {};
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
    friend struct ActionBindingsTestAccess;
    Appearance &settings;
    AudioDeviceManager &devices;
    struct Input {
        int status = 0, number = 0, value = 0, channel = 0;
    };
    AbstractFifo queue{256};
    CriticalSection producers;
    std::array<Input, 256> pending;
    std::set<int> heldMIDI;
    std::function<void(var)> midiCandidate;
    static bool sameMIDI(const var &a, const var &b) {
        return a.isObject() && b.isObject() && num(a,"status") == num(b,"status") &&
            num(a,"number") == num(b,"number") && num(a,"channel") == num(b,"channel");
    }
    void handleIncomingMidiMessage(MidiInput *, const MidiMessage &message) override {
        if (!inputEnabled.load(std::memory_order_relaxed)) return;
        if (!message.isNoteOnOrOff() && !message.isController())
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
            if (!inputEnabled.load(std::memory_order_relaxed)) continue;
            const bool release = input.status == 0x80 || input.value == 0;
            const int pressedKey = ((input.status == 0x80 ? 0x90 : input.status) << 16) | (input.channel << 8) | input.number;
            const bool wasHeld = heldMIDI.count(pressedKey) != 0;
            if (release) heldMIDI.erase(pressedKey); else heldMIDI.insert(pressedKey);
            const auto saved = settings.value("catlive.actions", object());
            String blockAction;
            if (const auto *values = saved.getDynamicObject()) for (const auto &entry : values->getProperties()) {
                const auto id = entry.name.toString();
                if (setlistBlockActionNumber(id) <= 0) continue;
                const auto midi = get(entry.value, "midi");
                if (midi.isObject() && (int)num(midi,"status") == (input.status == 0x80 ? 0x90 : input.status) &&
                    (int)num(midi,"number") == input.number && (int)num(midi,"channel") == input.channel) {
                    if (!release) blockAction = id;
                }
            }
            if (learning.isEmpty() && rawMIDI && rawMIDI(input.status,input.number,input.value,input.channel)) continue;
            if (input.status == 0x80 || (input.status == 0x90 && input.value == 0)) continue;
            if (learningKind == "midi" && learning.isNotEmpty()) {
                if (setlistBlockActionNumber(learning) > 0 && release) continue;
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
                if (midiCandidate) {
                    const auto capture = midiCandidate;
                    capture(value);
                    continue;
                }
                const auto learned = learning;
                assign(learned, "midi", value);
                continue;
            }
            if (blockAction.isNotEmpty()) {
                if (!wasHeld && invoke) invoke(blockAction, input.value / 127.f, 0);
                continue;
            }
            for (const auto &definition : actionDefinitions()) {
                const auto b = binding(definition), midi = get(b, "midi");
                if (midi.isObject() && (int)num(midi, "status") == input.status &&
                    (int)num(midi, "number") == input.number &&
                    (int)num(midi, "channel") == input.channel) {
                    if (invoke && (definition.continuous || input.value > 0) &&
                        (definition.id != "cancelSection" || !wasHeld))
                        invoke(definition.id, input.value / 127.f, (int)num(b, "track"));
                    break;
                }
            }
        }
    }
};
} // namespace catlive
