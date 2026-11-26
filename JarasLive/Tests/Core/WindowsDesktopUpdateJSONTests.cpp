#include "../../Windows/Source/DesktopUpdateService.h"
#include <cassert>
#include <iostream>
using catlive::DesktopUpdateService;

int main() {
    const auto parse = [](const char *body, int status = 200) {
        return DesktopUpdateService::parse("1.35.0", status, juce::String::fromUTF8(body));
    };
    const auto available = parse(R"({"enabled":true,"version":"1.36","url":"https://example.com/CatLive%20Setup.exe"})");
    assert(available.valid && available.notice && available.notice->version == "1.36");
    for (const char *body : {R"({"enabled":false})", R"({"enabled":false,"version":4,"url":null})"}) {
        const auto disabled = parse(body);
        assert(disabled.valid && !disabled.notice);
    }
    for (const char *body : {"", "[]", "null", "{}", "{broken}", "{\"enabled\":false} trailing",
             R"({"enabled":1,"version":"1.36","url":"https://example.com"})",
             R"({"enabled":"true","version":"1.36","url":"https://example.com"})",
             R"({"enabled":true,"version":1.36,"url":"https://example.com"})",
             R"({"enabled":true,"version":"1.36","url":7})",
             R"({"enabled":true,"version":"1.36","url":"https://example.com/\nupdate"})",
             R"({"enabled":true,"version":"1.36","url":"https://user:pass@example.com"})"}) {
        const auto response = parse(body);
        assert(!response.valid);
        auto previous = available.notice;
        assert(!catlive::desktopUpdate::apply(previous, response) && previous == available.notice);
    }
    assert(!parse(R"({"enabled":false})", 500).valid);
    assert(!parse(R"({"enabled":false})", 204).valid);
    const auto oversized = juce::String("{\"enabled\":false,\"ignored\":\"") + juce::String::repeatedString("x", 17000) + "\"}";
    assert(!DesktopUpdateService::parse("1.35.0", 200, oversized).valid);
    const std::string validBody = R"({"enabled":false})";
    assert(DesktopUpdateService::parseBytes("1.35.0", 200, juce::MemoryBlock(validBody.data(), validBody.size())).valid);
    for (const auto &invalidBody : {validBody + std::string(1, '\0') + "trailing", validBody + std::string(1, '\xff')})
        assert(!DesktopUpdateService::parseBytes("1.35.0", 200, juce::MemoryBlock(invalidBody.data(), invalidBody.size())).valid);
    std::cout << "WINDOWS_DESKTOP_UPDATE_REAL_JUCE_JSON_TYPES_PAYLOAD_LIMIT_AND_LAST_VALID_STATE_OK\n";
}
