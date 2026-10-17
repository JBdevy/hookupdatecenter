#include "VST3Host.h"
#include <nlohmann/json.hpp>
#include <fstream>
#include <iostream>
#include <array>
#include <cmath>
#include <windows.h>
using namespace catlive::native;
int wmain(int argc, wchar_t **argv) {
    if(argc<3)return 2;
    const auto apartment=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    nlohmann::json report;
    int code=0;
    try {
        const auto descriptions=vst3::scan(argv[1]);
        report["plugins"]=nlohmann::json::array();
        for(const auto &d:descriptions)report["plugins"].push_back({{"classID",d.classID},{"name",d.name},{"vendor",d.vendor},{"category",d.category}});
        if(argc>3&&std::wstring(argv[3])==L"--process"){
            if(descriptions.empty())throw std::runtime_error("No VST3 audio classes.");
            auto plugin=std::make_unique<vst3::Processor>(descriptions.front(),vst3::State{},48000,512);
            std::array<float,512> left{},right{};
            vst3::Transport transport;transport.playing=true;
            for(int n=0;n<30;++n){
                for(int i=0;i<512;++i)left[i]=right[i]=float(.1*std::sin((n*512+i)*.02));
                transport.seconds=n*512./48000;transport.quarterNotes=transport.seconds*2;
                if(!plugin->process(left.data(),right.data(),512,transport))throw std::runtime_error("VST3 process failed.");
                for(int i=0;i<512;++i){
                    if(!std::isfinite(left[i])||!std::isfinite(right[i]))throw std::runtime_error("Non-finite PCM.");
                    // An empty instrument may generate silence; it must not
                    // erase audio already playing on the track.
                    if(plugin->isInstrument()&&std::abs(left[i]-float(.1*std::sin((n*512+i)*.02)))>.000001f)
                        throw std::runtime_error("Empty instrument changed the track's existing PCM.");
                }
            }
            const auto state=plugin->state();
            report["componentStateBytes"]=state.component.size();report["controllerStateBytes"]=state.controller.size();
            report["latencySamples"]=plugin->latency();
            plugin.reset();
            plugin=std::make_unique<vst3::Processor>(descriptions.front(),state,48000,512);
            left.fill(.05f);right.fill(.05f);
            if(!plugin->process(left.data(),right.data(),512,transport))throw std::runtime_error("Restored VST3 process failed.");
            report["restored"]=true;
            if(argc>4&&std::wstring(argv[4])==L"--editor"){
                auto window=CreateWindowExW(0,L"STATIC",L"CatLive native VST3 validation",WS_OVERLAPPEDWINDOW,
                    0,0,800,600,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
                if(!window)throw std::runtime_error("Could not create editor validation HWND.");
                struct Window {HWND value;~Window(){DestroyWindow(value);}} owned{window};
                ShowWindow(window,SW_SHOWNOACTIVATE);
                auto editor=plugin->openEditor(window,[window](int width,int height){
                    RECT bounds{0,0,width,height};AdjustWindowRect(&bounds,WS_OVERLAPPEDWINDOW,FALSE);
                    SetWindowPos(window,nullptr,0,0,bounds.right-bounds.left,bounds.bottom-bounds.top,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);
                });
                const auto until=GetTickCount64()+1000;
                while(GetTickCount64()<until){MSG message;while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}Sleep(5);}
                report["nativeEditor"]={{"width",editor->width()},{"height",editor->height()}};
            }
        }
        report["success"]=true;
    }catch(const std::exception &e){report["success"]=false;report["error"]=e.what();code=1;}
    std::ofstream(std::filesystem::path(argv[2]))<<report.dump(2);
    if(SUCCEEDED(apartment))CoUninitialize();
    return code;
}
