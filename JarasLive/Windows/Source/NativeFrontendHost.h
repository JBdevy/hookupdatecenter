#pragma once
#include <functional>
#include <memory>
#include <string>
#include <windows.h>

namespace catlive {
// A presentation-only Win32 window. It never owns, calls, or renders audio.
// Every method and callback runs on the application's existing STA message thread.
class NativeFrontendHost final {
public:
    struct Options {
        std::wstring assetDirectory;
        std::wstring userDataDirectory;
        std::wstring title;
    };
    struct Callbacks {
        std::function<void(std::string)> message;
        std::function<void()> ready;
        std::function<void()> closeRequested;
        std::function<void(std::string)> error;
    };

    NativeFrontendHost(Options, Callbacks);
    ~NativeFrontendHost();
    NativeFrontendHost(const NativeFrontendHost&) = delete;
    NativeFrontendHost& operator=(const NativeFrontendHost&) = delete;

    void postJSON(const std::string&);
    void show();
    void close();
    HWND handle() const noexcept;

private:
    struct State;
    std::shared_ptr<State> state;
};
} // namespace catlive
