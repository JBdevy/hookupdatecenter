#pragma once
#include "../Project/Models.hpp"
#include <vector>
namespace jaras {
struct TrackRoleAlias { std::string alias; TrackRole role; };
class TrackTaxonomy {
public:
    TrackTaxonomy();
    void addAlias(std::string alias, TrackRole role);
    TrackRole classify(std::string filename) const;
private:
    std::vector<TrackRoleAlias> aliases_;
};
class TrackClassifier {
public:
    explicit TrackClassifier(const TrackTaxonomy& taxonomy): taxonomy_(taxonomy) {}
    TrackRole classify(const std::string& filename) const { return taxonomy_.classify(filename); }
private:
    const TrackTaxonomy& taxonomy_;
};
}
