#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace catlive::desktopUpdate {
struct Version {
    std::uint32_t major = 0;
    unsigned minor = 0;
    bool operator<(const Version &other) const {
        return major < other.major || (major == other.major && minor < other.minor);
    }
};

// Public releases use X.XX; JUCE appends a zero patch to the installed version.
inline std::optional<Version> version(std::string_view text, bool installed = false) {
    if (installed && text.size() > 2 && text.substr(text.size() - 2) == ".0")
        text.remove_suffix(2);
    const auto dot = text.find('.');
    if (dot == std::string_view::npos || dot == 0 || dot > 9 || text.size() != dot + 3)
        return {};
    Version result;
    for (std::size_t index = 0; index < text.size(); ++index) {
        if (index == dot) continue;
        const char digit = text[index];
        if (digit < '0' || digit > '9') return {};
        if (index < dot) result.major = result.major * 10 + static_cast<unsigned>(digit - '0');
        else result.minor = result.minor * 10 + static_cast<unsigned>(digit - '0');
    }
    return result;
}

inline std::string publicVersion(std::string_view installed) {
    const auto parsed = version(installed, true);
    if (!parsed) return {};
    return std::to_string(parsed->major) + "." + (parsed->minor < 10 ? "0" : "") + std::to_string(parsed->minor);
}

inline int hex(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

inline bool browserURL(std::string_view text) {
    if (text.empty() || text.size() > 2048) return false;
    for (std::size_t index = 0; index < text.size(); ++index) {
        const auto character = static_cast<unsigned char>(text[index]);
        if (character <= 32 || character >= 127 || character == '\\') return false;
        if (character == '%') {
            if (index + 2 >= text.size() || hex(text[index + 1]) < 0 || hex(text[index + 2]) < 0) return false;
            const int decoded = hex(text[index + 1]) * 16 + hex(text[index + 2]);
            if (decoded < 32 || decoded == 127 || decoded == '\\') return false;
            index += 2;
        }
    }
    auto scheme = text.substr(0, text.find(':'));
    std::string lower(scheme);
    for (auto &character : lower) if (character >= 'A' && character <= 'Z') character += 'a' - 'A';
    if (lower != "http" && lower != "https") return false;
    if (text.substr(scheme.size(), 3) != "://") return false;
    auto authority = text.substr(scheme.size() + 3);
    authority = authority.substr(0, authority.find_first_of("/?#"));
    if (authority.empty() || authority.find_first_of("@%") != std::string_view::npos) return false;
    std::string_view host = authority, port;
    if (authority.front() == '[') {
        const auto close = authority.find(']');
        if (close == std::string_view::npos) return false;
        host = authority.substr(1, close - 1);
        if (host.empty() || host.find(':') == std::string_view::npos) return false;
        for (const char character : host) if (hex(character) < 0 && character != ':' && character != '.') return false;
        if (close + 1 < authority.size()) {
            if (authority[close + 1] != ':') return false;
            port = authority.substr(close + 2);
            if (port.empty()) return false;
        }
    } else {
        const auto colon = authority.find(':');
        if (colon != std::string_view::npos) {
            host = authority.substr(0, colon); port = authority.substr(colon + 1);
            if (port.empty()) return false;
        }
        if (host.empty() || host.front() == '.' || host.find("..") != std::string_view::npos) return false;
        for (const char character : host)
            if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
                  (character >= '0' && character <= '9') || character == '.' || character == '-')) return false;
    }
    if (!port.empty()) {
        if (port.size() > 5) return false;
        unsigned value = 0;
        for (const char character : port) {
            if (character < '0' || character > '9') return false;
            value = value * 10 + static_cast<unsigned>(character - '0');
        }
        if (value == 0 || value > 65535) return false;
    }
    return true;
}

struct Notice {
    std::string version, url;
    bool operator==(const Notice &other) const { return version == other.version && url == other.url; }
    bool operator!=(const Notice &other) const { return !(*this == other); }
};
struct Response {
    bool valid = false;
    std::optional<Notice> notice;
};
// JUCE's JSON parser accepts a complete value followed by unrelated text.
// Require exactly one object before handing syntax/type validation to JUCE.
inline bool completeJSONObject(std::string_view text) {
    const auto whitespace = [](char value) { return value == ' ' || value == '\t' || value == '\r' || value == '\n'; };
    std::size_t index = 0;
    while (index < text.size() && whitespace(text[index])) ++index;
    if (index == text.size() || text[index] != '{') return false;
    unsigned depth = 0;
    bool quoted = false, escaped = false;
    for (; index < text.size(); ++index) {
        const char value = text[index];
        if (quoted) {
            if (escaped) escaped = false;
            else if (value == '\\') escaped = true;
            else if (value == '"') quoted = false;
        } else if (value == '"') quoted = true;
        else if (value == '{' || value == '[') ++depth;
        else if (value == '}' || value == ']') {
            if (depth == 0) return false;
            if (--depth == 0) {
                for (++index; index < text.size(); ++index) if (!whitespace(text[index])) return false;
                return true;
            }
        }
    }
    return false;
}
inline Response evaluate(std::string_view installed, int httpStatus, std::optional<bool> enabled,
                         std::optional<std::string_view> published, std::optional<std::string_view> url) {
    if (httpStatus != 200 || !enabled) return {};
    if (!*enabled) return {true, {}};
    if (!published || !url || !browserURL(*url)) return {};
    const auto current = version(installed, true), candidate = version(*published);
    if (!current || !candidate) return {};
    if (!(*current < *candidate)) return {true, {}};
    return {true, Notice{std::string(*published), std::string(*url)}};
}
// An unavailable service cannot withdraw an earlier valid announcement.
inline bool apply(std::optional<Notice> &current, const Response &response) {
    if (!response.valid || current == response.notice) return false;
    current = response.notice;
    return true;
}
} // namespace catlive::desktopUpdate
