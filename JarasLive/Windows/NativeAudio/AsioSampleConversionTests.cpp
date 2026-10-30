#include "AsioSampleConversion.h"
#include "AsioDevice.h"
#include <array>
#include <atomic>
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <new>

namespace {
thread_local bool countAllocations = false;
std::atomic<unsigned> allocations{0};
void* allocate(std::size_t size) {
    if (countAllocations) allocations.fetch_add(1, std::memory_order_relaxed);
    if (auto* value = std::malloc(size ? size : 1)) return value;
    throw std::bad_alloc();
}
}
void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void operator delete(void* value) noexcept { std::free(value); }
void operator delete[](void* value) noexcept { std::free(value); }
void operator delete(void* value, std::size_t) noexcept { std::free(value); }
void operator delete[](void* value, std::size_t) noexcept { std::free(value); }

int main() {
    using namespace catlive::native::audio;
    using namespace asio_detail;
    const PCMFormat formats[]{{2,16},{3,24},{4,16},{4,18},{4,20},{4,24},{4,32},{4,32,false,true},{8,64,false,true}};
    const std::array<float,12> samples{0.f,.5f,-.5f,1.f,-1.f,.125f,-.125f,2.f,-2.f,
        std::numeric_limits<float>::quiet_NaN(),std::numeric_limits<float>::infinity(),-std::numeric_limits<float>::infinity()};
    for (auto format : formats) for (bool big : {false,true}) {
        format.bigEndian = big;
        const auto converter = makeConverter(format); assert(converter && converter.bytes == format.storageBytes);
        std::array<unsigned char,128> encoded; encoded.fill(0xcc);
        std::array<float,samples.size()> decoded{};
        converter.encode(encoded.data()+3,samples.data(),samples.size());
        converter.decode(decoded.data(),encoded.data()+3,samples.size());
        const auto tolerance = format.floatingPoint ? 0. : 1. / double(std::uint64_t(1) << (format.validBits-1));
        for (std::size_t n=0;n<samples.size();++n) {
            const auto expected = std::isfinite(samples[n]) ? format.floatingPoint ? samples[n] : std::clamp(samples[n],-1.f,1.f) : 0.f;
            assert(std::abs(double(decoded[n])-expected) <= tolerance + 1.e-7);
        }
        for (std::size_t n=0;n<3;++n) assert(encoded[n]==0xcc);
        for (std::size_t n=3+samples.size()*format.storageBytes;n<encoded.size();++n) assert(encoded[n]==0xcc);
        // Known wire values independently verify endian order, sign extension,
        // and right alignment rather than only testing a paired round trip.
        std::uint64_t half = format.floatingPoint ? format.storageBytes == 4 ? 0x3f000000ULL : 0x3fe0000000000000ULL : std::uint64_t(1) << (format.validBits-2);
        std::uint64_t minusHalf = format.floatingPoint ? format.storageBytes == 4 ? 0xbf000000ULL : 0xbfe0000000000000ULL : static_cast<std::uint64_t>(-std::int64_t(half));
        for (unsigned byte=0;byte<format.storageBytes;++byte) {
            const auto shift=(big?format.storageBytes-1-byte:byte)*8;
            assert(encoded[3+format.storageBytes+byte]==static_cast<unsigned char>(half>>shift));
            assert(encoded[3+2*format.storageBytes+byte]==static_cast<unsigned char>(minusHalf>>shift));
        }
        allocations.store(0); countAllocations=true;
        for (int pass=0;pass<10000;++pass) { converter.encode(encoded.data()+3,samples.data(),samples.size()); converter.decode(decoded.data(),encoded.data()+3,samples.size()); }
        countAllocations=false; assert(allocations.load()==0);
    }
    assert(!makeConverter({1,8,false,true}));
    assert(!makeConverter({4,12,false,false}));
    assert(!makeConverter({8,64,false,false}));
    // An IEEE infinity presented by hardware is sanitized before reaching DSP.
    std::array<unsigned char,8> infinity{0,0,0,0,0,0,0xf0,0x7f}; float finite=1;
    makeConverter({8,64,false,true}).decode(&finite,infinity.data(),1); assert(finite==0);
#if !defined(_WIN32) || !defined(CATLIVE_HAS_ASIO_SDK) || !CATLIVE_HAS_ASIO_SDK
    assert(!AsioDevice::available()); assert(AsioDevice::enumerate().empty());
    AsioDevice device; bool rejected=false;
    try { device.open({}); } catch (const AudioDeviceError&) { rejected=true; }
    assert(rejected && device.status().state==DeviceState::closed);
#endif
    std::cout << "ASIO PCM tests passed: 18 wire formats, known bytes, signed alignment, finite sanitization, bounds, allocation-free conversion, unavailable-SDK path.\n";
}
