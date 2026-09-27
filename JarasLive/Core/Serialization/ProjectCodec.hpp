#pragma once
#include "../Project/Models.hpp"
namespace jaras {
// Platform codecs use this portable schema. Apple uses Codable + the ObjC++ bridge.
// A .jaras manifest contains relative paths; archive extraction is a future layer.
class ProjectCodec {
public:
    virtual ~ProjectCodec() = default;
    virtual Project decode(const std::string& json) const = 0;
    virtual std::string encode(const Project& project) const = 0;
};
}
