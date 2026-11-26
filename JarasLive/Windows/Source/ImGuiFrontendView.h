#pragma once
#include <functional>
#include <memory>
#include <string>

namespace catlive {
// UI-thread presentation. The JSON bridge remains the sole owner of document
// commands, authentication and audio. No JUCE component or device lives here.
class ImGuiFrontendView final {
public:
    explicit ImGuiFrontendView(std::function<void(std::string)> emit);
    ~ImGuiFrontendView();
    ImGuiFrontendView(const ImGuiFrontendView&) = delete;
    ImGuiFrontendView& operator=(const ImGuiFrontendView&) = delete;
    void receive(const std::string& json);
    void render();
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
}
