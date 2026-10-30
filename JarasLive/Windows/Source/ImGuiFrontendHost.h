#pragma once
#include <functional>
#include <memory>
#include <string>
#include <windows.h>

namespace catlive {
// Win32 owns the window and input; DirectX 11 owns presentation. All methods and
// callbacks run on the application's existing UI thread, never the audio thread.
class ImGuiFrontendHost final {
public:
    struct Options {
        std::wstring title;
        std::wstring fontPath;
        std::wstring diagnosticsPath;
    };
    struct Callbacks {
        std::function<void(std::string)> message;
        std::function<void()> ready;
        std::function<void()> closeRequested;
        std::function<void(std::string)> error;
    };

    // Creates a hidden native window immediately. Graphics initialization and ready
    // are deferred to the message loop so the caller can assign its owning pointer.
    ImGuiFrontendHost(Options, Callbacks);
    ~ImGuiFrontendHost();
    ImGuiFrontendHost(const ImGuiFrontendHost&) = delete;
    ImGuiFrontendHost& operator=(const ImGuiFrontendHost&) = delete;

    void postJSON(const std::string&);
    void show();
    void close();
    void restart();
    HWND handle() const noexcept;

private:
    struct State;
    std::shared_ptr<State> state;
};
} // namespace catlive
