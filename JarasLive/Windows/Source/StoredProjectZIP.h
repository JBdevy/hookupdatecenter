#pragma once
#include "Common.h"
#include <bcrypt.h>

namespace catlive::packageZIP {
inline void require(bool ok,
                    const char *message = "Invalid, damaged or unsupported CatLive ZIP package.") {
    if (!ok)
        throw std::runtime_error(message);
}
inline void validatePath(const String &path) {
    require(path.isNotEmpty() && path.getNumBytesAsUTF8() <= 4096 && !path.containsAnyOf("\\:<>\"|?*"));
    for (auto c : path)
        require(c >= 32 && c != 127);
    for (const auto &part : StringArray::fromTokens(path, "/", "")) {
        require(part.isNotEmpty() && part != "." && part != ".." && !part.endsWithChar('.') &&
                !part.endsWithChar(' '));
        const auto base = part.upToFirstOccurrenceOf(".", false, false).toUpperCase();
        require(base != "CON" && base != "PRN" && base != "AUX" && base != "NUL" &&
                !(base.length() == 4 && (base.startsWith("COM") || base.startsWith("LPT")) &&
                  base[3] >= '1' && base[3] <= '9'));
    }
    require(!path.startsWithChar('/') && !path.endsWithChar('/') && !path.contains("//"));
}
struct Digest {
    BCRYPT_ALG_HANDLE algorithm{};
    BCRYPT_HASH_HANDLE hash{};
    uint32 crc = 0xffffffff;
    Digest() {
        require(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0);
        if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
            BCryptCloseAlgorithmProvider(algorithm, 0);
            algorithm = nullptr;
            require(false);
        }
    }
    ~Digest() {
        if (hash)
            BCryptDestroyHash(hash);
        if (algorithm)
            BCryptCloseAlgorithmProvider(algorithm, 0);
    }
    void update(const void *data, size_t count) {
        require(count <= ULONG_MAX && BCryptHashData(hash, (PUCHAR)data, (ULONG)count, 0) >= 0);
        static const auto table = [] {
            std::array<uint32, 256> t{};
            for (uint32 i = 0; i < 256; ++i) {
                auto v = i;
                for (int b = 0; b < 8; ++b)
                    v = (v & 1) ? 0xedb88320 ^ (v >> 1) : v >> 1;
                t[i] = v;
            }
            return t;
        }();
        auto *bytes = static_cast<const uint8 *>(data);
        for (size_t i = 0; i < count; ++i)
            crc = table[(crc ^ bytes[i]) & 255] ^ (crc >> 8);
    }
    String finish() {
        std::array<uint8, 32> result{};
        require(BCryptFinishHash(hash, result.data(), 32, 0) >= 0);
        return String::toHexString(result.data(), 32, 0);
    }
};
struct Record {
    String path, sha256;
    uint64 bytes{};
};
inline Record fingerprint(const String &path, const File &source) {
    FileInputStream input(source);
    require(!input.failedToOpen(), "A package source is missing.");
    Digest hash;
    std::array<char, 262144> buffer;
    uint64 count = 0;
    for (;;) {
        int n = input.read(buffer.data(), (int)buffer.size());
        require(n >= 0);
        if (n == 0)
            break;
        hash.update(buffer.data(), (size_t)n);
        count += (uint64)n;
    }
    require((int64)count == source.getSize());
    return {path, hash.finish(), count};
}
inline Record fingerprint(const String &path, const MemoryBlock &bytes) {
    return {path, SHA256(bytes).toHexString(), bytes.getSize()};
}
// Same UTF-8/Store/data-descriptor envelope as StoredProjectZIPWriter on Apple.
// ZIP64 covers large individual media, archives and file inventories.
class Writer {
    struct Entry {
        Record record;
        uint64 offset;
        uint32 crc;
        bool large;
    };
    FileOutputStream out;
    std::vector<Entry> entries;
    bool force64;
    void le(uint64 v, int bytes) {
        uint8 b[8];
        for (int i = 0; i < bytes; ++i)
            b[i] = (uint8)(v >> (i * 8));
        require(out.write(b, (size_t)bytes), "Cannot write package.");
    }
    void write(const void *p, size_t n) { require(out.write(p, n), "Cannot write package."); }

