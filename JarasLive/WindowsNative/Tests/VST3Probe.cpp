#include "VST3Host.h"
#include <nlohmann/json.hpp>
#include <fstream>
#include <iostream>
#include <array>
#include <algorithm>
#include <cmath>
#include <windows.h>
using namespace catlive::native;
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
    const auto apartment=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    nlohmann::json report;
    auto stage=[&](const char *name){report["stage"]=name;std::ofstream(std::filesystem::path(argv[2]))<<report.dump(2);};
    int code=0;
    try {
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
            stage("create-processor");
            auto plugin=std::make_unique<vst3::Processor>(descriptions.front(),vst3::State{},48000,512);
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
            stage("release-processor");plugin.reset();
            stage("restore-processor");
            plugin=std::make_unique<vst3::Processor>(descriptions.front(),state,48000,512);
            left.fill(.05f);right.fill(.05f);
            if(!plugin->process(left.data(),right.data(),512,transport))throw std::runtime_error("Restored VST3 process failed.");
            report["restored"]=true;
            if(argc>4&&std::wstring(argv[4])==L"--editor"){
                stage("open-editor");
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
            stage("close-processor");
        }
        stage("complete");
        report["success"]=true;
    }catch(const std::exception &e){report["success"]=false;report["error"]=e.what();code=1;}
    std::ofstream(std::filesystem::path(argv[2]))<<report.dump(2);
    if(SUCCEEDED(apartment))CoUninitialize();
    return code;
}
