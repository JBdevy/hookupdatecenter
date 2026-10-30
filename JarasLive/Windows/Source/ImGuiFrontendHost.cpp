#include "ImGuiFrontendHost.h"
#include "ImGuiFrontendView.h"
#include <imgui.h>
#include <backends/imgui_impl_win32.h>
#include <backends/imgui_impl_dx11.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dxgi1_3.h>
#include <shellapi.h>
#include <wrl/client.h>
#include <nlohmann/json.hpp>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <deque>
#include <sstream>
#include <string_view>
#include <stdexcept>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

namespace catlive {
namespace {
using Microsoft::WRL::ComPtr;
constexpr size_t maximumPendingBytes = 32 * 1024 * 1024;
constexpr size_t maximumCommandBytes = 1024 * 1024;
constexpr size_t maximumDropBytes = maximumCommandBytes / 2; // Leave room for the resolved import command.
constexpr UINT maximumDropFiles = 1024;
constexpr UINT frameInterval = 16;
constexpr UINT renderMessage = WM_APP + 0x361;
constexpr wchar_t windowClass[] = L"CatLive.ImGuiFrontend";
std::string_view updateType(const std::string &json) {
    const auto key=json.find("\"type\"");if(key==std::string::npos)return {};
    const auto colon=json.find(':',key+6);if(colon==std::string::npos)return {};
    const auto begin=json.find('"',colon+1);if(begin==std::string::npos)return {};
    const auto end=json.find('"',begin+1);if(end==std::string::npos)return {};
    return std::string_view(json).substr(begin+1,end-begin-1);
}
std::string graphicsError(const char* operation, HRESULT code) {
    std::ostringstream result;
    result << operation << " (0x" << std::hex << static_cast<unsigned long>(code) << ')';
    return result.str();
}
bool deviceRemoved(HRESULT result) {
    return result == DXGI_ERROR_DEVICE_REMOVED || result == DXGI_ERROR_DEVICE_RESET ||
           result == DXGI_ERROR_DEVICE_HUNG || result == DXGI_ERROR_DRIVER_INTERNAL_ERROR;
}
struct CurrentContext {
    ImGuiContext* previous;
    ImGuiContext* selected;
    explicit CurrentContext(ImGuiContext* context) : previous(ImGui::GetCurrentContext()), selected(context) {
        ImGui::SetCurrentContext(context);
    }
    ~CurrentContext() {
        // A ready/command callback can destroy the selected host and context.
        // shutdown clears the current context in that case; never restore it.
        if (previous != selected || ImGui::GetCurrentContext() == selected)
            ImGui::SetCurrentContext(previous);
    }
};
struct DropHandle {
    HDROP value;
    ~DropHandle() { if (value) DragFinish(value); }
};
std::string fileDropEvent(HDROP drop, POINT point, bool shift) {
    const UINT count = DragQueryFileW(drop, 0xffffffffu, nullptr, 0);
    if (!count) return {};
    if (count > maximumDropFiles) throw std::invalid_argument("Drop at most 1024 files at a time.");
    auto paths = nlohmann::json::array();
    size_t pathBytes = 0;
    for (UINT index = 0; index < count; ++index) {
        const UINT length = DragQueryFileW(drop, index, nullptr, 0);
        if (!length || length > maximumDropBytes / sizeof(wchar_t))
            throw std::invalid_argument("The dropped file paths exceed the import limit.");
        // Query the complete name instead of truncating it to MAX_PATH.
        std::wstring wide(static_cast<size_t>(length) + 1, L'\0');
        if (DragQueryFileW(drop, index, wide.data(), length + 1) != length)
            throw std::invalid_argument("Cannot read a dropped file path. Please try again.");
        const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
            static_cast<int>(length), nullptr, 0, nullptr, nullptr);
        if (bytes <= 0) throw std::invalid_argument("A dropped file path contains invalid Unicode.");
        if (static_cast<size_t>(bytes) > maximumDropBytes - pathBytes)
            throw std::invalid_argument("The dropped file paths exceed the import limit.");
        std::string path(static_cast<size_t>(bytes), '\0');
        if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), static_cast<int>(length),
            path.data(), bytes, nullptr, nullptr) != bytes)
            throw std::invalid_argument("Cannot convert a dropped file path to Unicode.");
        pathBytes += path.size();
        paths.push_back(std::move(path));
    }
    auto event = nlohmann::json{{"type", "fileDrop"}, {"paths", std::move(paths)},
        {"x", point.x}, {"y", point.y}, {"shift", shift}}.dump();
    if (event.size() > maximumDropBytes)
        throw std::invalid_argument("The dropped file paths exceed the import limit.");
    return event;
}
std::vector<unsigned char> readFont(const std::wstring& path) {
    if (path.empty()) return {};
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return {};
    struct CloseFile { HANDLE value; ~CloseFile() { CloseHandle(value); } } closer{file};
    LARGE_INTEGER length{};
    if (!GetFileSizeEx(file, &length) || length.QuadPart <= 0 || length.QuadPart > 32 * 1024 * 1024)
        return {};
    std::vector<unsigned char> data(static_cast<size_t>(length.QuadPart));
    DWORD received = 0;
    if (!ReadFile(file, data.data(), static_cast<DWORD>(data.size()), &received, nullptr) || received != data.size())
        return {};
    return data;
}
} // namespace

