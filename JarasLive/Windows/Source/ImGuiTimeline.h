#pragma once
#include <functional>
#include <memory>
#include <string>
#include <nlohmann/json.hpp>

namespace catlive {
// Presentation only. The bridge owns the project, audio and all document edits.
class ImGuiTimeline final {
public:
    using Command = std::function<void(const std::string&,const nlohmann::json&)>;
    ImGuiTimeline();
    ~ImGuiTimeline();
    ImGuiTimeline(const ImGuiTimeline&)=delete;
    ImGuiTimeline& operator=(const ImGuiTimeline&)=delete;
    void render(const nlohmann::json& snapshot,const nlohmann::json& telemetry,const Command&);
    // Waveform replies retain the originating payload's requestId at the top level.
    void receive(const nlohmann::json& message);
    float verticalOffset() const;
    void setVerticalOffset(float);
    static float trackHeight(const nlohmann::json& track);
    float headerHeight(const nlohmann::json& snapshot) const;
    // Resolves a native client-space drop against the last rendered document.
    // Empty if the layout is stale or the point is outside the track grid.
    nlohmann::json mediaDropTarget(const nlohmann::json& snapshot, float x, float y, bool exact) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
}
