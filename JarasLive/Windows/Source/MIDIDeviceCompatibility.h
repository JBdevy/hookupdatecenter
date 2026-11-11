#pragma once
#include "Common.h"
#include <mmsystem.h>
#include <mmddk.h>

namespace catlive::midiDeviceCompatibility {
// WinRT exposes USB and BLE together, but its identifiers differ from WinMM.
// Resolve existing assignments only when both backends identify one unique
// named port. Never guess between identical controllers or discard offline IDs.
inline String resolve(const String &saved, const Array<MidiDeviceInfo> &current,
                      const Array<MidiDeviceInfo> &legacy) {
    if (saved.isEmpty()) return saved;
    for (const auto &device : current) if (device.identifier == saved) return saved;
    for (const auto &previous : legacy) if (previous.identifier == saved) {
        int oldMatches = 0, newMatches = 0;
        String next;
        for (const auto &device : legacy) if (device.name == previous.name) ++oldMatches;
        for (const auto &device : current) if (device.name == previous.name) {
            ++newMatches; next = device.identifier;
        }
        if (oldMatches == 1 && newMatches == 1) return next;
        break;
    }
    return saved;
}

inline Array<MidiDeviceInfo> legacyPorts(bool input) {
    StringArray names, identifiers;
    const auto count = input ? midiInGetNumDevs() : midiOutGetNumDevs();
    for (UINT i = 0; i < count; ++i) {
        String name;
        if (input) {
            MIDIINCAPSW caps{};
            if (midiInGetDevCapsW(i, &caps, sizeof caps) != MMSYSERR_NOERROR) continue;
            name = caps.szPname;
        } else {
            MIDIOUTCAPSW caps{};
            if (midiOutGetDevCapsW(i, &caps, sizeof caps) != MMSYSERR_NOERROR) continue;
            name = caps.szPname;
        }
        const auto message = [&](UINT command, DWORD_PTR data, DWORD_PTR size) {
            return input ? midiInMessage(reinterpret_cast<HMIDIIN>(UINT_PTR(i)), command, data, size)
                         : midiOutMessage(reinterpret_cast<HMIDIOUT>(UINT_PTR(i)), command, data, size);
        };
        ULONG bytes = 0;
        WCHAR path[512]{};
        String identifier;
        if (message(DRV_QUERYDEVICEINTERFACESIZE, reinterpret_cast<DWORD_PTR>(&bytes), 0) == MMSYSERR_NOERROR
            && bytes > 0 && bytes < std::size(path)
            && message(DRV_QUERYDEVICEINTERFACE, reinterpret_cast<DWORD_PTR>(path), sizeof path) == MMSYSERR_NOERROR)
            identifier = path;
        names.add(name);
        identifiers.add(identifier.isNotEmpty() ? identifier : name);
    }
    // Match the identifiers previously persisted by JUCE's WinMM backend.
    identifiers.appendNumbersToDuplicates(false, false, CharPointer_UTF8("-"), CharPointer_UTF8(""));
    Array<MidiDeviceInfo> result;
    for (int i = 0; i < names.size(); ++i) result.add({names[i], identifiers[i]});
    return result;
}

inline String resolve(const String &saved, bool input) {
    if (saved.isEmpty()) return saved;
    const auto current = input ? MidiInput::getAvailableDevices() : MidiOutput::getAvailableDevices();
    for (const auto &device : current) if (device.identifier == saved) return saved;
    return resolve(saved, current, legacyPorts(input));
}
} // namespace catlive::midiDeviceCompatibility
