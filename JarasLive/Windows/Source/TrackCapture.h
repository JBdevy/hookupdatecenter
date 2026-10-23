#pragma once
#include "Common.h"
#include "AudioFormats.h"
#include "MP3Writer.h"
#include "RecordingEncoding.h"
#include "RecordingPreview.h"
#include "NativeFX.h"
#include <deque>
#include <mutex>
namespace catlive {
// JUCE's AIFF writer implements signed PCM32, but its advertised depth list
// omits 32. Expose the implemented encoding for parity with Advanced on Mac.
class RecordingAiffFormat final : public AiffAudioFormat {
  public:
    Array<int> getPossibleBitDepths() override { return {8, 16, 24, 32}; }
};
// Prepared on the control thread, fed only by the audio callback, finalized after
// detaching from that callback. File writes run on the disk thread.
class TrackCapture {
  public:
    struct Target {
        ID track;
        File file;
        int input = 1, channels = 2;
        bool bus = false, midi = false, output = false;
        bool outputPostFX = true, outputPostFader = true;
        int bits = 0;
        bool floatingPoint = false;
        int bitrate = 320;
        std::shared_ptr<RecordingPreview> preview;
        bool postFader = true, postFX = true;
        float gain = 1;
        var effects;
        File mediaDirectory;
    };
    struct Take {
        ID track;
        File file;
        double duration = 0;
        std::optional<jaras::MIDIItem> midi;
        // MP3 is finalized on Session's worker after capture is detached. Keep
        // file pointing to recoverable PCM until encoding succeeds completely.
        File encodedFile;
        int bitrate = 320;
        int encoderDelaySamples = -1;
    };
    TrackCapture(const std::vector<Target> &specs, double sampleRate, int bits, double tempo)
        : rate(sampleRate), bpm(tempo) {
        if (specs.size() > 512 || rate <= 0 || bpm <= 0)
            throw std::runtime_error("Invalid recording configuration.");
        if (specs.empty()) return; // REC may run with no armed tracks, as on Mac.
        silence.fill(0);
        events.reserve(65536);
        thread.startThread(Thread::Priority::high);
        for (const auto &spec : specs) {
            if (spec.channels < 1 || spec.channels > 2 || spec.input < 1 || spec.input > 128)
                throw std::runtime_error("Invalid recording patch.");
            Entry entry;
            entry.target = spec;
            entry.gain = spec.gain;
            entry.processing = std::make_shared<ProcessingState>();
            if (!spec.midi) {
                const bool mp3 = spec.file.hasFileExtension("mp3");
                entry.captureFile = mp3 ? spec.file.withFileExtension(".capture.wav") : spec.file;
                if (spec.file.exists())
                    throw std::runtime_error("Recording file already exists.");
                if (entry.captureFile.exists())
                    throw std::runtime_error("Recording capture file already exists.");
                entry.captureFile.getParentDirectory().createDirectory();
                std::unique_ptr<OutputStream> stream = entry.captureFile.createOutputStream();
                if (!stream)
                    throw std::runtime_error("Unable to create recording.");
                WavAudioFormat wav;
                RecordingAiffFormat aiff;
                AudioFormat &format = entry.captureFile.hasFileExtension("aif;aiff")
                                          ? static_cast<AudioFormat &>(aiff)
                                          : static_cast<AudioFormat &>(wav);
                const auto options = AudioFormatWriterOptions{}.withSampleRate(rate)
                    .withNumChannels(spec.channels).withBitsPerSample(mp3 ? 32 : spec.bits ? spec.bits : bits)
                    .withSampleFormat(mp3 || spec.floatingPoint
                        ? AudioFormatWriterOptions::SampleFormat::floatingPoint
                        : AudioFormatWriterOptions::SampleFormat::integral);
                auto writer = format.createWriterFor(stream, options);
                if (!writer)
                    throw std::runtime_error("Invalid recording encoding.");
                entry.writer =
                    std::make_unique<AudioFormatWriter::ThreadedWriter>(new InputWriter(std::move(writer), spec, rate, entry.processing), thread, 131072);
            }
            entries.push_back(std::move(entry));
        }
    }
    ~TrackCapture() {
        entries.clear();
        thread.stopThread(5000);
    }
    void input(const float *const *data, int channels, int count,
               const std::array<int, 128> &mapping) {
        for (auto &entry : entries)
            if (!entry.target.bus && !entry.target.midi) {
                const float *pointers[3]{silence.data(), silence.data(), nullptr};
                for (int ch = 0; ch < entry.target.channels; ++ch) {
                    const int physical = entry.target.input - 1 + ch;
                    const int packed = physical < 128 ? mapping[(size_t)physical] : -1;
                    if (packed >= 0 && packed < channels && data && data[packed])
                        pointers[ch] = data[packed];
                }
                std::fill_n(gainSamples.data(), count, entry.gain);
                pointers[entry.target.channels] = gainSamples.data();
                if (!entry.writer->write(pointers, count))
                    ++dropped;
            }
    }
    void bus(const ID &id, const AudioBuffer<float> &buffer, int count, bool output = false, bool postFX = true, bool postFader = true) {
        for (auto &entry : entries)
            if (entry.target.bus && !entry.target.midi && entry.target.track == id && entry.target.output == output &&
                (!output || (entry.target.outputPostFX == postFX && entry.target.outputPostFader == postFader))) {
                const float *pointers[3]{buffer.getReadPointer(0), buffer.getReadPointer(1), nullptr};
                if (entry.target.channels == 1) {
                    for (int i = 0; i < count; ++i)
                        mono[(size_t)i] = (pointers[0][i] + pointers[1][i]) * .5f;
                    pointers[0] = mono.data();
                }
                std::fill_n(gainSamples.data(), count, entry.gain);
                pointers[entry.target.channels] = gainSamples.data();
                if (!entry.writer->write(pointers, count))
                    ++dropped;
            }
    }
    void midi(const ID &id, const MidiBuffer &messages, int count, int channelFilter = 0) {
        for (size_t target = 0; target < entries.size(); ++target)
            if (entries[target].target.midi && entries[target].target.track == id)
                for (const auto metadata : messages) {
                    const auto message = metadata.getMessage();
                    if (message.getRawDataSize() > 3 || !message.getChannel() ||
                        (channelFilter && message.getChannel() != channelFilter))
                        continue;
                    if (events.size() == events.capacity()) {
                        ++dropped;
                        continue;
                    }
                    Event event;
                    event.target = (int)target;
                    event.frame =
                        frames + jlimit(0, std::max(0, count - 1), metadata.samplePosition);
                    event.length = message.getRawDataSize();
                    std::copy_n(message.getRawData(), event.length, event.bytes.begin());
                    events.push_back(event);
                }
    }
    // Called by the control thread, never by the device callback. Prepare
    // plugins before handing the new isolated chain to the writer.
    void updateEffects(const ID &track, const var &settings) {
        for (auto &entry : entries) if (entry.target.track == track && entry.target.postFX && !entry.target.midi) {
            auto next = std::make_unique<NativeFX>(); next->prepare(settings, rate, nullptr, false, true, {}, entry.target.mediaDirectory);
            std::lock_guard<std::mutex> lock(entry.processing->mutex);
            entry.processing->pending = std::move(next);
            entry.processing->dynamics.clear();
            entry.processing->parameters.clear();
        }
    }
    // Parameter previews are consumed by the disk worker; capture's device callback
    // only enqueues PCM and never takes this mutex or constructs processors.
    void previewDynamics(const ID &track, const String &key, const NativeFX::DynamicsPreview &snapshot) {
        for (auto &entry : entries) if (entry.target.track == track && entry.target.postFX && !entry.target.midi) {
            std::lock_guard<std::mutex> lock(entry.processing->mutex);
            entry.processing->dynamics[key] = snapshot;
        }
    }
    void previewNativeParameters(const ID &track, const String &key, const NativeFX::ParameterPreview &snapshot) {
        for (auto &entry : entries) if (entry.target.track == track && entry.target.postFX && !entry.target.midi) {
            std::lock_guard<std::mutex> lock(entry.processing->mutex);
            entry.processing->parameters[key] = snapshot;
        }
    }
    void setGain(const ID &track, float gain) noexcept {
        for (auto &entry : entries) if (entry.target.track == track) entry.gain = gain;
    }
    void advance(int count) {
        frames += count;
        for (auto &entry : entries) if (entry.target.preview)
            entry.target.preview->frames.store(frames, std::memory_order_release);
    }
    int64 sampleCount() const { return frames; }
    uint64 overflows() const {
        uint64 result = dropped;
        for (const auto &entry : entries) if (entry.processing->failed.load()) ++result;
        return result;
    }
    std::vector<Take> finish() {
        std::vector<Take> takes;
        for (size_t target = 0; target < entries.size(); ++target) {
            auto &entry = entries[target];
            entry.writer.reset();
            Take take;
            take.track = entry.target.track;
            take.file = entry.target.midi ? File() : entry.captureFile;
            if (entry.target.file.hasFileExtension("mp3")) {
                take.encodedFile = entry.target.file;
                take.bitrate = recordingEncoding::normalizedBitrate(entry.target.bitrate);
            }
            take.duration = (double)frames / rate;
            if (entry.target.midi) {
                jaras::MIDIItem item;
                item.sourceBPM = bpm;
                struct Held {
                    int64 start = -1;
                    int velocity = 0;
                    bool released = false;
                };
                std::array<Held, 2048> held{};
                std::array<bool, 16> sustain{};
                auto finishNote = [&](int key, int64 at) {
                    auto &note = held[(size_t)key];
                    if (note.start >= 0 && at > note.start) {
                        jaras::MIDINote n;
                        n.id = uuid();
                        n.start = note.start / rate * bpm / 60;
                        n.length = (at - note.start) / rate * bpm / 60;
                        n.pitch = key % 128;
                        n.channel = key / 128 + 1;
                        n.velocity = note.velocity;
                        item.notes.push_back(n);
                    }
                    note = {};
                };
                for (const auto &event : events)
                    if (event.target == (int)target) {
                        MidiMessage message(event.bytes.data(), event.length);
                        const int channel = message.getChannel() - 1;
                        const int key = channel * 128 + message.getNoteNumber();
                        if (message.isNoteOn()) {
                            finishNote(key, event.frame);
                            held[(size_t)key] = {event.frame, message.getVelocity(), false};
                        } else if (message.isNoteOff()) {
                            if (sustain[(size_t)channel])
                                held[(size_t)key].released = true;
                            else
                                finishNote(key, event.frame);
                        } else if (message.isController() && message.getControllerNumber() == 64) {
                            sustain[(size_t)channel] = message.getControllerValue() >= 64;
                            if (!sustain[(size_t)channel])
                                for (int note = 0; note < 128; ++note)
                                    if (held[(size_t)(channel * 128 + note)].released)
                                        finishNote(channel * 128 + note, event.frame);
                        } else if (message.isAllNotesOff() || message.isAllSoundOff())
                            for (int note = 0; note < 128; ++note)
                                finishNote(channel * 128 + note, event.frame);
                    }
                for (int key = 0; key < 2048; ++key)
                    finishNote(key, frames);
                take.midi = std::move(item);
            }
            takes.push_back(std::move(take));
        }
        return takes;
    }

