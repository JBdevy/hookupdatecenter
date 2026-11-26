#include "../../Windows/Source/DesktopUpdatePolicy.h"
#include <cassert>
#include <iostream>
#include <vector>
using namespace catlive::desktopUpdate;

int main() {
    assert(completeJSONObject(" \r\n{\"enabled\":false,\"ignored\":[\"}\\\"\",{}]}\t"));
    for (const auto *invalid : {"", "[]", "{\"enabled\":false} trailing", "{\"enabled\":false}{}", "{\"enabled\":false}//comment", "{\"enabled\":false", "{\"x\":\"unterminated}"})
        assert(!completeJSONObject(invalid));
    assert(publicVersion("1.35.0") == "1.35");
    assert(publicVersion("12.05") == "12.05");
    assert(publicVersion("1.35.1").empty());
    assert(version("1.99") && version("2.00") && *version("1.99") < *version("2.00"));
    assert(*version("1.09") < *version("1.10"));
    for (const auto *invalid : {"", "1.3", "1.350", "1.35.0", "v1.35", "1.35 ", " 1.35", "-1.35", "1.3a", "1e2.35", "1..35", "١.٣٥", "9999999999.99"})
        assert(!version(invalid));
    for (const auto *url : {"https://catlive.app/download", "http://localhost:8080/releases/1.36", "HTTPS://example.com/installer.exe?key=a%2Bb#download", "https://example.com/CatLive%20Setup.exe", "https://[2001:db8::1]:443/update"})
        assert(browserURL(url));
    for (const auto *url : {"", "/update", "file:///app.exe", "javascript:run()", "https:///no-host", "https://", "https://user:pass@example.com/update", "https://user%40example.com/update", "https:\\example.com", "https://example.com/a\nb", "https://example.com/a b", "https://example.com/a%0db", "https://example.com/%7F", "https://example.com/%5c", "https://example.com/%", "https://example.com/%GG", "https://example.com:bad/update", "https://example.com:65536/update", "https://example.com:/update", "https://[oops]/update", "https://.example.com"})
        assert(!browserURL(url));
    assert(!browserURL("https://example.com/" + std::string(2048, 'a')));

    std::optional<Notice> current;
    const auto newer = evaluate("1.35.0", 200, true, "1.36", "https://example.com/update");
    assert(newer.valid && newer.notice && catlive::desktopUpdate::apply(current, newer));
    assert(current->version == "1.36");
    assert(!catlive::desktopUpdate::apply(current, newer));
    for (const auto status : {0, 204, 301, 401, 404, 500}) {
        const auto response = evaluate("1.35.0", status, false, {}, {});
        assert(!response.valid && !catlive::desktopUpdate::apply(current, response) && current == newer.notice);
    }
    for (const auto &response : {
             evaluate("1.35.0", 200, {}, "1.36", "https://example.com/update"),
             evaluate("1.35.0", 200, true, {}, "https://example.com/update"),
             evaluate("1.35.0", 200, true, "1.36.0", "https://example.com/update"),
             evaluate("1.35.0", 200, true, "1.36", {}),
             evaluate("1.35.0", 200, true, "1.36", "file:///update.exe")}) {
        assert(!response.valid && !catlive::desktopUpdate::apply(current, response) && current == newer.notice);
    }
    assert(catlive::desktopUpdate::apply(current, evaluate("1.35.0", 200, false, {}, {})) && !current);
    catlive::desktopUpdate::apply(current, newer);
    assert(catlive::desktopUpdate::apply(current, evaluate("1.35.0", 200, true, "1.35", "https://example.com/update")) && !current);
    catlive::desktopUpdate::apply(current, newer);
    assert(catlive::desktopUpdate::apply(current, evaluate("1.35.0", 200, true, "1.34", "https://example.com/update")) && !current);
    catlive::desktopUpdate::apply(current, newer);
    assert(catlive::desktopUpdate::apply(current, evaluate("1.35.0", 200, true, "1.36", "https://example.com/new-link")));
    assert(current->url == "https://example.com/new-link");
    // A subsequent check can restore an announcement that was explicitly disabled.
    catlive::desktopUpdate::apply(current, evaluate("1.35.0", 200, false, {}, {}));
    assert(catlive::desktopUpdate::apply(current, newer) && current == newer.notice);
    std::cout << "WINDOWS_DESKTOP_UPDATE_VERSION_URL_POLICY_AND_LAST_VALID_NOTICE_OK\n";
}
