#include "NativeFrontendHost.h"
#include <objbase.h>
#include <wrl.h>
#include <WebView2.h>
#include <algorithm>
#include <deque>
#include <filesystem>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace catlive {
namespace {
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
constexpr wchar_t origin[] = L"https://catlive.local/";
constexpr wchar_t home[] = L"https://catlive.local/app.html";
constexpr wchar_t windowClass[] = L"CatLive.NativeFrontend";
constexpr size_t maximumRequestCharacters = 1024 * 1024;
constexpr size_t maximumPendingBytes = 32 * 1024 * 1024;
constexpr UINT dispatchMessage = WM_APP + 117;

bool localURL(const wchar_t* url) {
    return url != nullptr && std::wstring(url).rfind(origin, 0) == 0;
}
std::string utf8(const wchar_t* value) {
    if (!value || !*value) return {};
    const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
    if (count <= 1) return {};
    std::string result(static_cast<size_t>(count), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result.data(), count, nullptr, nullptr);
    result.pop_back();
    return result;
}
std::wstring wide(const std::string& value) {
    if (value.empty()) return {};
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (count <= 0) return {};
    std::wstring result(static_cast<size_t>(count), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), count);
    return result;
}
std::string failure(const char* operation, HRESULT code) {
    std::ostringstream text;
    text << operation << " (0x" << std::hex << static_cast<unsigned long>(code) << ")";
    return text.str();
}
struct CoTaskString {
    LPWSTR value = nullptr;
    ~CoTaskString() { CoTaskMemFree(value); }
};
}

struct NativeFrontendHost::State : std::enable_shared_from_this<State> {
    Options options;
    Callbacks callbacks;
    HWND window = nullptr;
    ComPtr<ICoreWebView2Environment> environment;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> web;
    bool apartment = false, closed = false, loaded = false, failed = false, wasShown = false, startMaximized = false;
    std::deque<std::string> pending;
    std::deque<std::string> incoming;
    size_t pendingBytes = 0;

    State(Options value, Callbacks actions) : options(std::move(value)), callbacks(std::move(actions)) {}
    ~State() { shutdown(); if (apartment) CoUninitialize(); }