    // Worker thread only. Never encode MP3 from the realtime callback.
    // Failure preserves the full WAV capture and never publishes a partial MP3.
    static void finalizeEncoding(Take &take) {
        if (take.encodedFile == File() || take.midi || take.duration <= 0) return;
        if (take.encodedFile.exists()) throw std::runtime_error("O arquivo MP3 de destino já existe.");
        AudioFormatManager formats;
        registerAudioFormats(formats);
        auto reader = std::unique_ptr<AudioFormatReader>(formats.createReaderFor(take.file));
        if (!reader || reader->sampleRate <= 0 || reader->numChannels < 1 || reader->numChannels > 2)
            throw std::runtime_error("Não foi possível ler o áudio capturado para MP3.");
        const double sourceRate = reader->sampleRate;
        const int channels = (int)reader->numChannels;
        // Encode MPEG-1 MP3 rates. Keep compatible device
        // rates; downsample higher-rate captures without changing take duration.
        const int outputRate = sourceRate == 32000 || sourceRate == 44100 || sourceRate == 48000
                                   ? (int)sourceRate : 48000;
        const int64 outputFrames = (int64)std::llround(reader->lengthInSamples * outputRate / sourceRate);
        TemporaryFile temporary(take.encodedFile);
        {
            MP3Writer encoder(temporary.getFile(), outputRate, channels, take.bitrate);
            take.encoderDelaySamples = encoder.encoderDelaySamples();
            AudioFormatReaderSource source(reader.release(), true);
            ResamplingAudioSource resampler(&source, false, channels);
            resampler.setResamplingRatio(sourceRate / outputRate);
            resampler.prepareToPlay(2048, outputRate);
            AudioBuffer<float> block(channels, 2048);
            for (int64 position = 0; position < outputFrames; position += block.getNumSamples()) {
                const int count = (int)std::min<int64>(block.getNumSamples(), outputFrames - position);
                block.clear();
                resampler.getNextAudioBlock(AudioSourceChannelInfo(&block, 0, count));
                encoder.write(block, count);
            }
            resampler.releaseResources();
            encoder.finish();
        }
        if (take.encodedFile.exists() || !temporary.overwriteTargetFileWithTemporary())
            throw std::runtime_error("Não foi possível concluir o arquivo MP3.");
        const auto capture = take.file;
        take.file = take.encodedFile;
        take.encodedFile = File();
        capture.deleteFile();
    }

