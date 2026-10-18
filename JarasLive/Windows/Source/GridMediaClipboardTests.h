#pragma once
#include <shlobj.h>
#include "GridMediaClipboard.h"
#include <cstring>
#include <cwchar>

namespace catlive::gridMediaClipboardTests {
template <class Test> void registerTests(Test &test) {
    test("Explorer Unicode and long file paths are read without changing the clipboard", [] {
        const StringArray expected{String::fromUTF8("C:\\Shows\\São João 🎹\\Voz.wav"),
                                   String::fromUTF8("\\\\palco\\mídia\\Vídeo.mov"),
                                   String("C:\\Shows\\") + String::repeatedString("Folder\\", 50) + "Guitarra.wav"};
        std::vector<wchar_t> names;
        for (const auto &path : expected) {
            const wchar_t *wide = path.toWideCharPointer();
            names.insert(names.end(), wide, wide + std::wcslen(wide) + 1);
        }
        names.push_back(0);
        const auto bytes = sizeof(DROPFILES) + names.size() * sizeof(wchar_t);
        const auto memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
        if (!memory) throw std::runtime_error("Could not allocate isolated DROPFILES fixture.");
        struct Release { HGLOBAL memory; ~Release() { GlobalFree(memory); } } release{memory};
        auto *data = static_cast<DROPFILES *>(GlobalLock(memory));
        if (!data) throw std::runtime_error("Could not access DROPFILES fixture.");
        data->pFiles = sizeof(DROPFILES); data->fWide = TRUE;
        std::memcpy(reinterpret_cast<char *>(data) + sizeof(DROPFILES), names.data(), names.size() * sizeof(wchar_t));
        GlobalUnlock(memory);
        const auto drop = static_cast<HDROP>(memory);
        if (gridMediaClipboard::filesFromDrop(drop) != expected || gridMediaClipboard::filesFromDrop(drop) != expected)
            throw std::runtime_error("Clipboard paths were reordered, truncated, corrupted, or their handle was released.");
    });
    test("A newer Explorer copy supersedes grid items; a new grid copy takes precedence again", [] {
        using gridMediaClipboard::ownsItems;
        if (!ownsItems(true, DWORD{20}, 20) || ownsItems(true, DWORD{20}, 21) ||
            ownsItems(false, DWORD{20}, 20) || ownsItems(true, {}, 20) ||
            !ownsItems(true, DWORD{22}, 22))
            throw std::runtime_error("The grid retained a stale clipboard selection.");
    });
    test("An empty file-drop clipboard is harmless", [] {
        if (!gridMediaClipboard::filesFromDrop(nullptr).isEmpty())
            throw std::runtime_error("Empty clipboard produced a file import.");
    });
}
} // namespace catlive::gridMediaClipboardTests
