#pragma once
#include "Common.h"
namespace catlive {
class ProjectCodec {
  public:
    static jaras::Project decode(const var &json);
    static var encode(const jaras::Project &, const var &original = {});
    static var read(const File &);
    static var canonicalIDs(const var &);
    static void write(const File &, const var &);
    static MemoryBlock seal(const String &);
    static String unseal(const MemoryBlock &);
    static File resolveMedia(const File &directory, const std::string &relative);
};
} // namespace catlive
