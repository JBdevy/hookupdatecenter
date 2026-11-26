#pragma once
#include "../../Core/Project/Models.hpp"
#include <algorithm>
#include <cstdint>
#include <map>
#include <set>

namespace catlive {
enum class HozMixerScope { all, tracks, groups };

struct HozMixerView {
    enum Signal { audio = 1, midi = 2, sends = 4, bus = 8 };
    enum ComponentBit { patch = 1, fx = 2, envelope = 4, rec = 8, inputMonitor = 16, pan = 32,
        mute = 64, solo = 128, phase = 256, vu = 512, fader = 1024, peak = 2048,
        sendSlots = 4096, outputs = 8192, icon = 16384, insert = 32768 };
    static constexpr const char *componentTitles[]{ "Patch", "FX", "Envelope", "Rec", "Input Monitor", "Pan",
        "M", "S", "Phase", "VU Meter", "Fader", "Peak", "Sends", "Output", "Track Icon", "Insert" };
    HozMixerScope scope = HozMixerScope::all;
    int signals = 0;
    bool wide = false;
    int hiddenComponents = 0;
    std::map<jaras::ID, std::uint32_t> trackOverrides;

    int componentMask(const jaras::ID &track) const {
        const auto found = trackOverrides.find(track);
        if (found == trackOverrides.end()) return hiddenComponents;
        const auto chosen = found->second >> 16;
        return int((hiddenComponents & ~chosen) | (found->second & chosen));
    }

    void toggleComponent(const jaras::ID &track, int bit) {
        const int value = componentMask(track) ^ bit;
        const auto flag = std::uint32_t(bit) << 16;
        auto &choice = trackOverrides[track];
        if ((value & bit) == (hiddenComponents & bit)) choice &= ~(flag | bit);
        else choice = (choice & ~std::uint32_t(bit)) | (value & bit) | flag;
        if (choice == 0) trackOverrides.erase(track);
    }
};

class HozMixerTrackFilter {
public:
    HozMixerTrackFilter(const jaras::Song &song, const HozMixerView &view) : scope(view.scope), signals(view.signals) {
        if (scope != HozMixerScope::all)
            for (const auto &track : song.tracks) if (track.parentTrackID) groups.insert(*track.parentTrackID);
        if (!(signals & (HozMixerView::sends | HozMixerView::bus))) return;
        forEachConnection(song, [&](const jaras::Track &source, const jaras::ID &destination) {
            senders.insert(source.id);
            receivers.insert(destination);
        });
    }

    template<class Visitor>
    static void forEachConnection(const jaras::Song &song, Visitor &&visit) {
        std::map<jaras::ID, const jaras::Track *> tracks;
        for (const auto &track : song.tracks) tracks.emplace(track.id, &track);
        const auto add = [&](const jaras::Track &source, const jaras::ID &destination) {
            if (source.parentTrackID == destination) {
                const auto outputs = source.outputPatches();
                if (std::any_of(outputs.begin(), outputs.end(), [](auto patch) { return patch.firstChannel == -2; }))
                    return;
            }
            visit(source, destination);
        };
        for (const auto &track : song.tracks) if (track.routing) {
            for (const auto &destination : track.routing->transmitters)
                if (destination) add(track, *destination);
            for (const auto &source : track.routing->receives) if (source) {
                const auto found = tracks.find(*source);
                if (found != tracks.end()) add(*found->second, track.id);
            }
        }
    }

    bool includes(const jaras::Track &track) const {
        if (scope != HozMixerScope::all && (groups.count(track.id) != 0) != (scope == HozMixerScope::groups))
            return false;
        return signals == 0
            || ((signals & HozMixerView::audio) && track.inputPatch && track.inputPatch->firstChannel > 0)
            || ((signals & HozMixerView::midi) && track.midiInput.value_or(0) > 0)
            || ((signals & HozMixerView::sends) && senders.count(track.id))
            || ((signals & HozMixerView::bus) && (receivers.count(track.id) || track.receivesMain()));
    }
private:
    HozMixerScope scope;
    int signals;
    std::set<jaras::ID> groups, senders, receivers;
};
} // namespace catlive
