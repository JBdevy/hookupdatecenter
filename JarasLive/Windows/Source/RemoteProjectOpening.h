#pragma once
#include <string>
#include <utility>

namespace catlive::remote {
// Owned by the Remote host, not by a project tab. A terminal result remains
// available until the next request, so frame coalescing cannot lose completion.
class ProjectOpening {
  public:
    enum class State { none, opening, completed, failed, cancelled, waiting };
    const std::string &id() const { return command; }
    const std::string &status() const { return detail; }
    const std::string &error() const { return failure; }
    bool active() const { return state == State::opening || state == State::waiting; }
    const char *stateName() const {
        switch (state) {
            case State::opening: return "opening";
            case State::completed: return "completed";
            case State::failed: return "failed";
            case State::cancelled: return "cancelled";
            case State::waiting: return "waiting";
            default: return "";
        }
    }
    bool begin(const std::string &id) {
        if (id.empty() || active()) return false;
        command = id; state = State::opening; detail = "Opening project…"; failure.clear();
        return true;
    }
    void update(const std::string &id, State next, std::string message = {}, std::string error = {}) {
        if (id.empty() || id != command || !active() || next == State::none) return;
        state = next; detail = std::move(message); failure = std::move(error);
    }
  private:
    std::string command, detail, failure;
    State state = State::none;
};
} // namespace catlive::remote
