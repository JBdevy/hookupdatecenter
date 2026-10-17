#pragma once
#include "Common.h"
#include "AudioFormats.h"
#include "MP3Writer.h"
#include "RecordingEncoding.h"
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
        bool bus = false, midi = false;
        int bits = 0;
        bool floatingPoint = false;
        int bitrate = 320;
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
        if (specs.empty() || specs.size() > 512 || rate <= 0 || bpm <= 0)
            throw std::runtime_error("Invalid recording configuration.");
        silence.fill(0);
        events.reserve(65536);
        thread.startThread(Thread::Priority::high);
        for (const auto &spec : specs) {
            if (spec.channels < 1 || spec.channels > 2 || spec.input < 1 || spec.input > 128)
                throw std::runtime_error("Invalid recording patch.");
            Entry entry;
            entry.target = spec;
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
                    std::make_unique<AudioFormatWriter::ThreadedWriter>(writer.release(), thread, 131072);
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
                const float *pointers[2]{silence.data(), silence.data()};
                for (int ch = 0; ch < entry.target.channels; ++ch) {
                    const int physical = entry.target.input - 1 + ch;
                    const int packed = physical < 128 ? mapping[(size_t)physical] : -1;
                    if (packed >= 0 && packed < channels && data && data[packed])
                        pointers[ch] = data[packed];
                }
                if (!entry.writer->write(pointers, count))
                    ++dropped;
            }
    }
    void bus(const ID &id, const AudioBuffer<float> &buffer, int count) {
        for (auto &entry : entries)
            if (entry.target.bus && !entry.target.midi && entry.target.track == id) {
                const float *pointers[2]{buffer.getReadPointer(0), buffer.getReadPointer(1)};
                if (entry.target.channels == 1) {
                    for (int i = 0; i < count; ++i)
                        mono[(size_t)i] = (pointers[0][i] + pointers[1][i]) * .5f;
                    pointers[0] = mono.data();
                }
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
    void advance(int count) { frames += count; }
    int64 sampleCount() const { return frames; }
    uint64 overflows() const { return dropped; }
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
    struct Entry {
        Target target;
        File captureFile;
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
    std::array<float, 4096> silence{}, mono{};
    double rate, bpm;
    int64 frames = 0;
    uint64 dropped = 0;
};
} // namespace catlive
