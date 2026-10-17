#include "../Source/AudioFile.h"
#include "../ThirdParty/dr_libs/dr_mp3.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using namespace catlive::native;
using Bytes = std::vector<std::uint8_t>;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void word(Bytes& bytes, std::uint64_t value, unsigned width, bool big = false) {
    for (unsigned i = 0; i < width; ++i)
        bytes.push_back(static_cast<std::uint8_t>(value >> (8 * (big ? width - 1 - i : i))));
}
void tag(Bytes& bytes, const char* name) { bytes.insert(bytes.end(), name, name + 4); }
void chunk(Bytes& bytes, const char* name, const Bytes& data, bool big = false) {
    tag(bytes, name);
    word(bytes, data.size(), 4, big);
    bytes.insert(bytes.end(), data.begin(), data.end());
    if (data.size() % 2) bytes.push_back(0);
}
struct Fixture {
    Bytes bytes;
    std::vector<float> expected;
    unsigned channels = 2, rate = 48000, bits = 16, frames = 1001;
};
Bytes samples(Fixture& fixture, bool big, bool unsigned8 = false, bool floating = false) {
    Bytes data;
    for (unsigned frame = 0; frame < fixture.frames; ++frame)
        for (unsigned ch = 0; ch < fixture.channels; ++ch) {
            const int value = static_cast<int>((frame * 19 + ch * 57) % 251) - 125;
            const auto expected = value / 128.f * (floating ? 2.f : 1.f);
            fixture.expected.push_back(expected);
            if (floating) {
                if (fixture.bits == 32) {
                    std::uint32_t raw = 0;
                    std::memcpy(&raw, &expected, 4);
                    word(data, raw, 4, big);
                } else {
                    const double sample = expected;
                    std::uint64_t raw = 0;
                    std::memcpy(&raw, &sample, 8);
                    word(data, raw, 8, big);
                }
            } else if (fixture.bits == 8)
                word(data, static_cast<std::uint8_t>(value + (unsigned8 ? 128 : 0)), 1);
            else word(data, static_cast<std::uint64_t>(value * (std::int64_t(1) << (fixture.bits - 8))),
                      fixture.bits / 8, big);
        }
    return data;
}
Fixture wave(unsigned bits = 16, unsigned channels = 2, bool floating = false,
             bool extensible = false, bool rf64 = false) {
    Fixture f;
    f.bits = bits; f.channels = channels;
    auto data = samples(f, false, true, floating);
    Bytes format;
    word(format, extensible ? 0xfffe : floating ? 3 : 1, 2);
    word(format, channels, 2); word(format, f.rate, 4);
    word(format, f.rate * channels * bits / 8, 4);
    word(format, channels * bits / 8, 2); word(format, bits, 2);
    if (extensible) {
        word(format, 22, 2); word(format, bits == 32 && !floating ? 24 : bits, 2);
        word(format, channels == 4 ? 0x33 : 3, 4);
        word(format, floating ? 3 : 1, 4); word(format, 0, 2); word(format, 0x0010, 2);
        const std::uint8_t tail[]{0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71};
        format.insert(format.end(), std::begin(tail), std::end(tail));
    }
    Bytes body;
    tag(body, "WAVE");
    if (rf64) {
        Bytes ds;
        word(ds, 4 + 36 + 8 + format.size() + 12 + 8 + data.size(), 8);
        word(ds, data.size(), 8); word(ds, f.frames, 8); word(ds, 0, 4);
        chunk(body, "ds64", ds);
    }
    chunk(body, "fmt ", format);
    chunk(body, "JUNK", {1, 2, 3}); // Exercise odd-sized unknown chunk padding.
    if (rf64) {
        tag(body, "data"); word(body, 0xffffffffU, 4);
        body.insert(body.end(), data.begin(), data.end());
        if (data.size() % 2) body.push_back(0);
    } else chunk(body, "data", data);
    tag(f.bytes, rf64 ? "RF64" : "RIFF");
    word(f.bytes, rf64 ? 0xffffffffU : body.size(), 4);
    f.bytes.insert(f.bytes.end(), body.begin(), body.end());
    return f;
}
Fixture aiff(unsigned bits, const char* codec = nullptr) {
    Fixture f;
    f.bits = bits;
    const bool floating = codec && (std::strcmp(codec, "fl32") == 0 || std::strcmp(codec, "fl64") == 0);
    const bool little = codec && std::strcmp(codec, "sowt") == 0;
    auto data = samples(f, !little, false, floating);
    Bytes common;
    word(common, f.channels, 2, true); word(common, f.frames, 4, true); word(common, bits, 2, true);
    // Exact 80-bit extended representation of 48000 Hz.
    word(common, 0x400e, 2, true); word(common, 0xbb80000000000000ULL, 8, true);
    if (codec) { tag(common, codec); common.push_back(0); common.push_back(0); }
    Bytes body;
    tag(body, codec ? "AIFC" : "AIFF");
    if (codec) { Bytes version; word(version, 0xa2805140, 4, true); chunk(body, "FVER", version, true); }
    chunk(body, "COMM", common, true);
    chunk(body, "ANNO", {1, 2, 3}, true);
    Bytes sound;
    word(sound, 3, 4, true); word(sound, 0, 4, true);
    sound.insert(sound.end(), {0, 0, 0}); // SSND offset is not PCM.
    sound.insert(sound.end(), data.begin(), data.end());
    chunk(body, "SSND", sound, true);
    tag(f.bytes, "FORM"); word(f.bytes, body.size(), 4, true);
    f.bytes.insert(f.bytes.end(), body.begin(), body.end());
    return f;
}
unsigned crc(const Bytes& bytes, unsigned width, unsigned polynomial) {
    unsigned value = 0;
    for (auto byte : bytes) {
        value ^= unsigned(byte) << (width - 8);
        for (int bit = 0; bit < 8; ++bit)
            value = (value << 1) ^ ((value & (1U << (width - 1))) ? polynomial : 0);
        value &= (1U << width) - 1;
    }
    return value;
}
Fixture flac(bool unknownLength = false) {
    // Independent minimal RFC 9639 encoder: verbatim stereo frames with CRCs.
    // Synthetic PCM only; no borrowed recording or decoder writer is involved.
    Fixture f;
    f.frames = 1024;
    samples(f, true);
    tag(f.bytes, "fLaC");
    word(f.bytes, 0x80, 1); word(f.bytes, 34, 3, true);
    word(f.bytes, 32, 2, true); word(f.bytes, 32, 2, true);
    word(f.bytes, 0, 3); word(f.bytes, 0, 3);
    word(f.bytes, (std::uint64_t(f.rate) << 44) | (std::uint64_t(f.channels - 1) << 41) |
         (std::uint64_t(f.bits - 1) << 36) | (unknownLength ? 0 : f.frames), 8, true);
    f.bytes.insert(f.bytes.end(), 16, 0); // No MD5 supplied, as permitted by FLAC.
    for (unsigned block = 0; block < f.frames / 32; ++block) {
        Bytes frame{0xff, 0xf8, 0x60, 0x18, static_cast<std::uint8_t>(block), 31};
        word(frame, crc(frame, 8, 0x07), 1);
        for (unsigned ch = 0; ch < 2; ++ch) {
            frame.push_back(2); // Verbatim subframe, no wasted bits.
            for (unsigned i = 0; i < 32; ++i)
                word(frame, static_cast<std::uint16_t>(static_cast<std::int16_t>(
                    f.expected[(block * 32 + i) * 2 + ch] * 32768)), 2, true);
        }
        word(frame, crc(frame, 16, 0x8005), 2, true);
        f.bytes.insert(f.bytes.end(), frame.begin(), frame.end());
    }
    return f;
}
struct TemporaryDirectory {
    std::filesystem::path path;
    TemporaryDirectory() {
        path = std::filesystem::temp_directory_path() /
            ("catlive-audio-tests-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
        if (!std::filesystem::create_directory(path)) throw std::runtime_error("Could not create test directory.");
    }
    ~TemporaryDirectory() { std::error_code error; std::filesystem::remove_all(path, error); }
    std::filesystem::path write(const std::string& name, const Bytes& bytes) const {
        const auto file = path / std::filesystem::u8path(name);
        std::ofstream output(file, std::ios::binary);
        output.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        if (!output) throw std::runtime_error("Could not write audio test fixture.");
        return file;
    }
};
void compare(const float* actual, const float* expected, std::size_t samples, float tolerance = .000001f) {
    for (std::size_t i = 0; i < samples; ++i)
        if (!std::isfinite(actual[i]) || std::abs(actual[i] - expected[i]) > tolerance)
            throw std::runtime_error("PCM differs at sample " + std::to_string(i) + ": " +
                std::to_string(actual[i]) + " vs " + std::to_string(expected[i]));
}
void seekChecks(AudioFile& reader, const std::vector<float>& baseline, float tolerance = .000001f) {
    const auto channels = reader.info().channels;
    const auto frames = reader.info().frameCount;
    require(frames > 0 && baseline.size() == frames * channels, "Invalid baseline size.");
    std::uint64_t random = 79;
    for (unsigned trial = 0; trial < 120; ++trial) {
        random = random * 6364136223846793005ULL + 1442695040888963407ULL;
        const std::uint64_t first = trial < 6 ? std::min<std::uint64_t>(frames - 1,
            std::array<std::uint64_t, 6>{0, 1, 529, 1105, 2304, frames - 1}[trial]) : random % frames;
        const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(frames - first, 1 + trial * 53 % 4096));
        std::vector<float> output(count * channels);
        try {
            require(reader.readInterleaved(first, output.data(), count) == count, "Short PCM seek read.");
            compare(output.data(), baseline.data() + first * channels, output.size(), tolerance);
        }
        catch (const std::exception& error) {
            throw std::runtime_error("Seek frame " + std::to_string(first) + ": " + error.what());
        }
    }
}
void fixtureChecks(const TemporaryDirectory& temporary, const std::string& name, const Fixture& fixture,
                   AudioFileFormat format) {
    const auto file = temporary.write(name, fixture.bytes);
    AudioFile reader(file);
    const auto& info = reader.info();
    require(info.format == format && info.channels == fixture.channels && info.sampleRate == fixture.rate &&
            info.bitsPerSample == fixture.bits && info.frameCount == fixture.frames &&
            info.encodedBytes == fixture.bytes.size(), "Wrong source audio metadata.");
    std::vector<float> actual(fixture.expected.size());
    require(reader.readInterleaved(0, actual.data(), fixture.frames) == fixture.frames, "Short full PCM read.");
    compare(actual.data(), fixture.expected.data(), actual.size());
    seekChecks(reader, fixture.expected);
}
} // namespace

