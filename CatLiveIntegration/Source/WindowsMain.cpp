#include "Bridge.h"
#include <windows.h>
#include <future>

namespace {
std::unique_ptr<integration::Bridge> bridge;
std::vector<integration::Adapter> adapters;
HWND selector, button, label, title, caption;
HFONT font = nullptr, titleFont = nullptr;
HBRUSH background = nullptr;
std::future<void> operation;
UINT dpi = 96;
bool portuguese = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_PORTUGUESE;
const wchar_t* tr(const wchar_t* pt, const wchar_t* en) { return portuguese ? pt : en; }
int px(int value) { return MulDiv(value, int(dpi), 96); }
std::wstring wide(const std::string& value) {
    int n = MultiByteToWideChar(CP_UTF8, 0, value.data(), int(value.size()), nullptr, 0);
    std::wstring result(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.data(), int(value.size()), result.data(), n);
    return result;
}
void layout() {
    auto oldFont = font, oldTitle = titleFont;
    font = CreateFontW(-px(16),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
    titleFont = CreateFontW(-px(28),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
    SendMessage(title,WM_SETFONT,(WPARAM)titleFont,TRUE);
    for (auto control : {caption,selector,button,label}) SendMessage(control,WM_SETFONT,(WPARAM)font,TRUE);
    auto move = [](HWND control,int x,int y,int w,int h) { MoveWindow(control,px(x),px(y),px(w),px(h),TRUE); };
    move(title,20,32,500,45); move(caption,60,102,420,24);
    move(selector,60,131,420,180); move(button,170,184,200,36); move(label,25,240,490,58);
    if(oldFont)DeleteObject(oldFont); if(oldTitle)DeleteObject(oldTitle);
}
void refresh() {
    auto old = int(SendMessageW(selector,CB_GETCURSEL,0,0));
    std::string address = old >= 0 && old < int(adapters.size()) ? adapters[old].address : "";
    auto found = integration::adapters();
    bool changed = found.size() != adapters.size();
    if(!changed)for(size_t i=0;i<found.size();++i)
        if(found[i].address!=adapters[i].address || found[i].name!=adapters[i].name)changed=true;
    if(!changed && !adapters.empty())return;
    adapters=std::move(found); SendMessageW(selector,CB_RESETCONTENT,0,0);
    int selected=0;
    for(size_t i=0;i<adapters.size();++i) {
        auto text=wide(adapters[i].name+" · "+adapters[i].address);
        SendMessageW(selector,CB_ADDSTRING,0,(LPARAM)text.c_str());
        if(adapters[i].address==address)selected=int(i);
    }
    if(adapters.empty())SendMessageW(selector,CB_ADDSTRING,0,(LPARAM)tr(L"Conecte um adaptador Ethernet",L"Connect an Ethernet adapter"));
    SendMessageW(selector,CB_SETCURSEL,selected,0);
}
LRESULT CALLBACK proc(HWND window,UINT message,WPARAM w,LPARAM l) {
    switch(message) {
    case WM_CREATE: {
        dpi=GetDpiForWindow(window);
        auto control=[&](const wchar_t* type,const wchar_t* text,DWORD style,int id) {
            return CreateWindowW(type,text,WS_CHILD|WS_VISIBLE|style,0,0,0,0,window,(HMENU)(INT_PTR)id,nullptr,nullptr);
        };
        title=control(L"STATIC",L"CatLive Integration",SS_CENTER,0);
        caption=control(L"STATIC",tr(L"Adaptador Ethernet (RJ45)",L"Ethernet adapter (RJ45)"),0,0);
        selector=control(L"COMBOBOX",L"",WS_TABSTOP|CBS_DROPDOWNLIST|WS_VSCROLL,10);
        button=control(L"BUTTON",tr(L"Iniciar conexão",L"Start connection"),WS_TABSTOP|BS_PUSHBUTTON,11);
        label=control(L"STATIC",L"",SS_CENTER,0);
        layout(); refresh(); SetTimer(window,1,500,nullptr); return 0;
    }
    case WM_DPICHANGED: {
        dpi=HIWORD(w); auto rect=(RECT*)l;
        SetWindowPos(window,nullptr,rect->left,rect->top,rect->right-rect->left,rect->bottom-rect->top,SWP_NOZORDER|SWP_NOACTIVATE);
        layout(); return 0;
    }
    case WM_COMMAND:
        if(LOWORD(w)==11 && !operation.valid()) {
            const bool running=bridge->status()["running"];
            int index=int(SendMessage(selector,CB_GETCURSEL,0,0));
            if(!running && (index<0 || index>=int(adapters.size())))return 0;
            auto address=running?std::string():adapters[index].address;
            EnableWindow(button,FALSE); EnableWindow(selector,FALSE);
            operation=std::async(std::launch::async,[running,address] { if(running)bridge->stop();else bridge->start(address); });
            return 0;
        }
        break;
    case WM_TIMER: {
        if(operation.valid()) {
            if(operation.wait_for(std::chrono::seconds(0))!=std::future_status::ready)return 0;
            try { operation.get(); }
            catch(const std::exception& e) { MessageBoxW(window,wide(e.what()).c_str(),L"CatLive Integration",MB_OK|MB_ICONERROR); }
        }
        auto state=bridge->status(); bool running=state["running"];
        if(!running)refresh(); EnableWindow(selector,!running); EnableWindow(button,running||!adapters.empty());
        SetWindowTextW(button,running?tr(L"Encerrar conexão",L"Stop connection"):tr(L"Iniciar conexão",L"Start connection"));
        std::wstring text=tr(L"Escolha o adaptador usado para conectar ao CatLive.",L"Choose the adapter connected to the CatLive computer.");
        if(running) {
            text=state["connected"].get<bool>()?std::wstring(tr(L"Conectado: ",L"Connected: "))+wide(state["client"]):tr(L"Aguardando CatLive",L"Waiting for CatLive");
            text+=L"\n"+wide(state["address"])+tr(L" · porta ",L" · port ")+std::to_wstring(integration::defaultPort);
        }
        SetWindowTextW(label,text.c_str()); return 0;
    }
    case WM_CTLCOLORSTATIC:
        SetTextColor((HDC)w,RGB(235,235,235));SetBkColor((HDC)w,RGB(25,25,25));return (LRESULT)background;
    case WM_CLOSE:
        if(operation.valid())return 0;
        bridge->stop();DestroyWindow(window);return 0;
    case WM_DESTROY:
        DeleteObject(font);DeleteObject(titleFont);PostQuitMessage(0);return 0;
    }
    return DefWindowProcW(window,message,w,l);
}
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,LPWSTR,int show) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    bridge=std::make_unique<integration::Bridge>();
    background=CreateSolidBrush(RGB(25,25,25));
    WNDCLASSEXW cls{sizeof(cls)};cls.lpfnWndProc=proc;cls.hInstance=instance;cls.lpszClassName=L"CatLiveIntegration";
    cls.hCursor=LoadCursor(nullptr,IDC_ARROW);cls.hbrBackground=background;cls.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(101));
    RegisterClassExW(&cls);
    dpi=GetDpiForSystem(); RECT rect{0,0,px(540),px(320)};
    DWORD style=WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX;
    AdjustWindowRectExForDpi(&rect,style,FALSE,0,dpi);
    auto window=CreateWindowExW(0,cls.lpszClassName,L"CatLive Integration",style,CW_USEDEFAULT,CW_USEDEFAULT,rect.right-rect.left,rect.bottom-rect.top,nullptr,nullptr,instance,nullptr);
    if(!window)return 1;
    ShowWindow(window,show);MSG message;
    while(GetMessageW(&message,nullptr,0,0)>0)if(!IsDialogMessageW(window,&message)){TranslateMessage(&message);DispatchMessageW(&message);}
    DeleteObject(background);return 0;
}
