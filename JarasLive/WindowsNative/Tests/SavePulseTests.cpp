#include "../Source/SavePulseComposition.h"
#include <dwmapi.h>
#include <cstdio>
#include <algorithm>

static LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_PAINT) {
        PAINTSTRUCT ps{}; auto dc = BeginPaint(window, &ps); FillRect(dc, &ps.rcPaint, (HBRUSH)GetStockObject(WHITE_BRUSH)); EndPaint(window, &ps); return 0;
    }
    return DefWindowProcW(window, message, w, l);
}
int main() {
    const HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    HWND window = nullptr; int result = 1;
    try {
        WNDCLASSW wc{}; wc.lpfnWndProc = windowProc; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"CatLiveSavePulseTest";
        RegisterClassW(&wc);
        window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, wc.lpszClassName, L"Save pulse validation",
                                 WS_POPUP, 8, 8, 40, 40, nullptr, nullptr, wc.hInstance, nullptr);
        if (!window) throw std::runtime_error("No test window");
        ShowWindow(window, SW_SHOWNOACTIVATE); UpdateWindow(window); DwmFlush();
        auto sample = [&] { auto dc = GetDC(nullptr); const auto pixel = GetPixel(dc, 28, 28); ReleaseDC(nullptr, dc); return int(GetRValue(pixel)); };
        {
            catlive::native::SavePulseComposition pulse(window);
            if (!pulse.update(true, 40, 40, 0xff1d1d1d)) throw std::runtime_error("Composition could not start");
            // No message dispatch or application repaint during the whole cycle.
            // Real screen pixels must still fade, reverse smoothly and repeat.
            int low = 255, high = 0, changes = 0, previous = -1, largestStep = 0;
            for (int i = 0; i < 65; ++i) {
                Sleep(40); DwmFlush(); const int value = sample();
                low = std::min(low, value); high = std::max(high, value);
                if (previous >= 0) { changes += value != previous; largestStep = std::max(largestStep, std::abs(value - previous)); }
                previous = value;
            }
            std::printf("range=%d..%d changes=%d largestStep=%d\n", low, high, changes, largestStep);
            if (low < 125 || low > 160 || high < 235 || changes < 35 || largestStep > 30)
                throw std::runtime_error("Save pulse is not smooth while the UI thread is blocked");
            if (!pulse.update(false, 40, 40, 0xff1d1d1d)) throw std::runtime_error("Composition could not stop");
            Sleep(100); DwmFlush();
            if (sample() < 245) throw std::runtime_error("Saved state did not restore full opacity");
            if (!pulse.update(true, 60, 40, 0xff1d1d1d)) throw std::runtime_error("Composition could not restart after resize");
            Sleep(800); DwmFlush();
            if (sample() > 175) throw std::runtime_error("Save pulse did not restart after resize");
            if (!pulse.update(false, 60, 40, 0xff1d1d1d)) throw std::runtime_error("Composition could not stop after resize");
            Sleep(100); DwmFlush();
            if (sample() < 245) throw std::runtime_error("Saved state did not restore after resize");
        }
        std::puts("SAVE_PULSE_COMPOSITOR_CONTINUES_WITHOUT_UI_REPAINT_OK"); result = 0;
    } catch (const std::exception &e) { std::fprintf(stderr, "%s\n", e.what()); }
    if (window) DestroyWindow(window);
    if (SUCCEEDED(apartment)) CoUninitialize();
    return result;
}
