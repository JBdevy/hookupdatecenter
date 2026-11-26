#pragma once
#include "ProjectMigration.h"

namespace catlive {
// Owned by one import worker. Catalog entries and scan results never reference
// the UI-owned VST3 catalog, and each installed module is scanned at most once.
class ReaperVST3ImportSession {
  public:
    ReaperVST3ImportSession(Array<var> catalog, StringArray roots, File helper,
                           std::function<bool()> cancelled = {})
        : catalog(std::move(catalog)), roots(std::move(roots)), helper(std::move(helper)),
          cancelled(std::move(cancelled)) {}

    var resolve(const var &plugin) {
        checkpoint();
        auto found = match(str(plugin, "classID"));
        if (!found.isObject()) {
            discover();
            auto files = candidates;
            const auto original = str(plugin, "path").replaceCharacter('\\', '/');
            const auto basename = original.fromLastOccurrenceOf("/", false, false);
            if (File::isAbsolutePath(original)) {
                const File source(original);
                if (source.hasFileExtension("vst3") && source.exists())
                    files.addIfNotAlreadyThere(source);
            }
            std::sort(files.begin(), files.end(), [&](const File &left, const File &right) {
                const bool lm = left.getFileName().equalsIgnoreCase(basename),
                           rm = right.getFileName().equalsIgnoreCase(basename);
                return lm != rm ? lm : left.getFullPathName() < right.getFullPathName();
            });
            StringArray errors;
            for (const auto &file : files) {
                checkpoint();
                if (!scanned.insert(file.getFullPathName().toLowerCase()).second)
                    continue;
                try {
                    const auto report = inspect(file);
                    for (auto candidate : list(get(report, "plugins"))) {
                        put(candidate, "path", file.getFullPathName());
                        catalog.add(candidate);
                    }
                    found = match(str(plugin, "classID"));
                    if (found.isObject())
                        break;
                } catch (const std::exception &error) {
                    if (file.getFileName().equalsIgnoreCase(basename))
                        errors.addIfNotAlreadyThere(String::fromUTF8(error.what()));
                }
            }
            if (!found.isObject() && !errors.isEmpty())
                migration::require(false, errors.joinIntoString("\n"));
        }
        if (!found.isObject())
            return {};
        auto state = plugin.clone();
        put(state, "path", str(found, "path"));
        const auto report = inspect(File(str(found, "path")), state);
        auto resolved = found.clone();
        put(resolved, "parameterIDs", get(report, "parameterIDs"));
        return resolved;
    }

  private:
    Array<var> catalog;
    StringArray roots;
    File helper;
    std::function<bool()> cancelled;
    Array<File> candidates;
    std::set<String> scanned, seen;
    bool discovered = false;

    void checkpoint() const {
        if (cancelled && cancelled())
            throw ReaperImportCancelled{};
    }
    var match(const String &classID) const {
        for (const auto &candidate : catalog)
            if (str(candidate, "classID").equalsIgnoreCase(classID) &&
                File(str(candidate, "path")).exists())
                return candidate;
        return {};
    }
    void discover() {
        if (discovered)
            return;
        std::function<void(const File &)> visit = [&](const File &file) {
            checkpoint();
            if (!file.exists() || !seen.insert(file.getFullPathName().toLowerCase()).second)
                return;
            if (file.hasFileExtension("vst3")) {
                candidates.add(file);
                return;
            }
            if (!file.isDirectory() || file.isSymbolicLink())
                return;
            for (const auto &child : file.findChildFiles(File::findFilesAndDirectories, false))
                visit(child);
        };
        for (const auto &root : roots)
            if (root.isNotEmpty())
                visit(File(root));
        discovered = true;
    }
    var inspect(const File &module, const var &state = {}) const {
        checkpoint();
        const auto directory = File::getSpecialLocation(File::tempDirectory)
                                   .getNonexistentChildFile("catlive-reaper-vst3", "", true);
        migration::require(directory.createDirectory().wasOk(),
                           "Could not prepare VST3 import verification.");
        struct Cleanup {
            File directory;
            ~Cleanup() { directory.deleteRecursively(); }
        } cleanup{directory};
        const auto report = directory.getChildFile("result.json");
        StringArray arguments{helper.getFullPathName(), module.getFullPathName(),
                              report.getFullPathName()};
        if (state.isObject()) {
            const auto request = directory.getChildFile("request.json");
            migration::require(request.replaceWithText(JSON::toString(state)),
                               "Could not prepare VST3 import verification.");
            arguments.add("--import");
            arguments.add(request.getFullPathName());
        }
        ChildProcess process;
        migration::require(process.start(arguments, 0), "Could not start VST3 import verification.");
        try {
            // Plugin scans have no duration limit. Only explicit cancellation
            // terminates a helper that is still working or waiting on a plugin.
            while (process.isRunning()) {
                checkpoint();
                Thread::sleep(20);
            }
            checkpoint();
        } catch (...) {
            if (process.isRunning() && process.kill())
                process.waitForProcessToFinish(-1);
            throw;
        }
        const auto result = JSON::parse(report);
        migration::require(process.getExitCode() == 0 && flag(result, "success"),
                           str(result, "error", "VST3 import verification failed."));
        return result;
    }
};
} // namespace catlive
