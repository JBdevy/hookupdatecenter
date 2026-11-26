#pragma once
#include <shlobj.h>
#include "GridMediaClipboard.h"
#include <cstring>
#include <cwchar>

namespace catlive::gridMediaClipboardTests {
template <class Test> void registerTests(Test &test) {
    test("Cross-project paste copies media and FX samples without overwriting destination files", [] {
        const auto root = File::getSpecialLocation(File::tempDirectory).getChildFile("catlive-clipboard-" + text(uuid()));
        struct Cleanup { File folder; ~Cleanup() { folder.deleteRecursively(); } } cleanup{root};
        const auto source = root.getChildFile("source"), destination = root.getChildFile("destination");
        source.getChildFile("Stems").createDirectory(); destination.getChildFile("Stems").createDirectory();
        const auto audio = source.getChildFile("Stems/voice.wav"), sample = source.getChildFile("Stems/trigger.wav");
        if (!audio.replaceWithText("audio fixture") || !sample.replaceWithText("sample fixture") ||
            !destination.getChildFile("Stems/voice.wav").replaceWithText("existing file")) throw std::runtime_error("Cannot create media fixture");
        jaras::AudioClip clip; clip.id = uuid(); clip.audioFile = jaras::AudioFile{"Stems/voice.wav", {}};
        clip.fxJSON = R"({"trigger":{"samplePath":"Stems/trigger.wav"},"instances":[{"settings":{"trigger":{"samplePath":"Stems/trigger.wav"}}}]})";
        jaras::Track track; track.id = uuid(); track.clips = {clip, clip};
        const auto transfer = gridMediaClipboard::stage({track}, source, destination);
        const auto &copied = transfer.tracks[0].clips[0];
        const auto fx = JSON::parse(text(*copied.fxJSON));
        const auto path = fx["trigger"]["samplePath"].toString();
        if (copied.audioFile->path == clip.audioFile->path ||
            copied.audioFile->path != transfer.tracks[0].clips[1].audioFile->path ||
            fx["instances"][0]["settings"]["trigger"]["samplePath"].toString() != path ||
            destination.getChildFile("Stems/voice.wav").loadFileAsString() != "existing file")
            throw std::runtime_error("Cross-project transfer corrupted or duplicated media references");
        source.deleteRecursively();
        if (ProjectCodec::resolveMedia(destination, copied.audioFile->path).loadFileAsString() != "audio fixture" ||
            destination.getChildFile(path).loadFileAsString() != "sample fixture")
            throw std::runtime_error("Pasted media still depends on the source project");
        const auto count = destination.getChildFile("Stems").getNumberOfChildFiles(File::findDirectories);
        bool failed = false;
        try { gridMediaClipboard::stage({track}, source, destination); } catch (...) { failed = true; }
        if (!failed || destination.getChildFile("Stems").getNumberOfChildFiles(File::findDirectories) != count)
            throw std::runtime_error("Failed cross-project transfer left a partial media batch");
    });
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
