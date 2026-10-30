#pragma once
#include "InstrumentAssets.h"
#include "BoundedMIDIBuffer.h"
#include "Instrument.h"
#include "RegionPitch.h"
#include "ClipTempo.h"
#include "../../Core/Tracks/ItemFade.hpp"
#include "../../Core/Transport/PlaybackScope.hpp"
namespace catlive {
inline void appendLiveTrackMIDI(MidiBuffer &destination, const MidiBuffer &source,
                                int samples, bool armed, int channel = 0) {
    // Disarming blocks new notes, while the original route must still receive
    // note releases and pedal/controllers so an already sounding voice can end.
    for (const auto event : source)
        if ((channel <= 0 || event.getMessage().getChannel() == channel) &&
            event.samplePosition >= 0 && event.samplePosition < samples &&
            (armed || !event.getMessage().isNoteOn()))
            destination.addEvent(event.getMessage(), event.samplePosition);
}
// One voice per armed track in Omni; note-offs retain their original channel.
struct VirtualKeyboardRoute {
    std::array<std::array<uint8,128>,16> held{};
    void append(MidiBuffer &output, const MidiBuffer &input, int samples, bool armed, int selected, int trackChannel) {
        for (const auto event : input) {
            auto message = event.getMessage();
            if (event.samplePosition < 0 || event.samplePosition >= samples) continue;
            if (message.isAllNotesOff() || message.isAllSoundOff()) {
                auto &notes = held[size_t(message.getChannel()-1)];
                unsigned targets=0;
                if(message.isAllSoundOff()) {
                    for(const auto target:notes)if(target)targets|=1u<<(target-1);
                    for(int channel=1;channel<=16;++channel)if(targets&(1u<<(channel-1))) {
                        output.addEvent(MidiMessage::controllerEvent(channel,64,0),event.samplePosition);
                        output.addEvent(MidiMessage::allSoundOff(channel),event.samplePosition);
                    }
                }
                for (size_t note=0; note<notes.size(); ++note) if (notes[note]) {
                    if(!message.isAllSoundOff())
                        output.addEvent(MidiMessage::noteOff(notes[note],int(note)),event.samplePosition);
                    notes[note]=0;
                }
                continue;
            }
            if (!message.isNoteOn() && !message.isNoteOff()) continue;
            auto &target = held[size_t(message.getChannel()-1)][size_t(message.getNoteNumber())];
            if (message.isNoteOn()) {
                if (target) { output.addEvent(MidiMessage::noteOff(target,message.getNoteNumber()),event.samplePosition); target=0; }
                if (!armed || (selected > 0 && trackChannel > 0 && selected != trackChannel)) continue;
                target = uint8(selected > 0 ? selected : trackChannel > 0 ? trackChannel : 1);
                message.setChannel(target); output.addEvent(message,event.samplePosition);
            } else if (target) {
                message.setChannel(target); output.addEvent(message,event.samplePosition); target=0;
            }
        }
    }
};
struct PlaybackNote {
    double start = 0, end = 0;
    int pitch = 60, velocity = 100, channel = 1;
    std::optional<double> playbackStart;
    std::uint32_t regionOwnerIndex=0;
};
inline bool hasTakeInstrument(const var &fx, bool bypassed = false) {
    if (bypassed) return false;
    const auto inserted = list(get(fx, "inserted"));
    for (const auto &plugin : list(get(fx, "externalPlugins")))
        if (!flag(plugin, "bypassed") && str(plugin, "category").contains("Instrument") &&
            inserted.contains(var("External:" + str(plugin, "id"))))
            return true;
    return false;
}
inline bool hasTakeInstrument(const jaras::AudioClip &clip) {
    return clip.midi && !clip.frozenMIDI.value_or(false) && clip.fxJSON &&
           hasTakeInstrument(JSON::parse(text(*clip.fxJSON)), clip.fxBypassed.value_or(false));
}
inline std::vector<PlaybackNote> playbackNotes(const jaras::Track &track,
                                               const jaras::Song *song = nullptr, bool includeSilent = false,
                                               bool sharedInstrumentOnly = false) {
    std::vector<PlaybackNote> result;
    for (const auto &clip : track.clips) {
        if (!clip.midi || (!includeSilent && (clip.muted || clip.gain.value_or(1) <= 0)) || clip.frozenMIDI.value_or(false))
            continue;
        if (sharedInstrumentOnly && hasTakeInstrument(clip)) continue;
        const auto &midi = *clip.midi;
        const ClipTempo timing(clip, song);
        const double seconds = 60 / midi.sourceBPM,
                     sourceEnd = timing.sourceAt(clip.startTime + clip.duration);
        const double loop = clip.loopLength.value_or(0), origin = clip.loopStart.value_or(0);
        if (loop > 0 && (sourceEnd - origin) / loop > 1e12)
            throw std::runtime_error("MIDI loop position exceeds the supported range.");
        const int64 first = loop > 0
                                ? std::max(int64(0),
                                           (int64)std::floor((clip.sourceOffset - origin) / loop))
                                : 0,
                    last = loop > 0
                               ? std::max(first, (int64)std::ceil((sourceEnd - origin) / loop) - 1)
                               : 0;
        if (last - first > 100000)
            throw std::runtime_error("MIDI loop count exceeds the supported project size.");
        for (const auto &note : midi.notes)
            for (int64 cycle = first; cycle <= last; ++cycle) {
                const double shift = cycle * loop, noteStart = note.start * seconds,
                             noteEnd = (note.start + note.length) * seconds;
                const double rawStart = loop > 0 ? std::max(origin, noteStart) + shift : noteStart,
                             rawEnd = loop > 0 ? std::min(origin + loop, noteEnd) + shift : noteEnd;
                if (rawEnd <= rawStart)
                    continue;
                const double start =
                                 std::max(clip.startTime,
                                          timing.timeAt(rawStart, false)),
                             end = std::min(clip.startTime + clip.duration,
                                            timing.timeAt(rawEnd, false));
                if (end > start)
                    result.push_back(
                        {start, end,
                         jlimit(0, 127,
                                note.pitch + (int)std::round(clip.pitchSemitones.value_or(0)) +
                                    (song && !clip.renderedTiming.value_or(false)
                                         ? regionPitch::value(*song, track, start)
                                         : 0)),
                         jlimit(0, 127,
                                (int)std::round(note.velocity *
                                                (clip.muted ? 0 : std::min(127., clip.gain.value_or(1))) * jaras::itemFadeGain(clip, start))),
                         note.channel, song ? jaras::playbackItemStart(*song, clip) : std::optional<double>(clip.startTime), song ? jaras::playbackOwnerIndex(*song,clip.regionOwnerID) : 0});
                if (result.size() > 1000000)
                    throw std::runtime_error("Too many MIDI playback notes.");
            }
    }
    if(!includeSilent)result.erase(std::remove_if(result.begin(), result.end(), [](const auto &note) { return note.velocity == 0; }), result.end());
    std::stable_sort(result.begin(), result.end(),
                     [](const auto &a, const auto &b) { return a.start < b.start; });
    return result;
}
inline std::vector<PlaybackNote> takePlaybackNotes(const jaras::Track &track,
                                                  const jaras::AudioClip &clip,
                                                  const jaras::Song &song, bool audioControls) {
    jaras::Track source;
    source.id = track.id;
    source.role = track.role;
    source.parentTrackID = track.parentTrackID;
    source.clips = {clip};
    if (audioControls) {
        // The take's gain/fades act on its generated audio, not on note velocity.
        auto &item = source.clips.front();
        item.gain = 1;
        item.muted = false;
        item.fadeIn = 0;
        item.fadeOut = 0;
    }
    return playbackNotes(source, &song, true);
}
class MIDIPlayback {
  public:
    struct Event { double time; PlaybackNote note; bool on; };
    struct Sequence {
        std::vector<PlaybackNote> notes;
        std::vector<Event> events;
        jaras::MIDINoteChaseIndex chase;
    };
    static Sequence sequence(std::vector<PlaybackNote> notes) {
        Sequence result; result.notes=std::move(notes);
        std::stable_sort(result.notes.begin(),result.notes.end(),[](const auto& a,const auto& b){return a.start<b.start;});
        result.events.reserve(result.notes.size()*2);
        for(const auto &note:result.notes){if(note.velocity>0)result.events.push_back({note.start,note,true});result.events.push_back({note.end,note,false});}
        std::stable_sort(result.events.begin(),result.events.end(),[](const auto &a,const auto &b){return a.time==b.time?!a.on && b.on:a.time<b.time;});
        result.chase.prepare(result.notes);
        return result;
    }
    static void appendExternal(const Sequence &sequence, BoundedMIDIBuffer &messages,
                               double &expected, jaras::PlaybackScope &previousScope,
                               double at, int count, double rate, jaras::PlaybackScope scope = {},
                               bool running = true, int destinationOffset = 0) noexcept {
        if (count <= 0) return;
        if (!running) {
            if (expected != -1)
                for (int channel = 1; channel <= 16; ++channel)
                    if (!messages.addEvent(MidiMessage::allNotesOff(channel), destinationOffset)) break;
            expected = -1;
            return;
        }
        if (!messages.overflowed() && (std::abs(expected - at) > 1.5 / rate || previousScope != scope)) {
            for (int channel = 1; channel <= 16; ++channel)
                if (!messages.addEvent(MidiMessage::allNotesOff(channel), destinationOffset)) break;
            const bool chased=sequence.chase.visit(sequence.notes,at,[&]{return messages.inspect();},[&](const PlaybackNote& note){
                return note.velocity <= 0 || !scope.allows(note.playbackStart,note.regionOwnerIndex) ||
                    messages.addEvent(MidiMessage::noteOn(note.channel,note.pitch,(uint8)note.velocity),destinationOffset);
            });
            if (!chased) messages.panic();
        }
        const double end = at + count / rate;
        auto event = std::lower_bound(sequence.events.begin(), sequence.events.end(), at - 1e-9,
            [](const Event &event, double value) { return event.time < value; });
        for (; event != sequence.events.end() && event->time < end - 1e-9; ++event) {
            if (!messages.inspect()) break;
            const auto &note = event->note;
            if (!scope.allows(note.playbackStart,note.regionOwnerIndex)) continue;
            if (!messages.addEvent(event->on ? MidiMessage::noteOn(note.channel, note.pitch, (uint8)note.velocity)
                                             : MidiMessage::noteOff(note.channel, note.pitch),
                    destinationOffset+jlimit(0, count - 1, (int)std::round((event->time - at) * rate)))) break;
        }
        // Overflow discards this block and releases every held voice. Advance
        // the clock anyway: the next block accepts fresh events instead of
        // repeatedly chasing the same oversized discarded note backlog.
        expected = end;
        previousScope = scope;
    }
    void replaceSequence(Sequence &next,bool stopHeld=false) noexcept {
        std::swap(plan,next);if(stopHeld)reset();
    }
    MIDIPlayback(const std::vector<PlaybackNote> &source, const var &fx, const File &directory,
                 double sampleRate)
        : rate(sampleRate) {
        for (auto settings : instrumentAssets::settings(fx)) {
            const auto id = str(settings, "instrumentID");
            const auto file = instrumentAssets::resolve(id, directory);
            if (!file.existsAsFile())
                throw std::runtime_error(
                    utf8(String::fromUTF8("Instrumento ausente: ") + instrumentAssets::name(id)));
            auto layer = std::make_unique<Layer>();
            layer->synth[0] = std::make_unique<Instrument>();
            layer->synth[0]->prepare(rate);
            layer->synth[0]->loadSoundFont(file);
            layer->synth[1] = layer->synth[0]->copy();
            for (auto &synth : layer->synth)
                synth->configure(get(settings, "instrumentParameters"), id.startsWith("drum-"));
            layers.push_back(std::move(layer));
        }
        if (layers.empty())
            return;
        midi.prepare();
        auto prepared=sequence(source);replaceSequence(prepared);
    }
    bool empty() const { return layers.empty(); }
    void configure(const var &fx) {
        const auto settings = instrumentAssets::settings(fx);
        for (size_t i = 0; i < std::min(settings.size(), layers.size()); ++i) {
            const auto parameters = get(settings[i], "instrumentParameters");
            const bool drums = str(settings[i], "instrumentID").startsWith("drum-");
            for (auto &synth : layers[i]->synth)
                synth->configure(parameters, drums);
            if (layers[i]->live)
                layers[i]->live->configure(parameters, drums);
        }
    }
    void prepare(double sampleRate) {
        rate = sampleRate;
        for (auto &layer : layers) {
            for (auto &synth : layer->synth)
                synth->prepare(rate);
            if (layer->live)
                layer->live->prepare(rate);
        }
        reset();
    }
    void swapPlaybackHeads() noexcept {
        std::swap(expected[0],expected[1]);std::swap(scopes[0],scopes[1]);
        for(auto &layer:layers)layer->synth[0].swap(layer->synth[1]);
    }
    void reset(int head = -1) {
        for (int h = 0; h < 2; ++h)
            if (head < 0 || head == h) {
                expected[h] = -1;
                for (auto &layer : layers)
                    layer->synth[h]->stop();
            }
    }
    void render(int head, double at, AudioBuffer<float> &output, int start, int count, jaras::PlaybackScope scope = {}) {
        if (count <= 0 || layers.empty())
            return;
        midi.clear();
        if (std::abs(expected[head] - at) > 1.5 / rate || scopes[head] != scope)
            reset(head);
        appendExternal(plan,midi,expected[head],scopes[head],at,count,rate,scope);
        for (auto &layer : layers)
            layer->synth[head]->render(output, midi, count, start);
    }
    std::uint64_t builderOverflows() const noexcept { return midi.overflows(); }
    void live(AudioBuffer<float> &output, const MidiBuffer &messages, int samples,
              int channel = 0) {
        if (samples <= 0 || layers.empty())
            return;
        midi.clear();
        for (const auto event : messages) {
            if (!midi.inspect()) break;
            if ((channel <= 0 || event.getMessage().getChannel() == channel) &&
                !midi.addEvent(event.getMessage(), event.samplePosition)) break;
        }
        // Live notes use a separate voice bank from both timeline heads.
        for (auto &layer : layers) {
            if (layer->live)
                layer->live->render(output, midi, samples);
        }
    }
    void enableLive() {
        for (auto &layer : layers)
            layer->live = layer->synth[0]->copy();
    }
    void stopLive() {
        for (auto &layer : layers)
            if (layer->live)
                layer->live->stop();
    }

  private:
    struct Layer {
        std::unique_ptr<Instrument> synth[2], live;
    };
    Sequence plan;
    std::vector<std::unique_ptr<Layer>> layers;
    BoundedMIDIBuffer midi{false};
    double expected[2]{-1, -1}, rate;
    jaras::PlaybackScope scopes[2];
};
} // namespace catlive
