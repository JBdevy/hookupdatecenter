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
            updateFrameAppearance(true);
            markShellFullscreen(true);
        } else {
            markShellFullscreen(false);
            fullscreen = false;
            SetWindowLongPtrW(hwnd, GWL_STYLE, windowedStyle);
            if (windowedNonRude) SetPropW(hwnd, L"NonRudeHWND", windowedNonRude);
            SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                         SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            SetWindowPlacement(hwnd, &windowedPlacement);
            updateFrameAppearance(true);
        }
        return true;
    }
    void attach(HWND value) {
        hwnd = value;
        updateFrameAppearance(true);
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
    std::optional<bool> coveredFrame;
    bool updatingFrame = false;
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
    void updateFrameAppearance(bool force = false) {
        if (updatingFrame) return;
        const ScopedValueSetter<bool> updating(updatingFrame, true);
        const bool covered = fullscreen || IsZoomed(hwnd);
        if (!force && coveredFrame == covered) return;
        coveredFrame = covered;
        // JUCE extends one pixel of DWM glass into each side for the normal
        // window's shadow. Matching rcMonitor alone leaves that glass visible.
        // Remove both glass and rounded corners when filling the work area or
        // monitor; restore the normal shadow without recreating the peer.
        DynamicLibrary library;
        if(!library.open("dwmapi.dll"))return;
        struct Margins { int left, right, top, bottom; };
        using ExtendFrame=HRESULT(WINAPI *)(HWND,const Margins *);
        if (const auto extend=reinterpret_cast<ExtendFrame>(library.getFunction("DwmExtendFrameIntoClientArea"))) {
            const Margins margins{covered ? 0 : 1, covered ? 0 : 1, 0, 0};
            extend(hwnd,&margins);
        }
        // Windows 11 attributes are optional on older Windows releases.
        using SetAttribute=HRESULT(WINAPI *)(HWND,DWORD,LPCVOID,DWORD);
        const auto set=reinterpret_cast<SetAttribute>(library.getFunction("DwmSetWindowAttribute"));
        if(!set)return;
        const BOOL dark=TRUE;
        set(hwnd,20,&dark,sizeof(dark));
        const DWORD corners=covered ? 1u : 0u; // DWMWCP_DONOTROUND / DEFAULT
        set(hwnd,33,&corners,sizeof(corners));
        const COLORREF frameColor=covered ? 0xfffffffeu : RGB(22,22,22); // DWMWA_COLOR_NONE
        set(hwnd,34,&frameColor,sizeof(frameColor));
    }
    static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
        auto *self = reinterpret_cast<NativeWindowBounds *>(id);
        if (message == WM_NCDESTROY) RemoveWindowSubclass(window, procedure, id);
        if (message == WM_NCHITTEST && self->fullscreen) return HTCLIENT;
        // Windows can repaint a cached non-client caption on activation even
        // after its frame style was removed. Fullscreen has no non-client area.
        if (self->fullscreen && (message == WM_NCCALCSIZE || message == WM_NCPAINT)) return 0;
        if (self->fullscreen && message == WM_NCACTIVATE) return TRUE;
        if (message == WM_NCACTIVATE) {
            // Keep activation bookkeeping, but do not let DefWindowProc paint
            // the system's classic/accent frame over our custom client area.
            const auto result = DefSubclassProc(window, message, w, -1);
            self->updateFrameAppearance(true);
            return result;
        }
        const auto result = DefSubclassProc(window, message, w, l);
        // JUCE reapplies its corner/shadow policy after the nested WM_SIZE
        // handling. Restore ours after the enclosing position change too.
        if(message==WM_THEMECHANGED || message==WM_DWMCOMPOSITIONCHANGED || message==WM_WINDOWPOSCHANGED)
            self->updateFrameAppearance(true);
        if (message == WM_SIZE && w != SIZE_MINIMIZED)
            self->updateFrameAppearance();
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