struct ImGuiFrontendHost::State : std::enable_shared_from_this<State> {
    Options options;
    Callbacks callbacks;
    HWND window = nullptr;
    HWND nativeWindow = nullptr;
    UINT_PTR timer = 0;
    ImGuiContext* imgui = nullptr;
    std::unique_ptr<ImGuiFrontendView> view;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> deviceContext;
    ComPtr<IDXGISwapChain> swapChain;
    ComPtr<ID3D11RenderTargetView> target;
    std::vector<unsigned char> fontData;
    std::deque<std::string> incoming, outgoing;
    size_t incomingBytes = 0, outgoingBytes = 0;
    bool platformInitialized = false, rendererInitialized = false;
    bool initialized = false, closed = false, failed = false, inTick = false;
    bool showRequested = false, occluded = false, recovering = false, fullscreen = false;
    bool closeRequested = false;
    unsigned recoveryFailures = 0;
    UINT width = 0, height = 0;
    float scale = 1;
    ULONGLONG nextRender = 0, nextRecovery = 0;
    WINDOWPLACEMENT restoredPlacement{sizeof(WINDOWPLACEMENT)};
    LONG_PTR restoredStyle = 0, restoredExStyle = 0;
    std::string graphicsDiagnostic, fontDiagnostic;
    HANDLE frameReady=nullptr, pacerStop=nullptr, frameAcknowledged=nullptr;
    std::thread pacer;
    std::atomic<DWORD> pacingDelay{0};
    UINT_PTR pacingGeneration=0;
    std::array<double,1024> frameIntervals{};
    std::uint64_t framesPresented=0,intervalCount=0;
    double lastPresentation=0, renderMilliseconds=0;

