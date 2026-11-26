#pragma once
#include "../Utils/Identity.hpp"
#include <vector>
#include <optional>
#include <map>
#include <algorithm>
#include <cmath>
namespace jaras {
struct OutputPatch { int firstChannel = 0; int channelCount = 2; };
enum class TrackSendTap { preFX, postFX, preFader, postFader };
inline const char *sendTapID(TrackSendTap tap) {
    switch (tap) {
        case TrackSendTap::preFX: return "preFX";
        case TrackSendTap::postFX: return "postFX";
        case TrackSendTap::preFader: return "preFader";
        case TrackSendTap::postFader: return "postFader";
    }
    return "postFader";
}
struct TrackRouting {
    std::vector<std::optional<ID>> receives{std::nullopt, std::nullopt}, transmitters{std::nullopt, std::nullopt};
    std::optional<int> mainReceiveSlot;
    std::map<ID, TrackSendTap> sendTaps;
    std::optional<int> mainSendOrder;
    std::map<ID, double> sendGains;
    TrackSendTap sendTap(const ID &target) const {
        const auto found = sendTaps.find(target);
        return found == sendTaps.end() ? TrackSendTap::postFader : found->second;
    }
    double sendGain(const ID &target) const {
        const auto found = sendGains.find(target);
        return found == sendGains.end() || !std::isfinite(found->second) ? 1.0 : std::clamp(found->second, 0.0, 1.0);
    }
    void setSendGain(const ID &target, double gain) {
        if (!std::isfinite(gain)) return;
        if (gain >= 1.0) sendGains.erase(target);
        else sendGains[target] = std::max(0.0, gain);
    }
    void removeUnusedSendGains() {
        for (auto it = sendGains.begin(); it != sendGains.end();) {
            if (std::find(transmitters.begin(), transmitters.end(), std::optional<ID>(it->first)) == transmitters.end())
                it = sendGains.erase(it);
            else ++it;
        }
    }
};
struct TrackRole { std::string id = "other"; };
struct TimecodeSettings { std::string mode = "mtc"; double frameRate = 30, offset = 0; bool regionRelative = true; int midiDestination = 0; };
inline bool isTeleprompterRole(const TrackRole& role) { return role.id == "teleprompt" || role.id == "teleprompt2"; }
inline std::string fixedTrackName(const TrackRole& role) { return role.id == "programChange" ? "Program Change" : role.id == "generatedClick" ? "Click" : role.id == "timecode" ? "Timecode" : role.id == "video" ? "Video" : role.id == "teleprompt" ? "Teleprompter 1" : role.id == "teleprompt2" ? "Teleprompter 2" : role.id == "chords" ? "Chords" : ""; }
struct AudioFile { std::string path; std::optional<std::string> sha256; };
struct MIDINote { ID id; double start=0, length=1; int pitch=60, velocity=100, channel=1; };
struct MIDIItem { std::vector<MIDINote> notes; double sourceBPM=120; int division=16; std::string mode="straight"; double swing=.5; };
struct ItemTempoReference { ID markerID; double rate = 1; };
struct ElasticPoint {
    double position = 0, source = 0;
    // Slopes encode the start/end rate relative to the mean of the span.
    double slopeBefore = 0, slopeAfter = 0;
    bool operator==(const ElasticPoint &other) const {
        return position == other.position && source == other.source &&
               slopeBefore == other.slopeBefore && slopeAfter == other.slopeAfter;
    }
};
struct AudioClip { ID id; std::vector<ID> separatedStemTracks; std::string name; double startTime = 0, duration = 0, sourceOffset = 0; std::vector<double> waveform; std::optional<AudioFile> audioFile; std::optional<double> gain; std::optional<bool> phaseInverted; std::optional<double> pan; std::optional<double> normalizationGain; std::optional<double> fadeIn, fadeOut, fadeInCurve, fadeInSCurve, fadeOutCurve, fadeOutSCurve; std::optional<int> channelMode; std::vector<std::vector<double>> waveformChannels; bool muted = false; double playbackRate = 1; std::optional<int> recordingLane; std::optional<double> loopStart, loopLength; std::optional<std::string> fxJSON; std::optional<double> timecodeStartOffset, timecodeEndOffset; std::optional<bool> fxBypassed; std::optional<std::string> text; std::optional<MIDIItem> midi; std::optional<bool> frozenMIDI, renderedTiming; std::optional<double> pitchSemitones; std::optional<TimecodeSettings> timecode; std::optional<ID> regionOwnerID; std::optional<std::string> automationJSON; std::optional<double> tempoBasePlaybackRate; std::optional<bool> renderedTempo; std::optional<bool> clickDouble; std::vector<ItemTempoReference> tempoRateReferences; std::vector<ElasticPoint> elasticPoints; double elasticSourceScale = 1; std::optional<bool> fadeControlsEnabled; };
struct ProgramChangeMarker { ID id; double position = 0; int program = 0, channel = 1; std::string name; std::optional<int> output; };
struct ChordMarker { ID id, regionID; double offset = 0; std::string name; };
struct Track {
    ID id; std::string name; TrackRole role;
    double volume = 1, pan = 0;
    bool mute = false, solo = false;
    int output = 1;
    std::optional<AudioFile> audioFile;
    std::vector<AudioClip> clips;
    std::optional<OutputPatch> patch;
    std::optional<unsigned> color;
    std::optional<OutputPatch> inputPatch;
    std::optional<bool> inputMonitoring;
    std::optional<int> recordingChannels;
    std::optional<std::string> recordingFormat;
    std::optional<bool> recordingPostFader, recordingPostFX, recordingOutput;
    std::optional<std::string> fxJSON, automationJSON;
    std::optional<int> midiInput;
    std::optional<int> midiChannel;
    std::optional<int> midiOutput;
    std::vector<ProgramChangeMarker> programChanges;
    std::vector<ChordMarker> chordMarkers;
    std::optional<ID> parentTrackID;
    std::optional<OutputPatch> secondaryPatch;
    std::optional<std::vector<OutputPatch>> outputs;
    std::vector<OutputPatch> outputPatches() const {
        if (outputs) return *outputs;
        std::vector<OutputPatch> result{patch.value_or(OutputPatch{parentTrackID ? -2 : 0, 2})};
        if (secondaryPatch) result.push_back(*secondaryPatch);
        return result;
    }
    std::optional<TimecodeSettings> timecode;
    bool importedTimecodeItems = false;
    std::optional<TrackRouting> routing;
    bool receivesMain() const { return routing && routing->mainReceiveSlot.has_value(); }
    std::optional<ID> stereoLinkPartner;
    bool stereoLinkLeft = false;
    std::optional<std::string> stereoLinkJSON;
    std::optional<bool> phaseInverted;
    std::optional<double> heightScale;
    std::optional<bool> stackedStems;
    std::optional<int> hiddenMixerComponents;
    enum ComponentMask { patchBit=1, fxBit=2, envelopeBit=4, recBit=8, inputBit=16, panBit=32, muteBit=64, soloBit=128, phaseBit=256, vuBit=512 };
    static constexpr int compactMask = patchBit | fxBit | envelopeBit | recBit | panBit;
    bool supportsMixerComponents() const { return fixedTrackName(role).empty() && role.id != "vinhetas"; }
    int applicableMixerComponentMask(int mask) const { return supportsMixerComponents() ? mask : (mask & vuBit); }
    bool showsComponent(int mask) const { return (hiddenMixerComponents.value_or(0) & applicableMixerComponentMask(mask)) == 0; }
    bool compactMixerControls() const { return supportsMixerComponents() && (hiddenMixerComponents.value_or(0) & compactMask) == compactMask; }
    std::optional<std::string> instrumentIcon = "png:Other/waveform";
    std::optional<AudioFile> clickSound;
};
}