int main(int argc, char** argv) {
    int passed = 0, failed = 0, skipped = 0;
    const auto test = [&](const char* name, const std::function<void()>& body) {
        try { body(); ++passed; std::cout << "PASS " << name << '\n'; }
        catch (const std::exception& error) { ++failed; std::cerr << "FAIL " << name << ": " << error.what() << '\n'; }
    };
    TemporaryDirectory temporary;
    test("WAV integer PCM 8 16 24 32 and IEEE float 32 64 retain precision", [&] {
        for (unsigned bits : {8, 16, 24, 32})
            fixtureChecks(temporary, "integer" + std::to_string(bits) + ".wav", wave(bits), AudioFileFormat::wav);
        for (unsigned bits : {32, 64})
            fixtureChecks(temporary, "float" + std::to_string(bits) + ".wav", wave(bits, 2, true), AudioFileFormat::wav);
    });
    test("AIFF big-endian PCM and AIFC sowt float codecs seek correctly", [&] {
        for (unsigned bits : {8, 16, 24, 32})
            fixtureChecks(temporary, "integer" + std::to_string(bits) + ".aiff", aiff(bits), AudioFileFormat::aiff);
        fixtureChecks(temporary, "little.aifc", aiff(24, "sowt"), AudioFileFormat::aiff);
        fixtureChecks(temporary, "float.aifc", aiff(32, "fl32"), AudioFileFormat::aiff);
        fixtureChecks(temporary, "double.aifc", aiff(64, "fl64"), AudioFileFormat::aiff);
    });
    test("FLAC lossless PCM and unspecified total length are measured exactly", [&] {
        fixtureChecks(temporary, "lossless.flac", flac(), AudioFileFormat::flac);
        fixtureChecks(temporary, "unknown-length.flac", flac(true), AudioFileFormat::flac);
    });
    test("RF64 and extensible multichannel WAV preserve count and channel mask", [&] {
        fixtureChecks(temporary, "large-container.wav", wave(24, 2, false, false, true), AudioFileFormat::wav);
        const auto fixture = wave(32, 4, false, true);
        fixtureChecks(temporary, "four-tracks.wav", fixture, AudioFileFormat::wav);
        AudioFile reader(temporary.path / "four-tracks.wav");
        require(reader.info().channelMask == 0x33 && reader.info().validBitsPerSample == 24,
                "WAVE_FORMAT_EXTENSIBLE channel layout/precision was lost.");
    });
    test("Unicode paths and independent readers support interleaved main and sub positions", [&] {
        const auto fixture = wave(24);
        const auto file = temporary.write(u8"Música — Guilherme 東京.wav", fixture.bytes);
        AudioFile main(file), sub(file);
        for (unsigned i = 0; i < 20; ++i) {
            std::vector<float> a(66), b(82);
            main.readInterleaved(i * 31, a.data(), 33);
            sub.readInterleaved(900 - i * 39, b.data(), 41);
            compare(a.data(), fixture.expected.data() + i * 31 * 2, a.size());
            compare(b.data(), fixture.expected.data() + (900 - i * 39) * 2, b.size());
        }
    });
    test("planar output EOF and extra channels are zeroed without resampling", [&] {
        const auto fixture = wave(24);
        AudioFile reader(temporary.write("planes.wav", fixture.bytes));
        std::array<std::array<float, 64>, 4> planes;
        for (auto& plane : planes) plane.fill(3);
        float* pointers[]{planes[0].data(), nullptr, planes[2].data(), planes[3].data()};
        require(reader.readFrames(fixture.frames - 17, pointers, 4, 64) == 17, "EOF count is not exact.");
        for (unsigned i = 0; i < 64; ++i) {
            require(planes[0][i] == (i < 17 ? fixture.expected[(fixture.frames - 17 + i) * 2] : 0), "Planar source/EOF incorrect.");
            require(planes[1][i] == 3 && planes[2][i] == 0 && planes[3][i] == 0, "Null/extra output planes were mishandled.");
        }
        std::vector<float> end(128, 3);
        require(reader.readInterleaved(std::numeric_limits<std::uint64_t>::max(), end.data(), 64) == 0 &&
                std::all_of(end.begin(), end.end(), [](float sample) { return sample == 0; }), "Beyond-EOF output was not silent.");
    });
    test("truncation invalid format and non-finite PCM fail explicitly", [&] {
        auto expectFailure = [&](const std::string& name, Bytes bytes, bool read = false) {
            bool rejected = false;
            try {
                AudioFile reader(temporary.write(name, bytes));
                if (read) {
                    std::vector<float> output(static_cast<std::size_t>(reader.info().frameCount) * reader.info().channels);
                    reader.readInterleaved(0, output.data(), static_cast<std::size_t>(reader.info().frameCount));
                }
            } catch (const std::exception&) { rejected = true; }
            if (!rejected) throw std::runtime_error(name + ": damaged audio was accepted silently.");
        };
        auto truncated = wave(24).bytes; truncated.resize(truncated.size() - 20);
        expectFailure("truncated.wav", truncated);
        auto damagedFlac = flac().bytes; damagedFlac.resize(damagedFlac.size() - 30);
        expectFailure("truncated.flac", damagedFlac, true);
        expectFailure("unknown.bin", Bytes(32, 42));
        auto nan = wave(32, 2, true).bytes;
        nan[nan.size() - 4] = 0; nan[nan.size() - 3] = 0; nan[nan.size() - 2] = 0xc0; nan[nan.size() - 1] = 0x7f;
        expectFailure("not-finite.wav", nan, true);
        AudioFile good(temporary.write("valid.wav", wave().bytes));
        bool rejected = false;
        try { good.readInterleaved(0, nullptr, 8); } catch (const std::invalid_argument&) { rejected = true; }
        require(rejected, "Null destination accepted.");
    });
    test("rejected PCM does not leave the next read at a stale decoder position", [&] {
        auto fixture = wave(32, 2, true);
        auto& bytes = fixture.bytes;
        bytes[bytes.size() - 4] = 0; bytes[bytes.size() - 3] = 0;
        bytes[bytes.size() - 2] = 0xc0; bytes[bytes.size() - 1] = 0x7f;
        AudioFile reader(temporary.write("recoverable-prefix.wav", bytes));
        std::vector<float> output(fixture.expected.size());
        bool rejected = false;
        try { reader.readInterleaved(0, output.data(), fixture.frames); }
        catch (const std::runtime_error&) { rejected = true; }
        require(rejected, "Non-finite tail was not rejected.");
        require(reader.readInterleaved(0, output.data(), 32) == 32,
                "A valid prefix could not be read after a rejected block.");
        compare(output.data(), fixture.expected.data(), 32 * fixture.channels);
    });
    if (argc > 1) test("real MP3 random seeking equals continuous decode including priming and EOF", [&] {
        const auto file = std::filesystem::u8path(argv[1]);
        AudioFile sequential(file), random(file);
        require(sequential.info().format == AudioFileFormat::mp3 && sequential.info().bitsPerSample == 0,
                "MP3 metadata reported an invented PCM bit depth.");
        const auto frames = sequential.info().frameCount;
        const auto channels = sequential.info().channels;
        require(frames <= 64000000 / channels, "MP3 test fixture is too large for bounded baseline memory.");
        // The oracle starts at the upstream decoder's original position and
        // never seeks or creates checkpoints. This detects a common offset in
        // both of our indexed readers as well as bad individual random seeks.
        drmp3 reference{};
#if defined(_WIN32)
        const bool opened = drmp3_init_file_w(&reference, file.c_str(), nullptr) != 0;
#else
        const bool opened = drmp3_init_file(&reference, file.c_str(), nullptr) != 0;
#endif
        require(opened, "Could not open independent continuous MP3 reference.");
        const std::unique_ptr<drmp3, void(*)(drmp3*)> referenceOwner(&reference, drmp3_uninit);
        std::vector<float> baseline(static_cast<std::size_t>(frames) * channels);
        std::vector<float> indexed(997 * channels);
        for (std::uint64_t at = 0; at < frames; at += 997) {
            const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(997, frames - at));
            require(drmp3_read_pcm_frames_f32(&reference, count, baseline.data() + at * channels) == count,
                    "MP3 frame count differs from independent continuous decode.");
            require(sequential.readInterleaved(at, indexed.data(), count) == count,
                    "MP3 frame count differs from continuous decode.");
            compare(indexed.data(), baseline.data() + at * channels, count * channels, 0.f);
        }
        require(drmp3_read_pcm_frames_f32(&reference, 1, indexed.data()) == 0,
                "MP3 indexed length discarded audible frames.");
        require(std::any_of(baseline.begin(), baseline.end(), [](float value) { return std::abs(value) > .001f; }),
                "MP3 fixture is not audible.");
        seekChecks(random, baseline, 0.f);
        std::cout << "MP3 " << frames << " frames, " << sequential.info().sampleRate << " Hz, " << channels << " channels\n";
    });
    else { ++skipped; std::cout << "SKIP real MP3: pass an existing local .mp3 as the first argument.\n"; }
    std::cout << passed << " passed, " << failed << " failed, " << skipped << " skipped\n";
    return failed == 0 ? 0 : 1;
}
