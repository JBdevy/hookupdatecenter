// Portable presentation regressions: no window, JUCE, audio device or GPU required.
#include "ImGuiTimeline.h"
#include "ImGuiFrontendView.h"
#include <imgui.h>
#include <imgui_internal.h>
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
using J=nlohmann::json;
#define CHECK(condition) do { if(!(condition)) throw std::runtime_error(std::string(__FILE__)+":"+std::to_string(__LINE__)+": " #condition); } while(false)
struct Call {std::string action;J payload;};
void timelineTests() {
    ImGui::CreateContext();auto& io=ImGui::GetIO();io.DisplaySize={1000,700};io.DeltaTime=1.f/60;
    io.IniFilename=nullptr;io.Fonts->AddFontDefault();unsigned char* pixels=nullptr;int width=0,height=0;
    io.Fonts->GetTexDataAsRGBA32(&pixels,&width,&height);io.BackendFlags|=ImGuiBackendFlags_RendererHasVtxOffset;
    ImGui::GetStyle().WindowPadding={0,0};ImGui::GetStyle().WindowBorderSize=0;
    J snapshot={{"type","snapshot"},{"revision",1},{"project",{{"id","p"}}},
        {"selection",{{"trackIDs",J::array({"t1"})},{"itemIDs",J::array({"c1","c2"})},{"regionIDs",J::array()}}},
        {"transport",{{"playing",true},{"position",5.0},{"editPosition",2.5}}},
        {"song",{{"id","s"},{"duration",120},{"bpm",120},{"beatsPerBar",4},{"beatUnit",4},
            {"parts",J::array({{{"id","r1"},{"name","Intro"},{"startTime",0},{"endTime",20}}})},
            {"markers",J::array({{{"id","m1"},{"name","Verse"},{"position",20},{"tempoBPM",128}}})},
            {"tracks",J::array({
                {{"id","t1"},{"name","Drums"},{"color",0x526c8a},{"audioFile",{{"path","drums.wav"}}},{"clips",J::array({
                    {{"id","c1"},{"name","Drums A"},{"startTime",1},{"duration",10},{"playbackRate",1}},
                    {{"id","c2"},{"name","Drums B"},{"startTime",14},{"duration",10},{"playbackRate",1}}})}},
                {{"id","t2"},{"name","Bass"},{"clips",J::array({{{"id","c3"},{"name","Bass"},{"startTime",1},{"duration",40},{"text","Bass part"}}})}}
            })}}}};
    std::vector<Call> calls;catlive::ImGuiTimeline timeline;timeline.receive(snapshot);
    auto command=[&](const std::string& action,const J& payload){calls.push_back({action,payload});if(action=="selection")for(auto it=payload.begin();it!=payload.end();++it)if(it.key()!="projectID")snapshot["selection"][it.key()]=it.value();};
    auto frame=[&] {
        ImGui::NewFrame();ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({1000,700});
        ImGui::Begin("Audit",nullptr,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoScrollbar|ImGuiWindowFlags_NoScrollWithMouse);
        timeline.render(snapshot,J::object(),command);ImGui::End();ImGui::Render();
        CHECK(ImGui::GetDrawData()->TotalVtxCount>0);return ImGui::GetDrawData()->TotalVtxCount;
    };
    frame();frame();CHECK(calls.size()==2);for(const auto& call:calls)CHECK(call.action=="waveform");
    const auto drop=timeline.mediaDropTarget(snapshot,105,150,true);
    CHECK(drop.is_object()&&drop["trackID"]=="t1"&&drop["projectID"]=="p"&&drop["songID"]=="s");
    CHECK(std::abs(drop["seconds"].get<double>()-5.25)<.001);
    CHECK(timeline.mediaDropTarget(snapshot,105,50,false).is_null());
    CHECK(timeline.mediaDropTarget(snapshot,999,150,false).is_null());
    auto newer=snapshot;newer["revision"]=2;CHECK(timeline.mediaDropTarget(newer,105,150,true).is_null());
    std::cout<<"PASS native file-drop uses rendered grid geometry and rejects stale/header/scrollbar drops\n";
    const auto beforeWave=frame();const auto waveCalls=calls;
    for(const auto& call:waveCalls) {
        const auto start=call.payload["start"].get<double>(),end=call.payload["end"].get<double>();
        J low=J::array(),high=J::array();for(int i=0;i<128;++i){low.push_back(-.4);high.push_back(.6);}
        J result={
            {"projectID","p"},{"clipID",call.payload["clipID"]},{"revision",1},{"start",start},{"end",end},
            {"columnStart",start},{"columnDuration",(end-start)/128},{"channels",J::array({{{"min",low},{"max",high}}})}};
        timeline.receive({{"type","reply"},{"requestId",call.payload["requestId"]},{"ok",true},{"result",result}});
    }
    CHECK(frame()>beforeWave+500);std::cout<<"PASS real waveform reply produces geometry\n";

    auto cursorX=[](ImU32 color) {
        float lo=1.e9f,hi=-1.e9f;
        for(int list=0;list<ImGui::GetDrawData()->CmdListsCount;++list)
            for(const auto& v:ImGui::GetDrawData()->CmdLists[list]->VtxBuffer)if(v.col==color){lo=std::min(lo,v.pos.x);hi=std::max(hi,v.pos.x);}
        CHECK(hi>=lo);return (lo+hi)*.5f;
    };
    bool solid=false,yellow=false,translucent=false;
    for(int list=0;list<ImGui::GetDrawData()->CmdListsCount;++list)for(const auto& v:ImGui::GetDrawData()->CmdLists[list]->VtxBuffer) {
        solid|=v.col==IM_COL32(0x52,0x6c,0x8a,255);
        yellow|=v.col==IM_COL32(255,223,111,255);
        translucent|=v.col==IM_COL32(0x52,0x6c,0x8a,175);
    }
    CHECK(solid&&yellow&&!translucent);std::cout<<"PASS opaque item fills and selected yellow names\n";
    calls.clear();io.AddMousePosEvent(100,150);frame();io.AddMouseButtonEvent(0,true);frame();
    CHECK(snapshot["selection"]["itemIDs"].size()==2);CHECK(calls.empty());
    CHECK(snapshot["transport"]["playing"]==true&&snapshot["transport"]["position"]==5.0);
    io.AddMouseButtonEvent(0,false);frame();CHECK(snapshot["selection"]["itemIDs"].size()==1);
    CHECK(calls.back().action=="transport"&&calls.back().payload["kind"]=="editSeek");
    const auto editCall=calls.back();
    calls.clear();io.AddKeyEvent(ImGuiKey_S,true);frame();
    CHECK(calls.back().action=="splitItems"&&std::abs(calls.back().payload["seconds"].get<double>()-5)<.01);
    io.AddKeyEvent(ImGuiKey_S,false);frame();
    timeline.receive({{"type","reply"},{"requestId",editCall.payload["requestId"]},{"ok",false}});
    calls.clear();io.AddKeyEvent(ImGuiKey_S,true);frame();
    CHECK(calls.back().action=="splitItems"&&std::abs(calls.back().payload["seconds"].get<double>()-2.5)<.01);
    io.AddKeyEvent(ImGuiKey_S,false);frame();
    std::cout<<"PASS immediate split uses clicked cursor and failed editSeek restores authoritative cursor\n";
    std::cout<<"PASS edit cursor preserves transport and selection collapse waits for release\n";
    snapshot["selection"]["itemIDs"]=J::array({"c1","c2"});calls.clear();
    io.AddMousePosEvent(100,150);frame();io.AddMouseButtonEvent(0,true);frame();io.AddMousePosEvent(140,150);frame();io.AddMouseButtonEvent(0,false);frame();
    const auto moved=std::find_if(calls.begin(),calls.end(),[](const auto& c){return c.action=="moveItems";});
    CHECK(moved!=calls.end()&&moved->payload["itemIDs"].size()==2&&std::abs(moved->payload["delta"].template get<double>()-1.5)<.01);
    std::cout<<"PASS multi-item move retains group and snaps delta\n";

    timeline.receive({{"type","telemetry"},{"projectID","p"},{"transport",{{"playing",true},{"position",5},{"editPosition",4.3}}}});frame();
    calls.clear();io.AddMousePosEvent(100,150);frame();io.AddMouseButtonEvent(0,true);frame();io.AddMousePosEvent(163,150);frame();io.AddMouseButtonEvent(0,false);frame();
    auto magnet=std::find_if(calls.begin(),calls.end(),[](const auto& c){return c.action=="moveItems";});
    CHECK(magnet!=calls.end()&&std::abs(magnet->payload["delta"].get<double>()-3.3)<.001);
    for(const auto& call:calls)CHECK(call.action!="transport");
    calls.clear();io.AddKeyEvent(ImGuiMod_Shift,true);io.AddMousePosEvent(100,150);frame();io.AddMouseButtonEvent(0,true);frame();io.AddMousePosEvent(163,150);frame();io.AddMouseButtonEvent(0,false);frame();
    auto exact=std::find_if(calls.begin(),calls.end(),[](const auto& c){return c.action=="moveItems";});
    CHECK(exact!=calls.end()&&std::abs(exact->payload["delta"].get<double>()-3.15)<.001);
    io.AddKeyEvent(ImGuiMod_Shift,false);frame();
    snapshot["project"]["timelineMovementLocked"]=true;calls.clear();
    io.AddMousePosEvent(100,150);frame();io.AddMouseButtonEvent(0,true);frame();io.AddMousePosEvent(180,150);frame();io.AddMouseButtonEvent(0,false);frame();
    for(const auto& call:calls)CHECK(call.action!="moveItems"&&call.action!="transport");
    CHECK(snapshot["selection"]["itemIDs"].size()==2);snapshot["project"]["timelineMovementLocked"]=false;
    std::cout<<"PASS edit cursor magnet, Shift bypass, movement lock and drag cursor preservation\n";
    io.AddKeyEvent(ImGuiMod_Ctrl,true);io.AddKeyEvent(ImGuiKey_A,true);frame();CHECK(snapshot["selection"]["itemIDs"].size()==3);
    io.AddKeyEvent(ImGuiKey_A,false);io.AddKeyEvent(ImGuiMod_Ctrl,false);frame();
    calls.clear();io.AddKeyEvent(ImGuiKey_S,true);frame();CHECK(calls.back().action=="splitItems");io.AddKeyEvent(ImGuiKey_S,false);frame();
    calls.clear();io.AddKeyEvent(ImGuiKey_Delete,true);frame();CHECK(calls.back().action=="removeItems");io.AddKeyEvent(ImGuiKey_Delete,false);frame();
    std::cout<<"PASS focused timeline selection/split/delete commands\n";

    frame();const auto cursorBefore=cursorX(IM_COL32(240,109,123,255));
    io.AddMousePosEvent(500,150);frame();io.AddKeyEvent(ImGuiMod_Ctrl,true);io.AddMouseWheelEvent(0,1);frame();
    CHECK(std::abs(cursorX(IM_COL32(240,109,123,255))-cursorBefore)<.01f);
    io.AddKeyEvent(ImGuiMod_Ctrl,false);frame();std::cout<<"PASS paused follow zoom preserves edit cursor screen anchor\n";
    // Fresh playback start resumes following after manual navigation.
    timeline.receive({{"type","telemetry"},{"projectID","p"},{"transport",{{"playing",false},{"position",70},{"editPosition",2.5}}}});frame();
    timeline.receive({{"type","telemetry"},{"projectID","p"},{"transport",{{"playing",true},{"position",70},{"editPosition",2.5}}}});frame();
    float playX=-1;
    for(int list=0;list<ImGui::GetDrawData()->CmdListsCount;++list)for(const auto& vertex:ImGui::GetDrawData()->CmdLists[list]->VtxBuffer)
        if(vertex.col==IM_COL32(248,215,117,255))playX=std::max(playX,vertex.pos.x);
    CHECK(playX>350&&playX<550);std::cout<<"PASS interpolated transport follows continuously\n";
    timeline.setVerticalOffset(100000);frame();CHECK(std::isfinite(timeline.verticalOffset())&&timeline.verticalOffset()>=0);
    for(const auto& call:calls)CHECK(call.action!="seek"&&call.action!="viewport");
    calls.clear();snapshot["project"]["id"]="replacement";timeline.receive(snapshot);frame();
    const auto beforeStale=frame();const auto newWaveCalls=calls;
    for(const auto& call:waveCalls)timeline.receive({{"type","reply"},{"requestId",call.payload["requestId"]},{"ok",true},{"result",{{"projectID","p"},{"clipID",call.payload["clipID"]},{"channels",J::array({{{"min",J::array({-.9})},{"max",J::array({.9})}}})}}}});
    CHECK(frame()==beforeStale);
    for(const auto& call:newWaveCalls)if(call.action=="waveform")timeline.receive({{"type","reply"},{"requestId",call.payload["requestId"]},{"ok",true},{"result",{{"projectID","p"},{"clipID",call.payload["clipID"]},{"channels",J::array({{{"min",J::array({-.9})},{"max",J::array({.9})}}})}}}});
    CHECK(frame()==beforeStale);
    std::cout<<"PASS prior-project waveform requests and mismatched replies are ignored\n";
    ImGui::DestroyContext();std::cout<<"PASS no seek or competing viewport commands\n";
}

