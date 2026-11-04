#pragma once
#include "Common.h"
#include "GridItemClipboard.h"
#include "ProjectCodec.h"
#include <shellapi.h>

namespace catlive::gridMediaClipboard {
// A fresh Explorer copy supersedes CatLive's internal item selection. Keeping
// the clipboard generation also lets a subsequent Ctrl+C inside the grid win.
inline bool ownsItems(bool hasItems, const std::optional<DWORD> &copiedAt, DWORD current) {
    return hasItems && copiedAt && *copiedAt == current;
}

// Copy belongs to the application, not to a particular tab. Cut remains local.
inline std::optional<GridItemClipboard> sharedItems;
inline File sharedDirectory;
inline std::optional<DWORD> sharedSequence;
inline bool claimItems(HWND owner) {
    const auto format = RegisterClipboardFormatW(L"CatLive.GridItems");
    if (!format || !OpenClipboard(owner)) return false;
    struct Close { ~Close() { CloseClipboard(); } } close;
    auto memory = GlobalAlloc(GMEM_MOVEABLE, 1);
    if (!memory) return false;
    if (auto *data = GlobalLock(memory)) { *static_cast<char *>(data) = 1; GlobalUnlock(memory); }
    else { GlobalFree(memory); return false; }
    if (!EmptyClipboard() || !SetClipboardData(format, memory)) { GlobalFree(memory); return false; }
    return true;
}

struct Transfer {
    std::vector<jaras::Track> tracks;
    Array<File> directories;
    void discard() const { for (const auto &directory : directories) directory.deleteRecursively(); }
};
inline Transfer stage(std::vector<jaras::Track> tracks, const File &source, const File &destination) {
    Transfer transfer{std::move(tracks), {}};
    const auto batch = "Clipboard-" + text(uuid());
    std::map<std::string, std::string> mapping;
    const auto copy = [&](const std::string &path) -> std::string {
        if (auto found = mapping.find(path); found != mapping.end()) return found->second;
        auto input = ProjectCodec::resolveMedia(source, path);
        const auto folder = String(path.rfind("Videos/", 0) == 0 ? "Videos/" : "Stems/") + batch;
        const auto relative = folder + "/" + String(int(mapping.size())) + "-" + input.getFileName();
        const auto directory = destination.getChildFile(folder);
        if (!transfer.directories.contains(directory)) {
            if (directory.createDirectory().failed()) throw std::runtime_error("Could not copy media for the pasted items.");
            transfer.directories.add(directory);
        }
        if (!input.existsAsFile() || !input.copyFileTo(destination.getChildFile(relative)))
            throw std::runtime_error("Could not copy media for the pasted items.");
        return mapping[path] = utf8(relative);
    };
    std::function<void(var &)> remap = [&](var &value) {
        if (auto *object = value.getDynamicObject()) {
            if (object->hasProperty("samplePath") && object->getProperty("samplePath").isString()) {
                const auto path = object->getProperty("samplePath").toString();
                if (path.isNotEmpty()) object->setProperty("samplePath", text(copy(utf8(path))));
            }
            for (const auto &property : object->getProperties()) {
                auto child = property.value; remap(child); object->setProperty(property.name, child);
            }
        } else if (auto *array = value.getArray()) for (auto &child : *array) remap(child);
    };
    try {
        for (auto &track : transfer.tracks) for (auto &clip : track.clips) {
            if (clip.audioFile) clip.audioFile->path = copy(clip.audioFile->path);
            if (clip.fxJSON) {
                auto fx = JSON::parse(text(*clip.fxJSON)); remap(fx);
                clip.fxJSON = utf8(JSON::toString(fx, true, 17));
            }
        }
        return transfer;
    } catch (...) { transfer.discard(); throw; }
}

inline StringArray filesFromDrop(HDROP drop) {
    StringArray paths;
    if (!drop) return paths;
    const auto count = DragQueryFileW(drop, 0xffffffffu, nullptr, 0);
    for (UINT index = 0; index < count; ++index) {
        const auto length = DragQueryFileW(drop, index, nullptr, 0);
        // Win32 file names (including extended/UNC paths) fit in 32K UTF-16
        // code units. Avoid truncating a name into a different valid path.
        if (length == 0 || length >= 32768)
            throw std::runtime_error("A lista de arquivos copiados é inválida. Copie os arquivos novamente.");
        std::vector<wchar_t> path(static_cast<size_t>(length) + 1);
        if (DragQueryFileW(drop, index, path.data(), length + 1) != length)
            throw std::runtime_error("Não foi possível ler um dos arquivos copiados.");
        const String name(path.data());
        if (!File::isAbsolutePath(name))
            throw std::runtime_error("O arquivo copiado não possui um caminho completo.");
        paths.add(name);
    }
    return paths;
}

inline StringArray files() {
    if (!IsClipboardFormatAvailable(CF_HDROP)) return {};
    if (!OpenClipboard(nullptr))
        throw std::runtime_error("Não foi possível acessar os arquivos copiados. Tente colar novamente.");
    struct Close { ~Close() { CloseClipboard(); } } close;
    // The clipboard owns this handle. Never DragFinish/GlobalFree it.
    return filesFromDrop(static_cast<HDROP>(GetClipboardData(CF_HDROP)));
}
} // namespace catlive::gridMediaClipboard
