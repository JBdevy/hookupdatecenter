#pragma once
#include "RemoteProjectOpening.h"
#include <stdexcept>

namespace catlive::remoteProjectOpeningTests {
inline void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
template <typename Test> void registerStateTests(Test &test) {
    using State = remote::ProjectOpening::State;
    test("Remote project opening retains correlated completion and ignores late progress", [] {
        remote::ProjectOpening state;
        require(state.begin("first") && state.active(), "Opening was not immediate");
        require(!state.begin("second"), "A second request replaced the active opening");
        state.update("first", State::completed);
        require(!state.active() && state.id() == "first" && std::string(state.stateName()) == "completed", "Same-project or successful opening did not retain its completion");
        state.update("first", State::opening, "Late progress");
        require(!state.active() && state.status().empty(), "Late worker progress reopened the completed loading modal");
        require(state.begin("second"), "Completed opening blocked the next request");
        state.update("first", State::failed, {}, "Old error");
        require(state.active() && state.id() == "second" && state.error().empty(), "An old project's completion terminated a newer request");
        state.update("second", State::failed, {}, "Cannot read project");
        require(!state.active() && state.error() == "Cannot read project", "Load error was lost");
    });
    test("Remote project opening waits for host confirmation and can resume or cancel", [] {
        for (const bool cancel : {false, true}) {
            remote::ProjectOpening state; state.begin("request");
            state.update("request", State::waiting, "Resolve missing media on the PC");
            require(state.active() && std::string(state.stateName()) == "waiting" && !state.status().empty(), "Missing media or save confirmation was reported as success");
            if (!cancel) {
                state.update("request", State::opening, "Preparing audio");
                require(state.active() && std::string(state.stateName()) == "opening", "Host confirmation did not resume loading");
            }
            state.update("request", cancel ? State::cancelled : State::completed);
            require(!state.active() && state.error().empty() && std::string(state.stateName()) == (cancel ? "cancelled" : "completed"), "Cancel or completion left the Remote blocked");
        }
    });
}
} // namespace catlive::remoteProjectOpeningTests
