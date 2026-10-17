#pragma once
#include "Project/Models.hpp"
#include <nlohmann/json.hpp>
#include <filesystem>
#include <cstdint>
#include <vector>

namespace catlive::native {
using json = nlohmann::json;
// JUCE-free document model codec. Unknown object fields are retained through
// encode(model, original); numbers use the JSON library's lossless double writer.
class ProjectCodec final {
  public:
    static jaras::Project decode(const json &);
    static json encode(const jaras::Project &, json original = json::object());
    static json read(const std::filesystem::path &);
    static void write(const std::filesystem::path &, const json &);
    static json canonicalIDs(const json &);
    static std::vector<std::uint8_t> seal(const std::string &);
    static std::string unseal(const std::vector<std::uint8_t> &);
    static std::filesystem::path resolveMedia(const std::filesystem::path &directory,
        const std::string &relative, bool resolveExisting = true);
};
} // namespace catlive::native
