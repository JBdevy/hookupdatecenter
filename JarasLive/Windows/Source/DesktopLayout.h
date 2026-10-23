#pragma once
#include "Common.h"
namespace catlive {
// Rounded from the Mac SidebarWidthLimits.setlist (305.63671875 pt).
inline constexpr int minimumSetlistWidth = 306;
inline const Identifier editorWindowLayoutKey { "catlive.editorWindowLayout" };
// A project/tab owns its content, not the shared desktop window's placement.
inline void setInterfaceScalePreservingWindow(DocumentWindow *window, float scale) {
    const auto hwnd = window && window->getPeer()
        ? static_cast<HWND>(window->getPeer()->getNativeHandle()) : nullptr;
    RECT before{};
    const bool captured = hwnd && GetWindowRect(hwnd, &before);
    Desktop::getInstance().setGlobalScaleFactor(scale);
    RECT after{};
    if (captured && IsWindow(hwnd) && GetWindowRect(hwnd, &after)
        && !EqualRect(&before, &after))
        SetWindowPos(hwnd, nullptr, before.left, before.top,
                     before.right - before.left, before.bottom - before.top,
                     SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER);
}
// Logical dimensions: the peer applies the monitor's DPI. Never force a window
// larger than the work area, including after moving from a larger monitor.
inline void fitEditorWindow(DocumentWindow &window, juce::Rectangle<int> restored = {}) {
    window.getProperties().set(editorWindowLayoutKey, true);
    const auto &displays = Desktop::getInstance().getDisplays();
    const auto *display = restored.isEmpty() ? displays.getPrimaryDisplay()
                                             : displays.getDisplayForRect(restored);
    if (!display)
        display = displays.getPrimaryDisplay();
    if (!display)
        return;
    const auto area = display->userArea.reduced(8);
    const int minWidth = std::min(900, area.getWidth());
    const int minHeight = std::min(480, area.getHeight());
    window.setResizeLimits(minWidth, minHeight, 7680, 4320);
    const int width = jlimit(minWidth, area.getWidth(), restored.isEmpty() ? 1680 : restored.getWidth());
    const int height = jlimit(minHeight, area.getHeight(), restored.isEmpty() ? 1020 : restored.getHeight());
    const int x = restored.isEmpty() ? area.getCentreX() - width / 2
                                    : jlimit(area.getX(), area.getRight() - width, restored.getX());
    const int y = restored.isEmpty() ? area.getCentreY() - height / 2
                                    : jlimit(area.getY(), area.getBottom() - height, restored.getY());
    window.setBounds(x, y, width, height);
}
inline void showEditorWindow(DocumentWindow &window, juce::Rectangle<int> restored = {}) {
    if (!(bool)window.getProperties().getWithDefault(editorWindowLayoutKey, false))
        fitEditorWindow(window, restored);
}
inline void fitLoginWindow(DocumentWindow &window) {
    window.getProperties().set(editorWindowLayoutKey, false);
    const auto &displays=Desktop::getInstance().getDisplays();
    auto *display=displays.getDisplayForRect(window.getBounds());
    if(!display)display=displays.getPrimaryDisplay();
    if(!display)return;
    const auto area=display->userArea.reduced(8);
    const int width=std::min(600,area.getWidth()),height=std::min(640,area.getHeight());
    window.setFullScreen(false);window.setResizeLimits(width,height,7680,4320);
    window.setBounds(area.getCentreX()-width/2,area.getCentreY()-height/2,width,height);
}
inline void fitProjectBrowserWindow(DocumentWindow &window) {
    window.getProperties().set(editorWindowLayoutKey, false);
    const auto *display = Desktop::getInstance().getDisplays().getDisplayForRect(window.getBounds());
    if (!display)
        display = Desktop::getInstance().getDisplays().getPrimaryDisplay();
    if (!display)
        return;
    const auto area = display->userArea.reduced(8);
    const int width = std::min(600, area.getWidth()), height = std::min(492, area.getHeight());
    window.setResizeLimits(width, height, 7680, 4320);
    window.setBounds(area.getCentreX() - width / 2, area.getCentreY() - height / 2, width, height);
}
} // namespace catlive
