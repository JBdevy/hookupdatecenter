#include "pluginterfaces/base/funknown.h"
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>

int main() {
    // A TUID has byte alignment, including pointers into packed plugin state.
    // Exercise every possible alignment and every differing byte, not only
    // the naturally aligned globals produced by an ASan-instrumented plugin.
    for (unsigned leftOffset = 0; leftOffset < 8; ++leftOffset) {
        for (unsigned rightOffset = 0; rightOffset < 8; ++rightOffset) {
            alignas(std::uint64_t) std::array<unsigned char, 24> left{};
            alignas(std::uint64_t) std::array<unsigned char, 24> right{};
            left.fill(0xA5); right.fill(0x5A);
            auto a = left.data() + leftOffset, b = right.data() + rightOffset;
            for (unsigned index = 0; index < sizeof(Steinberg::TUID); ++index)
                a[index] = b[index] = static_cast<unsigned char>(index * 17);
            assert(Steinberg::FUnknownPrivate::iidEqual(a, b));
            assert(Steinberg::FUnknownPrivate::iidEqual(b, a));
            for (unsigned index = 0; index < sizeof(Steinberg::TUID); ++index) {
                b[index] ^= 0x80;
                assert(!Steinberg::FUnknownPrivate::iidEqual(a, b));
                assert(!Steinberg::FUnknownPrivate::iidEqual(b, a));
                b[index] ^= 0x80;
                assert(Steinberg::FUnknownPrivate::iidEqual(a, b));
            }
        }
    }
    std::puts("VST3_UID_ALL_BYTE_ALIGNMENTS_EQUALITY_DIFFERING_BYTES_AND_EXACT_RANGE_OK");
}
