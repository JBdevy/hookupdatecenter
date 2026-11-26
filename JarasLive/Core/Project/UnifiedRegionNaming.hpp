#pragma once
#include <algorithm>
#include <cctype>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

namespace jaras {
inline std::pair<int, std::string> splitUnifiedRegionName(std::string title) {
    int number = 0;
    for (;;) {
        std::size_t digits = 0;
        while (digits < title.size() && std::isdigit(static_cast<unsigned char>(title[digits]))) ++digits;
        auto end = digits;
        while (end < title.size() && std::isspace(static_cast<unsigned char>(title[end]))) ++end;
        if (digits < 3 || end >= title.size() || title[end] != '-') break;
        if (!number) { try { number = std::stoi(title.substr(0, digits)); } catch (...) {} }
        ++end;
        while (end < title.size() && std::isspace(static_cast<unsigned char>(title[end]))) ++end;
        title.erase(0, end);
    }
    return {number, title};
}
inline std::string normalizedUnifiedRegionName(const std::string& name) {
    const auto value=splitUnifiedRegionName(name);
    if(!value.first)return value.second;
    std::ostringstream result;result<<std::setfill('0')<<std::setw(3)<<value.first<<" - "<<value.second;
    return result.str();
}
inline std::string nextUnifiedRegionName(const std::string& title, const std::vector<std::string>& existing) {
    int highest = static_cast<int>(existing.size());
    for (const auto& name : existing) highest = std::max(highest, splitUnifiedRegionName(name).first);
    std::ostringstream result;
    result << std::setfill('0') << std::setw(3) << highest + 1 << " - " << splitUnifiedRegionName(title).second;
    return result.str();
}
}
