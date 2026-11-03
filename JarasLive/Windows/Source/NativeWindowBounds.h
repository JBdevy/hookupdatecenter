#pragma once
#include "Common.h"
#include <commctrl.h>
#include <shobjidl.h>
namespace catlive {
class NativeWindowBounds final {
  public:
    bool isFullscreen() const { return fullscreen; }
    bool setFullscreen(bool value) {
        if (!IsWindow(hwnd)) return false;
        if (value == fullscreen) return true;
        if (value) {
            MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
            windowedPlacement = {}; windowedPlacement.length = sizeof(windowedPlacement);
            if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)
                || !GetWindowPlacement(hwnd, &windowedPlacement)) return false;
            windowedStyle = GetWindowLongPtrW(hwnd, GWL_STYLE);
            windowedNonRude = GetPropW(hwnd, L"NonRudeHWND");
            fullscreen = true;
            // JUCE's Windows setFullScreen means SW_MAXIMIZE. Use a borderless
            // normal HWND covering rcMonitor instead, keeping the same peer and
            // its Direct2D/video/plugin child surfaces alive.
            if (IsZoomed(hwnd) || IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
            SetWindowLongPtrW(hwnd, GWL_STYLE,
                             windowedStyle & ~(WS_CAPTION | WS_THICKFRAME | WS_MAXIMIZE));
            RemovePropW(hwnd, L"NonRudeHWND");
            fitFullscreenMonitor();
            markShellFullscreen(true);
        } else {
            markShellFullscreen(false);
            fullscreen = false;
            SetWindowLongPtrW(hwnd, GWL_STYLE, windowedStyle);
            if (windowedNonRude) SetPropW(hwnd, L"NonRudeHWND", windowedNonRude);
            SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                         SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            SetWindowPlacement(hwnd, &windowedPlacement);
        }
        return true;
    }
    void attach(HWND value) {
        hwnd = value;
        applyFrameAppearance(hwnd);
        SetWindowSubclass(hwnd, procedure, reinterpret_cast<UINT_PTR>(this), 0);
    }
    ~NativeWindowBounds() {
        if (IsWindow(hwnd)) {
            if (fullscreen) markShellFullscreen(false);
            RemoveWindowSubclass(hwnd, procedure, reinterpret_cast<UINT_PTR>(this));
        }
    }
  private:
    HWND hwnd = nullptr;
    bool fullscreen = false;
    WINDOWPLACEMENT windowedPlacement{};
    LONG_PTR windowedStyle = 0;
    HANDLE windowedNonRude = nullptr;
    void fitFullscreenMonitor() {
        MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
        if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
            const auto &r = monitor.rcMonitor;
            SetWindowPos(hwnd, HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top,
                         SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
        }
    }
    void markShellFullscreen(bool value) {
        const auto initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        ITaskbarList2 *taskbar = nullptr;
        if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                       IID_PPV_ARGS(&taskbar)))) {
            if (SUCCEEDED(taskbar->HrInit())) taskbar->MarkFullscreenWindow(hwnd, value ? TRUE : FALSE);
            taskbar->Release();
        }
        if (SUCCEEDED(initialized)) CoUninitialize();
    }
    static void applyFrameAppearance(HWND window) {
        // DWM's default light outline is still visible on a borderless,
        // maximized JUCE peer. Keep resizing/shadows and paint that outline with our background.
        // Resolve at runtime so unsupported attributes remain harmless on Win10.
        DynamicLibrary library;
        if(!library.open("dwmapi.dll"))return;
        using SetAttribute=HRESULT(WINAPI *)(HWND,DWORD,LPCVOID,DWORD);
        const auto set=reinterpret_cast<SetAttribute>(library.getFunction("DwmSetWindowAttribute"));
        if(!set)return;
        const BOOL dark=TRUE;
        set(window,20,&dark,sizeof(dark));
        const COLORREF frameColor=RGB(22,22,22);
        set(window,34,&frameColor,sizeof(frameColor));
    }
    static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
        auto *self = reinterpret_cast<NativeWindowBounds *>(id);
        if (message == WM_NCDESTROY) RemoveWindowSubclass(window, procedure, id);
        if (message == WM_NCHITTEST && self->fullscreen) return HTCLIENT;
        // Windows can repaint a cached non-client caption on activation even
        // after its frame style was removed. Fullscreen has no non-client area.
        if (self->fullscreen && (message == WM_NCCALCSIZE || message == WM_NCPAINT)) return 0;
        if (self->fullscreen && message == WM_NCACTIVATE) return TRUE;
        const auto result = DefSubclassProc(window, message, w, l);
        if(message==WM_THEMECHANGED || message==WM_DWMCOMPOSITIONCHANGED)
            applyFrameAppearance(window);
        if ((message == WM_DISPLAYCHANGE || message == WM_DPICHANGED) && self->fullscreen)
            self->fitFullscreenMonitor();
        if (message == WM_GETMINMAXINFO && !self->fullscreen) {
            MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
            if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
                auto &limits = *reinterpret_cast<MINMAXINFO *>(l);
                limits.ptMaxPosition = {monitor.rcWork.left - monitor.rcMonitor.left,
                                        monitor.rcWork.top - monitor.rcMonitor.top};
                limits.ptMaxSize = {monitor.rcWork.right - monitor.rcWork.left,
                                    monitor.rcWork.bottom - monitor.rcWork.top};
                return 0;
            }
        }
        return result;
    }
};
}
