#pragma once
#include "Appearance.h"
#include <powrprof.h>
#include <shellapi.h>
#include <objbase.h>
#include <thread>
namespace catlive {
// Uses Hook Center's lid GUIDs, restores the original AC/DC actions, and keeps
// the application's system-sleep assertion on the message thread.
class ShowMode final : public std::enable_shared_from_this<ShowMode> {
  public:
    struct State {
        String scheme;
        bool hasLid = false, enabled = false;
        DWORD ac = 1, dc = 1;
    };
    struct Backend {
        std::function<State()> query;
        std::function<void(const State &, DWORD, DWORD)> apply;
    };
    static std::shared_ptr<ShowMode> shared() {
        static auto value = std::make_shared<ShowMode>();
        return value;
    }
    explicit ShowMode(File storage = {}, Backend operations = nativeBackend())
        : preferences(storage == File{} ? File::getSpecialLocation(File::userApplicationDataDirectory)
                        .getChildFile("Hook Developer/CatLive/show-mode.json") : storage), backend(std::move(operations)) {}
    bool enabled = false, busy = false, loaded = false;
    String error;
    void start() { managingPower = true; refresh(); }
    void stop() { managingPower = false; SetThreadExecutionState(ES_CONTINUOUS); }
    void refresh() { update(std::nullopt); }
    void setEnabled(bool value) { update(value); }
    // Also exercised with an isolated preferences file and a fake power backend.
    static State transition(Appearance &preferences, const Backend &backend, std::optional<bool> desired) {
        auto before = backend.query();
        if (!desired) {
            before.enabled = before.hasLid ? before.ac == 0 && before.dc == 0 : (bool)preferences.value("enabled", false);
            return before;
        }
        auto originals = preferences.value("originals", object()).clone();
        if (!originals.isObject()) originals = object();
        auto original = get(originals, Identifier(before.scheme));
        if (*desired && before.hasLid && !original.isObject()) {
            original = object(); put(original,"ac",(int)before.ac); put(original,"dc",(int)before.dc);
            put(originals,Identifier(before.scheme),original);
            const auto saved = preferences.set("originals", originals);
            if (saved.failed()) throw std::runtime_error(utf8(saved.getErrorMessage()));
        }
        const DWORD ac = *desired ? 0 : (DWORD)jlimit(0,3,(int)get(original,"ac",1));
        const DWORD dc = *desired ? 0 : (DWORD)jlimit(0,3,(int)get(original,"dc",1));
        if (before.hasLid) backend.apply(before, ac, dc);
        auto after = backend.query();
        if (before.hasLid && (!after.hasLid || after.scheme != before.scheme || after.ac != ac || after.dc != dc))
            throw std::runtime_error("The system did not confirm the Show Mode change.");
        auto saved = preferences.set("enabled", *desired);
        if (saved.failed()) throw std::runtime_error(utf8(saved.getErrorMessage()));
        if (!*desired && before.hasLid && original.isObject()) {
            originals.getDynamicObject()->removeProperty(Identifier(before.scheme));
            saved = preferences.set("originals", originals);
            if (saved.failed()) throw std::runtime_error(utf8(saved.getErrorMessage()));
        }
        after.enabled = after.hasLid ? after.ac == 0 && after.dc == 0 : *desired;
        return after;
    }
    static Backend nativeBackend() { return {querySystem, applySystem}; }
  private:
    Appearance preferences;
    Backend backend;
    bool managingPower = false;
    void update(std::optional<bool> desired) {
        if (busy) return;
        busy = true; error.clear();
        const auto self = shared_from_this();
        std::thread([self, desired] {
            State state; String failure;
            try { state = transition(self->preferences, self->backend, desired); }
            catch (const std::exception &e) { failure = String::fromUTF8(e.what()); }
            MessageManager::callAsync([self,state,failure] {
                self->busy = false; self->error = failure;
                if (failure.isEmpty()) {
                    self->enabled = state.enabled; self->loaded = true;
                    if (self->managingPower)
                        SetThreadExecutionState(ES_CONTINUOUS | (self->enabled ? ES_SYSTEM_REQUIRED : 0));
                }
            });
        }).detach();
    }
    static inline const GUID buttons{0x4f971e89,0xeebd,0x4455,{0xa8,0xde,0x9e,0x59,0x04,0x0e,0x73,0x47}};
    static inline const GUID lid{0x5ca83367,0x6e45,0x459f,{0xa2,0x7b,0x47,0x6b,0x1d,0x01,0xc9,0x36}};
    static String guidText(const GUID &g) {
        return String::formatted("%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            g.Data1,g.Data2,g.Data3,g.Data4[0],g.Data4[1],g.Data4[2],g.Data4[3],g.Data4[4],g.Data4[5],g.Data4[6],g.Data4[7]);
    }
    static State querySystem() {
        const auto library = LoadLibraryExW(L"powrprof.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!library) throw std::runtime_error("Unable to read the Windows power plan.");
        struct Release { HMODULE module; ~Release(){FreeLibrary(module);} } release{library};
        const auto active = (decltype(&PowerGetActiveScheme))GetProcAddress(library,"PowerGetActiveScheme");
        const auto readAC = (decltype(&PowerReadACValueIndex))GetProcAddress(library,"PowerReadACValueIndex");
        const auto readDC = (decltype(&PowerReadDCValueIndex))GetProcAddress(library,"PowerReadDCValueIndex");
        GUID *scheme = nullptr;
        if (!active || !readAC || !readDC || active(nullptr,&scheme) != ERROR_SUCCESS || !scheme)
            throw std::runtime_error("Unable to read the Windows power plan.");
        const GUID value = *scheme; LocalFree(scheme);
        State state; state.scheme = guidText(value);
        const auto ac = readAC(nullptr,&value,&buttons,&lid,&state.ac);
        const auto dc = readDC(nullptr,&value,&buttons,&lid,&state.dc);
        if (ac == ERROR_ACCESS_DENIED || dc == ERROR_ACCESS_DENIED)
            throw std::runtime_error("Unable to read the Windows lid settings.");
        state.hasLid = ac == ERROR_SUCCESS && dc == ERROR_SUCCESS;
        state.enabled = state.hasLid && state.ac == 0 && state.dc == 0;
        return state;
    }
    static String powerCommands(const State &before, DWORD ac, DWORD dc) {
        const auto prefix = " & \"$env:SystemRoot\\System32\\powercfg.exe\" ";
        const auto setting = before.scheme + " 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 ";
        auto call = [&](String args) { return String(prefix)+args+"; if($LASTEXITCODE){throw 'powercfg failed'}; "; };
        return call("/setacvalueindex "+setting+String((int)ac)) + call("/setdcvalueindex "+setting+String((int)dc)) + call("/setactive "+before.scheme);
    }
    static void applySystem(const State &before, DWORD ac, DWORD dc) {
        const auto initialized = CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED|COINIT_DISABLE_OLE1DDE);
        struct ReleaseCOM { HRESULT result; ~ReleaseCOM(){ if (SUCCEEDED(result)) CoUninitialize(); } } release{initialized};
        const auto script = "$ErrorActionPreference='Stop'; try {"+powerCommands(before,ac,dc)+"} catch { try {"+
            powerCommands(before,before.ac,before.dc)+"} catch { exit 2 }; exit 1 }; exit 0";
        const auto wide = script.toWideCharPointer();
        const auto bytes = MemoryBlock(wide,(size_t)script.length()*sizeof(wchar_t));
        const auto arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand "+Base64::toBase64(bytes.getData(),bytes.getSize());
        const auto executable = File::getSpecialLocation(File::windowsSystemDirectory).getChildFile("WindowsPowerShell/v1.0/powershell.exe").getFullPathName();
        SHELLEXECUTEINFOW launch{}; launch.cbSize=sizeof(launch); launch.fMask=SEE_MASK_NOCLOSEPROCESS|SEE_MASK_NOASYNC;
        launch.lpVerb=L"runas"; launch.lpFile=executable.toWideCharPointer(); launch.lpParameters=arguments.toWideCharPointer(); launch.nShow=SW_HIDE;
        if (!ShellExecuteExW(&launch) || !launch.hProcess)
            throw std::runtime_error("Show Mode was not changed. Administrator authorization is required.");
        WaitForSingleObject(launch.hProcess,INFINITE);
        DWORD result=1; GetExitCodeProcess(launch.hProcess,&result); CloseHandle(launch.hProcess);
        if (result == 2) throw std::runtime_error("Unable to change Show Mode. Check the system lid settings.");
        if (result) throw std::runtime_error("Unable to change Show Mode. The previous lid settings were restored.");
    }
};
} // namespace catlive