void dropTimelineTests() {
    ImGui::CreateContext();auto& io=ImGui::GetIO();io.DisplaySize={1000,700};io.DeltaTime=1.f/60;
    io.IniFilename=nullptr;io.ConfigInputTrickleEventQueue=false;
    unsigned char* pixels=nullptr;int width=0,height=0;io.Fonts->GetTexDataAsRGBA32(&pixels,&width,&height);
    ImGui::GetStyle().WindowPadding={0,0};ImGui::GetStyle().WindowBorderSize=0;
    J tracks=J::array();for(int i=0;i<12;++i)tracks.push_back({{"id","drop-track-"+std::to_string(i)},{"clips",J::array()}});
    tracks[0]["clips"].push_back({{"id","edge"},{"startTime",20.25},{"duration",2.6},{"text","Edge"}});
    J snapshot={{"type","snapshot"},{"revision",1},{"project",{{"id","drop-project"}}},
        {"transport",{{"playing",false},{"position",8.35},{"editPosition",4.3}}},
        {"song",{{"id","drop-song"},{"duration",240},{"bpm",120},{"beatsPerBar",4},{"beatUnit",4},
            {"tracks",tracks},{"parts",J::array({{{"id","region"},{"startTime",28.2},{"endTime",29.7}}})},
            {"markers",J::array({{{"id","marker"},{"position",31.2}},{{"id","tempo"},{"position",35.2},{"tempoBPM",60}}})}}}};
    catlive::ImGuiTimeline timeline;timeline.receive(snapshot);float drawnDpi=1;
    auto frame=[&] {
        ImGui::NewFrame();ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({1000,700});
        ImGui::Begin("Drop geometry",nullptr,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoScrollbar|ImGuiWindowFlags_NoScrollWithMouse);
        drawnDpi=ImGui::GetFontSize()/13.f;timeline.render(snapshot,J::object(),{});ImGui::End();ImGui::Render();
    };
    frame();frame();
    auto at=[&](double time,bool exact=false) {
        const auto target=timeline.mediaDropTarget(snapshot,float(time*20*drawnDpi),150*drawnDpi,exact);
        CHECK(target.is_object());return target["seconds"].get<double>();
    };
    auto transport=[&](double edit,double main,double sub=0,bool subPlaying=false) {
        timeline.receive({{"type","telemetry"},{"projectID","drop-project"},{"transport",{{"playing",false},{"position",main},
            {"editPosition",edit},{"subPosition",sub},{"subPlaying",subPlaying}}}});frame();
    };
    CHECK(std::abs(at(20.30)-20.25)<1.e-6);CHECK(std::abs(at(22.90)-22.85)<1.e-6);
    CHECK(std::abs(at(4.31)-4.3)<1.e-6);CHECK(std::abs(at(8.4)-8.35)<1.e-6);
    CHECK(std::abs(at(20.30,true)-20.30)<1.e-5);
    transport(20.1,8.35);CHECK(std::abs(at(20.23)-20.25)<1.e-6);
    transport(20.75,8.35);CHECK(std::abs(at(20.5)-20.25)<1.e-6);
    transport(4.3,8.35,12.37,true);const auto drawnSub=at(12.4);CHECK(std::abs(drawnSub-12.37)<.02);
    // Receiving new clocks must not move anchors until those clocks are drawn.
    timeline.receive({{"type","telemetry"},{"projectID","drop-project"},{"transport",{{"playing",false},{"position",40},
        {"editPosition",40},{"subPosition",40},{"subPlaying",true}}}});
    CHECK(at(12.4)==drawnSub);CHECK(std::abs(at(4.31)-4.3)<1.e-6);
    transport(4.3,8.35);
    CHECK(std::abs(at(28.3)-28.2)<1.e-6);CHECK(std::abs(at(31.25)-31.2)<1.e-6);
    CHECK(std::abs(at(36.85)-37.2)<1.e-6);
    snapshot["song"]["bpm"]=80;snapshot["song"]["beatsPerBar"]=8;snapshot["revision"]=2;frame();
    CHECK(std::abs(at(11.15)-10.5)<1.e-6); // 15-pixel subdivisions thin to the shipping 16-pixel minimum.
    snapshot["song"]["beatsPerBar"]=4;snapshot["revision"]=3;frame();
    CHECK(std::abs(at(11.15)-10.5)<1.e-6); // Zoomed-out bars use the shipping half-bar rule.
    snapshot["song"]["bpm"]=120;snapshot["revision"]=4;frame();
    CHECK(std::abs(at(4.89)-4.3)<1.e-6);CHECK(std::abs(at(4.91)-5)<1.e-6);
    ImGui::GetStyle().FontScaleDpi=2;frame();frame();
    CHECK(std::abs(at(4.89)-4.3)<1.e-6);CHECK(std::abs(at(4.91)-5)<1.e-6);
    ImGui::GetStyle().FontScaleDpi=1;frame();frame();
    std::cout<<"PASS drop snapping matches clip/cursor anchors, ties, Shift, tempo/grid density and logical-pixel DPI\n";

    const auto beforeHorizontal=timeline.mediaDropTarget(snapshot,100,150,true);
    io.AddMousePosEvent(100,694);frame();io.AddMouseButtonEvent(0,true);frame();
    io.AddMousePosEvent(240,694);frame();
    const auto drawnHorizontal=timeline.mediaDropTarget(snapshot,100,150,true);
    CHECK(drawnHorizontal==beforeHorizontal);
    frame();const auto nextHorizontal=timeline.mediaDropTarget(snapshot,100,150,true);
    CHECK(nextHorizontal["seconds"].get<double>()>beforeHorizontal["seconds"].get<double>()+1);
    io.AddMouseButtonEvent(0,false);frame();
    const auto beforeVertical=timeline.mediaDropTarget(snapshot,100,150,true);
    io.AddMousePosEvent(994,160);frame();io.AddMouseButtonEvent(0,true);frame();
    io.AddMousePosEvent(994,300);frame();
    CHECK(timeline.mediaDropTarget(snapshot,100,150,true)["trackID"]==beforeVertical["trackID"]);
    frame();CHECK(timeline.mediaDropTarget(snapshot,100,150,true)["trackID"]!=beforeVertical["trackID"]);
    io.AddMouseButtonEvent(0,false);frame();
    std::cout<<"PASS native drops use drawn horizontal/vertical scrollbar state before the next frame\n";
    ImGui::DestroyContext();
}