  public:
    explicit Writer(const File &file, bool forceZIP64 = false) : out(file), force64(forceZIP64) {
        require(!out.failedToOpen() && out.getPosition() == 0);
    }
    void add(const Record &record, InputStream &source,
             const std::function<void(uint64)> &progress = {}) {
        validatePath(record.path);
        const auto start = (uint64)out.getPosition();
        const bool large = force64 || record.bytes >= UINT32_MAX;
        const auto name = record.path.toUTF8();
        const auto length = record.path.getNumBytesAsUTF8();
        le(0x04034b50, 4);
        le(large ? 45 : 20, 2);
        le(0x0808, 2);
        le(0, 2);
        le(0, 2);
        le(0x21, 2);
        le(0, 4);
        le(large ? UINT32_MAX : 0, 4);
        le(large ? UINT32_MAX : 0, 4);
        le(length, 2);
        le(large ? 20 : 0, 2);
        write(name.getAddress(), length);
        if (large) {
            le(1, 2);
            le(16, 2);
            le(record.bytes, 8);
            le(record.bytes, 8);
        }
        Digest hash;
        uint64 copied = 0;
        std::array<char, 262144> buffer;
        for (;;) {
            const int n = source.read(buffer.data(), (int)buffer.size());
            require(n >= 0);
            if (!n)
                break;
            require((uint64)n <= record.bytes - copied, "A project source changed while exporting.");
            hash.update(buffer.data(), (size_t)n);
            write(buffer.data(), (size_t)n);
            copied += (uint64)n;
            if (progress)
                progress(copied);
        }
        require(copied == record.bytes && hash.finish() == record.sha256,
                "A project source changed while exporting.");
        const auto crc = hash.crc ^ 0xffffffff;
        le(0x08074b50, 4);
        le(crc, 4);
        le(copied, large ? 8 : 4);
        le(copied, large ? 8 : 4);
        entries.push_back({record, start, crc, large});
    }
    void add(const String &path, const MemoryBlock &data) {
        MemoryInputStream input(data, false);
        add(fingerprint(path, data), input);
    }
    void finish() {
        const auto start = (uint64)out.getPosition();
        for (const auto &e : entries) {
            const bool offset64 = force64 || e.offset >= UINT32_MAX;
            const auto name = e.record.path.toUTF8();
            const auto length = e.record.path.getNumBytesAsUTF8();
            int extra = (e.large ? 16 : 0) + (offset64 ? 8 : 0);
            le(0x02014b50, 4);
            le(0x032d, 2);
            le(45, 2);
            le(0x0808, 2);
            le(0, 2);
            le(0, 2);
            le(0x21, 2);
            le(e.crc, 4);
            le(e.large ? UINT32_MAX : e.record.bytes, 4);
            le(e.large ? UINT32_MAX : e.record.bytes, 4);
            le(length, 2);
            le(extra ? extra + 4 : 0, 2);
            le(0, 2);
            le(0, 2);
            le(0, 2);
            le((uint32)0100600 << 16, 4);
            le(offset64 ? UINT32_MAX : e.offset, 4);
            write(name.getAddress(), length);
            if (extra) {
                le(1, 2);
                le(extra, 2);
                if (e.large) {
                    le(e.record.bytes, 8);
                    le(e.record.bytes, 8);
                }
                if (offset64)
                    le(e.offset, 8);
            }
        }
        const auto size = (uint64)out.getPosition() - start;
        bool large =
            force64 || start >= UINT32_MAX || size >= UINT32_MAX || entries.size() >= UINT16_MAX;
        if (large) {
            auto offset = (uint64)out.getPosition();
            le(0x06064b50, 4);
            le(44, 8);
            le(45, 2);
            le(45, 2);
            le(0, 4);
            le(0, 4);
            le(entries.size(), 8);
            le(entries.size(), 8);
            le(size, 8);
            le(start, 8);
            le(0x07064b50, 4);
            le(0, 4);
            le(offset, 8);
            le(1, 4);
        }
        le(0x06054b50, 4);
        le(0, 2);
        le(0, 2);
        le(large ? UINT16_MAX : entries.size(), 2);
        le(large ? UINT16_MAX : entries.size(), 2);
        le(large ? UINT32_MAX : size, 4);
        le(large ? UINT32_MAX : start, 4);
        le(0, 2);
        out.flush();
        require(out.getStatus().wasOk(), "Cannot finish package.");
    }
};
class Reader {
  public:
    struct Entry {
        String path;
        uint64 size, offset, start, end;
        uint32 crc;
    };
    std::map<String, Entry> entries;
    uint64 totalBytes = 0;

