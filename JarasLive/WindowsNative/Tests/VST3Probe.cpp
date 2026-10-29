#include "VST3Host.h"
#include <nlohmann/json.hpp>
#include <fstream>
#include <iostream>
#include <array>
#include <algorithm>
#include <cmath>
#include <windows.h>
#include <dbghelp.h>
#include <sstream>
#include <thread>
#include <chrono>
#include <atomic>
using namespace catlive::native;
namespace {
nlohmann::json *crashReport = nullptr;
std::filesystem::path crashReportPath;
LONG WINAPI recordPluginCrash(EXCEPTION_POINTERS *fault) {
    if (!crashReport || !fault || !fault->ExceptionRecord) return EXCEPTION_EXECUTE_HANDLER;
    try {
        const auto code=fault->ExceptionRecord->ExceptionCode;
        std::ostringstream message;message<<"Plugin process crashed (0x"<<std::hex<<code<<") during "<<crashReport->value("stage",std::string("scan"))<<".";
        (*crashReport)["success"]=false;(*crashReport)["error"]=message.str();
        (*crashReport)["exceptionCode"]=code;
        MEMORY_BASIC_INFORMATION info{};
        if(VirtualQuery(fault->ExceptionRecord->ExceptionAddress,&info,sizeof(info))){
            wchar_t name[32768]{};
            if(GetModuleFileNameW(static_cast<HMODULE>(info.AllocationBase),name,32768))
                (*crashReport)["faultModule"]=std::filesystem::path(name).filename().u8string();
            (*crashReport)["faultOffset"]=uintptr_t(fault->ExceptionRecord->ExceptionAddress)-uintptr_t(info.AllocationBase);
        }
        std::ofstream(crashReportPath)<<crashReport->dump(2);
        if(GetEnvironmentVariableW(L"CATLIVE_VST3_CRASH_DUMP",nullptr,0)){
            auto path=crashReportPath;path+=L".dmp";
            auto file=CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
            if(file!=INVALID_HANDLE_VALUE){MINIDUMP_EXCEPTION_INFORMATION exception{GetCurrentThreadId(),fault,FALSE};
                MiniDumpWriteDump(GetCurrentProcess(),GetCurrentProcessId(),file,MiniDumpNormal,&exception,nullptr,nullptr);CloseHandle(file);}
        }
    } catch (...) {}
    return EXCEPTION_EXECUTE_HANDLER;
}
}

