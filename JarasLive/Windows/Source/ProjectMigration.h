#pragma once
#include "ProjectCodec.h"
namespace catlive {
struct MigratedProject {
    jaras::Project project;
    std::map<std::string, File> media;
    StringArray warnings;
};
// Returns resolved local metadata plus an optional parameterIDs object keyed by
// REAPER parameter index. A missing result preserves the preset without insertion.
using ReaperVST3Resolver = std::function<var(const var &, const std::set<int> &)>;
// Cancellation deliberately bypasses the importer's recoverable data-error
// catches, so it cannot turn into an omitted effect followed by a saved project.
struct ReaperImportCancelled {};
ReaperVST3Resolver makeReaperVST3Resolver(std::function<bool()> cancelled = {});
MigratedProject readReaperProject(const File &, const ReaperVST3Resolver & = {});
MigratedProject readLogicProject(const File &);
File saveMigratedProject(const MigratedProject &, const File &selection);
namespace migration {
jaras::Project emptyProject(const String &);
void finish(MigratedProject &, bool createDefaultRegion = true);
void require(bool, const String &);
} // namespace migration
} // namespace catlive
