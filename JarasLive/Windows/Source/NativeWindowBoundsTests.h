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
        const auto verifyFrameAppearance = [&](bool covered) {
            DynamicLibrary dwm;
            if (!dwm.open("dwmapi.dll")) return;
            using GetAttribute = HRESULT(WINAPI *)(HWND,DWORD,PVOID,DWORD);
            const auto get = reinterpret_cast<GetAttribute>(dwm.getFunction("DwmGetWindowAttribute"));
            if (!get) return;
            const auto beforeFocus = rectangle();
            for (int activation : {-1,0,1}) {
            if (activation >= 0) SendMessageW(hwnd,WM_NCACTIVATE,activation,0);
            const auto afterFocus = rectangle();
            require(EqualRect(&beforeFocus,&afterFocus), "Focus changes moved the custom window frame");
            DWORD corners = 0; COLORREF border = 0;
            if (SUCCEEDED(get(hwnd,33,&corners,sizeof(corners))) && corners != (covered ? 1u : 0u))
                throw std::runtime_error("Window corner policy " + std::to_string(corners) +
                    " covered=" + std::to_string(covered) + " fullscreen=" + std::to_string(native.isFullscreen()) +
                    " maximized=" + std::to_string(IsZoomed(hwnd)));
            if (SUCCEEDED(get(hwnd,34,&border,sizeof(border))))
                require(border == (covered ? 0xfffffffeu : RGB(22,22,22)), "Window frame decoration was not updated/restored");
            }
        };
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
            verifyFrameAppearance(true);
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
            verifyFrameAppearance(false);
            ShowWindow(hwnd, SW_MAXIMIZE);
            const auto maximized = rectangle();
            require(IsZoomed(hwnd) && !native.isFullscreen(), "Maximize was confused with true fullscreen");
            MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
            GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
            RECT client{}; GetClientRect(hwnd,&client); MapWindowPoints(hwnd,nullptr,reinterpret_cast<POINT *>(&client),2);
            require(EqualRect(&client,&monitor.rcWork), "Maximized client does not fill the work area");
            verifyFrameAppearance(true);
            require(native.setFullscreen(true), "Could not enter from maximized"); verifyFullscreen();
            require(native.setFullscreen(false) && IsZoomed(hwnd), "Maximized state was not restored");
            restored = rectangle(); require(EqualRect(&maximized, &restored), "Maximized bounds were not restored");
            ShowWindow(hwnd, SW_RESTORE);
            restored = rectangle(); require(EqualRect(&normal, &restored), "Fullscreen lost the restore-down position");
            verifyFrameAppearance(false);
        }
    });
}
}