static std::vector<std::uint8_t> decodeState(const std::string &text) {
    static const std::string alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    if(text.size()>90*1024*1024)throw std::runtime_error("VST3 state too large.");
    std::vector<std::uint8_t> result;unsigned value=0;int bits=0;bool padded=false;
    for(unsigned char ch:text){
        if(ch=='='){padded=true;continue;}
        const auto index=alphabet.find(char(ch));if(padded||index==std::string::npos)throw std::runtime_error("Invalid VST3 state encoding.");
        value=(value<<6)|unsigned(index);bits+=6;if(bits>=8){bits-=8;result.push_back(std::uint8_t(value>>bits));}
    }
    return result;
}
int wmain(int argc, wchar_t **argv) {
    if(argc<3)return 2;
    const auto apartment=OleInitialize(nullptr);
    nlohmann::json report;
    crashReport=&report;crashReportPath=argv[2];SetUnhandledExceptionFilter(recordPluginCrash);
    auto stage=[&](const char *name){report["stage"]=name;std::ofstream(std::filesystem::path(argv[2]))<<report.dump(2);};
    int code=0;
    try {
        stage("load-module");
        const auto module = vst3::retainModule(argv[1]);
        stage("scan");
        const auto descriptions=vst3::scan(argv[1]);
        report["plugins"]=nlohmann::json::array();
        for(const auto &d:descriptions)report["plugins"].push_back({{"classID",d.classID},{"name",d.name},{"vendor",d.vendor},{"category",d.category}});
        if(argc>4 && std::wstring(argv[3])==L"--import") {
            stage("restore-imported-state");
            std::ifstream input{std::filesystem::path(argv[4])};const auto request=nlohmann::json::parse(input);
            const auto id=request.at("classID").get<std::string>();
            const auto found=std::find_if(descriptions.begin(),descriptions.end(),[&](const auto &d){return d.classID==id;});
            if(found==descriptions.end())throw std::runtime_error("VST3 class not found in the installed module.");
            vst3::State state{decodeState(request.value("componentState",std::string())),decodeState(request.value("controllerState",std::string()))};
            auto plugin=std::make_unique<vst3::Processor>(*found,state,48000,512);
            report["parameterIDs"]=nlohmann::json::object();const auto ids=plugin->parameterIDs();
            for(const auto &[index,id]:ids)report["parameterIDs"][std::to_string(index)]=id;
            report["restored"]=true;
            stage("release-imported-processor");plugin.reset();
        }
        if(argc>3&&(std::wstring(argv[3])==L"--process"||std::wstring(argv[3])==L"--validate")){
            const bool validate=std::wstring(argv[3])==L"--validate";
            if(descriptions.empty())throw std::runtime_error("No VST3 audio classes.");
            auto selected=descriptions.begin();bool showEditor=false,freshEditor=false,editorSilence=false;
            for(int arg=4;arg<argc;++arg){
                const std::wstring option=argv[arg];
                if(option==L"--editor")showEditor=true;
                if(option==L"--editor-silence")editorSilence=showEditor=true;
                if(option==L"--fresh-editor")freshEditor=showEditor=true;
                if(option.rfind(L"--class-id=",0)==0){
                    const auto value=option.substr(11);const std::string id(value.begin(),value.end());
                    selected=std::find_if(descriptions.begin(),descriptions.end(),[&](const auto &d){return d.classID==id;});
                    if(selected==descriptions.end())throw std::runtime_error("Requested VST3 class was not found.");
                }
            }
            report["validatedClass"]=selected->name;
            stage("create-processor");
            auto plugin=std::make_unique<vst3::Processor>(*selected,vst3::State{},48000,512);
            std::array<float,512> left{},right{};
            vst3::Transport transport;transport.playing=true;
            stage("process");
            for(int n=0;n<30;++n){
                for(int i=0;i<512;++i)left[i]=right[i]=float(.1*std::sin((n*512+i)*.02));
                transport.seconds=n*512./48000;transport.quarterNotes=transport.seconds*2;
                if(!plugin->process(left.data(),right.data(),512,transport))throw std::runtime_error("VST3 process failed.");
                for(int i=0;i<512;++i){
                    if(!std::isfinite(left[i])||!std::isfinite(right[i]))throw std::runtime_error("Non-finite PCM.");
                    // An empty instrument may generate silence; it must not
                    // erase audio already playing on the track.
                    if(!validate&&plugin->isInstrument()&&std::abs(left[i]-float(.1*std::sin((n*512+i)*.02)))>.000001f)
                        throw std::runtime_error("Empty instrument changed the track's existing PCM.");
                }
            }
            stage("capture-state");
            const auto state=plugin->state();
            report["componentStateBytes"]=state.component.size();report["controllerStateBytes"]=state.controller.size();
            report["latencySamples"]=plugin->latency();
            if(!freshEditor){
            stage("release-processor");plugin.reset();
            stage("restore-processor");
            plugin=std::make_unique<vst3::Processor>(*selected,state,48000,512);
            left.fill(.05f);right.fill(.05f);
            if(!plugin->process(left.data(),right.data(),512,transport))throw std::runtime_error("Restored VST3 process failed.");
            report["restored"]=true;
            }
            if(showEditor){
                stage("open-editor");
                // The native application processes realtime VST3 audio on its
                // audio thread while the editor runs on the UI thread.
                struct AudioLoop {
                    std::atomic<bool> stop{false},okay{true};
                    std::thread thread;
                    explicit AudioLoop(vst3::Processor &processor):thread([this,&processor]{
                        std::array<float,512> left{},right{};vst3::Transport transport;
                        auto next=std::chrono::steady_clock::now();
                        while(!stop.load()){
                            left.fill(0);right.fill(0);
                            if(!processor.process(left.data(),right.data(),512,transport))okay=false;
                            transport.seconds+=512./48000;transport.quarterNotes=transport.seconds*2;
                            next+=std::chrono::microseconds(10667);std::this_thread::sleep_until(next);
                        }
                    }){}
                    ~AudioLoop(){stop=true;if(thread.joinable())thread.join();}
                };
                std::unique_ptr<AudioLoop> audio;
                if(!editorSilence)audio=std::make_unique<AudioLoop>(*plugin);
                auto window=CreateWindowExW(0,L"STATIC",L"CatLive native VST3 validation",WS_OVERLAPPEDWINDOW,
                    0,0,800,600,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
                if(!window)throw std::runtime_error("Could not create editor validation HWND.");
                struct Window {HWND value;~Window(){DestroyWindow(value);}} owned{window};
                ShowWindow(window,SW_SHOWNOACTIVATE);
                auto editor=plugin->openEditor(window,[window](int width,int height){
                    RECT bounds{0,0,width,height};AdjustWindowRect(&bounds,WS_OVERLAPPEDWINDOW,FALSE);
                    SetWindowPos(window,nullptr,0,0,bounds.right-bounds.left,bounds.bottom-bounds.top,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);
                });
                if(editorSilence) {
                    left.fill(.2f);right.fill(.2f);transport.playing=true;
                    if(!plugin->process(left.data(),right.data(),512,transport))throw std::runtime_error("Editor active block failed.");
                    if(plugin->processEditorSilence(512,transport))throw std::runtime_error("Active editor processed twice in one callback.");
                    transport.playing=false;
                    for(int block=0;block<120;++block) {
                        if(!plugin->processEditorSilence(512,transport))throw std::runtime_error("Stopped item editor stopped receiving silence.");
                        MSG message;while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}
                        Sleep(11);
                    }
                    editor->setVisible(false);
                    if(plugin->processEditorSilence(512,transport))throw std::runtime_error("Hidden editor kept processing idle blocks.");
                    editor->setVisible(true);
                    if(!plugin->processEditorSilence(512,transport))throw std::runtime_error("Reopened editor did not resume idle blocks.");
                    editor.reset();
                    if(plugin->processEditorSilence(512,transport))throw std::runtime_error("Closed editor kept processing idle blocks.");
                    report["editorSilence"]={{"blocks",120},{"skipsActive",true},{"skipsHidden",true},{"skipsClosed",true}};
                }
                const auto until=GetTickCount64()+(editorSilence?0:1000);
                while(GetTickCount64()<until){
                    MSG message;while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}
                    if(audio&&!audio->okay.load())throw std::runtime_error("VST3 editor playback failed.");
                    Sleep(5);
                }
                if(editor)report["nativeEditor"]={{"width",editor->width()},{"height",editor->height()}};
            }
            stage("close-processor");
        }
        stage("complete");
        report["success"]=true;
    }catch(const std::exception &e){report["success"]=false;report["error"]=e.what();code=1;}
    std::ofstream(std::filesystem::path(argv[2]))<<report.dump(2);
    if(SUCCEEDED(apartment))OleUninitialize();
    return code;
}