struct Item {std::string label,window;ImRect rect;};
static std::vector<Item> items;
void ImGuiTestEngineHook_ItemAdd(ImGuiContext*,ImGuiID,const ImRect&,const ImGuiLastItemData*){}
void ImGuiTestEngineHook_ItemInfo(ImGuiContext* c,ImGuiID,const char* label,ImGuiItemStatusFlags){items.push_back({label,c->CurrentWindow->Name,c->LastItemData.Rect});}
void ImGuiTestEngineHook_Log(ImGuiContext*,const char*,...){}
const char* ImGuiTestEngine_FindItemDebugLabel(ImGuiContext*,ImGuiID){return nullptr;}
void clipboardTimelineTests() {
    ImGui::CreateContext();auto &io=ImGui::GetIO();io.IniFilename=nullptr;io.DisplaySize={1000,700};io.DeltaTime=1.f/60;io.ConfigInputTrickleEventQueue=false;io.ConfigMacOSXBehaviors=false;
    unsigned char* pixels=nullptr;int width=0,height=0;io.Fonts->GetTexDataAsRGBA32(&pixels,&width,&height);
    ImGui::GetStyle().WindowPadding={0,0};ImGui::GetStyle().WindowBorderSize=0;ImGui::GetCurrentContext()->TestEngineHookItems=true;
    std::string textClipboard;
    auto &platform=ImGui::GetPlatformIO();platform.Platform_ClipboardUserData=&textClipboard;
    platform.Platform_GetClipboardTextFn=[](ImGuiContext*){return static_cast<std::string*>(ImGui::GetPlatformIO().Platform_ClipboardUserData)->c_str();};
    platform.Platform_SetClipboardTextFn=[](ImGuiContext*,const char* value){*static_cast<std::string*>(ImGui::GetPlatformIO().Platform_ClipboardUserData)=value;};
    J snapshot={{"type","snapshot"},{"revision",1},{"project",{{"id","clipboard-project"}}},
        {"song",{{"id","clipboard-song"},{"duration",60},{"bpm",120},{"tracks",J::array({{{"id","track"},{"name","Items"},{"clips",J::array({{{"id","item"},{"name","Text"},{"text","Body"},{"startTime",1},{"duration",10}}})}}})}}},
        {"selection",{{"itemIDs",J::array({"item"})},{"trackIDs",J::array({"track"})}}},
        {"transport",{{"playing",false},{"position",2},{"editPosition",2}}}};
    std::vector<Call> calls;catlive::ImGuiTimeline timeline;timeline.receive(snapshot);
    bool showText=false,focusText=false;char textBuffer[64]="needle";
    auto command=[&](const std::string &action,const J &payload){calls.push_back({action,payload});};
    auto frame=[&] {
        items.clear();ImGui::NewFrame();
        if(showText) {
            ImGui::SetNextWindowPos({650,0});ImGui::SetNextWindowSize({300,100});
            if(focusText)ImGui::SetNextWindowFocus();
            ImGui::Begin("Text owner");if(focusText){ImGui::SetKeyboardFocusHere();focusText=false;}
            ImGui::InputText("##editor",textBuffer,sizeof(textBuffer));ImGui::End();
        }
        ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({1000,700});
        ImGui::Begin("Clipboard audit",nullptr,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoScrollbar|ImGuiWindowFlags_NoScrollWithMouse|ImGuiWindowFlags_NoBringToFrontOnFocus);
        timeline.render(snapshot,J::object(),command);ImGui::End();ImGui::Render();
    };
    auto key=[&](ImGuiKey value,bool control=true){io.AddKeyEvent(ImGuiMod_Ctrl,control);io.AddKeyEvent(value,true);frame();io.AddKeyEvent(value,false);io.AddKeyEvent(ImGuiMod_Ctrl,false);frame();};
    auto shaded=[] {
        for(int list=0;list<ImGui::GetDrawData()->CmdListsCount;++list)for(const auto &v:ImGui::GetDrawData()->CmdLists[list]->VtxBuffer)
            if(v.col==IM_COL32(25,28,33,140))return true;
        return false;
    };
    auto publishClipboard=[&](bool available,bool moving,const char* project="clipboard-project") {
        snapshot["clipboard"]={{"available",available},{"moving",moving},{"projectID",project},{"songID","clipboard-song"},{"cutItemIDs",moving?J::array({"item"}):J::array()}};
        timeline.receive(snapshot);frame();
    };
    frame();frame();io.AddMousePosEvent(100,120);frame();io.AddMouseButtonEvent(0,true);frame();io.AddMouseButtonEvent(0,false);frame();
    calls.clear();key(ImGuiKey_C);CHECK(calls.size()==1&&calls[0].action=="copyItems");
    CHECK(calls[0].payload["itemIDs"]==J::array({"item"})&&calls[0].payload["projectID"]=="clipboard-project"&&calls[0].payload["songID"]=="clipboard-song");
    publishClipboard(true,false);calls.clear();key(ImGuiKey_X);
    CHECK(calls.size()==1&&calls[0].action=="cutItems"&&!shaded());
    publishClipboard(true,true);CHECK(shaded());calls.clear();key(ImGuiKey_V);
    CHECK(calls.size()==1&&calls[0].action=="pasteItems"&&std::abs(calls[0].payload["seconds"].get<double>()-5)<.001);
    timeline.receive({{"type","reply"},{"ok",false},{"error","fixture paste failure"}});frame();CHECK(shaded());
    calls.clear();key(ImGuiKey_Escape,false);CHECK(calls.size()==1&&calls[0].action=="cancelItemCut"&&shaded());
    publishClipboard(false,false);CHECK(!shaded());
    publishClipboard(true,true);publishClipboard(true,false);CHECK(!shaded());
    snapshot["project"]["timelineMovementLocked"]=true;publishClipboard(true,true);calls.clear();key(ImGuiKey_X);key(ImGuiKey_V);CHECK(calls.empty());
    key(ImGuiKey_C);CHECK(calls.size()==1&&calls[0].action=="copyItems");snapshot["project"]["timelineMovementLocked"]=false;
    publishClipboard(true,true,"other-project");calls.clear();key(ImGuiKey_V);CHECK(calls.empty()&&!shaded());
    publishClipboard(true,true);snapshot["clipboard"]["songID"]="other-song";frame();calls.clear();key(ImGuiKey_V);CHECK(calls.empty()&&!shaded());
    key(ImGuiKey_Escape,false);CHECK(calls.size()==1&&calls[0].action=="cancelItemCut");
    publishClipboard(true,false);io.AddMousePosEvent(100,120);frame();io.AddMouseButtonEvent(1,true);frame();io.AddMouseButtonEvent(1,false);frame();
    auto menu=std::find_if(items.begin(),items.end(),[](const auto &item){return item.label=="Cut";});CHECK(menu!=items.end());const auto hit=menu->rect.GetCenter();
    calls.clear();io.AddMousePosEvent(hit.x,hit.y);frame();io.AddMouseButtonEvent(0,true);frame();io.AddMouseButtonEvent(0,false);frame();CHECK(calls.size()==1&&calls[0].action=="cutItems");
    // Preserve text shortcuts even though the timeline still remembers focus.
    showText=focusText=true;frame();frame();calls.clear();key(ImGuiKey_A);key(ImGuiKey_C);CHECK(textClipboard=="needle");
    key(ImGuiKey_X);CHECK(std::string(textBuffer).empty());key(ImGuiKey_V);CHECK(std::string(textBuffer)=="needle");CHECK(calls.empty());
    ImGui::DestroyContext();std::cout<<"PASS grid clipboard shortcuts/context, confirmed cut shading, scope/lock safety and InputText ownership\n";
}

