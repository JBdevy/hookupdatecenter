#include "NativeFrontendHost.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

// Runs the real HWND and installed WebView2 Runtime, without JUCE or any audio
// engine. Verifies local assets, both JSON directions, rejected network fetch,
// and the close-request handshake instead of destroying a dirty project window.
int main() {
    using catlive::NativeFrontendHost;
    const auto root = std::filesystem::temp_directory_path() / (L"CatLive-Frontend-Probe-" + std::to_wstring(GetCurrentProcessId()));
    const auto assets = root / L"assets";
    std::filesystem::create_directories(assets);
    std::ofstream(assets / "local.json") << "{\"local\":true}";
    std::ofstream(assets / "app.html") << R"HTML(<!doctype html><meta charset="utf-8"><title>CatLive frontend test</title>
<script>
window.chrome.webview.addEventListener('message', async event => {
  if (event.data.probe !== 'native-to-web') return;
  try {
    const local = await (await fetch('./local.json')).json();
    let networkBlocked = false;
    try { const response = await fetch('https://example.invalid/catlive-probe'); networkBlocked = response.status === 403; }
    catch { networkBlocked = false; }
    window.chrome.webview.postMessage({type:'probe',ok:local.local && networkBlocked && location.href === 'https://catlive.local/app.html'});
  } catch (error) { window.chrome.webview.postMessage({type:'probe',ok:false,error:String(error)}); }
});
</script>)HTML";
    int result = 1;
    bool complete = false, closeRequested = false;
    NativeFrontendHost* live = nullptr;
    NativeFrontendHost::Callbacks callbacks;
    callbacks.message = [&](std::string message) {
        if (message.find("\"ok\":true") == std::string::npos) { std::cerr << message << '\n'; complete = true; return; }
        SendMessageW(live->handle(), WM_CLOSE, 0, 0);
        if (!closeRequested || !IsWindow(live->handle())) { std::cerr << "WM_CLOSE bypassed confirmation\n"; complete = true; return; }
        result = 0; complete = true;
    };
    callbacks.ready = [&] { live->show(); live->postJSON(R"({"probe":"native-to-web"})"); };
    callbacks.closeRequested = [&] { closeRequested = true; };
    callbacks.error = [&](std::string error) { std::cerr << error << '\n'; complete = true; };
    {
        NativeFrontendHost host({assets.wstring(), (root / L"cache").wstring(), L"CatLive frontend integration test"}, std::move(callbacks));
        live = &host;
        const auto started = GetTickCount64();
        while (!complete && GetTickCount64() - started < 20000) {
            MSG message{};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
            MsgWaitForMultipleObjects(0, nullptr, FALSE, 20, QS_ALLINPUT);
        }
        if (!complete) std::cerr << "Timed out waiting for the real WebView2 frontend\n";
        host.close();
    }
    // Runtime child processes may release their cache files slightly later.
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
    if (result == 0) std::cout << "Native frontend: local assets, bidirectional JSON, network isolation and confirmed close passed\n";
    return result;
}
