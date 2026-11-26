#include "PCMConversion.h"
#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <memory>
#include <new>

namespace {
std::atomic<bool> countAllocations{false};
std::atomic<unsigned> allocations{0};
void check(bool condition, const char* expression, int line) {
    if (!condition) {
        std::fprintf(stderr, "PCMConversionTests:%d: %s\n", line, expression);
        std::abort();
    }
}
#define CHECK(condition) check((condition), #condition, __LINE__)
using namespace catlive::native::audio;
using catlive::native::audio::detail::PCMConversion;
SampleFormat format(SampleEncoding encoding, unsigned channels, unsigned bits, unsigned valid = 0) {
    SampleFormat result;
    result.encoding = encoding; result.channels = static_cast<std::uint16_t>(channels);
    result.containerBits = static_cast<std::uint16_t>(bits);
    result.validBits = static_cast<std::uint16_t>(valid ? valid : bits);
    result.sampleRate = 48000;
    return result;
}

void signedPCM() {
    const std::array<float, 7> samples{-2.f, -1.f, -.5f, 0.f, .5f, 1.f, 2.f};
    // Known two's-complement values, including clipping at each endpoint.
    const std::array<std::uint32_t, 7> values16{0x8000, 0x8000, 0xc000, 0, 0x4000, 0x7fff, 0x7fff};
    const std::array<std::uint32_t, 7> values24{0x800000, 0x800000, 0xc00000, 0, 0x400000, 0x7fffff, 0x7fffff};
    const std::array<std::uint32_t, 7> values32{0x80000000, 0x80000000, 0xc0000000, 0, 0x40000000, 0x7fffffff, 0x7fffffff};
    const std::array<std::uint32_t, 7> values24In32{0x80000000, 0x80000000, 0xc0000000, 0, 0x40000000, 0x7fffff00, 0x7fffff00};
    for (unsigned configuration = 0; configuration < 4; ++configuration) {
        const unsigned bits = configuration == 0 ? 16 : configuration == 1 ? 24 : 32;
        const unsigned valid = configuration == 3 ? 24 : bits;
        const auto& expected = configuration == 0 ? values16 : configuration == 1 ? values24 : configuration == 2 ? values32 : values24In32;
        const PCMConversion conversion(format(SampleEncoding::signedPCM, 1, bits, valid));
        std::array<unsigned char, 32> wire{};
        wire.fill(0x5a);
        auto mutableSamples = samples;
        float* source[]{mutableSamples.data()};
        const std::uint32_t channels[]{0};
        conversion.encode(source, wire.data() + 1, channels, 1, 7);
        CHECK(wire.front() == 0x5a && wire[1 + 7 * bits / 8] == 0x5a);
        for (unsigned sample = 0; sample < 7; ++sample)
            for (unsigned byte = 0; byte < bits / 8; ++byte)
                CHECK(wire[1 + sample * bits / 8 + byte] == ((expected[sample] >> (byte * 8)) & 255));
        // Invalid padding bits must never contaminate a 24-in-32 sample.
        if (configuration == 3) for (unsigned sample = 0; sample < 7; ++sample) wire[1 + sample * 4] = 0xff;
        std::array<float, 9> decoded{}; decoded.fill(99.f);
        float* destination[]{decoded.data() + 1};
        conversion.decode(wire.data() + 1, destination, channels, 1, 7, false);
        CHECK(decoded.front() == 99.f && decoded.back() == 99.f);
        CHECK(decoded[1] == -1.f && decoded[2] == -1.f && decoded[3] == -.5f);
        CHECK(decoded[4] == 0.f && decoded[5] == .5f);
        const float maximum = static_cast<float>(1. - std::ldexp(1., 1 - int(valid)));
        CHECK(decoded[6] == maximum && decoded[7] == maximum);
    }
}

void routingAndSilence() {
    const PCMConversion conversion(format(SampleEncoding::signedPCM, 3, 16));
    std::array<float, 2> first{.5f, -.5f}, second{-1.f, .25f};
    float* source[]{first.data(), second.data()};
    const std::uint32_t selected[]{2, 0};
    std::array<unsigned char, 14> wire{}; wire.fill(0x5a);
    conversion.encode(source, wire.data() + 1, selected, 2, 2);
    const std::array<unsigned char, 12> expected{0x00, 0x80, 0, 0, 0, 0x40, 0, 0x20, 0, 0, 0, 0xc0};
    CHECK(std::equal(expected.begin(), expected.end(), wire.begin() + 1));
    CHECK(wire.front() == 0x5a && wire.back() == 0x5a);
    std::array<float, 2> restoredFirst{}, restoredSecond{};
    float* destination[]{restoredFirst.data(), restoredSecond.data()};
    conversion.decode(wire.data() + 1, destination, selected, 2, 2, false);
    CHECK(restoredFirst == first && restoredSecond == second);
    conversion.decode(nullptr, destination, selected, 2, 2, true);
    CHECK(restoredFirst[0] == 0 && restoredFirst[1] == 0 && restoredSecond[0] == 0 && restoredSecond[1] == 0);

    const PCMConversion unsignedConversion(format(SampleEncoding::unsignedPCM, 2, 8));
    std::array<float, 5> unsignedSamples{-1.f, -.5f, 0.f, .5f, 1.f};
    float* unsignedSource[]{unsignedSamples.data()};
    const std::uint32_t right[]{1};
    std::array<unsigned char, 10> unsignedWire{};
    unsignedConversion.encode(unsignedSource, unsignedWire.data(), right, 1, 5);
    const std::array<unsigned char, 10> unsignedExpected{128, 0, 128, 64, 128, 128, 128, 192, 128, 255};
    CHECK(unsignedWire == unsignedExpected);
    std::array<float, 5> decoded{};
    float* unsignedDestination[]{decoded.data()};
    unsignedConversion.decode(unsignedWire.data(), unsignedDestination, right, 1, 5, false);
    CHECK(decoded[0] == -1.f && decoded[1] == -.5f && decoded[2] == 0 && decoded[3] == .5f && decoded[4] == 127.f / 128);
}

void floatingPointAndInvalidFormats() {
    for (unsigned bits : {32u, 64u}) {
        const PCMConversion conversion(format(SampleEncoding::floatingPoint, 1, bits));
        std::array<float, 5> sourceValues{2.f, -.25f, std::numeric_limits<float>::infinity(),
                                        std::numeric_limits<float>::quiet_NaN(), -3.f};
        std::array<unsigned char, 42> wire{}; wire.fill(0x5a);
        float* source[]{sourceValues.data()}; const std::uint32_t channels[]{0};
        conversion.encode(source, wire.data() + 1, channels, 1, 5);
        std::array<float, 5> destinationValues{};
        float* destination[]{destinationValues.data()};
        conversion.decode(wire.data() + 1, destination, channels, 1, 5, false);
        CHECK(destinationValues[0] == 2.f && destinationValues[1] == -.25f);
        CHECK(destinationValues[2] == 0.f && destinationValues[3] == 0.f && destinationValues[4] == -3.f);
        CHECK(wire.front() == 0x5a && wire[1 + 5 * bits / 8] == 0x5a);
        if (bits == 64) {
            const double invalid[]{std::numeric_limits<double>::infinity(), std::numeric_limits<double>::max(),
                                   std::numeric_limits<double>::quiet_NaN()};
            conversion.decode(invalid, destination, channels, 1, 3, false);
        } else {
            const float invalid[]{std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity(),
                                  std::numeric_limits<float>::quiet_NaN()};
            conversion.decode(invalid, destination, channels, 1, 3, false);
        }
        CHECK(destinationValues[0] == 0.f && destinationValues[1] == 0.f && destinationValues[2] == 0.f);
    }
    CHECK(!PCMConversion::supports(format(SampleEncoding::signedPCM, 0, 16)));
    CHECK(!PCMConversion::supports(format(SampleEncoding::signedPCM, 129, 16)));
    CHECK(!PCMConversion::supports(format(SampleEncoding::signedPCM, 2, 8)));
    CHECK(!PCMConversion::supports(format(SampleEncoding::signedPCM, 2, 24, 25)));
    CHECK(!PCMConversion::supports(format(SampleEncoding::floatingPoint, 2, 32, 24)));
    CHECK(!PCMConversion::supports(format(SampleEncoding::unsignedPCM, 2, 16)));
}

void allocationFreeMaximumBlock() {
    constexpr unsigned frames = 65536;
    const PCMConversion conversion(format(SampleEncoding::signedPCM, 2, 32, 24));
    auto input = std::make_unique<float[]>(frames * 2);
    auto output = std::make_unique<float[]>(frames * 2);
    auto wire = std::make_unique<unsigned char[]>(frames * 8);
    float* source[]{input.get(), input.get() + frames};
    float* destination[]{output.get(), output.get() + frames};
    const std::uint32_t channels[]{1, 0};
    std::fill_n(source[0], frames, .125f); std::fill_n(source[1], frames, -.75f);
    allocations.store(0); countAllocations.store(true);
    for (unsigned iteration = 0; iteration < 8; ++iteration) {
        conversion.encode(source, wire.get(), channels, 2, frames);
        conversion.decode(wire.get(), destination, channels, 2, frames, false);
    }
    countAllocations.store(false);
    CHECK(allocations.load() == 0);
    CHECK(destination[0][0] == .125f && destination[0][frames - 1] == .125f);
    CHECK(destination[1][0] == -.75f && destination[1][frames - 1] == -.75f);
}
} // namespace

void* operator new(std::size_t bytes) {
    if (countAllocations.load(std::memory_order_relaxed)) allocations.fetch_add(1, std::memory_order_relaxed);
    if (auto* memory = std::malloc(bytes ? bytes : 1)) return memory;
    throw std::bad_alloc();
}
void* operator new[](std::size_t bytes) { return ::operator new(bytes); }
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void* memory, std::size_t) noexcept { std::free(memory); }

int main() {
    signedPCM(); routingAndSilence(); floatingPointAndInvalidFormats(); allocationFreeMaximumBlock();
    std::puts("Native PCM conversion tests passed.");
}
