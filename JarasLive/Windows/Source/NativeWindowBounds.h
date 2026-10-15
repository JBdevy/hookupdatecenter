#pragma once
#include "Common.h"
#include <commctrl.h>
namespace catlive {
class NativeWindowBounds final {
  public:
    void attach(HWND value) {
        hwnd = value;
        SetWindowSubclass(hwnd, procedure, reinterpret_cast<UINT_PTR>(this), 0);
    }
    ~NativeWindowBounds() {
        if (IsWindow(hwnd)) RemoveWindowSubclass(hwnd, procedure, reinterpret_cast<UINT_PTR>(this));
    }
  private:
    HWND hwnd = nullptr;
    static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
        if (message == WM_NCDESTROY) RemoveWindowSubclass(window, procedure, id);
        const auto result = DefSubclassProc(window, message, w, l);
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
