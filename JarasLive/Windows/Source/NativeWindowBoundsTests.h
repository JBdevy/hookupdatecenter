#pragma once
#include "NativeWindowBounds.h"
namespace catlive::nativeWindowBoundsTests {
template <typename Register> void registerTests(Register &test) {
    test("Workspace fullscreen covers the monitor and restores normal and maximized windows", [] {
        const auto require = [](bool okay, const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        struct TestWindow final : DocumentWindow {
            TestWindow() : DocumentWindow("Fullscreen test", Colours::black, 0) {
                setUsingNativeTitleBar(false); setTitleBarHeight(0);
                setResizable(true, false); setDropShadowEnabled(true);
            }
            void closeButtonPressed() override {}
        } window;
        window.setBounds(40, 40, 600, 400); window.setVisible(true);
        const auto hwnd = static_cast<HWND>(window.getPeer()->getNativeHandle());
        NativeWindowBounds native; native.attach(hwnd);
        const auto rectangle = [hwnd] { RECT r{}; GetWindowRect(hwnd, &r); return r; };
        const auto verifyFullscreen = [&] {
            require(native.isFullscreen(), "Fullscreen state was not retained");
            require(window.getPeer()->getNativeHandle() == hwnd, "Fullscreen recreated the native peer");
            MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
            require(GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor), "No monitor");
            const auto frame = rectangle();
            require(EqualRect(&frame, &monitor.rcMonitor), "Fullscreen did not cover the complete monitor");
            RECT client{}; GetClientRect(hwnd, &client); MapWindowPoints(hwnd, nullptr, reinterpret_cast<POINT *>(&client), 2);
            require(EqualRect(&client, &monitor.rcMonitor), "Fullscreen client area lost space to the frame/taskbar");
            require(!(GetWindowLongPtrW(hwnd, GWL_STYLE) & (WS_CAPTION | WS_THICKFRAME | WS_MAXIMIZE)),
                    "Fullscreen is still a decorated/maximized window");
            require(!(GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST), "Fullscreen forced always-on-top");
        };
        for (const auto &display : Desktop::getInstance().getDisplays().displays) {
            window.setBounds(display.userArea.reduced(40).withSizeKeepingCentre(600, 400));
            const auto normal = rectangle();
            const auto style = GetWindowLongPtrW(hwnd, GWL_STYLE);
            require(native.setFullscreen(true), "Could not enter fullscreen"); verifyFullscreen();
            require(native.setFullscreen(true), "Repeated enter failed");
            require(native.setFullscreen(false) && !native.isFullscreen(), "Could not exit fullscreen");
            auto restored = rectangle();
            require(EqualRect(&normal, &restored), "Normal bounds changed after exiting fullscreen");
            require(GetWindowLongPtrW(hwnd, GWL_STYLE) == style, "Normal window style was not restored");
            ShowWindow(hwnd, SW_MAXIMIZE);
            const auto maximized = rectangle();
            require(IsZoomed(hwnd) && !native.isFullscreen(), "Maximize was confused with true fullscreen");
            require(native.setFullscreen(true), "Could not enter from maximized"); verifyFullscreen();
            require(native.setFullscreen(false) && IsZoomed(hwnd), "Maximized state was not restored");
            restored = rectangle(); require(EqualRect(&maximized, &restored), "Maximized bounds were not restored");
            ShowWindow(hwnd, SW_RESTORE);
            restored = rectangle(); require(EqualRect(&normal, &restored), "Fullscreen lost the restore-down position");
        }
    });
}
}