  private:
    FileInputStream input;
    uint64 length, centralStart = 0;
    static uint64 le(const MemoryBlock &b, size_t offset, size_t n) {
        require(n <= 8 && offset <= b.getSize() && n <= b.getSize() - offset);
        auto *p = (const uint8 *)b.getData();
        uint64 v = 0;
        for (size_t i = 0; i < n; ++i)
            v |= (uint64)p[offset + i] << (8 * i);
        return v;
    }
    MemoryBlock read(uint64 offset, size_t n) {
        require(offset <= length && n <= length - offset && n <= INT_MAX &&
                input.setPosition((int64)offset));
        MemoryBlock b(n);
        require(input.read(b.getData(), (int)n) == (int)n);
        return b;
    }

  public:
    explicit Reader(const File &file) : input(file), length((uint64)std::max<int64>(0, file.getSize())) {
        require(!input.failedToOpen() && length >= 22);
        auto end = read(length - 22, 22);
        require(le(end, 0, 4) == 0x06054b50 && le(end, 4, 2) == 0 && le(end, 6, 2) == 0 &&
                le(end, 20, 2) == 0 && le(end, 8, 2) == le(end, 10, 2));
        uint64 count = le(end, 10, 2), size = le(end, 12, 4), start = le(end, 16, 4),
               boundary = length - 22;
        if (count == UINT16_MAX || size == UINT32_MAX || start == UINT32_MAX) {
            require(length >= 98);
            auto loc = read(length - 42, 20);
            require(le(loc, 0, 4) == 0x07064b50 && le(loc, 4, 4) == 0 && le(loc, 16, 4) == 1 &&
                    le(loc, 8, 8) == length - 98);
            auto z = read(length - 98, 56);
            require(le(z, 0, 4) == 0x06064b50 && le(z, 4, 8) == 44 && le(z, 16, 4) == 0 &&
                    le(z, 20, 4) == 0 && le(z, 24, 8) == le(z, 32, 8));
            count = le(z, 32, 8);
            size = le(z, 40, 8);
            start = le(z, 48, 8);
            boundary = length - 98;
        }
        require(count >= 2 && count <= 100000 && size <= 64 * 1024 * 1024 && start <= boundary &&
                size == boundary - start);
        centralStart = start;
        auto central = read(start, (size_t)size);
        size_t pos = 0;
        std::set<String> names;
        for (uint64 i = 0; i < count; ++i) {
            require(le(central, pos, 4) == 0x02014b50 && le(central, pos + 8, 2) == 0x0808 &&
                    le(central, pos + 10, 2) == 0 && le(central, pos + 34, 2) == 0);
            size_t n = (size_t)le(central, pos + 28, 2), extra = (size_t)le(central, pos + 30, 2),
                   comment = (size_t)le(central, pos + 32, 2), next = pos + 46 + n + extra + comment;
            require(next <= central.getSize() && n > 0);
            auto *bytes = (const char *)central.getData();
            require(CharPointer_UTF8::isValidString(bytes + pos + 46, (int)n));
            String path = String::fromUTF8(bytes + pos + 46, (int)n);
            validatePath(path);
            require(names.insert(unicodeCase(path, false)).second &&
                    ((le(central, pos + 38, 4) >> 16) & 0170000) == 0100000);
            uint64 compressed = le(central, pos + 20, 4), uncompressed = le(central, pos + 24, 4),
                   offset = le(central, pos + 42, 4);
            if (compressed == UINT32_MAX || uncompressed == UINT32_MAX || offset == UINT32_MAX) {
                size_t cursor = pos + 46 + n;
                bool found = false;
                while (cursor < pos + 46 + n + extra) {
                    auto kind = le(central, cursor, 2), lengthExtra = le(central, cursor + 2, 2);
                    cursor += 4;
                    require(lengthExtra <= pos + 46 + n + extra - cursor);
                    if (kind == 1) {
                        require(!found);
                        found = true;
                        size_t p = cursor;
                        auto take = [&] {
                            require(p + 8 <= cursor + lengthExtra);
                            auto v = le(central, p, 8);
                            p += 8;
                            return v;
                        };
                        if (uncompressed == UINT32_MAX)
                            uncompressed = take();
                        if (compressed == UINT32_MAX)
                            compressed = take();
                        if (offset == UINT32_MAX)
                            offset = take();
                    }
                    cursor += (size_t)lengthExtra;
                }
                require(found);
            }
            require(compressed == uncompressed && offset < start &&
                    uncompressed <= 1099511627776ULL - totalBytes);
            totalBytes += uncompressed;
            entries.emplace(path,
                            Entry{path, uncompressed, offset, 0, 0, (uint32)le(central, pos + 16, 4)});
            pos = next;
        }
        require(pos == central.getSize());
        std::vector<Entry *> ordered;
        for (auto &[path, e] : entries)
            ordered.push_back(&e);
        std::sort(ordered.begin(), ordered.end(),
                  [](auto *a, auto *b) { return a->offset < b->offset; });
        uint64 previous = 0;
        for (auto *e : ordered) {
            require(e->offset == previous);
            auto h = read(e->offset, 30);
            require(le(h, 0, 4) == 0x04034b50 && le(h, 6, 2) == 0x0808 && le(h, 8, 2) == 0);
            auto n = le(h, 26, 2), extra = le(h, 28, 2);
            auto name = read(e->offset + 30, (size_t)n);
            require(String::fromUTF8((const char *)name.getData(), (int)n) == e->path);
            e->start = e->offset + 30 + n + extra;
            require(e->start <= centralStart && e->size <= centralStart - e->start);
            bool large = le(h, 18, 4) == UINT32_MAX || le(h, 22, 4) == UINT32_MAX;
            auto d = read(e->start + e->size, large ? 24 : 16);
            require(le(d, 0, 4) == 0x08074b50 && le(d, 4, 4) == e->crc &&
                    le(d, 8, large ? 8 : 4) == e->size &&
                    le(d, large ? 16 : 12, large ? 8 : 4) == e->size);
            e->end = e->start + e->size + (large ? 24 : 16);
            require(e->end <= centralStart);
            previous = e->end;
        }
        require(previous == centralStart);
    }
    MemoryBlock data(const String &path, uint64 maximum) {
        auto it = entries.find(path);
        require(it != entries.end() && it->second.size <= maximum);
        auto b = read(it->second.start, (size_t)it->second.size);
        Digest d;
        d.update(b.getData(), b.getSize());
        require((d.crc ^ 0xffffffff) == it->second.crc);
        return b;
    }
    void extract(const Record &record, const File &target,
                 const std::function<void(uint64)> &progress = {}) {
        auto it = entries.find(record.path);
        require(it != entries.end() && it->second.size == record.bytes);
        const auto &e = it->second;
        FileOutputStream out(target);
        require(!out.failedToOpen() && out.getPosition() == 0 && input.setPosition((int64)e.start));
        Digest hash;
        std::array<char, 262144> buffer;
        uint64 copied = 0;
        while (copied < e.size) {
            int count = (int)std::min<uint64>(buffer.size(), e.size - copied);
            require(input.read(buffer.data(), count) == count &&
                    out.write(buffer.data(), (size_t)count));
            hash.update(buffer.data(), (size_t)count);
            copied += (uint64)count;
            if (progress)
                progress(copied);
        }
        out.flush();
        require(out.getStatus().wasOk() && hash.finish() == record.sha256 &&
                    (hash.crc ^ 0xffffffff) == e.crc,
                "A package file failed its integrity check.");
    }
};
} // namespace catlive::packageZIP
