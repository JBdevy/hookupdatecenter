#pragma once
#include "ProjectCodec.h"
namespace catlive {
struct MigratedProject {
    jaras::Project project;
    std::map<std::string, File> media;
    StringArray warnings;
};
MigratedProject readReaperProject(const File &);
MigratedProject readLogicProject(const File &);
File saveMigratedProject(const MigratedProject &, const File &selection);
namespace migration {
jaras::Project emptyProject(const String &);
void finish(MigratedProject &);
void require(bool, const String &);
} // namespace migration
} // namespace catlive
