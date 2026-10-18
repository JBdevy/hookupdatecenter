#pragma once
#include "Common.h"
#include <shellapi.h>

namespace catlive::gridMediaClipboard {
// A fresh Explorer copy supersedes CatLive's internal item selection. Keeping
// the clipboard generation also lets a subsequent Ctrl+C inside the grid win.
inline bool ownsItems(bool hasItems, const std::optional<DWORD> &copiedAt, DWORD current) {
    return hasItems && copiedAt && *copiedAt == current;
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
