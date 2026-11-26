#pragma once
#include "Common.h"
#include "monocypher.h"
#include <bcrypt.h>
#include <limits>
namespace catlive::remote {
constexpr size_t maximumPacket = 2 * 1024 * 1024, maximumFrame = maximumPacket + 64;
using Bytes = std::vector<uint8_t>;
using Key = std::array<uint8_t, 32>;
inline void require(bool valid) {
    if (!valid)
        throw std::runtime_error("Pacote Remote inválido.");
}
inline void cryptoCheck(NTSTATUS status) { require(status >= 0); }
inline void append(Bytes &bytes, const void *data, size_t size) {
    if (size) {
        const auto *first = static_cast<const uint8_t *>(data);
        bytes.insert(bytes.end(), first, first + size);
    }
}
inline void append(Bytes &bytes, const Bytes &next) { append(bytes, next.data(), next.size()); }
inline uint64 readCounter(const uint8_t *bytes) {
    uint64 result = 0;
    for (int i = 0; i < 8; ++i)
        result = (result << 8) | bytes[i];
    return result;
}
inline void writeCounter(uint8_t *bytes, uint64 value) {
    for (int i = 7; i >= 0; --i) {
        bytes[i] = (uint8_t)value;
        value >>= 8;
    }
}
inline Key hmac(const uint8_t *key, size_t keySize, const uint8_t *data, size_t size) {
    struct Hash {
        BCRYPT_ALG_HANDLE algorithm{};
        BCRYPT_HASH_HANDLE hash{};
        ~Hash() {
            if (hash)
                BCryptDestroyHash(hash);
            if (algorithm)
                BCryptCloseAlgorithmProvider(algorithm, 0);
        }
    } context;
    require(keySize <= ULONG_MAX && size <= ULONG_MAX);
    cryptoCheck(BCryptOpenAlgorithmProvider(&context.algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                            BCRYPT_ALG_HANDLE_HMAC_FLAG));
    cryptoCheck(BCryptCreateHash(context.algorithm, &context.hash, nullptr, 0,
                                 const_cast<PUCHAR>(key), (ULONG)keySize, 0));
    cryptoCheck(BCryptHashData(context.hash, const_cast<PUCHAR>(data), (ULONG)size, 0));
    Key result{};
    cryptoCheck(BCryptFinishHash(context.hash, result.data(), (ULONG)result.size(), 0));
    return result;
}
inline Key derive(const Key &shared, const MemoryBlock &salt, const char *direction) {
    auto extracted = hmac(static_cast<const uint8_t *>(salt.getData()), salt.getSize(),
                          shared.data(), shared.size());
    Bytes info;
    append(info, direction, std::strlen(direction));
    info.push_back(1);
    const auto result = hmac(extracted.data(), extracted.size(), info.data(), info.size());
    crypto_wipe(extracted.data(), extracted.size());
    return result;
}
// Mirrors DAWRemoteCipher in DAWRemoteSession.swift: X25519, HKDF-SHA256 and
// IETF ChaCha20-Poly1305, with independent directional keys and strict counters.
class Cipher final {
  public:
    enum Role : uint8_t { host = 1, client = 2 };
    Cipher(Role value, String displayName, std::optional<Key> fixtureKey = {}) : role(value) {
        require(value == host || value == client);
        name = displayName;
        while (name.getNumBytesAsUTF8() > 63)
            name = name.dropLastCharacters(1);
        if (name.isEmpty())
            name = "CatLive";
        if (fixtureKey)
            secret = *fixtureKey;
        else
            cryptoCheck(BCryptGenRandom(nullptr, secret.data(), (ULONG)secret.size(),
                                        BCRYPT_USE_SYSTEM_PREFERRED_RNG));
        crypto_x25519_public_key(publicKey.data(), secret.data());
    }
    ~Cipher() {
        crypto_wipe(secret.data(), secret.size());
        crypto_wipe(outgoing.data(), outgoing.size());
        crypto_wipe(incoming.data(), incoming.size());
    }
    Cipher(const Cipher &) = delete;
    Cipher &operator=(const Cipher &) = delete;
    MemoryBlock sessionBinding;
    Bytes hello() const {
        Bytes value{0x4a, 0x44, 1, 2, role};
        append(value, publicKey.data(), publicKey.size());
        append(value, name.toRawUTF8(), name.getNumBytesAsUTF8());
        return value;
    }
    String accept(const Bytes &peer) {
        require(!ready && peer.size() >= 38 && peer.size() <= 197 && peer[0] == 0x4a &&
                peer[1] == 0x44 && peer[2] == 1 && peer[3] == 2 &&
                (peer[4] == host || peer[4] == client) && peer[4] != role);
        const auto *label = reinterpret_cast<const char *>(peer.data() + 37);
        require(CharPointer_UTF8::isValidString(label, (int)peer.size() - 37));
        const auto peerName = String::fromUTF8(label, (int)peer.size() - 37);
        require(peerName.isNotEmpty() &&
                std::find(peer.begin() + 37, peer.end(), uint8_t(0)) == peer.end());
        Key shared{}, zero{};
        crypto_x25519(shared.data(), secret.data(), peer.data() + 5);
        require(crypto_verify32(shared.data(), zero.data()) != 0);
        Bytes transcript;
        const char context[] = "Jaras Live Direct 1";
        append(transcript, context, sizeof(context) - 1);
        const auto mine = hello();
        append(transcript, role == host ? mine : peer);
        append(transcript, role == host ? peer : mine);
        const auto salt = SHA256(transcript.data(), transcript.size()).getRawData();
        sessionBinding = salt;
        try {
            outgoing = derive(shared, salt, role == host ? "host-to-client" : "client-to-host");
            incoming = derive(shared, salt, role == host ? "client-to-host" : "host-to-client");
        } catch (...) {
            crypto_wipe(shared.data(), shared.size());
            throw;
        }
        crypto_wipe(shared.data(), shared.size());
        ready = true;
        return peerName;
    }
    Bytes seal(const Bytes &plain) {
        require(ready && sent < std::numeric_limits<uint64>::max() && !plain.empty() &&
                plain.size() <= maximumPacket + 1);
        Bytes result(9 + plain.size() + 16);
        result[0] = 2;
        writeCounter(result.data() + 1, ++sent);
        std::array<uint8_t, 12> nonce{};
        writeCounter(nonce.data() + 4, sent);
        crypto_aead_ctx context;
        crypto_aead_init_ietf(&context, outgoing.data(), nonce.data());
        crypto_aead_write(&context, result.data() + 9, result.data() + 9 + plain.size(),
                          result.data(), 9, plain.data(), plain.size());
        crypto_wipe(&context, sizeof(context));
        return result;
    }
    Bytes open(const Bytes &sealed) {
        require(ready && sealed.size() >= 26 && sealed.size() <= maximumFrame && sealed[0] == 2 &&
                received < std::numeric_limits<uint64>::max());
        const auto counter = readCounter(sealed.data() + 1);
        require(counter == received + 1);
        std::array<uint8_t, 12> nonce{};
        writeCounter(nonce.data() + 4, counter);
        Bytes plain(sealed.size() - 25);
        crypto_aead_ctx context;
        crypto_aead_init_ietf(&context, incoming.data(), nonce.data());
        const auto result =
            crypto_aead_read(&context, plain.data(), sealed.data() + sealed.size() - 16,
                             sealed.data(), 9, sealed.data() + 9, plain.size());
        crypto_wipe(&context, sizeof(context));
        if (result != 0) {
            crypto_wipe(plain.data(), plain.size());
            require(false);
        }
        received = counter;
        return plain;
    }

