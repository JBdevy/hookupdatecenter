#pragma once
#include <array>
#include <random>
#include <string>

namespace catlive::native {
// Control-thread identities. No engine callback may create document objects.
inline std::string freshIdentifier() {
    std::random_device source;
    std::array<unsigned char, 16> bytes{};
    for (auto& byte : bytes) byte = static_cast<unsigned char>(source());
    bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0f) | 0x40);
    bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3f) | 0x80);
    constexpr char hex[] = "0123456789abcdef";
    std::string result; result.reserve(36);
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        if (index == 4 || index == 6 || index == 8 || index == 10) result += '-';
        result += hex[bytes[index] >> 4]; result += hex[bytes[index] & 15];
    }
    return result;
}
}