    static double preciseTime() {return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
    void reportPerformance() {
        if(options.diagnosticsPath.empty()||intervalCount==0)return;
        auto intervals=frameIntervals;const auto count=static_cast<size_t>(std::min<std::uint64_t>(intervalCount,intervals.size()));
        std::sort(intervals.begin(),intervals.begin()+count);double total=0;for(size_t i=0;i<count;++i)total+=intervals[i];
        std::ostringstream json;json<<"{\"renderer\":\""<<(graphicsDiagnostic.empty()?"DirectX 11 hardware":"DirectX 11 WARP")
            <<"\",\"submittedFrames\":"<<framesPresented<<",\"submissionFPS\":"<<(total>0?count*1000/total:0)
            <<",\"medianPresentCallIntervalMs\":"<<intervals[count/2]<<",\"p95PresentCallIntervalMs\":"<<intervals[std::min(count-1,count*95/100)]
            <<",\"averageRenderMs\":"<<renderMilliseconds/framesPresented<<"}";
        const auto data=json.str();HANDLE file=CreateFileW(options.diagnosticsPath.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(file!=INVALID_HANDLE_VALUE){DWORD written=0;WriteFile(file,data.data(),static_cast<DWORD>(data.size()),&written,nullptr);CloseHandle(file);}
    }

    State(Options value, Callbacks actions) : options(std::move(value)), callbacks(std::move(actions)) {}
    ~State() { shutdown(); }

    static auto& timers() {
        static thread_local std::unordered_map<UINT_PTR, std::weak_ptr<State>> values;
        return values;
    }
    static void CALLBACK timerCallback(HWND, UINT, UINT_PTR id, DWORD) noexcept {
        const auto found = timers().find(id);
        if (found == timers().end()) return;
        auto owner = found->second.lock();
        if (!owner || owner->closed || owner->failed || owner->inTick) return;
        owner->inTick = true;
        struct Finish { State& owner; ~Finish() { owner.inTick = false; } } finish{*owner};
        try { owner->tick(); }
        catch (const std::exception& error) { owner->fail(error.what()); }
        catch (...) { owner->fail("Unexpected failure in the Win32/DirectX 11 interface."); }
    }
    void fail(std::string message) noexcept {
        if (closed || failed) return;
        failed = true;
        OutputDebugStringA(("CatLive ImGui: " + message + "\n").c_str());
        try {
            auto callback = callbacks.error;
            if (callback) callback(std::move(message));
        } catch (...) { OutputDebugStringA("CatLive ImGui error callback failed.\n"); }
    }
    void start() {
        // The HWND retains its creation DPI context. Restore the surrounding
        // message thread's context so other application windows keep theirs.
        struct RestoreDPI {
            DPI_AWARENESS_CONTEXT previous;
            ~RestoreDPI() { if (previous) SetThreadDpiAwarenessContext(previous); }
        } dpi{SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)};
        WNDCLASSEXW type{sizeof(WNDCLASSEXW)};
        type.style = CS_HREDRAW | CS_VREDRAW;
        type.lpfnWndProc = procedure;
        type.hInstance = GetModuleHandleW(nullptr);
        type.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
        type.hIcon = LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
        type.lpszClassName = windowClass;
        if (!RegisterClassExW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
            throw std::runtime_error("Cannot register the native interface window.");
        window = CreateWindowExW(0, windowClass, options.title.empty() ? L"CatLive" : options.title.c_str(),
            WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1280, 800, nullptr, nullptr, type.hInstance, this);
        if (!window) throw std::runtime_error("Cannot create the native interface window.");
        nativeWindow = window;
        DragAcceptFiles(window, TRUE);
        scale = std::clamp(float(GetDpiForWindow(nativeWindow)) / 96.f, .75f, 4.f);
        MONITORINFO monitor{sizeof(MONITORINFO)};
        if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
            RECT bounds{0, 0, int(1280 * scale), int(800 * scale)};
            AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, 0, GetDpiForWindow(window));
            const int workWidth = monitor.rcWork.right - monitor.rcWork.left;
            const int workHeight = monitor.rcWork.bottom - monitor.rcWork.top;
            const int initialWidth = std::min(int(bounds.right - bounds.left), workWidth);
            const int initialHeight = std::min(int(bounds.bottom - bounds.top), workHeight);
            SetWindowPos(window, nullptr, monitor.rcWork.left + (workWidth - initialWidth) / 2,
                monitor.rcWork.top + (workHeight - initialHeight) / 2, initialWidth, initialHeight,
                SWP_NOACTIVATE | SWP_NOZORDER);
        }
        timer = SetTimer(nullptr, 0, frameInterval, timerCallback);
        if (!timer) throw std::runtime_error("Cannot create the interface message-loop timer.");
        timers().emplace(timer, weak_from_this());
    }
    HRESULT createTarget() {
        ComPtr<ID3D11Texture2D> backBuffer;
        HRESULT result = swapChain->GetBuffer(0, IID_PPV_ARGS(backBuffer.GetAddressOf()));
        if (FAILED(result)) return result;
        return device->CreateRenderTargetView(backBuffer.Get(), nullptr, target.ReleaseAndGetAddressOf());
    }
    void stopPacer() noexcept {
        ++pacingGeneration;
        if(pacerStop)SetEvent(pacerStop);
        if(pacer.joinable())pacer.join();
        for(auto *handle:{&frameReady,&pacerStop,&frameAcknowledged})if(*handle){CloseHandle(*handle);*handle=nullptr;}
    }
    HRESULT startPacer() {
        ComPtr<IDXGISwapChain2> modern;
        HRESULT result=swapChain.As(&modern);if(FAILED(result))return result;
        result=modern->SetMaximumFrameLatency(1);if(FAILED(result))return result;
        frameReady=modern->GetFrameLatencyWaitableObject();
        pacerStop=CreateEventW(nullptr,TRUE,FALSE,nullptr);frameAcknowledged=CreateEventW(nullptr,FALSE,FALSE,nullptr);
        if(!frameReady||!pacerStop||!frameAcknowledged){result=HRESULT_FROM_WIN32(GetLastError());stopPacer();return FAILED(result)?result:E_FAIL;}
        const auto generation=++pacingGeneration;const auto targetWindow=nativeWindow;
        pacer=std::thread([this,generation,targetWindow] {
            const HANDLE ready[]{pacerStop,frameReady},done[]{pacerStop,frameAcknowledged};
            bool permit=false;
            for(;;) {
                const auto delay=pacingDelay.load(std::memory_order_relaxed);
                if(delay&&WaitForSingleObject(pacerStop,delay)==WAIT_OBJECT_0)return;
                if(!permit&&WaitForMultipleObjects(2,ready,FALSE,INFINITE)!=WAIT_OBJECT_0+1)return;
                permit=true;
                if(!PostMessageW(targetWindow,renderMessage,generation,0))return;
                if(WaitForMultipleObjects(2,done,FALSE,INFINITE)!=WAIT_OBJECT_0+1)return;
                // The DXGI handle is auto-reset. A skipped/occluded frame
                // retains its grant: no Present happened to signal it again.
                if(pacingDelay.load(std::memory_order_relaxed)==0)permit=false;
            }
        });
        return S_OK;
    }
    void releaseGraphics() noexcept {
        stopPacer();
        if (rendererInitialized) {
            ImGui_ImplDX11_Shutdown();
            rendererInitialized = false;
        }
        if (deviceContext) { deviceContext->OMSetRenderTargets(0, nullptr, nullptr); deviceContext->ClearState(); }
        target.Reset();
        swapChain.Reset();
        deviceContext.Reset();
        device.Reset();
        width = height = 0;
    }
    HRESULT createGraphics() {
        RECT bounds{};
        GetClientRect(nativeWindow, &bounds);
        DXGI_SWAP_CHAIN_DESC description{};
        description.BufferCount = 2;
        description.BufferDesc.Width = std::max<LONG>(1, bounds.right - bounds.left);
        description.BufferDesc.Height = std::max<LONG>(1, bounds.bottom - bounds.top);
        description.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        description.OutputWindow = nativeWindow;
        description.SampleDesc.Count = 1;
        description.Windowed = TRUE;
        description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        description.Flags=DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
        const D3D_FEATURE_LEVEL requested[] = {D3D_FEATURE_LEVEL_11_0};
        D3D_FEATURE_LEVEL supplied{};
        auto create = [&](D3D_DRIVER_TYPE driver) {
            return D3D11CreateDeviceAndSwapChain(nullptr, driver, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                requested, 1, D3D11_SDK_VERSION, &description, swapChain.ReleaseAndGetAddressOf(),
                device.ReleaseAndGetAddressOf(), &supplied, deviceContext.ReleaseAndGetAddressOf());
        };
        HRESULT result = create(D3D_DRIVER_TYPE_HARDWARE);
        if (FAILED(result)) {
            graphicsDiagnostic = graphicsError("Hardware DirectX 11 unavailable; using the WARP software renderer", result);
            OutputDebugStringA(("CatLive ImGui: " + graphicsDiagnostic + "\n").c_str());
            result = create(D3D_DRIVER_TYPE_WARP);
        } else graphicsDiagnostic.clear();
        if (FAILED(result)) return result;
        ComPtr<IDXGIFactory> factory;
        if (SUCCEEDED(swapChain->GetParent(IID_PPV_ARGS(factory.GetAddressOf()))))
            factory->MakeWindowAssociation(nativeWindow, DXGI_MWA_NO_ALT_ENTER);
        result = createTarget();
        if (FAILED(result)) return result;
        width = description.BufferDesc.Width;
        height = description.BufferDesc.Height;
        if (!ImGui_ImplDX11_Init(device.Get(), deviceContext.Get())) return E_FAIL;
        rendererInitialized = true;
        if (!ImGui_ImplDX11_CreateDeviceObjects()) return E_FAIL;
        return startPacer();
    }
    void initialize() {
        IMGUI_CHECKVERSION();
        auto* previous = ImGui::GetCurrentContext();
        imgui = ImGui::CreateContext();
        ImGui::SetCurrentContext(previous);
        if (!imgui) throw std::runtime_error("Cannot create the ImGui interface context.");
        CurrentContext current(imgui);
        auto& io = ImGui::GetIO();
        io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
        io.IniFilename = nullptr; // The view's layout is supplied by application state.
        io.LogFilename = nullptr;
        ImGui::StyleColorsDark();
        ImGui::GetStyle().ScaleAllSizes(scale);
        ImGui::GetStyle().FontScaleDpi = scale;
        ImGui::GetStyle().FontSizeBase = 16;
        fontData = readFont(options.fontPath);
        ImFontConfig font;
        font.FontDataOwnedByAtlas = false;
        if (fontData.empty() || !io.Fonts->AddFontFromMemoryTTF(fontData.data(), static_cast<int>(fontData.size()), 16, &font)) {
            fontDiagnostic = "Inter font unavailable; using the built-in interface font.";
            OutputDebugStringA(("CatLive ImGui: " + fontDiagnostic + "\n").c_str());
            io.Fonts->AddFontDefault();
        }
        if (!ImGui_ImplWin32_Init(window)) throw std::runtime_error("Cannot initialize ImGui Win32 input.");
        platformInitialized = true;
        const HRESULT result = createGraphics();
        if (FAILED(result)) throw std::runtime_error(graphicsError("Cannot initialize DirectX 11 hardware or WARP", result));
        std::weak_ptr<State> weak = shared_from_this();
        view = std::make_unique<ImGuiFrontendView>([weak](std::string json) {
            if (auto owner = weak.lock()) owner->enqueueCommand(std::move(json));
        });
        initialized = true;
        if (showRequested) reveal();
        // No callback is made by the constructor, and no ImGui frame is active.
        auto callback = callbacks.ready;
        if (callback) callback();
    }
    void enqueueCommand(std::string json) {
        if (closed || failed) return;
        if (json.size() > maximumCommandBytes || outgoingBytes + json.size() > maximumPendingBytes)
            throw std::runtime_error("The interface command queue exceeded its limit.");
        outgoingBytes += json.size();
        outgoing.push_back(std::move(json));
    }
    void post(const std::string& json) {
        if (closed || failed) return;
        const auto type=updateType(json);
        if(type=="telemetry"||type=="snapshot") {
            for(auto it=incoming.begin();it!=incoming.end();) {
                if(updateType(*it)==type){incomingBytes-=it->size();it=incoming.erase(it);}
                else ++it;
            }
        }
        if (incomingBytes + json.size() > maximumPendingBytes) {
            fail("The interface update queue exceeded its limit.");
            return;
        }
        incomingBytes += json.size();
        incoming.push_back(json);
    }
    void dropNotice(const char* message) {
        const auto notice = nlohmann::json{{"type", "notice"}, {"title", "Import files"}, {"message", message}}.dump();
        if (notice.size() <= maximumPendingBytes - incomingBytes) post(notice);
        else OutputDebugStringA("CatLive ImGui: file drop rejected because the update queue is full.\n");
    }
    void filesDropped(HDROP drop) {
        if (!drop || !initialized || closed || failed || !window || !IsWindowEnabled(window)) return;
        POINT point{};
        RECT bounds{};
        if (!DragQueryPoint(drop, &point) || !GetClientRect(window, &bounds) || !PtInRect(&bounds, point)) return;
        try {
            // The PMv2 HWND and ImGui both use client pixels; do not apply DPI scaling.
            auto event = fileDropEvent(drop, point, (GetKeyState(VK_SHIFT) & 0x8000) != 0);
            if (event.empty()) return;
            if (event.size() > maximumPendingBytes - incomingBytes) {
                dropNotice("The interface is busy. Please try dropping the files again.");
                return;
            }
            // tick delivers this event outside any ImGui frame. Commands emitted
            // by the view still pass through the usual after-frame command queue.
            post(event);
        } catch (const std::invalid_argument& error) { dropNotice(error.what()); }
    }
    void reveal() {
        if (!window || closed) return;
        showRequested = true;
        if (!initialized) return;
        ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
        SetForegroundWindow(window);
        nextRender = 0;
    }
    void toggleFullscreen() {
        if (!fullscreen) {
            MONITORINFO monitor{sizeof(MONITORINFO)};
            if (!GetWindowPlacement(window, &restoredPlacement) ||
                !GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) return;
            restoredStyle = GetWindowLongPtrW(window, GWL_STYLE);
            restoredExStyle = GetWindowLongPtrW(window, GWL_EXSTYLE);
            SetWindowLongPtrW(window, GWL_STYLE, restoredStyle & ~LONG_PTR(WS_OVERLAPPEDWINDOW));
            SetWindowLongPtrW(window, GWL_EXSTYLE, restoredExStyle &
                ~LONG_PTR(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE));
            fullscreen = true;
            SetWindowPos(window, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                monitor.rcMonitor.right - monitor.rcMonitor.left, monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
        } else {
            fullscreen = false;
            SetWindowLongPtrW(window, GWL_STYLE, restoredStyle);
            SetWindowLongPtrW(window, GWL_EXSTYLE, restoredExStyle);
            SetWindowPlacement(window, &restoredPlacement);
            SetWindowPos(window, nullptr, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        }
        nextRender = 0;
    }
    static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) noexcept {
        // Ownership transfers with WM_DROPFILES, including drops ignored while
        // closing or while no live State remains attached to the HWND.
        DropHandle drop{message == WM_DROPFILES ? reinterpret_cast<HDROP>(wparam) : nullptr};
        auto* self = reinterpret_cast<State*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (message == WM_NCCREATE) {
            self = static_cast<State*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
            self->window = self->nativeWindow = window;
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        }
        if (!self) return message == WM_DROPFILES ? 0 : DefWindowProcW(window, message, wparam, lparam);
        auto owner = self->weak_from_this().lock();
        if (!owner) return message == WM_DROPFILES ? 0 : DefWindowProcW(window, message, wparam, lparam);
        try {
            switch (message) {
            case WM_DROPFILES: self->filesDropped(drop.value); return 0;
            case renderMessage: {
                if(wparam!=self->pacingGeneration)return 0;
                const auto previousFrames=self->framesPresented;
                if(!self->inTick&&!self->closed&&!self->failed) {
                    self->inTick=true;
                    struct Finish{State &state;~Finish(){state.inTick=false;}} finish{*self};
                    try{self->tick(true);}catch(const std::exception &error){self->fail(error.what());}catch(...){self->fail("Unexpected render failure.");}
                }
                if(wparam==self->pacingGeneration&&self->frameAcknowledged) {
                    self->pacingDelay.store(self->framesPresented==previousFrames?100:0,std::memory_order_relaxed);
                    SetEvent(self->frameAcknowledged);
                }
                return 0;
            }
            case WM_CLOSE: self->closeRequested = true; return 0;
            case WM_KEYDOWN: case WM_SYSKEYDOWN:
                if (wparam == VK_F11 && (GetKeyState(VK_SHIFT) & 0x8000)) {
                    if (!(lparam & (LPARAM(1) << 30))) self->toggleFullscreen();
                    return 0;
                }
                break;
            case WM_SIZE: self->nextRender = 0; return 0;
            case WM_DPICHANGED: {
                RECT bounds = *reinterpret_cast<RECT*>(lparam);
                if (self->fullscreen) {
                    MONITORINFO monitor{sizeof(MONITORINFO)};
                    if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) bounds = monitor.rcMonitor;
                }
                SetWindowPos(window, nullptr, bounds.left, bounds.top, bounds.right - bounds.left,
                    bounds.bottom - bounds.top, SWP_NOACTIVATE | SWP_NOZORDER);
                self->nextRender = 0;
                return 0;
            }
            case WM_GETMINMAXINFO: {
                auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
                const UINT dpi = GetDpiForWindow(window);
                limits->ptMinTrackSize = {MulDiv(800, int(dpi ? dpi : 96), 96), MulDiv(500, int(dpi ? dpi : 96), 96)};
                return 0;
            }
            // Keep native Alt+Space/title-bar system menus and their standard
            // move, resize, minimize and close actions in DefWindowProc.
            case WM_SYSCOMMAND: return DefWindowProcW(window, message, wparam, lparam);
            case WM_PAINT: {
                PAINTSTRUCT paint{}; BeginPaint(window, &paint); EndPaint(window, &paint);
                self->nextRender = 0;
                return 0;
            }
            case WM_ERASEBKGND: return 1;
            case WM_NCDESTROY:
                SetWindowLongPtrW(window, GWLP_USERDATA, 0);
                self->window = self->nativeWindow = nullptr;
                return DefWindowProcW(window, message, wparam, lparam);
            default: break;
            }
            if (self->platformInitialized && !self->closed) {
                CurrentContext current(self->imgui);
                if (ImGui_ImplWin32_WndProcHandler(window, message, wparam, lparam)) return 1;
            }
        } catch (const std::exception& error) { self->fail(error.what()); }
        catch (...) { self->fail("Unexpected error in the native interface window."); }
        return message == WM_DROPFILES ? 0 : DefWindowProcW(window, message, wparam, lparam);
    }
    void updateScale() {
        const float next = std::clamp(float(GetDpiForWindow(nativeWindow)) / 96.f, .75f, 4.f);
        if (std::abs(next - scale) < .01f) return;
        const float ratio = next / scale;
        ImGui::GetStyle().ScaleAllSizes(ratio);
        ImGui::GetStyle().FontScaleDpi = next;
        scale = next;
    }
    void graphicsFailure(HRESULT result, const char* operation) {
        if (!deviceRemoved(result)) throw std::runtime_error(graphicsError(operation, result));
        const HRESULT reason = device ? device->GetDeviceRemovedReason() : result;
        OutputDebugStringA((graphicsError(operation, reason) + "; rebuilding the DirectX 11 renderer.\n").c_str());
        releaseGraphics();
        recovering = true;
        nextRecovery = GetTickCount64() + 250;
        recoveryFailures = 0;
    }
    bool recoverGraphics() {
        if (!recovering) return true;
        if (GetTickCount64() < nextRecovery) return false;
        const HRESULT result = createGraphics();
        if (FAILED(result)) {
            releaseGraphics();
            if (++recoveryFailures >= 3)
                throw std::runtime_error(graphicsError("DirectX 11 recovery failed after three attempts", result));
            nextRecovery = GetTickCount64() + 1000;
            return false;
        }
        recovering = false;
        occluded = false;
        nextRender = 0;
        return false; // The new swap chain's pacer grants its first frame.
    }
    void diagnosticOverlay() {
        if (graphicsDiagnostic.empty() && fontDiagnostic.empty()) return;
        const auto* viewport = ImGui::GetMainViewport();
        ImGui::SetNextWindowPos(ImVec2(viewport->WorkPos.x + 12 * scale,
            viewport->WorkPos.y + viewport->WorkSize.y - 12 * scale), ImGuiCond_Always, ImVec2(0, 1));
        ImGui::SetNextWindowBgAlpha(.94f);
        const ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
            ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav;
        if (ImGui::Begin("Presentation diagnostics###CatLiveRendererStatus", nullptr, flags)) {
            ImGui::PushTextWrapPos(620 * scale);
            if (!graphicsDiagnostic.empty()) ImGui::TextWrapped("%s", graphicsDiagnostic.c_str());
            if (!fontDiagnostic.empty()) ImGui::TextWrapped("%s", fontDiagnostic.c_str());
            ImGui::PopTextWrapPos();
        }
        ImGui::End();
    }
    void render() {
        if (!window || !showRequested || !IsWindowVisible(window) || IsIconic(window)) return;
        const auto now = GetTickCount64();
        if (now < nextRender || !recoverGraphics()) return;
        updateScale();
        if (occluded) {
            const HRESULT result = swapChain->Present(0, DXGI_PRESENT_TEST);
            if (result == DXGI_STATUS_OCCLUDED) { nextRender = now + 250; return; }
            if (FAILED(result)) { graphicsFailure(result, "Cannot restore the presentation surface"); return; }
            occluded = false;
        }
        RECT bounds{};
        GetClientRect(nativeWindow, &bounds);
        const UINT nextWidth = static_cast<UINT>(std::max<LONG>(0, bounds.right - bounds.left));
        const UINT nextHeight = static_cast<UINT>(std::max<LONG>(0, bounds.bottom - bounds.top));
        if (!nextWidth || !nextHeight) return;
        if (width != nextWidth || height != nextHeight) {
            deviceContext->OMSetRenderTargets(0, nullptr, nullptr);
            target.Reset();
            HRESULT result = swapChain->ResizeBuffers(0, nextWidth, nextHeight, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
            if (SUCCEEDED(result)) result = createTarget();
            if (FAILED(result)) { graphicsFailure(result, "Cannot resize the presentation surface"); return; }
            width = nextWidth; height = nextHeight;
        }
        ImGui_ImplDX11_NewFrame();
        const double renderStarted=preciseTime();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();
        try {
            view->render();
            diagnosticOverlay();
            ImGui::Render();
        } catch (...) {
            ImGui::EndFrame();
            throw;
        }
        ID3D11RenderTargetView* output = target.Get();
        deviceContext->OMSetRenderTargets(1, &output, nullptr);
        const float clear[] = {.035f, .045f, .055f, 1};
        deviceContext->ClearRenderTargetView(output, clear);
        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        const auto elapsedRender=(preciseTime()-renderStarted)*1000;
        const HRESULT result = swapChain->Present(1, 0);
        if (FAILED(result)) { graphicsFailure(result, "DirectX 11 presentation failed"); return; }
        occluded = result == DXGI_STATUS_OCCLUDED;
        if(occluded){lastPresentation=0;nextRender=GetTickCount64()+250;return;}
        renderMilliseconds+=elapsedRender;
        const auto presentedAt=preciseTime();
        if(lastPresentation>0)frameIntervals[(intervalCount++)%frameIntervals.size()]=(presentedAt-lastPresentation)*1000;
        lastPresentation=presentedAt;++framesPresented;
        if(framesPresented%120==0)reportPerformance();
        nextRender = occluded ? GetTickCount64() + 250 : 0;
    }
    void tick(bool frameRequest=false) {
        if (!initialized) { initialize(); if (closed || failed) return; }
        CurrentContext current(imgui);
        for (unsigned count = 0; count < 8 && !incoming.empty(); ++count) {
            auto json = std::move(incoming.front()); incoming.pop_front();
            incomingBytes -= json.size();
            view->receive(json);
        }
        if(frameRequest||!frameReady||recovering)render();
        // The view may open native modal dialogs or trigger owner destruction.
        // Dispatch only after the frame ends, and keep State alive in the timer.
        if (closeRequested) {
            closeRequested = false;
            auto callback = callbacks.closeRequested;
            if (callback) callback();
            if (closed || failed) return;
        }
        for (unsigned count = 0; count < 8 && !outgoing.empty(); ++count) {
            auto json = std::move(outgoing.front()); outgoing.pop_front();
            outgoingBytes -= json.size();
            auto callback = callbacks.message;
            if (callback) callback(std::move(json));
            if (closed || failed) return;
        }
    }
    void shutdown() noexcept {
        if (closed) return;
        try{reportPerformance();}catch(...){}
        closed = true;
        if (timer) { KillTimer(nullptr, timer); timers().erase(timer); timer = 0; }
        auto* previous = ImGui::GetCurrentContext();
        if (imgui) ImGui::SetCurrentContext(imgui);
        view.reset();
        releaseGraphics();
        if (platformInitialized) { ImGui_ImplWin32_Shutdown(); platformInitialized = false; }
        if (imgui) {
            auto* destroyed = imgui;
            ImGui::DestroyContext(imgui); imgui = nullptr;
            ImGui::SetCurrentContext(previous == destroyed ? nullptr : previous);
        }
        fontData.clear();
        if (window) { DragAcceptFiles(window, FALSE); DestroyWindow(window); window = nullptr; }
        nativeWindow = nullptr;
        incoming.clear(); outgoing.clear();
        incomingBytes = outgoingBytes = 0;
        callbacks = {};
    }
};

ImGuiFrontendHost::ImGuiFrontendHost(Options options, Callbacks callbacks)
    : state(std::make_shared<State>(std::move(options), std::move(callbacks))) { state->start(); }
ImGuiFrontendHost::~ImGuiFrontendHost() { state->shutdown(); }
void ImGuiFrontendHost::postJSON(const std::string& json) { state->post(json); }
void ImGuiFrontendHost::show() { state->reveal(); }
void ImGuiFrontendHost::close() { state->shutdown(); }
void ImGuiFrontendHost::restart() {
    auto options=state->options;auto callbacks=state->callbacks;
    state->shutdown();
    state=std::make_shared<State>(std::move(options),std::move(callbacks));
    state->start();
}
HWND ImGuiFrontendHost::handle() const noexcept { return state->nativeWindow; }
} // namespace catlive