  private:
    struct ProcessingState {
        std::mutex mutex;
        std::unique_ptr<NativeFX> pending;
        std::map<String, NativeFX::DynamicsPreview> dynamics;
        std::map<String, NativeFX::ParameterPreview> parameters;
        std::atomic<bool> failed{false};
    };
    // Only the disk worker invokes this processor. The callback enqueues the
    // new input plus its fader value; no playback bus enters this writer.
    class InputWriter final : public AudioFormatWriter {
      public:
        InputWriter(std::unique_ptr<AudioFormatWriter> file, const Target &target, double rate, std::shared_ptr<ProcessingState> state)
            : AudioFormatWriter(nullptr, "CatLive recording input", rate, target.channels + 1, 32),
              destination(std::move(file)), preview(target.preview), channels(target.channels),
              postFader(target.postFader), block(2, 4096), state(std::move(state)) {
            usesFloatingPointData = true;
            if (target.postFX) {
                effects.prepare(target.effects, rate, nullptr, false, true, {}, target.mediaDirectory);
                latency = effects.latencyFrames();
            }
            skip = latency;
        }
        ~InputWriter() override {
            try {
                while (!gains.empty() && !state->failed.load()) {
                    const int count = std::min<int64>(4096, (int64)gains.size() + skip);
                    block.clear(); emit(count);
                }
            } catch (...) { state->failed = true; }
            if (preview) preview->flush();
        }
        bool write(const int **data, int count) override {
            try {
                std::unique_ptr<NativeFX> next;
                std::map<String, NativeFX::DynamicsPreview> previews;
                std::map<String, NativeFX::ParameterPreview> parameters;
                { std::lock_guard<std::mutex> lock(state->mutex); next.swap(state->pending); previews.swap(state->dynamics); parameters.swap(state->parameters); }
                if (next) {
                    while (!gains.empty() && !state->failed.load()) { block.clear(); emit(std::min<int64>(4096, (int64)gains.size() + skip)); }
                    next->adoptDynamicsState(effects); effects.swap(*next); latency = effects.latencyFrames(); skip = latency;
                }
                for (const auto &[key, values] : previews) effects.previewDynamics(key, values);
                for (const auto &[key, values] : parameters) effects.previewParameters(key, values);
                for (int at = 0; at < count; at += 4096) {
                    const int length = std::min(4096, count - at);
                    for (int ch = 0; ch < 2; ++ch)
                        block.copyFrom(ch, 0, reinterpret_cast<const float *>(data[std::min(ch, channels - 1)]) + at, length);
                    const auto *gain = reinterpret_cast<const float *>(data[channels]) + at;
                    for (int i = 0; i < length; ++i) gains.push_back(postFader ? gain[i] : 1.f);
                    if (!emit(length)) return false;
                }
                return true;
            } catch (...) { state->failed = true; return false; }
        }
      private:
        bool emit(int count) {
            effects.process(block, count, double(processed) / sampleRate, true);
            processed += count;
            const int drop = std::min(count, skip); skip -= drop;
            const int kept = std::min<int>(count - drop, (int)gains.size());
            if (!kept) return true;
            for (int i = 0; i < kept; ++i) {
                const auto gain = gains.front(); gains.pop_front();
                for (int ch = 0; ch < channels; ++ch)
                    block.setSample(ch, i, block.getSample(ch, i + drop) * gain);
            }
            if (preview) preview->append(block.getArrayOfReadPointers(), kept);
            const bool ok = destination->writeFromAudioSampleBuffer(block, 0, kept);
            if (!ok) state->failed = true;
            return ok;
        }
        std::unique_ptr<AudioFormatWriter> destination;
        std::shared_ptr<RecordingPreview> preview;
        NativeFX effects;
        int channels, latency = 0, skip = 0;
        bool postFader;
        int64 processed = 0;
        AudioBuffer<float> block;
        std::deque<float> gains;
        std::shared_ptr<ProcessingState> state;
    };
    struct Entry {
        Target target;
        File captureFile;
        float gain = 1;
        std::shared_ptr<ProcessingState> processing;
        std::unique_ptr<AudioFormatWriter::ThreadedWriter> writer;
    };
    struct Event {
        int target = 0, length = 0;
        int64 frame = 0;
        std::array<uint8, 3> bytes{};
    };
    TimeSliceThread thread{"CatLive multitrack recording"};
    std::vector<Entry> entries;
    std::vector<Event> events;
    std::array<float, 4096> silence{}, mono{}, gainSamples{};
    double rate, bpm;
    int64 frames = 0;
    uint64 dropped = 0;
};
} // namespace catlive
