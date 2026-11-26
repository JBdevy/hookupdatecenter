#pragma once
#include "ProjectCodec.h"
#include "Transport/Engine.hpp"
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <vector>

namespace catlive::native {
// Control-thread document state. Device callbacks consume a separately prepared
// audio graph; JSON, validation, file I/O and history never run on that callback.
class NativeSession final {
public:
    void open(const std::filesystem::path& file);
    void loadDocument(const nlohmann::json& document);
    void save(const std::filesystem::path& file);
    void edit(const std::function<void(jaras::Project&)>& mutation);
    void editDocument(const nlohmann::json& document);
    void editEngine(const std::function<void(jaras::Engine&)>& mutation);
    void command(const jaras::Command& command);
    void advance(double seconds);
    bool undo();
    bool redo();
    nlohmann::json document() const;
    nlohmann::json state() const;
    const jaras::Project& project() const noexcept { return engine_.project(); }
    const jaras::TransportState& transport() const noexcept { return engine_.transport(); }
    const std::filesystem::path& path() const noexcept { return path_; }
    std::uint64_t revision() const noexcept { return revision_; }
    bool dirty() const noexcept { return dirty_; }
private:
    struct History {
        jaras::Project project;
        std::shared_ptr<const nlohmann::json> original;
        std::size_t projectBytes = 0, originalBytes = 0;
    };
    jaras::Engine engine_;
    std::shared_ptr<const nlohmann::json> original_ =
        std::make_shared<const nlohmann::json>(nlohmann::json::object());
    std::size_t originalBytes_ = sizeof(nlohmann::json);
    std::filesystem::path path_;
    std::vector<History> past_, future_;
    std::uint64_t revision_ = 0;
    bool dirty_ = false;
    void commit(jaras::Project project, bool remember);
    void commitEngine(jaras::Engine engine, bool remember);
    void restore(const History& history);
    History snapshot() const;
    std::size_t historyBytes() const noexcept;
    void trimHistory() noexcept;
};
}
