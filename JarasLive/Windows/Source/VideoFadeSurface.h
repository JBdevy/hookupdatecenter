#pragma once
#include "Common.h"
namespace catlive {
// DirectShow renders into its own HWND, outside JUCE's component alpha.
// Blend a native black child above that surface; keep mouse input with video.
// https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-setlayeredwindowattributes
class VideoFadeSurface {
  public:
    ~VideoFadeSurface(){if(overlay)DestroyWindow(overlay);}
    void hide(){if(overlay)ShowWindow(overlay,SW_HIDE);}
    void update(Component &video,float opacity) {
        auto *peer=video.getPeer();if(!peer || !video.isShowing() || opacity>=.9999f){hide();return;}
        const auto parent=(HWND)peer->getNativeHandle();HWND surface=nullptr;
        EnumChildWindows(parent,[](HWND window,LPARAM target)->BOOL {
            wchar_t name[128]{};GetClassNameW(window,name,128);
            if(String(name).startsWith("JUCE_DIRECTSHOW_") && IsWindowVisible(window)){*reinterpret_cast<HWND*>(target)=window;return FALSE;}return TRUE;
        },reinterpret_cast<LPARAM>(&surface));
        if(!surface){hide();return;}
        if(overlay && (!IsWindow(overlay) || GetParent(overlay)!=parent)){DestroyWindow(overlay);overlay=nullptr;}
        if(!overlay)overlay=CreateWindowExW(WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE,L"STATIC",L"",WS_CHILD|SS_BLACKRECT,0,0,1,1,parent,nullptr,GetModuleHandleW(nullptr),nullptr);
        if(!overlay)return;
        RECT bounds{};GetWindowRect(surface,&bounds);MapWindowPoints(nullptr,parent,reinterpret_cast<POINT*>(&bounds),2);
        SetLayeredWindowAttributes(overlay,0,(BYTE)jlimit(0,255,roundToInt(255*(1-opacity))),LWA_ALPHA);
        SetWindowPos(overlay,HWND_TOP,bounds.left,bounds.top,bounds.right-bounds.left,bounds.bottom-bounds.top,SWP_NOACTIVATE|SWP_SHOWWINDOW);
    }
  private: HWND overlay=nullptr;
};
}