    std::wstring placementFile() const { return (std::filesystem::path(options.userDataDirectory) / L"window.ini").wstring(); }
    void savePlacement() const {
        if (!window) return;
        WINDOWPLACEMENT placement{sizeof(WINDOWPLACEMENT)};
        if (!GetWindowPlacement(window, &placement)) return;
        const auto file = placementFile();
        const auto put = [&file](const wchar_t* key, int value) {
            WritePrivateProfileStringW(L"window", key, std::to_wstring(value).c_str(), file.c_str());
        };
        put(L"left", placement.rcNormalPosition.left); put(L"top", placement.rcNormalPosition.top);
        put(L"width", placement.rcNormalPosition.right - placement.rcNormalPosition.left);
        put(L"height", placement.rcNormalPosition.bottom - placement.rcNormalPosition.top);
        put(L"dpi", static_cast<int>(GetDpiForWindow(window)));
        put(L"maximized", placement.showCmd == SW_SHOWMAXIMIZED ? 1 : 0);
    }
    void restorePlacement() {
        const auto file = placementFile();
        const auto get = [&file](const wchar_t* key, int fallback) {
            return static_cast<int>(GetPrivateProfileIntW(L"window", key, fallback, file.c_str()));
        };
        const int savedWidth = get(L"width", 0), savedHeight = get(L"height", 0);
        if (savedWidth < 200 || savedHeight < 200) return;
        RECT bounds{get(L"left", 0), get(L"top", 0), 0, 0};
        bounds.right = bounds.left + std::min(savedWidth, 16384);
        bounds.bottom = bounds.top + std::min(savedHeight, 16384);
        MONITORINFO monitor{sizeof(MONITORINFO)};
        if (!GetMonitorInfoW(MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST), &monitor)) return;
        const auto dpi = static_cast<int>(GetDpiForWindow(window));
        const auto previousDPI = std::clamp(get(L"dpi", dpi), 48, 768);
        const auto width = std::min(MulDiv(std::max(800, savedWidth), dpi, previousDPI), static_cast<int>(monitor.rcWork.right - monitor.rcWork.left));
        const auto height = std::min(MulDiv(std::max(500, savedHeight), dpi, previousDPI), static_cast<int>(monitor.rcWork.bottom - monitor.rcWork.top));
        const auto left = std::clamp(bounds.left, monitor.rcWork.left, monitor.rcWork.right - width);
        const auto top = std::clamp(bounds.top, monitor.rcWork.top, monitor.rcWork.bottom - height);
        SetWindowPos(window, nullptr, left, top, width, height, SWP_NOACTIVATE | SWP_NOZORDER);
        startMaximized = get(L"maximized", 0) != 0;
    }

    void report(const char* operation, HRESULT code) {
        if (closed || failed) return;
        failed = true;
        if (callbacks.error) callbacks.error(failure(operation, code));
    }
    void resize() {
        if (!window || !controller) return;
        RECT bounds{};
        GetClientRect(window, &bounds);
        controller->put_Bounds(bounds);
        controller->NotifyParentWindowPositionChanged();
    }
    static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
        auto* self = reinterpret_cast<State*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (message == WM_NCCREATE) {
            self = static_cast<State*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
            self->window = window;
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        }
        if (!self) return DefWindowProcW(window, message, wparam, lparam);
        switch (message) {
        case dispatchMessage: {
            if (self->closed || self->incoming.empty()) return 0;
            auto json = std::move(self->incoming.front());
            self->incoming.pop_front();
            // Commands can open a native file dialog or close this window.
            // Never do that reentrantly inside a WebView2 COM event callback.
            if (self->callbacks.message) self->callbacks.message(std::move(json));
            return 0;
        }
        case WM_CLOSE:
            if (self->callbacks.closeRequested) self->callbacks.closeRequested();
            return 0;
        case WM_SIZE:
        case WM_MOVE:
            self->resize(); return 0;
        case WM_DPICHANGED: {
            const auto* bounds = reinterpret_cast<RECT*>(lparam);
            SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
                         bounds->bottom - bounds->top, SWP_NOACTIVATE | SWP_NOZORDER);
            self->resize(); return 0;
        }
        case WM_SETFOCUS:
            if (self->controller) self->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
            return 0;
        case WM_GETMINMAXINFO: {
            auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
            const auto dpi = GetDpiForWindow(window);
            limits->ptMinTrackSize = {MulDiv(800, static_cast<int>(dpi), 96), MulDiv(500, static_cast<int>(dpi), 96)};
            return 0;
        }
        case WM_EXITSIZEMOVE:
            self->savePlacement(); return 0;
        case WM_NCDESTROY:
            SetWindowLongPtrW(window, GWLP_USERDATA, 0);
            self->window = nullptr;
            break;
        default: break;
        }
        return DefWindowProcW(window, message, wparam, lparam);
    }
    void start() {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (FAILED(com)) { report("Cannot initialize the Windows presentation thread", com); return; }
        apartment = true;
        if (!std::filesystem::is_regular_file(std::filesystem::path(options.assetDirectory) / L"app.html")) {
            report("CatLive interface files are missing", HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)); return;
        }
        std::error_code directoryError;
        std::filesystem::create_directories(options.userDataDirectory, directoryError);
        if (directoryError) { report("Cannot create the CatLive interface cache", HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)); return; }
        const auto instance = GetModuleHandleW(nullptr);
        WNDCLASSEXW type{sizeof(WNDCLASSEXW)};
        type.style = CS_HREDRAW | CS_VREDRAW;
        type.lpfnWndProc = procedure;
        type.hInstance = instance;
        type.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
        type.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
        type.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
        type.lpszClassName = windowClass;
        if (!RegisterClassExW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
            report("Cannot create the CatLive window class", HRESULT_FROM_WIN32(GetLastError())); return;
        }
        window = CreateWindowExW(WS_EX_APPWINDOW, windowClass, options.title.c_str(), WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT, CW_USEDEFAULT, 1280, 800, nullptr, nullptr, instance, this);
        if (!window) { report("Cannot create the CatLive window", HRESULT_FROM_WIN32(GetLastError())); return; }
        restorePlacement();
        const std::weak_ptr<State> weak = shared_from_this();
        const auto result = CreateCoreWebView2EnvironmentWithOptions(nullptr, options.userDataDirectory.c_str(), nullptr,
            Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>([weak](HRESULT code, ICoreWebView2Environment* value) -> HRESULT {
                auto self = weak.lock(); if (!self || self->closed) return S_OK;
                if (FAILED(code) || !value) { self->report("Microsoft Edge WebView2 Runtime is unavailable", FAILED(code) ? code : E_FAIL); return S_OK; }
                self->environment = value;
                const auto created = value->CreateCoreWebView2Controller(self->window,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>([weak](HRESULT status, ICoreWebView2Controller* host) -> HRESULT {
                        auto live = weak.lock(); if (!live || live->closed) { if (host) host->Close(); return S_OK; }
                        if (FAILED(status) || !host) { live->report("Cannot initialize the CatLive interface", FAILED(status) ? status : E_FAIL); return S_OK; }
                        live->controller = host;
                        host->get_CoreWebView2(&live->web);
                        if (!live->web) { live->report("Cannot access the CatLive interface", E_FAIL); return S_OK; }
                        live->configure(); return S_OK;
                    }).Get());
                if (FAILED(created)) self->report("Cannot create the CatLive interface", created);
                return S_OK;
            }).Get());
        if (FAILED(result)) report("Microsoft Edge WebView2 Runtime is unavailable", result);
    }
    void configure() {
        ComPtr<ICoreWebView2_3> mapped;
        if (FAILED(web.As(&mapped))) { report("The WebView2 Runtime must be updated", E_NOINTERFACE); return; }
        const auto mapping = mapped->SetVirtualHostNameToFolderMapping(L"catlive.local", options.assetDirectory.c_str(), COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY);
        if (FAILED(mapping)) { report("Cannot load local CatLive interface files", mapping); return; }
        ComPtr<ICoreWebView2Settings> settings;
        if (SUCCEEDED(web->get_Settings(&settings))) {
            settings->put_IsWebMessageEnabled(TRUE);
            settings->put_AreDefaultContextMenusEnabled(FALSE);
            settings->put_AreDefaultScriptDialogsEnabled(FALSE);
            settings->put_AreDevToolsEnabled(FALSE);
            settings->put_IsStatusBarEnabled(FALSE);
            settings->put_IsZoomControlEnabled(FALSE);
            settings->put_AreHostObjectsAllowed(FALSE);
            ComPtr<ICoreWebView2Settings3> extras;
            if (SUCCEEDED(settings.As(&extras))) extras->put_AreBrowserAcceleratorKeysEnabled(FALSE);
        }
        ComPtr<ICoreWebView2Controller2> colours;
        if (SUCCEEDED(controller.As(&colours))) colours->put_DefaultBackgroundColor({255, 20, 20, 20});
        const std::weak_ptr<State> weak = shared_from_this();
        EventRegistrationToken token{};
        web->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>([weak](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            const auto self = weak.lock();
            CoTaskString uri; args->get_Uri(&uri.value);
            if (!self || self->closed || !localURL(uri.value)) args->put_Cancel(TRUE);
            return S_OK;
        }).Get(), &token);
        web->add_FrameNavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>([](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            args->put_Cancel(TRUE); return S_OK;
        }).Get(), &token);
        web->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>([](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
            args->put_Handled(TRUE); return S_OK;
        }).Get(), &token);
        web->add_PermissionRequested(Callback<ICoreWebView2PermissionRequestedEventHandler>([](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
            args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY); return S_OK;
        }).Get(), &token);
        web->AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
        web->add_WebResourceRequested(Callback<ICoreWebView2WebResourceRequestedEventHandler>([weak](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
            const auto self = weak.lock(); if (!self || self->closed) return S_OK;
            ComPtr<ICoreWebView2WebResourceRequest> request;
            if (FAILED(args->get_Request(&request))) return S_OK;
            CoTaskString uri; request->get_Uri(&uri.value);
            if (!localURL(uri.value)) {
                ComPtr<ICoreWebView2WebResourceResponse> response;
                self->environment->CreateWebResourceResponse(nullptr, 403, L"Local interface only",
                    L"Content-Type: text/plain\r\nAccess-Control-Allow-Origin: https://catlive.local", &response);
                args->put_Response(response.Get());
            }
            return S_OK;
        }).Get(), &token);
        ComPtr<ICoreWebView2_4> downloads;
        if (SUCCEEDED(web.As(&downloads))) downloads->add_DownloadStarting(Callback<ICoreWebView2DownloadStartingEventHandler>([](ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
            args->put_Cancel(TRUE); return S_OK;
        }).Get(), &token);
        web->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>([weak](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
            const auto self = weak.lock(); if (!self || self->closed) return S_OK;
            CoTaskString source; args->get_Source(&source.value);
            if (!localURL(source.value)) return S_OK;
            CoTaskString json;
            if (FAILED(args->get_WebMessageAsJson(&json.value)) || !json.value || wcsnlen_s(json.value, maximumRequestCharacters + 1) > maximumRequestCharacters) return S_OK;
            if (self->incoming.size() < 64 && self->window) {
                self->incoming.push_back(utf8(json.value));
                PostMessageW(self->window, dispatchMessage, 0, 0);
            }
            return S_OK;
        }).Get(), &token);
        web->add_NavigationCompleted(Callback<ICoreWebView2NavigationCompletedEventHandler>([weak](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
            const auto self = weak.lock(); if (!self || self->closed) return S_OK;
            BOOL success = FALSE; args->get_IsSuccess(&success);
            if (!success) {
                if (!self->loaded) self->report("Cannot open the local CatLive interface", E_FAIL);
                return S_OK;
            }
            self->loaded = true;
            auto queued = std::move(self->pending); self->pending.clear(); self->pendingBytes = 0;
            for (const auto& message : queued) self->post(message);
            if (self->callbacks.ready) self->callbacks.ready();
            return S_OK;
        }).Get(), &token);
        resize();
        const auto result = web->Navigate(home);
        if (FAILED(result)) report("Cannot open the local CatLive interface", result);
    }
    void post(const std::string& json) {
        if (closed || failed || json.empty() || json.size() > maximumPendingBytes) return;
        if (!loaded || !web) {
            while (!pending.empty() && (pending.size() >= 64 || pendingBytes + json.size() > maximumPendingBytes)) {
                pendingBytes -= pending.front().size(); pending.pop_front();
            }
            pending.push_back(json); pendingBytes += json.size(); return;
        }
        const auto value = wide(json);
        if (!value.empty()) web->PostWebMessageAsJson(value.c_str());
    }
    void shutdown() {
        if (closed) return;
        if (wasShown) savePlacement();
        closed = true; callbacks = {}; pending.clear(); incoming.clear(); pendingBytes = 0;
        if (controller) controller->Close();
        web.Reset(); controller.Reset(); environment.Reset();
        if (window) { auto handle = window; DestroyWindow(handle); window = nullptr; }
    }
};

NativeFrontendHost::NativeFrontendHost(Options options, Callbacks callbacks)
    : state(std::make_shared<State>(std::move(options), std::move(callbacks))) { state->start(); }
NativeFrontendHost::~NativeFrontendHost() { state->shutdown(); }
void NativeFrontendHost::postJSON(const std::string& json) { state->post(json); }
void NativeFrontendHost::show() {
    if (!state->window || state->closed) return;
    const int mode = IsIconic(state->window) ? SW_RESTORE : (!state->wasShown && state->startMaximized ? SW_SHOWMAXIMIZED : SW_SHOW);
    state->wasShown = true;
    ShowWindow(state->window, mode);
    SetForegroundWindow(state->window);
}
void NativeFrontendHost::close() { state->shutdown(); }
HWND NativeFrontendHost::handle() const noexcept { return state->window; }
} // namespace catlive
