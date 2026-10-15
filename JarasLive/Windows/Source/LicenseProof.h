#pragma once
#include "Common.h"
#include "monocypher-ed25519.h"

namespace catlive::license {
// The service and CryptoKit use RFC 4648 Base64. MemoryBlock's similarly named
// encoding has a JUCE-specific length prefix and cannot decode license proofs.
inline bool decodeBase64(const String &encoded, MemoryBlock &bytes, size_t limit) {
    if (encoded.isEmpty() || (size_t)encoded.length() > ((limit + 2) / 3) * 4 ||
        encoded.length() % 4 != 0)
        return false;
    MemoryOutputStream output;
    if (!Base64::convertFromBase64(output, encoded) || output.getDataSize() > limit)
        return false;
    bytes = output.getMemoryBlock();
    return Base64::toBase64(bytes.getData(), bytes.getSize()) == encoded;
}

inline bool verify(const var &entitlement, const String &account, const String &installation,
                   const String &pinnedKey) {
    const auto proof = get(entitlement, "proof");
    MemoryBlock payload, signature, key;
    if (!decodeBase64(str(proof, "payload"), payload, 16384) || payload.getSize() >= 16384 ||
        !decodeBase64(str(proof, "signature"), signature, 64) || signature.getSize() != 64 ||
        !decodeBase64(pinnedKey, key, 32) || key.getSize() != 32)
        return false;
    if (crypto_ed25519_check((const uint8_t *)signature.getData(), (const uint8_t *)key.getData(),
                             (const uint8_t *)payload.getData(), payload.getSize()) != 0)
        return false;
    const auto signedValue = JSON::parse(payload.toString());
    if ((int)num(signedValue, "version") != 1 ||
        !str(signedValue, "accountId").equalsIgnoreCase(account) ||
        !str(signedValue, "installationId").equalsIgnoreCase(installation))
        return false;
    for (auto keyName : {"status", "planId", "expiresAt", "offlineValidUntil", "serverTime",
                         "maxDevices", "graceStartsAt", "graceUntil", "graceReason"})
        if (get(signedValue, keyName) != get(entitlement, keyName))
            return false;
    const auto a = list(get(signedValue, "features")), b = list(get(entitlement, "features"));
    if (a.size() != b.size()) return false;
    for (int i = 0; i < a.size(); ++i)
        if (a[i] != b[i]) return false;
    return str(signedValue, "serverTime").isNotEmpty();
}
} // namespace catlive::license
