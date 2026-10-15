#pragma once
#include "RemoteCipher.h"
namespace catlive::remote {
inline bool validID(const var &value) {
    if (!value.isString())
        return false;
    auto s = value.toString();
    // JUCE's project UUIDs may omit separators; Swift UUID decoding requires them.
    if (s.length() != 36)
        return false;
    for (int i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (s[i] != '-')
                return false;
        } else if (String("0123456789abcdefABCDEF").indexOfChar(s[i]) < 0)
            return false;
    }
    return true;
}
inline String wireID(const ID &id) { return Uuid(text(id)).toDashedString().toUpperCase(); }
inline ID modelID(const var &id) {
    return utf8(Uuid(id.toString()).toDashedString().toUpperCase());
}
inline bool pinValid(const String &pin) {
    return pin.isEmpty() || (pin.length() == 4 && pin.containsOnly("0123456789"));
}
struct Command {
    String action, message;
    ID id, project, song, target, playlist;
    double value = 0;
    std::optional<bool> enabled, receipt;
    static Command decode(const var &v) {
        require(v.isObject() && validID(v["id"]) && validID(v["project"]) &&
                v["action"].isString());
        Command c;
        c.id = modelID(v["id"]);
        c.project = modelID(v["project"]);
        c.action = v["action"].toString();
        for (auto entry : {std::pair<const char *, ID *>{"song", &c.song},
                           {"target", &c.target},
                           {"playlist", &c.playlist}}) {
            auto field = get(v, Identifier(entry.first));
            if (!field.isVoid() && !field.isUndefined()) {
                require(validID(field));
                *entry.second = modelID(field);
            }
        }
        const auto value = v["value"];
        require(value.isDouble() || value.isInt() || value.isInt64());
        c.value = (double)value;
        require(std::isfinite(c.value));
        const auto a = c.action;
        const auto t = v["text"];
        if (!t.isVoid() && !t.isUndefined()) {
            require(t.isString() && t.toString().length() <= 500 &&
                    t.toString().getNumBytesAsUTF8() <= 4000 &&
                    (a == "noticeSend" || a == "noticeSaveTemplate" || a == "editRegion" ||
                     a == "renamePlaylist"));
            c.message = t.toString();
        }
        if (!c.playlist.empty())
            require(a == "deleteRegion");
        for (auto entry : {std::pair<const char *, std::optional<bool> *>{"enabled", &c.enabled},
                           {"noticeReceiptRequested", &c.receipt}}) {
            auto field = get(v, Identifier(entry.first));
            if (!field.isVoid() && !field.isUndefined()) {
                require(field.isBool());
                *entry.second = (bool)field;
            }
        }
        require(!c.enabled || a == "noticeDestination");
        require(!c.receipt || a == "noticeSend");
        const bool target = !c.target.empty(), zero = c.value == 0,
                   integral = std::floor(c.value) == c.value;
        const auto range = [&](double low, double high) {
            return c.value >= low && c.value <= high;
        };
        bool valid = false;
        if (a == "editRegion")
            valid = target && c.message.trim().isNotEmpty() && range(0, 16777215) && integral;
        else if (a == "renamePlaylist")
            valid = target && zero && c.message.trim().isNotEmpty();
        else if (a == "deleteRegion" || a == "duplicatePlaylist" || a == "deletePlaylist" ||
                 a == "requestImage" || a == "openRecentProject" || a == "clipMute" ||
                 a == "queueSection")
            valid = target && zero;
        else if (a == "toggleMultiLoopBypass" || a == "toggleSetlistLive" || a == "cancelSection" ||
                 a == "timerStop" || a == "noticeClear")
            valid = !target && zero;
        else if (a == "timerStart")
            valid = !target && range(0, 359999) && integral;
        else if (a == "remotePanel")
            valid = !target && range(0, 3) && integral;
        else if (a == "noticeSend" || a == "noticeSaveTemplate")
            valid = !target && t.isString() && range(a == "noticeSend" ? -1 : 0, 2) && integral;
        else if (a == "noticePin")
            valid = !target && (zero || c.value == 1);
        else if (a == "noticeDestination")
            valid = !target && (c.value == 1 || c.value == 2) && c.enabled.has_value();
        else if (a == "clipGain")
            valid = target && range(0, std::pow(10., 24. / 20));
        else if (a == "volume")
            valid = range(0, 4);
        else if (a == "pan")
            valid = target && range(-1, 1);
        else if (a == "tempo")
            valid = range(20, 400);
        else if (a == "pitch")
            valid = target && range(-12, 12) && integral;
        else if (a == "seek")
            valid = range(0, 604800);
        else if (a == "selectRegion" || a == "selectSong")
            valid = target;
        else if (StringArray{"play", "pause", "stop", "subPlay", "subStop", "toggleLoop", "mute",
                             "solo", "masterMono", "resetMeterPeak", "save", "toggleRegionAuto",
                             "selectPlaylist"}
                     .contains(a))
            valid = zero;
        require(valid);
        return c;
    }
    bool allowed(const String &mode) const {
        if (mode == "director")
            return true;
        if (mode == "observer")
            return action == "requestImage" || (action == "remotePanel" && value <= 2);
        if (mode == "notices")
            return StringArray{"noticeSend", "noticeClear", "noticePin", "noticeDestination",
                               "noticeSaveTemplate"}
                       .contains(action) ||
                   (action == "remotePanel" && (value == 0 || value == 3));
        return false;
    }
};
} // namespace catlive::remote
