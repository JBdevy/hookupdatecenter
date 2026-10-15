#pragma once
#include "InstrumentAssets.h"
#include "Instrument.h"
#include "RegionPitch.h"
#include "../../Core/Transport/PlaybackScope.hpp"
namespace catlive {
struct PlaybackNote {
    double start = 0, end = 0;
    int pitch = 60, velocity = 100, channel = 1;
    std::optional<double> playbackStart;
};
inline std::vector<PlaybackNote> playbackNotes(const jaras::Track &track,
                                               const jaras::Song *song = nullptr) {
    std::vector<PlaybackNote> result;
    for (const auto &clip : track.clips) {
        if (!clip.midi || clip.muted || clip.frozenMIDI.value_or(false) ||
            clip.gain.value_or(1) <= 0)
            continue;
        const auto &midi = *clip.midi;
        const double seconds = 60 / midi.sourceBPM, rate = clip.playbackRate,
                     sourceEnd = clip.sourceOffset + clip.duration * rate;
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
                                          clip.startTime + (rawStart - clip.sourceOffset) / rate),
                             end = std::min(clip.startTime + clip.duration,
                                            clip.startTime + (rawEnd - clip.sourceOffset) / rate);
                if (end > start)
                    result.push_back(
                        {start, end,
                         jlimit(0, 127,
                                note.pitch + (int)std::round(clip.pitchSemitones.value_or(0)) +
                                    (song && !clip.renderedTiming.value_or(false)
                                         ? regionPitch::value(*song, track, start)
                                         : 0)),
                         jlimit(1, 127,
                                (int)std::round(note.velocity *
                                                std::min(127., clip.gain.value_or(1)))),
                         note.channel, song ? jaras::playbackItemStart(*song, clip) : std::optional<double>(clip.startTime)});
                if (result.size() > 1000000)
                    throw std::runtime_error("Too many MIDI playback notes.");
            }
    }
    std::stable_sort(result.begin(), result.end(),
                     [](const auto &a, const auto &b) { return a.start < b.start; });
    return result;
}
class MIDIPlayback {
  public:
    MIDIPlayback(const std::vector<PlaybackNote> &source, const var &fx, const File &directory,
                 double sampleRate)
        : notes(source), rate(sampleRate) {
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
        for (const auto &note : notes) {
            events.push_back({note.start, note, true});
            events.push_back({note.end, note, false});
        }
        std::stable_sort(events.begin(), events.end(), [](const auto &a, const auto &b) {
            return a.time == b.time ? !a.on && b.on : a.time < b.time;
        });
        midi.ensureSize(1048576);
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
    void reset(int head = -1) {
        for (int h = 0; h < 2; ++h)
            if (head < 0 || head == h) {
                expected[h] = -1;
                for (auto &layer : layers)
                    layer->synth[h]->stop();
            }
    }
    void render(int head, double at, AudioBuffer<float> &output, int start, int count, jaras::PlaybackScope scope = {}) {
        if (layers.empty())
            return;
        midi.clear();
        if (std::abs(expected[head] - at) > 1.5 / rate || scopes[head] != scope) {
            scopes[head] = scope;
            reset(head);
            for (const auto &note : notes)
                if (scope.allows(note.playbackStart) && note.start < at - 1e-9 && note.end > at + 1e-9)
                    midi.addEvent(
                        MidiMessage::noteOn(note.channel, note.pitch, (uint8)note.velocity), 0);
        }
        const double end = at + count / rate;
        auto event =
            std::lower_bound(events.begin(), events.end(), at - 1e-9,
                             [](const Event &event, double value) { return event.time < value; });
        for (; event != events.end() && event->time < end - 1e-9; ++event) {
            const auto &note = event->note;
            if (!scope.allows(note.playbackStart)) continue;
            const int sample = jlimit(0, count - 1, (int)std::round((event->time - at) * rate));
            midi.addEvent(event->on
                              ? MidiMessage::noteOn(note.channel, note.pitch, (uint8)note.velocity)
                              : MidiMessage::noteOff(note.channel, note.pitch),
                          sample);
        }
        for (auto &layer : layers)
            layer->synth[head]->render(output, midi, count, start);
        expected[head] = end;
    }
    void live(AudioBuffer<float> &output, const MidiBuffer &messages, int samples,
              int channel = 0) {
        if (layers.empty())
            return;
        midi.clear();
        for (const auto event : messages)
            if (channel <= 0 || event.getMessage().getChannel() == channel)
                midi.addEvent(event.getMessage(), event.samplePosition);
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
    struct Event {
        double time;
        PlaybackNote note;
        bool on;
    };
    std::vector<PlaybackNote> notes;
    std::vector<Event> events;
    std::vector<std::unique_ptr<Layer>> layers;
    MidiBuffer midi;
    double expected[2]{-1, -1}, rate;
    jaras::PlaybackScope scopes[2];
};
} // namespace catlive
