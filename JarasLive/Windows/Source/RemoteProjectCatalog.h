#pragma once
#include "RemoteProtocol.h"
namespace catlive::remote {
// Only names and opaque IDs travel over Remote; paths stay on the host.
class ProjectCatalog {
    std::map<String, String> identifiers;
public:
    var update(const StringArray &paths, const File &current) {
        std::map<String, String> next;
        Array<var> rows;
        for (const auto &path : paths) {
            if (!File::isAbsolutePath(path)) continue;
            const File file(path);
            const auto key = file.getFullPathName();
            if (next.count(key)) continue;
            const auto found = identifiers.find(key);
            const auto id = found == identifiers.end() ? Uuid().toDashedString().toUpperCase() : found->second;
            next.emplace(key, id);
            auto row = object();
            put(row, "id", id); put(row, "name", file.getFileNameWithoutExtension());
            put(row, "current", file == current); rows.add(row);
            if (rows.size() == 20) break;
        }
        identifiers = std::move(next);
        return var(rows);
    }
    std::optional<File> file(const ID &id) const {
        const auto wire = wireID(id);
        for (const auto &entry : identifiers)
            if (entry.second == wire) return File(entry.first);
        return {};
    }
};
}
