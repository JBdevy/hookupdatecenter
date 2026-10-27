#pragma once
#include "Common.h"
#include <commctrl.h>
namespace catlive {
class NativeWindowBounds final {
  public:
    void attach(HWND value) {
        hwnd = value;
        applyFrameAppearance(hwnd);
        SetWindowSubclass(hwnd, procedure, reinterpret_cast<UINT_PTR>(this), 0);
    }
    ~NativeWindowBounds() {
        if (IsWindow(hwnd)) RemoveWindowSubclass(hwnd, procedure, reinterpret_cast<UINT_PTR>(this));
    }
  private:
    HWND hwnd = nullptr;
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
        if (message == WM_NCDESTROY) RemoveWindowSubclass(window, procedure, id);
        const auto result = DefSubclassProc(window, message, w, l);
        if(message==WM_THEMECHANGED || message==WM_DWMCOMPOSITIONCHANGED)
            applyFrameAppearance(window);
        if (message == WM_GETMINMAXINFO) {
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