void viewTests(){
 ImGui::CreateContext();auto& io=ImGui::GetIO();io.IniFilename=nullptr;io.DisplaySize={1440,900};io.DeltaTime=1.f/60;io.ConfigInputTrickleEventQueue=false;
 unsigned char* pixels=nullptr;int width=0,height=0;io.Fonts->GetTexDataAsRGBA32(&pixels,&width,&height);
 ImGui::GetCurrentContext()->TestEngineHookItems=true;
 std::vector<J> sent;
 {
 catlive::ImGuiFrontendView view([&](std::string s){sent.push_back(J::parse(s));});
 J tracks=J::array();
 for(int n=0;n<20;++n)tracks.push_back({{"id","t"+std::to_string(n)},{"name","Track "+std::to_string(n+1)},{"heightScale",n%4==0?1.5:1.},{"color",0x446688},{"volume",1.},{"pan",0.},{"clips",J::array({J{{"id","c"+std::to_string(n)},{"startTime",0.},{"duration",40.},{"name","Audio"},{"audioFile",{{"path","fixture.wav"}}}}})}});
 J song={{"id","s"},{"duration",120.},{"tracks",tracks},{"parts",J::array({J{{"id","p1"},{"name","First song"},{"startTime",0.},{"endTime",60.}},J{{"id","p2"},{"name","Verse"},{"startTime",5.},{"endTime",20.},{"parentRegionID","p1"}}})}};
 J snap={{"type","snapshot"},{"revision",1},{"project",{{"id","project"},{"name","Fixture"},{"masterVolume",1.}}},{"song",song},{"selection",{{"trackIDs",J::array({"t0"})},{"itemIDs",J::array()},{"regionIDs",J::array()}}},{"transport",{{"playing",false},{"position",0.},{"editPosition",0.},{"bpm",120.}}},{"auth",{{"allowed",true},{"message","Signed in"}}},{"language","en"},{"canUndo",true},{"canRedo",true}};
 view.receive(snap.dump());
 auto frame=[&]{items.clear();ImGui::NewFrame();view.render();ImGui::Render();CHECK(ImGui::GetDrawData()->TotalVtxCount>0);};
 auto reply=[&](const J& call,J result=J::object(),bool ok=true){view.receive(J{{"type","reply"},{"id",call["id"]},{"ok",ok},{"result",result},{"error",ok?"":"Fixture error"}}.dump());};
 auto click=[&](const std::string& label,const std::string& window="",int button=0){
   Item hit;bool found=false;for(const auto& item:items)if(item.label==label&&(window.empty()||item.window.find(window)!=std::string::npos)){hit=item;found=true;break;}
   if(!found){std::cerr<<"Missing "<<label<<" in "<<window<<"\n";for(const auto& i:items)std::cerr<<i.window<<": "<<i.label<<"\n";}CHECK(found);
   auto p=hit.rect.GetCenter();io.AddMousePosEvent(p.x,p.y);frame();io.AddMouseButtonEvent(button,true);frame();io.AddMouseButtonEvent(button,false);frame();frame();
 };
 frame();frame();CHECK(!sent.empty()&&sent.front()["action"]=="snapshot");
 const auto beforeForwardedWave=ImGui::GetDrawData()->TotalVtxCount;
 for(auto call:std::vector<J>(sent)){
   if(call["action"]=="waveform") {
     const auto start=call["payload"]["start"].get<double>(),end=call["payload"]["end"].get<double>();
     reply(call,{{"clipID",call["payload"]["clipID"]},{"projectID","project"},{"revision",1},{"start",start},{"end",end},{"columnStart",start},{"columnDuration",(end-start)/128},{"channels",J::array({J{{"min",J(std::vector<double>(128,-.4))},{"max",J(std::vector<double>(128,.6))}}})}});
   }
   else reply(call);
 }
 frame();CHECK(ImGui::GetDrawData()->TotalVtxCount>beforeForwardedWave+500);click("Save");CHECK(sent.back()["action"]=="save");CHECK(sent.back()["payload"]["projectID"]=="project");reply(sent.back());
 // Shell drops retain Unicode paths, ask about multiple-file placement and
 // cannot import using coordinates from a previously displayed document.
 auto nativeDrop=[&](J paths){view.receive(J{{"type","fileDrop"},{"x",500.},{"y",300.},{"shift",true},{"paths",std::move(paths)}}.dump());};
 frame();nativeDrop(J::array({"C:\\Músicas\\Canção.wav"}));
 CHECK(sent.back()["action"]=="importMedia"&&sent.back()["payload"]["trackID"]=="t0");
 CHECK(sent.back()["payload"]["paths"][0]=="C:\\Músicas\\Canção.wav");reply(sent.back());frame();
 const auto beforeBatch=sent.size();nativeDrop(J::array({"C:\\one.wav","C:\\two.wav"}));frame();frame();
 CHECK(sent.size()==beforeBatch);click("On the same track, starting together","##importMedia");click("Import","##importMedia");
 CHECK(sent.back()["action"]=="importMedia"&&sent.back()["payload"]["layout"]=="stacked"&&sent.back()["payload"]["paths"].size()==2);reply(sent.back());frame();
 nativeDrop(J::array({"C:\\one.wav","C:\\two.wav"}));frame();frame();const auto beforeCanceled=sent.size();click("Cancel","##importMedia");CHECK(sent.size()==beforeCanceled);
 snap["revision"]=2;view.receive(snap.dump());nativeDrop(J::array({"C:\\one.wav"}));CHECK(sent.size()==beforeCanceled);frame();frame();
 nativeDrop(J::array({"C:\\one.wav","C:\\two.wav"}));frame();frame();
 snap["song"]["id"]="replacement-song";view.receive(snap.dump());const auto beforeStaleDrop=sent.size();frame();frame();
 for(size_t i=beforeStaleDrop;i<sent.size();++i)CHECK(sent[i]["action"]!="importMedia");
 snap["song"]["id"]="s";view.receive(snap.dump());frame();frame();
 std::cout<<"PASS native file drop preserves paths, batch layout/cancel and stale document protection\n";
 auto importVisible=[] {return std::any_of(items.begin(),items.end(),[](const auto& item){return item.window.find("##importMedia")!=std::string::npos;});};
 auto notice=[&] {view.receive(J{{"type","notice"},{"title","Import interrupted"},{"message","Fixture notice"}}.dump());};
 auto nextDropWorks=[&] {
   const auto before=sent.size();nativeDrop(J::array({"C:\\after-notice.wav"}));
   CHECK(sent.size()==before+1&&sent.back()["action"]=="importMedia"&&sent.back()["payload"]["paths"]==J::array({"C:\\after-notice.wav"}));
   reply(sent.back());frame();
 };
 // Host tick can deliver a notice and a drop before the next presentation.
 const auto beforeQueuedNotice=sent.size();notice();nativeDrop(J::array({"C:\\one.wav","C:\\two.wav"}));frame();frame();frame();frame();
 for(size_t i=beforeQueuedNotice;i<sent.size();++i)CHECK(sent[i]["action"]!="importMedia");CHECK(!importVisible());click("OK##ok","##message");nextDropWorks();
 // Replacing a visible options modal must clear its staged payload as well.
 nativeDrop(J::array({"C:\\one.wav","C:\\two.wav"}));frame();frame();CHECK(importVisible());
 const auto beforeInterrupted=sent.size();notice();frame();frame();frame();frame();CHECK(!importVisible());for(size_t i=beforeInterrupted;i<sent.size();++i)CHECK(sent[i]["action"]!="importMedia");
 click("OK##ok","##message");nextDropWorks();
 nativeDrop(J::array({"C:\\one.wav","C:\\two.wav"}));frame();frame();CHECK(importVisible());
 snap["busy"]=true;view.receive(snap.dump());frame();frame();CHECK(!importVisible());
 snap["busy"]=false;view.receive(snap.dump());frame();frame();nextDropWorks();
 std::cout<<"PASS queued notices and replacement notice/progress modals cancel staged drops without disabling future imports\n";
 click("##playStop");CHECK(sent.back()["action"]=="play");reply(sent.back());
 click("FX","##master");CHECK(sent.back()["action"]=="effectsGet");
 reply(sent.back(),{{"settings",{{"inserted",J::array({"Compressor"})},{"compressorEnabled",true},{"threshold",-20.},{"ratio",4.},{"attack",.005},{"release",.1},{"makeup",0.}}}});frame();frame();
 click("Enabled","nativeEffects");CHECK(sent.back()["action"]=="effectsCommit");CHECK(sent.back()["payload"]["settings"]["compressorEnabled"]==false);reply(sent.back());frame();click("Close","nativeEffects");
 view.receive(J{{"type","confirm"},{"token","token"},{"title","Discard?"},{"message","Choose deliberately"},{"buttons",J::array({J{{"id","cancel"},{"label","Cancel"}},J{{"id","discard"},{"label","Discard"}}})}}.dump());frame();frame();click("Cancel##cancel");CHECK(sent.back()["action"]=="confirm");CHECK(sent.back()["payload"]["choice"]=="cancel");reply(sent.back());
 view.receive(J{{"type","notice"},{"title","Notice"},{"message","Fixture notice"}}.dump());frame();frame();click("OK##ok");
 click("Mixer");frame();click("Account");frame();frame();click("Close","##account");
 for(int n=0;n<150;++n){io.DisplaySize={float(900+n%7*100),float(600+n%3*100)};view.receive(J{{"type","telemetry"},{"projectID","project"},{"transport",{{"playing",true},{"position",n*.05},{"bpm",120.}}},{"meters",J::array({J{{"trackID",""},{"left",.3},{"right",.4},{"peak",.8}},J{{"trackID","t0"},{"left",.3},{"right",.4},{"peak",.8}}})}}.dump());frame();}
 snap["busy"]=true;snap["progress"]=.5;view.receive(snap.dump());frame();frame();snap["busy"]=false;view.receive(snap.dump());frame();frame();
 view.receive(J{{"type","reply"},{"id",999999},{"ok",true}}.dump());frame();

 // A native OS open may replace the document while an ImGui modal is open.
 // A confirmation for one document must never inherit another's selected IDs.
 io.DisplaySize={1440,900};frame();frame();
 auto modalVisible=[](const std::string& name){return std::any_of(items.begin(),items.end(),[&](const auto& item){return item.window.find(name)!=std::string::npos;});};
 click("1  Track 1##select","",1);click("Delete selected tracks");CHECK(modalVisible("##removeTracks"));
 snap["project"]["id"]="replacement";snap["selection"]["trackIDs"]=J::array({"t1"});view.receive(snap.dump());frame();frame();
 CHECK(!modalVisible("##removeTracks"));
 click("1  Track 1##select","",1);click("Rename track");CHECK(modalVisible("##renameTrack"));
 snap["project"]["id"]="third-document";view.receive(snap.dump());frame();frame();CHECK(!modalVisible("##renameTrack"));
 for(const auto& call:sent)CHECK(call["action"]!="removeTracks"&&call["action"]!="renameTrack");
 std::cout<<"PASS project replacement closes stale delete and rename confirmations\n";
 std::cout<<"View smoke passed: transport/save, waveform reply forwarding, native FX commit, confirmation/notice/account, mixer, progress, resize/telemetry. Commands="<<sent.size()<<"\n";
 }
 ImGui::DestroyContext();
}

int main() {
    try { timelineTests(); dropTimelineTests(); clipboardTimelineTests(); viewTests(); return 0; }
    catch(const std::exception& e) { std::cerr<<"FAIL "<<e.what()<<"\n"; return 1; }
}
