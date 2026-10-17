#pragma once
#include "TrackCapture.h"
#include "AudioExport.h"

namespace catlive::recordingCaptureTests {
inline void require(bool passed, const String &message) {
    if (!passed) throw std::runtime_error(utf8(message));
}
inline TrackCapture::Take capture(const File &file, int rate, int channels, int bits,
                                  bool floatingPoint, int bitrate, bool impulse) {
    TrackCapture::Target target{uuid(), file, 1, channels};
    target.bits = bits; target.floatingPoint = floatingPoint; target.bitrate = bitrate;
    TrackCapture recorder({target}, rate, bits, 120);
    std::array<int, 128> mapping; mapping.fill(-1); mapping[0] = 0; mapping[1] = 1;
    AudioBuffer<float> block(2, 512);
    const int frames = rate / 2;
    for (int at = 0; at < frames; at += block.getNumSamples()) {
        const int count = std::min(block.getNumSamples(), frames - at);
        block.clear();
        for (int i = 0; i < count; ++i) {
            const int position = at + i;
            const float value = impulse ? (position == rate / 8 ? .95f :
                position > rate / 4 ? .08f * (float)std::sin(2 * MathConstants<double>::pi * 440 * position / rate) : 0.f)
                : floatingPoint ? 1.25f : .25f;
            block.setSample(0, i, value); block.setSample(1, i, -.5f * value);
        }
        recorder.input(block.getArrayOfReadPointers(), 2, count, mapping);
        recorder.advance(count);
    }
    require(recorder.overflows() == 0, "Test capture overflowed");
    auto takes = recorder.finish();
    require(takes.size() == 1, "Capture did not return one take");
    return std::move(takes.front());
}
inline std::unique_ptr<AudioFormatReader> read(const File &file) {
    AudioFormatManager formats; registerAudioFormats(formats);
    auto reader = std::unique_ptr<AudioFormatReader>(formats.createReaderFor(file));
    require(reader != nullptr, "Unable to decode captured file: " + file.getFileName());
    return reader;
}
inline void rules() {
    using recordingEncoding::resolve;
    require(resolve({}, "WAV", 24, 320).extension == ".wav", "Default format is not WAV");
    require(resolve({}, "WAV", 32, 320).bits == 32 && !resolve({}, "WAV", 32, 320).floatingPoint,
            "Advanced WAV32 must be PCM");
    require(resolve("wav32", "MP3", 16, 320).floatingPoint && resolve("wav32", "MP3", 16, 320).extension == ".wav",
            "Track WAV32 must override Advanced and use float");
    require(resolve("wav", "AIFF", 32, 320).bits == 24 && resolve("wav", "AIFF", 32, 320).extension == ".wav",
            "Track WAV must override Advanced as 24-bit PCM");
    require(resolve({}, "AIFF", 16, 320).extension == ".aiff" && resolve({}, "AIFF", 16, 320).bits == 16,
            "Advanced AIFF16 changed");
    require(resolve({}, "invalid", 12, 129).bits == 24 && resolve({}, "invalid", 12, 129).bitrate == 320,
            "Invalid preferences do not use Mac defaults");
    for (int rate : recordingEncoding::mp3Bitrates)
        require(resolve("mp3", "WAV", 24, rate).bitrate == rate && resolve("mp3", "WAV", 24, rate).extension == ".mp3",
                "MP3 bitrate was discarded");
}
inline void pcm(const File &directory, const String &extension, int bits, bool floatingPoint) {
    const auto file = directory.getChildFile(text(uuid()) + extension);
    const auto take = capture(file, 48000, 1, bits, floatingPoint, 320, false);
    auto reader = read(take.file);
    require(reader->bitsPerSample == (unsigned)bits && reader->usesFloatingPointData == floatingPoint,
            "Recorded PCM/float encoding differs from the selected format");
    require(reader->lengthInSamples == 24000 && reader->sampleRate == 48000 && reader->numChannels == 1,
            "Recorded PCM changed sample count/rate/channels");
    AudioBuffer<float> block(1, 32); reader->read(&block, 0, 32, 100, true, false);
    require(std::abs(block.getSample(0, 0) - (floatingPoint ? 1.25f : .25f)) < .0001f,
            "Recorded float was clipped or PCM amplitude changed");
}
inline void mp3(const File &directory, int bitrate, int channels, int rate = 48000) {
    const auto file = directory.getChildFile(text(uuid()) + ".mp3");
    auto take = capture(file, rate, channels, 24, false, bitrate, true);
    const auto raw = take.file;
    require(raw.hasFileExtension("wav") && !file.existsAsFile(), "MP3 capture was encoded on the realtime path");
    TrackCapture::finalizeEncoding(take);
    require(take.file == file && !raw.existsAsFile(), "Finalized MP3 did not replace its temporary capture");
    auto reader = read(take.file);
    const auto outputRate = rate == 32000 || rate == 44100 || rate == 48000 ? rate : 48000;
    require(reader->numChannels == (unsigned)channels && reader->sampleRate == outputRate,
            "MP3 changed channel count or expected rate");
    require(std::abs(take.duration - .5) < 1e-9 &&
            reader->lengthInSamples == outputRate / 2, "MP3 gapless PCM length changed");
    MemoryBlock encoded; require(file.loadFileAsData(encoded), "Could not inspect MP3 frame header");
    const auto *bytes = static_cast<const uint8 *>(encoded.getData());
    constexpr int rates[]{0,32,40,48,56,64,80,96,112,128,160,192,224,256,320,0};
    int headerRate = 0;
    for (size_t i = 0; i + 4 < encoded.getSize(); ++i)
        if (bytes[i] == 0xff && (bytes[i + 1] & 0xfe) == 0xfa && rates[bytes[i + 2] >> 4]) {
            headerRate = rates[bytes[i + 2] >> 4]; break;
        }
    require(headerRate == bitrate, "MP3 frame bitrate differs from preference: " + String(headerRate));
    AudioBuffer<float> decoded(channels, (int)reader->lengthInSamples);
    reader->read(&decoded, 0, decoded.getNumSamples(), 0, true, true);
    int peak = 0;
    for (int i = 1; i < std::min(decoded.getNumSamples(), outputRate / 4); ++i)
        if (std::abs(decoded.getSample(0, i)) > std::abs(decoded.getSample(0, peak))) peak = i;
    require(std::abs(decoded.getSample(0, peak)) > .1f, "MP3 lost captured impulse");
    const int delay = peak - outputRate / 8;
    require(std::abs(delay) <= 2, "MP3 impulse delay=" + String(delay) + " samples; " +
            String(bitrate) + " kbps, " + String(channels) + "ch, " + String(rate) + "Hz; metadata=" +
            reader->metadataValues.getDescription() + "; encoder delay=" + String(take.encoderDelaySamples));
    AudioBuffer<float> seek(channels, 333);
    require(reader->read(&seek, 0, 333, outputRate / 8 - 100, true, true), "MP3 backward seek failed");
    for (int ch = 0; ch < channels; ++ch) for (int i = 0; i < 333; ++i)
        require(seek.getSample(ch, i) == decoded.getSample(ch, outputRate / 8 - 100 + i),
                "MP3 seek changed the decoded waveform");
}
inline void collision(const File &directory) {
    const auto file = directory.getChildFile(text(uuid()) + ".mp3");
    auto take = capture(file, 48000, 1, 24, false, 192, true);
    require(file.replaceWithText("existing"), "Could not create collision fixture");
    bool rejected = false;
    try { TrackCapture::finalizeEncoding(take); } catch (...) { rejected = true; }
    require(rejected && take.file.existsAsFile() && take.file.hasFileExtension("wav") && file.loadFileAsString() == "existing",
            "Failed MP3 finalization destroyed the raw take or existing destination");
}
inline void aiff32Export(const File &directory) {
    const auto folder = directory.getChildFile("aiff32-export-" + text(uuid()));
    folder.createDirectory();
    capture(folder.getChildFile("source.wav"), 48000, 2, 24, false, 320, false);
    jaras::Project project; project.id = uuid();
    jaras::Song song; song.id = uuid(); song.duration = .5;
    jaras::Track track; track.id = uuid(); track.name = "AIFF32 export";
    track.role.id = "other"; track.volume = 1;
    track.outputs = std::vector<jaras::OutputPatch>{{0, 2}};
    jaras::AudioClip clip; clip.id = uuid(); clip.duration = .5;
    clip.audioFile = jaras::AudioFile{"source.wav", {}};
    track.clips.push_back(clip); song.tracks.push_back(track); project.songs.push_back(song);
    ExportRequest request; request.directory = folder.getChildFile("exported");
    auto &encoding = request.encodings[0];
    encoding.format = "AIFF"; encoding.bits = 32; encoding.rate = 48000; encoding.channels = 2;
    ExportJob job; job.name = "render-32.aiff"; job.start = 0; job.end = .5; job.track = track.id;
    request.jobs.push_back(job);
    std::atomic<bool> cancel{false};
    audioExport::render(project, song, folder, request, cancel, {});
    auto reader = read(request.directory.getChildFile(job.name));
    require(reader->bitsPerSample == 32 && !reader->usesFloatingPointData &&
            reader->numChannels == 2 && reader->sampleRate == 48000 && reader->lengthInSamples == 24000,
            "AIFF32 export did not preserve requested signed PCM depth/rate/channels/length");
    AudioBuffer<float> decoded(2, 64);
    require(reader->read(&decoded, 0, 64, 100, true, true), "AIFF32 export could not be decoded");
    require(std::abs(decoded.getSample(0, 0) - .25f) < .0002f &&
            std::abs(decoded.getSample(1, 0) + .125f) < .0002f, "AIFF32 export changed the PCM amplitude");
}
template <typename Register>
void registerTests(const File &directory, Register &&test) {
    const auto folder = directory.getChildFile("recording-encoding-" + text(uuid()));
    folder.createDirectory();
    test("Recording format defaults and track overrides match Mac", [] { rules(); });
    for (int bits : {16, 24, 32}) for (const String extension : {String(".wav"), String(".aiff")})
        test("Recording PCM " + extension + " " + String(bits), [=] { pcm(folder, extension, bits, false); });
    test("Recording WAV32 float preserves headroom", [=] { pcm(folder, ".wav", 32, true); });
    for (int bitrate : recordingEncoding::mp3Bitrates) for (int channels : {1, 2})
        test("Recording MP3 " + String(bitrate) + "kbps " + String(channels) + "ch alignment", [=] { mp3(folder, bitrate, channels); });
    test("Recording MP3 resamples 96kHz without shifting timeline", [=] { mp3(folder, 192, 2, 96000); });
    test("Recording MP3 failure keeps captured WAV and existing destination", [=] { collision(folder); });
    test("AIFF32 export renders real signed PCM and reopens correctly", [=] { aiff32Export(folder); });
}
} // namespace catlive::recordingCaptureTests
