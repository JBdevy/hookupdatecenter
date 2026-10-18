#pragma once
#include "FloatingShortcuts.h"
#include <windows.h>
namespace catlive {
// VST3 editors own native child HWNDs: JUCE KeyListeners cannot see their
// messages. Intercept only this UI thread and only registered plug-in windows.
class NativePluginShortcuts final {
    struct State {
        HWND root{};
        std::function<bool(const KeyPress &)> key;
        std::function<void(bool)> keyState;
        std::set<WPARAM> consumed;
        int received = 0, textRejected = 0, shortcutRejected = 0;
    };
    std::shared_ptr<State> state;
    inline static HHOOK hook{};
    inline static std::vector<std::weak_ptr<State>> windows;
    static bool nativeTextInput(HWND focus) {
        GUITHREADINFO info{};info.cbSize=sizeof(info);
        if(GetGUIThreadInfo(GetCurrentThreadId(),&info)&&info.hwndCaret)return true;
        for(auto hwnd=focus;hwnd;hwnd=GetParent(hwnd)){
            wchar_t name[128]{};GetClassNameW(hwnd,name,128);auto type=String(name).toLowerCase();
            if(type=="edit"||type.contains("richedit")||type.contains("textinput"))return true;
        }
        return false;
    }
    static int keyCode(WPARAM vk) {
        if(vk>=VK_F1&&vk<=VK_F24)return KeyPress::F1Key+(int)(vk-VK_F1);
        if(vk>='A'&&vk<='Z')return (int)vk;
        if(vk>='0'&&vk<='9')return (int)vk;
        switch(vk){case VK_SPACE:return KeyPress::spaceKey;case VK_ESCAPE:return KeyPress::escapeKey;
            case VK_RETURN:return KeyPress::returnKey;case VK_TAB:return KeyPress::tabKey;
            case VK_BACK:return KeyPress::backspaceKey;case VK_DELETE:return KeyPress::deleteKey;
            case VK_LEFT:return KeyPress::leftKey;case VK_RIGHT:return KeyPress::rightKey;
            case VK_UP:return KeyPress::upKey;case VK_DOWN:return KeyPress::downKey;
            case VK_HOME:return KeyPress::homeKey;case VK_END:return KeyPress::endKey;
            case VK_PRIOR:return KeyPress::pageUpKey;case VK_NEXT:return KeyPress::pageDownKey;}
        if(vk>=VK_OEM_1&&vk<=VK_OEM_102){const auto c=MapVirtualKeyW((UINT)vk,MAPVK_VK_TO_CHAR);if(!(c&0x80000000))return (int)c;}
        return 0;
    }
    static LRESULT CALLBACK messages(int code,WPARAM remove,LPARAM data) {
        if(code>=0&&remove==PM_REMOVE){auto &message=*reinterpret_cast<MSG*>(data);
            const bool down=message.message==WM_KEYDOWN||message.message==WM_SYSKEYDOWN;
            const bool up=message.message==WM_KEYUP||message.message==WM_SYSKEYUP;
            if(down||up)for(auto weak:windows)if(auto current=weak.lock()){
                // Check the editor itself; SSH/CI desktops can be hidden even
                // when a window has WS_VISIBLE and receives queued messages.
                if(!(GetWindowLongPtrW(current->root,GWL_STYLE)&WS_VISIBLE)||!(message.hwnd==current->root||IsChild(current->root,message.hwnd)))continue;
                ++current->received;
                if(up){const bool consumed=current->consumed.erase(message.wParam)!=0;if(current->keyState)current->keyState(false);if(consumed)message.message=WM_NULL;break;}
                if(nativeTextInput(GetFocus())) { ++current->textRejected; break; }
                if((message.lParam&(LPARAM(1)<<30))&&current->consumed.count(message.wParam)){message.message=WM_NULL;break;}
                // A release outside the plug-in window must not leave a sticky shortcut.
                if(!(message.lParam&(LPARAM(1)<<30)))current->consumed.erase(message.wParam);
                const auto key=keyCode(message.wParam);if(!key)break;
                int modifiers=0;
                if(GetKeyState(VK_CONTROL)<0)modifiers|=ModifierKeys::ctrlModifier;
                if(GetKeyState(VK_SHIFT)<0)modifiers|=ModifierKeys::shiftModifier;
                if(GetKeyState(VK_MENU)<0)modifiers|=ModifierKeys::altModifier;
                const KeyPress press(key,ModifierKeys(modifiers),0);
                if (!FloatingShortcuts::allows(press)) ++current->shortcutRejected;
                if(FloatingShortcuts::allows(press)&&current->key&&current->key(press)){
                    current->consumed.insert(message.wParam);message.message=WM_NULL;
                }
                break;
            }
        }
        return CallNextHookEx(hook,code,remove,data);
    }
public:
    String diagnostics() const { return "hook="+String((int)(hook!=nullptr))+" visible="+String((int)IsWindowVisible(state->root))+" thread="+String((int)GetWindowThreadProcessId(state->root,nullptr))+" currentThread="+String((int)GetCurrentThreadId())+" received="+String(state->received)+" textRejected="+String(state->textRejected)+" shortcutRejected="+String(state->shortcutRejected); }
    NativePluginShortcuts(HWND root,std::function<bool(const KeyPress &)> key,std::function<void(bool)> changed)
        :state(std::make_shared<State>()) {
        state->root=root;state->key=std::move(key);state->keyState=std::move(changed);
        windows.erase(std::remove_if(windows.begin(),windows.end(),[](auto &w){return w.expired();}),windows.end());
        windows.push_back(state);
        if(!hook)hook=SetWindowsHookExW(WH_GETMESSAGE,messages,nullptr,GetCurrentThreadId());
    }
    ~NativePluginShortcuts(){state.reset();windows.erase(std::remove_if(windows.begin(),windows.end(),[](auto &w){return w.expired();}),windows.end());if(windows.empty()&&hook){UnhookWindowsHookEx(hook);hook=nullptr;}}
};
}