  private:
    Role role;
    String name;
    Key secret{}, publicKey{}, outgoing{}, incoming{};
    uint64 sent = 0, received = 0;
    bool ready = false;
};
class Frames final {
  public:
    std::vector<Bytes> receive(const uint8_t *bytes, size_t size) {
        require(size <= maximumFrame + 4 && buffer.size() <= maximumFrame + 4);
        append(buffer, bytes, size);
        size_t offset = 0;
        std::vector<Bytes> result;
        while (buffer.size() - offset >= 4) {
            const auto *header = buffer.data() + offset;
            const auto length = (uint32(header[0]) << 24) | (uint32(header[1]) << 16) |
                                (uint32(header[2]) << 8) | header[3];
            require(length > 0 && length <= maximumFrame);
            if (buffer.size() - offset - 4 < length)
                break;
            result.emplace_back(header + 4, header + 4 + length);
            offset += 4 + length;
        }
        if (offset)
            buffer.erase(buffer.begin(), buffer.begin() + offset);
        require(buffer.size() <= maximumFrame + 4);
        return result;
    }
    static Bytes encode(const Bytes &payload) {
        require(!payload.empty() && payload.size() <= maximumFrame);
        const auto size = (uint32)payload.size();
        Bytes value{uint8_t(size >> 24), uint8_t(size >> 16), uint8_t(size >> 8), uint8_t(size)};
        append(value, payload);
        return value;
    }

  private:
    Bytes buffer;
};
inline Bytes packet(uint8_t kind, const var &value) {
    const auto json = JSON::toString(value, true);
    Bytes data{0x4a, 0x4c, 2, kind};
    append(data, json.toRawUTF8(), json.getNumBytesAsUTF8());
    require(data.size() <= maximumPacket);
    return data;
}
} // namespace catlive::remote
