#include "ImGuiTimeline.h"
#include <imgui.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <optional>
#include <set>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace catlive {
namespace {
using J=nlohmann::json;
const J& member(const J& value,const char* key) {
    static const J empty;
    if(!value.is_object())return empty;
    const auto found=value.find(key);return found==value.end()?empty:*found;
}
const J& array(const J& value,const char* key) {
    static const J empty=J::array();
    const auto& result=member(value,key);return result.is_array()?result:empty;
}
double number(const J& value,const char* key,double fallback=0) {
    const auto& item=member(value,key);
    if(!item.is_number())return fallback;
    const auto result=item.get<double>();return std::isfinite(result)?result:fallback;
}
std::string string(const J& value,const char* key,const std::string& fallback={}) {
    const auto& item=member(value,key);return item.is_string()?item.get<std::string>():fallback;
}
bool flag(const J& value,const char* key,bool fallback=false) {
    const auto& item=member(value,key);return item.is_boolean()?item.get<bool>():fallback;
}
float uiScale(){return ImGui::GetFontSize()/13.f;}
double now(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
std::set<std::string> identifiers(const J& value,const char* key) {
    std::set<std::string> result;for(const auto& item:array(value,key))if(item.is_string())result.insert(item.get<std::string>());return result;
}
J ids(const std::set<std::string>& values){return J(std::vector<std::string>(values.begin(),values.end()));}
ImU32 colour(const J& value,const char* key,ImU32 fallback,int alpha=255) {
    const auto& entry=member(value,key);if(!entry.is_number_integer())return fallback;
    const auto rgb=entry.get<std::uint32_t>();return IM_COL32((rgb>>16)&255,(rgb>>8)&255,rgb&255,alpha);
}
ImU32 withAlpha(ImU32 c,int alpha){return (c&0x00ffffffu)|(ImU32(alpha)<<24);}
ImU32 mutedColour(ImU32 c){return IM_COL32(int((c>>IM_COL32_R_SHIFT)&255)*.52f,int((c>>IM_COL32_G_SHIFT)&255)*.52f,int((c>>IM_COL32_B_SHIFT)&255)*.52f,255);}
std::string clockText(double seconds,bool precise=false) {
    const auto ms=static_cast<long long>(std::llround(std::max(0.,seconds)*1000));char text[64];
    if(precise)std::snprintf(text,sizeof(text),"%02lld:%02lld:%02lld.%03lld",ms/3600000,(ms/60000)%60,(ms/1000)%60,ms%1000);
    else std::snprintf(text,sizeof(text),"%02lld:%02lld:%02lld",ms/3600000,(ms/60000)%60,(ms/1000)%60);
    return text;
}
struct Rect {
    float x=0,y=0,w=0,h=0;
    bool contains(ImVec2 p)const{return p.x>=x&&p.x<x+w&&p.y>=y&&p.y<y+h;}
    ImVec2 min()const{return {x,y};}ImVec2 max()const{return {x+w,y+h};}
};
void label(ImDrawList& draw,const Rect& bounds,const std::string& text,ImU32 colour,float inset=4) {
    if(bounds.w<=inset*2||bounds.h<=0||text.empty())return;
    draw.PushClipRect(bounds.min(),bounds.max(),true);
    draw.AddText({bounds.x+inset,bounds.y+std::max(0.f,(bounds.h-ImGui::GetFontSize())*.5f)},colour,text.c_str());draw.PopClipRect();
}
struct RegionLane {size_t index=0;int lane=0;double start=0,end=0;std::string id;};
std::vector<RegionLane> regionLanes(const J& song) {
    std::vector<RegionLane> result;const auto& parts=array(song,"parts");
    for(size_t n=0;n<parts.size();++n) {
        const auto start=number(parts[n],"startTime"),end=number(parts[n],"endTime");
        if(end>start)result.push_back({n,0,start,end,string(parts[n],"id")});
    }
    std::sort(result.begin(),result.end(),[](const auto& a,const auto& b){return a.start==b.start?a.end>b.end:a.start<b.start;});
    std::vector<double> ends;std::map<std::string,int> placed;
    for(auto& part:result) {
        const auto parent=placed.find(string(parts[part.index],"parentRegionID"));
        int lane=parent==placed.end()?0:parent->second+1;
        while(lane<int(ends.size())&&ends[size_t(lane)]>part.start+1.e-7)++lane;
        if(lane>=int(ends.size()))ends.resize(size_t(lane+1),-1);
        ends[size_t(lane)]=part.end;placed[part.id]=part.lane=lane;
    }
    return result;
}
int regionCount(const std::vector<RegionLane>& regions){int count=1;for(const auto& part:regions)count=std::max(count,part.lane+1);return count;}
double fadeCurve(double value,double curvature,double sCurve) {
    const auto t=std::clamp(value,0.,1.),bias=std::pow(2.,4*std::clamp(curvature,-1.,1.));
    const auto shaped=t+std::clamp(sCurve,-1.,1.)*(t*t*(3-2*t)-t);return shaped/(bias+(1-bias)*shaped);
}
double fadeAt(const J& clip,double time) {
    const auto start=number(clip,"startTime"),duration=number(clip,"duration");double gain=1;
    const auto in=std::min(duration,number(clip,"fadeIn")),out=std::min(duration,number(clip,"fadeOut"));
    if(in>0)gain*=fadeCurve((time-start)/in,number(clip,"fadeInCurve"),number(clip,"fadeInSCurve",1));
    if(out>0)gain*=fadeCurve((start+duration-time)/out,number(clip,"fadeOutCurve"),number(clip,"fadeOutSCurve",1));
    return gain;
}
}

struct ImGuiTimeline::Impl {
    struct Tempo {double start,bpm,beats,unit;};
    struct Clip {size_t index=0;int lane=0,lanes=1;double start=0,end=0;std::string id;};
    struct Row {size_t index=0;float y=0,height=80;std::string id;std::vector<Clip> clips;};
    struct Wave {
        J data;std::string signature;double start=0,end=0,step=0,retryAt=0,lastUse=0;
        std::uint64_t request=0;double requestedAt=0;
    };
    struct Pending {std::string clip,signature,project;double start=0,end=0,step=0;};
    struct Hit {Rect bounds,gain,pan,mute;std::string clip,track;double start=0,gainValue=1,panValue=0;bool muted=false;};
    enum class Gesture {none,items,marquee,gain,pan,horizontal,vertical};
    Gesture gesture=Gesture::none;
    ImVec2 press{};double pressOffset=0,pressScale=1,initialValue=0,previewValue=0,dragDelta=0,dragStart=0,dragLowerBound=0,clickTime=0;
    float pressVertical=0;
    bool moved=false,collapse=false,focused=false,follow=true,followPaused=false,wasPlaying=false;
    std::string pressedItem,project,songID,playingSource;
    std::set<std::string> gestureItems,marqueeBase;
    std::vector<Row> rows;std::vector<RegionLane> regions;std::vector<Hit> hits;
    std::vector<Tempo> tempos;
    double gridDivisions=4;
    std::unordered_map<std::string,Wave> waves;
    std::unordered_map<std::uint64_t,Pending> pending;
    std::uint64_t serial=0;double revision=-1,offset=0,scale=20,clockAt=0,previousPosition=-1;
    float vertical=0,totalHeight=0,lastUIScale=0;
    J clockTransport;std::string clockProject;
    std::optional<double> editPreview;
    std::uint64_t editRequest=0;
    int issuedThisFrame=0;
    Rect dropBody;
    double dropOffset=0,dropScale=20,dropEdit=0,dropPosition=0,dropSubPosition=0,dropRevision=-1;
    float dropVertical=0,dropUIScale=1;
    bool dropSubPlaying=false;
    std::string dropProject,dropSong;
    void rebuild(const J& snapshot) {
        const auto& song=member(snapshot,"song");const auto nextProject=string(member(snapshot,"project"),"id"),nextSong=string(song,"id");
        const auto dpi=uiScale();
        if(nextProject!=project||nextSong!=songID) {
            project=nextProject;songID=nextSong;offset=0;vertical=0;waves.clear();pending.clear();gesture=Gesture::none;
            previousPosition=-1;followPaused=false;clockTransport=member(snapshot,"transport");clockProject=project;clockAt=now();revision=-1;
            editPreview.reset();editRequest=0;
        }
        if(lastUIScale!=dpi) {
            if(lastUIScale>0){scale*=dpi/lastUIScale;vertical*=dpi/lastUIScale;}
            else scale=20*dpi;
        }
        if(revision==number(snapshot,"revision")&&lastUIScale==dpi)return;
        lastUIScale=dpi;revision=number(snapshot,"revision");rows.clear();totalHeight=0;regions=regionLanes(song);
        // Tempo markers change with the document, not with each presentation
        // frame. The grid and ruler share one prepared ordering while scrolling.
        tempos={{0,number(song,"bpm",120),number(song,"beatsPerBar",4),number(song,"beatUnit",4)}};
        for(const auto& marker:array(song,"markers"))if(number(marker,"tempoBPM")>0)
            tempos.push_back({number(marker,"position"),number(marker,"tempoBPM"),number(marker,"tempoBeats",4),number(marker,"tempoUnit",4)});
        std::stable_sort(tempos.begin(),tempos.end(),[](const auto&a,const auto&b){return a.start<b.start;});
        gridDivisions=std::max(1.,number(member(song,"timeSettings"),"divisions",4));
        const auto& tracks=array(song,"tracks");
        for(size_t index=0;index<tracks.size();++index) {
            Row row;row.index=index;row.id=string(tracks[index],"id");row.y=totalHeight;row.height=ImGuiTimeline::trackHeight(tracks[index]);totalHeight+=row.height;
            const auto& clips=array(tracks[index],"clips");
            for(size_t c=0;c<clips.size();++c) {
                const auto start=number(clips[c],"startTime"),duration=number(clips[c],"duration");
                if(duration>0)row.clips.push_back({c,0,1,start,start+duration,string(clips[c],"id")});
            }
            std::sort(row.clips.begin(),row.clips.end(),[](const auto& a,const auto& b){return a.start==b.start?a.id<b.id:a.start<b.start;});
            size_t first=0;
            while(first<row.clips.size()) {
                size_t end=first+1;double right=row.clips[first].end;
                while(end<row.clips.size()&&row.clips[end].start<right-1.e-9){right=std::max(right,row.clips[end].end);++end;}
                std::vector<double> laneEnds;
                for(size_t c=first;c<end;++c) {
                    auto& item=row.clips[c];int lane=0;
                    while(lane<int(laneEnds.size())&&laneEnds[size_t(lane)]>item.start+1.e-9)++lane;
                    if(lane==int(laneEnds.size()))laneEnds.push_back(item.end);else laneEnds[size_t(lane)]=item.end;
                    item.lane=lane;
                }
                for(size_t c=first;c<end;++c)row.clips[c].lanes=int(laneEnds.size());first=end;
            }
            rows.push_back(std::move(row));
        }
    }
    double playPosition(const J& transport,const char* key,const char* playing) const {
        const auto extra=flag(transport,playing)?std::clamp(now()-clockAt,0.,.25):0.;return std::max(0.,number(transport,key)+extra);
    }
    void emit(const Command& command,const std::string& action,J payload)const {
        if(command&&!project.empty()){payload["projectID"]=project;command(action,payload);}
    }
    void seekEdit(const Command& command,double position) {
        // Keyboard edits in the next frame must use this click even before the
        // bridge's next telemetry message. A failed command restores its clock.
        editPreview=position;editRequest=++serial;
        emit(command,"transport",{{"kind","editSeek"},{"value",position},{"requestId",editRequest}});
    }
    void select(const Command& command,const std::set<std::string>& items,const std::set<std::string>& tracks)const {
        emit(command,"selection",{{"itemIDs",ids(items)},{"trackIDs",ids(tracks)}});
    }
    std::set<std::string> tracksFor(const std::set<std::string>& items)const {
        std::set<std::string> tracks;for(const auto& row:rows)for(const auto& clip:row.clips)if(items.count(clip.id)){tracks.insert(row.id);break;}return tracks;
    }
    double snap(double time,const J& song,bool exact,std::optional<double> editAnchor={})const {
        time=std::max(0.,time);if(exact)return time;
        if(editAnchor&&std::isfinite(*editAnchor)&&*editAnchor>=0&&std::abs(time-*editAnchor)*scale<=12*std::max(.01f,lastUIScale))return *editAnchor;
        double origin=0,bpm=number(song,"bpm",120),unit=number(song,"beatUnit",4);
        for(const auto& marker:array(song,"markers"))if(number(marker,"position")<=time&&number(marker,"position")>=origin&&number(marker,"tempoBPM")>0) {
            origin=number(marker,"position");bpm=number(marker,"tempoBPM");unit=number(marker,"tempoUnit",4);
        }
        const auto divisions=number(member(song,"timeSettings"),"divisions",4);
        if(bpm<=0||unit<=0||divisions<=0)return time;
        double step=60/bpm*4/divisions;
        step*=std::pow(2.,std::max(0.,std::ceil(std::log2(12/std::max(.001,step*scale)))));
        double chosen=origin+std::round((time-origin)/step)*step,distance=std::abs(chosen-time);
        auto consider=[&](double at){if(at>=0&&std::abs(at-time)<distance){chosen=at;distance=std::abs(at-time);}};
        for(const auto& part:regions){consider(part.start);consider(part.end);}
        for(const auto& marker:array(song,"markers"))consider(number(marker,"position"));
        return std::max(0.,chosen);
    }
    double snapDrop(double time,const J& song,bool exact)const {
        const double position=std::max(0.,time);
        if(exact)return position;
        // Match TimelineGrid::snapSelection in logical pixels. The drop uses
        // the cursors and scale actually drawn, even if telemetry has advanced.
        const double pixels=dropScale/std::max(.01f,dropUIScale);
        double strong=position,strongDistance=std::numeric_limits<double>::infinity();
        auto considerStrong=[&](double at) {
            const auto distance=std::abs(at-position);
            if(std::isfinite(at)&&at>=0&&distance*pixels<=12+1.e-9&&
               (distance<strongDistance||(distance==strongDistance&&at<strong))) {
                strong=at;strongDistance=distance;
            }
        };
        considerStrong(dropEdit);considerStrong(dropPosition);
        if(dropSubPlaying)considerStrong(dropSubPosition);
        for(const auto& row:rows)for(const auto& clip:row.clips){considerStrong(clip.start);considerStrong(clip.end);}
        if(std::isfinite(strongDistance))return strong;

        double origin=0,end=std::max(number(song,"duration"),position)+1;
        double bpm=number(song,"bpm",120),beats=number(song,"beatsPerBar",4),unit=number(song,"beatUnit",4);
        bool markerActive=false;std::string markerID;
        for(const auto& marker:array(song,"markers")) {
            const auto at=number(marker,"position",-1),tempo=number(marker,"tempoBPM");
            if(at<0||tempo<=0)continue;
            const auto id=string(marker,"id");
            if(at<=position&&(at>origin||(at==origin&&(!markerActive||id>markerID)))) {
                origin=at;bpm=tempo;beats=number(marker,"tempoBeats",4);unit=number(marker,"tempoUnit",4);
                markerActive=true;markerID=id;
            } else if(at>position)end=std::min(end,at);
        }
        const auto divisions=number(member(song,"timeSettings"),"divisions",4);
        const double bar=bpm>0&&unit>0?60/bpm*beats*4/unit:0;
        double step=0;
        if(divisions>0&&bar>0) {
            if(bar*pixels>=64) {
                step=bar/beats*unit/divisions;
                step*=std::pow(2.,std::max(0.,std::ceil(std::log2(16/std::max(.001,step*pixels)))));
            } else step=bar*std::pow(2.,std::max(0.,std::ceil(std::log2(16/std::max(.001,bar*pixels)))))/2;
        }
        double nearest=0,distance=position;
        auto consider=[&](double at) {
            if(!std::isfinite(at)||at<0)return;
            const auto delta=std::abs(at-position);
            if(delta<distance||(delta==distance&&at<nearest)){nearest=at;distance=delta;}
        };
        if(step>0)consider(std::min(end,origin+std::round((position-origin)/step)*step));
        for(const auto& part:regions){consider(part.start);consider(part.end);}
        for(const auto& marker:array(song,"markers"))consider(number(marker,"position",-1));
        for(const auto& row:rows)for(const auto& clip:row.clips){consider(clip.start);consider(clip.end);}
        consider(dropEdit);consider(dropPosition);if(dropSubPlaying)consider(dropSubPosition);
        return nearest;
    }
    void zoom(double next,double anchor,float screenX,float width,double duration) {
        scale=std::clamp(next,.01*uiScale(),81920.*uiScale());
        offset=std::clamp(anchor-screenX/scale,0.,std::max(0.,duration-width/scale));
    }
    void waveform(ImDrawList& draw,const Rect& body,const J& clip,const J& track,double from,double to,const Command& command,double delta,float canvasX) {
        const auto id=string(clip,"id");if(id.empty()||to<=from)return;
        J signature=J::array();
        for(const auto* key:{"audioFile","sourceOffset","playbackRate","loopStart","loopLength","channelMode","startTime","duration"})signature.push_back(member(clip,key));
        signature.push_back(member(track,"audioFile"));const auto fingerprint=signature.dump();
        auto& wave=waves[id];wave.lastUse=now();
        if(wave.signature!=fingerprint){wave.data=J();wave.signature=fingerprint;wave.request=0;wave.retryAt=0;}
        if(wave.request&&now()-wave.requestedAt>15){pending.erase(wave.request);wave.request=0;wave.retryAt=now()+.25;}
        const auto targetStep=1/scale;
        const bool enough=wave.data.is_object()&&wave.start<=from+targetStep&&wave.end>=to-targetStep&&wave.step<=targetStep*1.8&&wave.step>=targetStep*.3;
        if(!enough&&!wave.request&&now()>=wave.retryAt&&issuedThisFrame<3&&pending.size()<24) {
            const auto clipStart=number(clip,"startTime"),clipEnd=clipStart+number(clip,"duration");
            const auto span=std::max(to-from,.01),step=std::pow(2.,std::ceil(std::log2(targetStep)));
            const auto start=std::max(clipStart,std::floor((from-span*.4)/step)*step),end=std::min(clipEnd,std::ceil((to+span*.4)/step)*step);
            const int pixels=std::clamp(int(std::ceil((end-start)/targetStep)),1,4096);
            const auto request=++serial;wave.request=request;wave.requestedAt=now();++issuedThisFrame;
            pending.emplace(request,Pending{id,fingerprint,project,start,end,(end-start)/pixels});
            emit(command,"waveform",{{"requestId",request},{"revision",revision},{"clipID",id},{"start",start},{"end",end},{"pixelWidth",pixels}});
        }
        const auto& channels=array(wave.data,"channels");if(channels.empty())return;
        const double columnStart=number(wave.data,"columnStart",number(wave.data,"start")),step=number(wave.data,"columnDuration");if(step<=0)return;
        const auto gain=(gesture==Gesture::gain&&gestureItems.count(id)?previewValue:number(clip,"gain",1))*number(clip,"normalizationGain",1);
        const auto phase=flag(clip,"phaseInverted")?-1.:1.;const float laneH=body.h/float(channels.size());
        draw.PushClipRect(body.min(),body.max(),true);
        for(size_t ch=0;ch<channels.size();++ch) {
            const float middle=body.y+(float(ch)+.5f)*laneH,amplitude=laneH*.46f;
            draw.AddLine({body.x,middle},{body.x+body.w,middle},IM_COL32(196,202,188,65));
            const auto& lows=array(channels[ch],"min");const auto& highs=array(channels[ch],"max");const auto count=std::min(lows.size(),highs.size());
            const size_t begin=size_t(std::clamp(std::floor((from-columnStart)/step),0.,double(count)));
            const size_t end=size_t(std::clamp(std::ceil((to-columnStart)/step)+1,0.,double(count)));
            for(size_t n=begin;n<end;++n) {
                if(!lows[n].is_number()||!highs[n].is_number())continue;
                const auto factor=gain*phase*fadeAt(clip,columnStart+(n+.5)*step);
                const auto a=lows[n].get<double>()*factor,b=highs[n].get<double>()*factor;
                if(!std::isfinite(a)||!std::isfinite(b))continue;
                const float x=canvasX+float((columnStart+n*step+delta-offset)*scale);
                const float high=middle-float(std::clamp(std::max(a,b),-1.,1.))*amplitude,low=middle-float(std::clamp(std::min(a,b),-1.,1.))*amplitude;
                draw.AddRectFilled({x,high},{x+std::max(.75f,float(step*scale)),std::max(high+.75f,low)},IM_COL32(210,218,195,flag(clip,"muted")?100:225));
            }
        }
        draw.PopClipRect();
    }
    void grid(ImDrawList& draw,const Rect& body,const Rect& ruler) {
        const auto end=offset+body.w/scale;float lastLabel=-10000;
        for(size_t t=0;t<tempos.size();++t) {
            const auto& tempo=tempos[t];const auto until=t+1<tempos.size()?std::min(end,tempos[t+1].start):end;
            if(until<offset||tempo.start>end||tempo.bpm<=0||tempo.unit<=0)continue;
            const auto beat=60/tempo.bpm*4/tempo.unit,bar=beat*std::max(1.,tempo.beats);
            double step=beat*tempo.unit/gridDivisions;step*=std::pow(2.,std::max(0.,std::ceil(std::log2(14*uiScale()/std::max(.001,step*scale)))));
            const auto first=std::ceil(std::max(0.,offset-tempo.start)/step);
            for(double i=first,time=tempo.start+i*step;time<=until+1.e-9;i+=1,time=tempo.start+i*step) {
                const auto x=body.x+float((time-offset)*scale);const bool major=std::abs(std::round((time-tempo.start)/bar)-(time-tempo.start)/bar)<1.e-7;
                const auto c=major?IM_COL32(117,126,138,100):IM_COL32(88,96,108,65);
                for(float y=body.y+2;y<body.y+body.h;y+=8*uiScale())draw.AddRectFilled({x,y},{x+1,y+(major?2.f:1.f)},c);
                draw.AddLine({x,ruler.y+ruler.h-(major?8.f:4.f)*uiScale()},{x,ruler.y+ruler.h},c);
                if(x-lastLabel>78*uiScale()) {label(draw,{x+2,ruler.y,110*uiScale(),ruler.h-3},clockText(time,scale>400),IM_COL32(173,182,194,255),0);lastLabel=x;}
            }
        }
    }
};

ImGuiTimeline::ImGuiTimeline():impl(std::make_unique<Impl>()){}
ImGuiTimeline::~ImGuiTimeline()=default;
float ImGuiTimeline::trackHeight(const J& track){return 80*uiScale()*float(std::clamp(number(track,"heightScale",1),.4,4.));}
float ImGuiTimeline::verticalOffset()const{return impl->vertical;}
void ImGuiTimeline::setVerticalOffset(float value){if(std::isfinite(value))impl->vertical=std::max(0.f,value);}
float ImGuiTimeline::headerHeight(const J& snapshot)const {
    return ImGui::GetFrameHeight()+ImGui::GetStyle().ItemSpacing.y+(regionCount(regionLanes(member(snapshot,"song")))*18+42)*uiScale();
}
void ImGuiTimeline::receive(const J& message) {
    auto& s=*impl;const auto type=string(message,"type");
    if(type=="telemetry"||type=="snapshot") {
        const auto incoming=type=="snapshot"?string(member(message,"project"),"id"):string(message,"projectID");
        if(!member(message,"transport").is_object())return;
        if(s.editPreview&&incoming==s.project&&std::abs(number(member(message,"transport"),"editPosition")-*s.editPreview)<1.e-7)s.editPreview.reset();
        s.clockTransport=member(message,"transport");s.clockAt=now();s.clockProject=incoming;return;
    }
    const auto& request=member(message,"requestId");if(!request.is_number_unsigned()&&!request.is_number_integer())return;
    const auto id=request.get<std::uint64_t>();
    if(id==s.editRequest){s.editRequest=0;if(!flag(message,"ok"))s.editPreview.reset();return;}
    const auto found=s.pending.find(id);if(found==s.pending.end())return;
    const auto call=found->second;s.pending.erase(found);
    const auto wave=s.waves.find(call.clip);if(wave==s.waves.end()||wave->second.request!=id)return;
    auto& value=wave->second;value.request=0;
    const auto& result=member(message,"result");
    if(!flag(message,"ok")||!result.is_object()||string(result,"projectID")!=s.project||call.project!=s.project||call.signature!=value.signature) {value.retryAt=now()+.4;return;}
    if(string(result,"clipID")!=call.clip||array(result,"channels").empty()){value.retryAt=now()+2;return;}
    value.data=result;value.start=number(result,"start",call.start);value.end=number(result,"end",call.end);value.step=number(result,"columnDuration",call.step);value.retryAt=0;
}

void ImGuiTimeline::render(const J& snapshot,const J& telemetry,const Command& command) {
    auto& s=*impl;s.rebuild(snapshot);s.issuedThisFrame=0;s.hits.clear();s.dropBody={};
    const auto& song=member(snapshot,"song");const auto& tracks=array(song,"tracks");
    const auto& selection=member(snapshot,"selection");auto selected=identifiers(selection,"itemIDs"),selectedTracks=identifiers(selection,"trackIDs");
    const auto selectedRegions=identifiers(selection,"regionIDs");
    const auto& clipboard=member(snapshot,"clipboard");
    const bool clipboardHere=flag(clipboard,"available")&&string(clipboard,"projectID")==s.project&&string(clipboard,"songID")==s.songID;
    const bool cutPending=flag(clipboard,"moving")&&string(clipboard,"projectID")==s.project;
    const auto cutItems=clipboardHere?identifiers(clipboard,"cutItemIDs"):std::set<std::string>{};
    const auto& fallback=member(telemetry,"transport").is_object()?member(telemetry,"transport"):member(snapshot,"transport");
    const auto& transport=s.clockProject==s.project&&s.clockTransport.is_object()?s.clockTransport:fallback;
    const float unit=uiScale();const double duration=std::max(1.,number(song,"duration",60));
    const auto position=s.playPosition(transport,"position","playing"),subPosition=s.playPosition(transport,"subPosition","subPlaying");
    const auto edit=s.editPreview.value_or(number(transport,"editPosition",position));
    const bool movementLocked=flag(member(snapshot,"project"),"timelineMovementLocked"),editable=!flag(snapshot,"busy")&&!flag(snapshot,"readOnly");
    const bool canCopy=!flag(snapshot,"busy")&&!selected.empty();
    const bool canCut=canCopy&&editable&&!movementLocked;
    const bool canPaste=editable&&clipboardHere&&(!flag(clipboard,"moving")||!movementLocked);
    const auto clipboardCommand=[&](const char* action) {
        J payload={{"songID",s.songID}};
        if(std::string_view(action)=="copyItems"||std::string_view(action)=="cutItems")payload["itemIDs"]=ids(selected);
        if(std::string_view(action)=="pasteItems")payload["seconds"]=s.editPreview.value_or(edit);
        s.emit(command,action,std::move(payload));
    };
    const bool playing=flag(transport,"playing")||flag(transport,"subPlaying");const auto followPosition=flag(transport,"subPlaying")?subPosition:position;
    const auto source=flag(transport,"subPlaying")?std::string("sub:")+string(transport,"regionID"):std::string("main:")+string(transport,"regionID");
    if(playing!=s.wasPlaying||source!=s.playingSource){s.followPaused=false;s.previousPosition=-1;}s.wasPlaying=playing;s.playingSource=source;
    const auto anchor=s.followPaused||!playing?edit:followPosition;
    const float initialWidth=std::max(1.f,ImGui::GetContentRegionAvail().x-12*unit);
    const float anchorX=float(std::clamp((anchor-s.offset)*s.scale,0.,double(initialWidth)));
    ImGui::PushID(this);
    if(ImGui::SmallButton("-"))s.zoom(s.scale/1.35,anchor,anchorX,initialWidth,duration);ImGui::SameLine();
    if(ImGui::SmallButton("+"))s.zoom(s.scale*1.35,anchor,anchorX,initialWidth,duration);ImGui::SameLine();
    if(ImGui::SmallButton("Fit")){s.zoom(initialWidth/duration,duration*.5,initialWidth*.5f,initialWidth,duration);s.followPaused=true;}ImGui::SameLine();
    if(ImGui::Checkbox("Follow",&s.follow))s.followPaused=false;ImGui::SameLine();
    ImGui::TextDisabled("%s",clockText(edit,true).c_str());
    const auto origin=ImGui::GetCursorScreenPos(),available=ImGui::GetContentRegionAvail();
    if(available.x<20||available.y<20){ImGui::PopID();return;}
    const float scrollSize=12*unit,regionHeight=regionCount(s.regions)*18*unit;
    const Rect canvas{origin.x,origin.y,available.x-scrollSize,available.y-scrollSize};
    const Rect regionArea{canvas.x,canvas.y,canvas.w,regionHeight},markerArea{canvas.x,canvas.y+regionHeight,canvas.w,20*unit};
    const Rect ruler{canvas.x,markerArea.y+markerArea.h,canvas.w,22*unit};
    const Rect body{canvas.x,ruler.y+ruler.h,canvas.w,std::max(1.f,canvas.h-regionHeight-markerArea.h-ruler.h)};
    const Rect hscroll{canvas.x,canvas.y+canvas.h,canvas.w,scrollSize},vscroll{canvas.x+canvas.w,body.y,scrollSize,body.h};
    ImGui::InvisibleButton("##timeline",available,ImGuiButtonFlags_MouseButtonLeft|ImGuiButtonFlags_MouseButtonRight|ImGuiButtonFlags_MouseButtonMiddle);
    const bool hovered=ImGui::IsItemHovered();auto& io=ImGui::GetIO();const auto mouse=io.MousePos;
    s.vertical=std::clamp(s.vertical,0.f,std::max(0.f,s.totalHeight-body.h));
    if(s.follow&&!s.followPaused&&playing&&s.gesture==Impl::Gesture::none) {
        if(followPosition<s.offset||followPosition>s.offset+body.w*.45/s.scale||followPosition<s.previousPosition-.001)
            s.offset=std::max(0.,followPosition-body.w*.45/s.scale);
    }
    s.previousPosition=followPosition;s.offset=std::clamp(s.offset,0.,std::max(0.,duration-body.w/s.scale));
    if(hovered&&(io.MouseWheel!=0||io.MouseWheelH!=0)) {
        if(io.KeyCtrl||io.KeySuper) {
            const auto time=s.followPaused||!playing?edit:followPosition;
            const float x=float(std::clamp((time-s.offset)*s.scale,0.,double(body.w)));
            s.zoom(s.scale*std::pow(1.22,io.MouseWheel),time,x,body.w,duration);
        } else if(io.KeyShift||std::abs(io.MouseWheelH)>0) {
            s.offset=std::clamp(s.offset-(io.MouseWheelH!=0?io.MouseWheelH:io.MouseWheel)*80*unit/s.scale,0.,std::max(0.,duration-body.w/s.scale));s.followPaused=true;
        } else s.vertical=std::clamp(s.vertical-io.MouseWheel*55*unit,0.f,std::max(0.f,s.totalHeight-body.h));
    }
    // Scrollbar gestures below update state for the next frame. Retain the
    // transform and cursors used by this frame's pixels for native drop events.
    s.dropBody=body;s.dropOffset=s.offset;s.dropScale=s.scale;s.dropVertical=s.vertical;s.dropEdit=edit;
    s.dropPosition=position;s.dropSubPosition=subPosition;s.dropSubPlaying=flag(transport,"subPlaying");s.dropUIScale=unit;
    s.dropProject=s.project;s.dropSong=s.songID;s.dropRevision=s.revision;
    auto& draw=*ImGui::GetWindowDrawList();draw.PushClipRect(origin,{origin.x+available.x,origin.y+available.y},true);
    draw.AddRectFilled(canvas.min(),canvas.max(),IM_COL32(25,28,33,255));
    draw.AddRectFilled(regionArea.min(),{ruler.x+ruler.w,ruler.y+ruler.h},IM_COL32(31,35,41,255));
    for(const auto& row:s.rows) {
        const float y=body.y+row.y-s.vertical;if(y+row.height<=body.y||y>=body.y+body.h)continue;
        draw.PushClipRect(body.min(),body.max(),true);
        const bool active=selectedTracks.count(row.id)!=0;
        draw.AddRectFilled({body.x,y},{body.x+body.w,y+row.height},active?IM_COL32(44,57,67,255):(row.index%2?IM_COL32(28,31,36,255):IM_COL32(25,28,33,255)));
        if(active)draw.AddRectFilled({body.x,y},{body.x+3*unit,y+row.height},IM_COL32(102,197,225,255));
        draw.AddLine({body.x,y+row.height-.5f},{body.x+body.w,y+row.height-.5f},IM_COL32(67,73,81,255));draw.PopClipRect();
    }
    draw.PushClipRect(body.min(),body.max(),true);s.grid(draw,body,ruler);draw.PopClipRect();
    // Ruler labels have their own clip; grid lines remain confined to tracks.
    draw.PushClipRect(ruler.min(),ruler.max(),true);s.grid(draw,{body.x,body.y,body.w,0},ruler);draw.PopClipRect();
    const auto& parts=array(song,"parts");
    for(const auto& part:s.regions) {
        const Rect rect{canvas.x+float((part.start-s.offset)*s.scale),canvas.y+part.lane*18*unit,float((part.end-part.start)*s.scale),18*unit};
        if(rect.x+rect.w<canvas.x||rect.x>canvas.x+canvas.w)continue;
        draw.PushClipRect(regionArea.min(),regionArea.max(),true);
        const auto fill=colour(parts[part.index],"color",IM_COL32(104,94,127,255));
        draw.AddRectFilled(rect.min(),rect.max(),withAlpha(fill,selectedRegions.count(part.id)?240:175));
        label(draw,rect,string(parts[part.index],"name"),IM_COL32(245,246,248,255),4*unit);
        if(selectedRegions.count(part.id)||part.id==string(transport,"regionID"))draw.AddRect(rect.min(),rect.max(),IM_COL32(194,230,184,255),0,0,1.5f);
        draw.PopClipRect();
    }
    draw.PushClipRect(markerArea.min(),markerArea.max(),true);
    for(const auto& marker:array(song,"markers")) {
        const float x=canvas.x+float((number(marker,"position")-s.offset)*s.scale);if(x<canvas.x-150*unit||x>canvas.x+canvas.w)continue;
        const auto c=colour(marker,"color",IM_COL32(202,180,116,255));draw.AddTriangleFilled({x,markerArea.y},{x+6*unit,markerArea.y},{x,markerArea.y+6*unit},c);
        auto name=string(marker,"name");if(number(marker,"tempoBPM")>0){char tempo[40];std::snprintf(tempo,sizeof(tempo),"  %.0f BPM",number(marker,"tempoBPM"));name+=tempo;}
        label(draw,{x+4*unit,markerArea.y,160*unit,markerArea.h},name,c,2*unit);
    }
    draw.PopClipRect();
    for(const auto& row:s.rows) {
        const float y=body.y+row.y-s.vertical;if(y+row.height<=body.y||y>=body.y+body.h||row.index>=tracks.size())continue;
        const auto& track=tracks[row.index];const auto& clips=array(track,"clips");
        for(const auto& layout:row.clips) {
            if(layout.index>=clips.size())continue;const auto& clip=clips[layout.index];
            const auto delta=s.gesture==Impl::Gesture::items&&s.moved&&s.gestureItems.count(layout.id)?s.dragDelta:0.;
            const float x=body.x+float((layout.start+delta-s.offset)*s.scale),width=float((layout.end-layout.start)*s.scale);
            if(x+width<body.x||x>body.x+body.w)continue;
            const float laneHeight=row.height/layout.lanes;
            const auto leftEdge=std::max(body.x,x+1),rightEdge=std::min(body.x+body.w,x+width-1);
            Rect rect{leftEdge,y+layout.lane*laneHeight+3*unit,std::max(1.f,rightEdge-leftEdge),std::max(4.f,laneHeight-6*unit)};
            const float header=std::min(20*unit,rect.h*.43f);const Rect top{rect.x,rect.y,rect.w,header},waveBody{rect.x,rect.y+header,rect.w,rect.h-header};
            const auto c=colour(track,"color",IM_COL32(81,104,118,255));
            const bool chosen=selected.count(layout.id)!=0||(s.gesture==Impl::Gesture::items&&s.gestureItems.count(layout.id));
            draw.PushClipRect(body.min(),body.max(),true);draw.AddRectFilled(rect.min(),rect.max(),flag(clip,"muted")?mutedColour(c):withAlpha(c,255),3*unit);
            draw.PushClipRect(rect.min(),rect.max(),true);draw.AddRectFilled(top.min(),top.max(),IM_COL32(64,70,79,255));
            Impl::Hit hit{rect,{},{},{},layout.id,row.id,layout.start,number(clip,"gain",1),number(clip,"pan"),flag(clip,"muted")};
            float left=top.x+4*unit,right=top.x+top.w-4*unit;
            if(top.w>190*unit) {
                hit.gain={left,top.y,48*unit,top.h};const auto value=s.gesture==Impl::Gesture::gain&&s.gestureItems.count(layout.id)?s.previewValue:hit.gainValue;
                char gain[32];if(value>0)std::snprintf(gain,sizeof(gain),"%+.1f",20*std::log10(value));else std::snprintf(gain,sizeof(gain),"-inf");
                label(draw,hit.gain,gain,IM_COL32(224,227,231,255),0);left+=48*unit;
                if(top.w>270*unit) {
                    hit.pan={right-42*unit,top.y,42*unit,top.h};const auto pan=s.gesture==Impl::Gesture::pan&&s.gestureItems.count(layout.id)?s.previewValue:hit.panValue;
                    char text[24];if(std::abs(pan)<.005)std::snprintf(text,sizeof(text),"C");else std::snprintf(text,sizeof(text),"%s%.0f",pan<0?"L":"R",std::abs(pan)*100);
                    label(draw,hit.pan,text,IM_COL32(191,209,225,255),4*unit);right-=42*unit;
                }
            }
            if(top.w>54*unit){hit.mute={left,top.y,18*unit,top.h};label(draw,hit.mute,"M",hit.muted?IM_COL32(255,111,111,255):IM_COL32(175,183,194,255),0);left+=18*unit;}
            label(draw,{left,top.y,std::max(0.f,right-left),top.h},string(clip,"name",string(track,"name")),chosen?IM_COL32(255,223,111,255):IM_COL32(235,238,243,255),0);
            const auto from=std::max(layout.start,s.offset-delta),to=std::min(layout.end,s.offset+body.w/s.scale-delta);
            const auto& midi=member(clip,"midi");const auto& text=member(clip,"text");
            if(midi.is_object()&&!flag(clip,"frozenMIDI")) {
                const auto seconds=60/std::max(1.,number(midi,"sourceBPM",120)),rate=std::max(.001,number(clip,"playbackRate",1));
                for(const auto& note:array(midi,"notes")) {
                    const double start=(number(note,"start")*seconds-number(clip,"sourceOffset"))/rate,length=number(note,"length",.25)*seconds/rate;
                    const float nx=body.x+float((layout.start+start+delta-s.offset)*s.scale),ny=waveBody.y+waveBody.h*float(1-number(note,"pitch",60)/127.);
                    draw.AddRectFilled({nx,ny},{nx+std::max(2.f,float(length*s.scale)),ny+std::max(2.f,waveBody.h/64)},IM_COL32(219,237,220,230));
                }
            } else if(text.is_string())label(draw,waveBody,text.get<std::string>(),IM_COL32(230,233,239,255),5*unit);
            else if(!member(clip,"audioFile").is_null()||!member(track,"audioFile").is_null())s.waveform(draw,waveBody,clip,track,from,to,command,delta,body.x);
            draw.PopClipRect();
            draw.AddRect(rect.min(),rect.max(),chosen?IM_COL32(149,229,167,255):withAlpha(c,255),3*unit,0,chosen?2*unit:1.f);
            if(cutItems.count(layout.id))draw.AddRectFilled(rect.min(),rect.max(),IM_COL32(25,28,33,140),3*unit);
            draw.PopClipRect();s.hits.push_back(std::move(hit));
        }
    }
    const auto cursor=[&](double time,ImU32 c,bool triangle) {
        const float x=canvas.x+float((time-s.offset)*s.scale);if(x<canvas.x||x>canvas.x+canvas.w)return;
        draw.AddLine({x,ruler.y},{x,body.y+body.h},c,1.4f*unit);
        if(triangle)draw.AddTriangleFilled({x-5*unit,ruler.y},{x+5*unit,ruler.y},{x,ruler.y+7*unit},c);
    };
    cursor(edit,IM_COL32(240,109,123,255),true);if(flag(transport,"playing"))cursor(position,IM_COL32(248,215,117,255),false);
    if(flag(transport,"subPlaying"))cursor(subPosition,IM_COL32(110,190,255,255),false);
    draw.AddLine({body.x,body.y},{body.x+body.w,body.y},IM_COL32(76,83,94,255));
    draw.AddRectFilled(hscroll.min(),hscroll.max(),IM_COL32(22,25,29,255));draw.AddRectFilled(vscroll.min(),vscroll.max(),IM_COL32(22,25,29,255));
    const float thumbWidth=std::min(hscroll.w,std::max(24*unit,float(hscroll.w*(body.w/s.scale)/duration)));
    const float hx=hscroll.x+float(s.offset/std::max(.001,duration-body.w/s.scale))*(hscroll.w-thumbWidth);
    draw.AddRectFilled({hx,hscroll.y+2*unit},{hx+thumbWidth,hscroll.y+hscroll.h-2*unit},IM_COL32(91,101,114,255),3*unit);
    const float thumbHeight=std::min(vscroll.h,std::max(24*unit,vscroll.h*body.h/std::max(body.h,s.totalHeight)));
    const float vy=vscroll.y+s.vertical/std::max(1.f,s.totalHeight-body.h)*(vscroll.h-thumbHeight);
    draw.AddRectFilled({vscroll.x+2*unit,vy},{vscroll.x+vscroll.w-2*unit,vy+thumbHeight},IM_COL32(91,101,114,255),3*unit);
    if(hovered&&ImGui::IsMouseClicked(ImGuiMouseButton_Left)) {
        s.focused=true;s.press=mouse;s.pressOffset=s.offset;s.pressVertical=s.vertical;s.pressScale=s.scale;s.moved=false;s.dragDelta=0;s.collapse=false;
        if(hscroll.contains(mouse)){s.gesture=Impl::Gesture::horizontal;s.followPaused=true;}
        else if(vscroll.contains(mouse))s.gesture=Impl::Gesture::vertical;
        else {
            const auto hit=std::find_if(s.hits.rbegin(),s.hits.rend(),[&](const auto& h){return body.contains(mouse)&&h.bounds.contains(mouse);});
            if(hit!=s.hits.rend()) {
                if(io.KeyCtrl||io.KeySuper) {if(selected.count(hit->clip))selected.erase(hit->clip);else selected.insert(hit->clip);s.select(command,selected,s.tracksFor(selected));s.gesture=Impl::Gesture::none;}
                else {
                    s.collapse=selected.count(hit->clip)&&selected.size()>1;
                    if(!selected.count(hit->clip)){selected={hit->clip};selectedTracks={hit->track};s.select(command,selected,selectedTracks);}
                    s.gestureItems=selected;s.pressedItem=hit->clip;s.dragStart=hit->start;s.gesture=Impl::Gesture::items;
                    double earliest=hit->start;
                    for(const auto& row:s.rows)for(const auto& clip:row.clips)if(selected.count(clip.id))earliest=std::min(earliest,clip.start);
                    s.dragLowerBound=-earliest;
                    if(hit->mute.contains(mouse)){if(editable)s.emit(command,"itemControls",{{"itemIDs",ids(selected)},{"muted",!hit->muted}});s.gesture=Impl::Gesture::none;}
                    else if(hit->gain.contains(mouse)&&editable){s.gesture=Impl::Gesture::gain;s.initialValue=s.previewValue=hit->gainValue;}
                    else if(hit->pan.contains(mouse)&&editable){s.gesture=Impl::Gesture::pan;s.initialValue=s.previewValue=hit->panValue;}
                    // A drag must keep the existing edit cursor available as a
                    // snap target. Commit the cursor only for a completed click.
                    else {s.clickTime=s.snap(s.offset+(mouse.x-body.x)/s.scale,song,io.KeyShift);s.followPaused=true;}
                }
            } else if(canvas.contains(mouse)) {
                s.followPaused=true;if(editable)s.seekEdit(command,s.snap(s.offset+(mouse.x-body.x)/s.scale,song,io.KeyShift));
                if(body.contains(mouse)) {
                    s.gesture=Impl::Gesture::marquee;s.marqueeBase=io.KeyCtrl||io.KeySuper?selected:std::set<std::string>{};
                    if(!io.KeyCtrl&&!io.KeySuper){std::set<std::string> rowSelection;for(const auto& row:s.rows)if(mouse.y>=body.y+row.y-s.vertical&&mouse.y<body.y+row.y+row.height-s.vertical){rowSelection.insert(row.id);break;}s.select(command,{},rowSelection);}
                } else {
                    s.gesture=Impl::Gesture::none;
                    for(auto part=s.regions.rbegin();part!=s.regions.rend();++part) {
                        const Rect rect{canvas.x+float((part->start-s.offset)*s.scale),canvas.y+part->lane*18*unit,float((part->end-part->start)*s.scale),18*unit};
                        if(rect.contains(mouse)){s.emit(command,"selection",{{"regionIDs",J::array({part->id})}});break;}
                    }
                }
            }
        }
    } else if(ImGui::IsMouseClicked(ImGuiMouseButton_Left)&&!hovered)s.focused=false;
    if(s.gesture!=Impl::Gesture::none&&ImGui::IsMouseDown(ImGuiMouseButton_Left)) {
        const float dx=mouse.x-s.press.x,dy=mouse.y-s.press.y;s.moved=s.moved||dx*dx+dy*dy>9*unit*unit;
        if(s.gesture==Impl::Gesture::horizontal)s.offset=std::clamp(s.pressOffset+dx/std::max(1.f,hscroll.w-thumbWidth)*std::max(0.,duration-body.w/s.scale),0.,std::max(0.,duration-body.w/s.scale));
        if(s.gesture==Impl::Gesture::vertical)s.vertical=std::clamp(s.pressVertical+dy/std::max(1.f,vscroll.h-thumbHeight)*std::max(0.f,s.totalHeight-body.h),0.f,std::max(0.f,s.totalHeight-body.h));
        if(s.gesture==Impl::Gesture::items&&s.moved)s.dragDelta=movementLocked||!editable?0:std::max(s.dragLowerBound,s.snap(s.dragStart+dx/s.pressScale,song,io.KeyShift,edit)-s.dragStart);
        if(s.gesture==Impl::Gesture::gain)s.previewValue=std::pow(10.,std::clamp(20*std::log10(std::max(.001,s.initialValue))-dy*.2/unit,-60.,12.)/20);
        if(s.gesture==Impl::Gesture::pan)s.previewValue=std::clamp(s.initialValue+dx/(100*unit),-1.,1.);
        if(s.gesture==Impl::Gesture::marquee&&s.moved) {
            const Rect rectangle{std::min(mouse.x,s.press.x),std::min(mouse.y,s.press.y),std::abs(dx),std::abs(dy)};
            draw.PushClipRect(body.min(),body.max(),true);draw.AddRectFilled(rectangle.min(),rectangle.max(),IM_COL32(96,183,219,35));draw.AddRect(rectangle.min(),rectangle.max(),IM_COL32(119,206,237,200));draw.PopClipRect();
        }
    }
    if(s.gesture!=Impl::Gesture::none&&ImGui::IsMouseReleased(ImGuiMouseButton_Left)) {
        if(s.gesture==Impl::Gesture::items) {
            if(s.moved&&editable&&!movementLocked&&std::abs(s.dragDelta)>1.e-9)s.emit(command,"moveItems",{{"itemIDs",ids(s.gestureItems)},{"delta",s.dragDelta}});
            else if(!s.moved){if(s.collapse)s.select(command,{s.pressedItem},s.tracksFor({s.pressedItem}));if(editable)s.seekEdit(command,s.clickTime);}
        } else if(s.gesture==Impl::Gesture::gain&&s.moved&&editable)s.emit(command,"itemControls",{{"itemIDs",ids(s.gestureItems)},{"gain",s.previewValue}});
        else if(s.gesture==Impl::Gesture::pan&&s.moved&&editable)s.emit(command,"itemControls",{{"itemIDs",ids(s.gestureItems)},{"pan",s.previewValue}});
        else if(s.gesture==Impl::Gesture::marquee&&s.moved) {
            auto picked=s.marqueeBase;const float left=std::min(mouse.x,s.press.x),right=std::max(mouse.x,s.press.x),top=std::min(mouse.y,s.press.y),bottom=std::max(mouse.y,s.press.y);
            for(const auto& hit:s.hits)if(hit.bounds.x<right&&hit.bounds.x+hit.bounds.w>left&&hit.bounds.y<bottom&&hit.bounds.y+hit.bounds.h>top)picked.insert(hit.clip);
            s.select(command,picked,s.tracksFor(picked));
        }
        s.gesture=Impl::Gesture::none;s.gestureItems.clear();s.dragDelta=0;
    }
    if(hovered&&ImGui::IsMouseClicked(ImGuiMouseButton_Right)) {
        s.focused=true;const auto hit=std::find_if(s.hits.rbegin(),s.hits.rend(),[&](const auto& h){return h.bounds.contains(mouse);});
        if(hit!=s.hits.rend()&&!selected.count(hit->clip)){selected={hit->clip};s.select(command,selected,{hit->track});}
        ImGui::OpenPopup("Timeline actions");
    }
    draw.PopClipRect();
    if(ImGui::BeginPopup("Timeline actions")) {
        // Recompute selection-dependent availability after a right-click may
        // have selected a different item in this same frame.
        const bool copyEnabled=!flag(snapshot,"busy")&&!selected.empty();
        if(ImGui::MenuItem("Copy","Ctrl+C",false,copyEnabled))clipboardCommand("copyItems");
        if(ImGui::MenuItem("Cut","Ctrl+X",false,copyEnabled&&editable&&!movementLocked))clipboardCommand("cutItems");
        if(ImGui::MenuItem("Paste at edit cursor","Ctrl+V",false,canPaste))clipboardCommand("pasteItems");
        if(cutPending&&ImGui::MenuItem("Cancel cut","Esc"))clipboardCommand("cancelItemCut");
        ImGui::Separator();
        if(ImGui::MenuItem("Split at edit cursor","S",false,editable&&!selected.empty()))s.emit(command,"splitItems",{{"itemIDs",ids(selected)},{"seconds",s.editPreview.value_or(edit)}});
        if(ImGui::MenuItem("Delete items","Delete",false,editable&&!selected.empty()))s.emit(command,"removeItems",{{"itemIDs",ids(selected)}});
        if(ImGui::MenuItem("Select all items","Ctrl+A")){std::set<std::string> all;for(const auto& row:s.rows)for(const auto& clip:row.clips)all.insert(clip.id);s.select(command,all,s.tracksFor(all));}
        ImGui::Separator();if(ImGui::MenuItem("Follow playback",nullptr,s.follow)){s.follow=!s.follow;s.followPaused=false;}ImGui::EndPopup();
    }
    if(s.focused&&!io.WantTextInput&&!ImGui::IsAnyItemActive()&&!ImGui::IsPopupOpen(nullptr,ImGuiPopupFlags_AnyPopupId)&&s.gesture==Impl::Gesture::none) {
        if((io.KeyCtrl||io.KeySuper)&&!io.KeyAlt) {
            if(canCopy&&ImGui::IsKeyPressed(ImGuiKey_C,false))clipboardCommand("copyItems");
            if(canCut&&ImGui::IsKeyPressed(ImGuiKey_X,false))clipboardCommand("cutItems");
            if(canPaste&&ImGui::IsKeyPressed(ImGuiKey_V,false))clipboardCommand("pasteItems");
        }
        if(cutPending&&ImGui::IsKeyPressed(ImGuiKey_Escape,false))clipboardCommand("cancelItemCut");
        if((io.KeyCtrl||io.KeySuper)&&ImGui::IsKeyPressed(ImGuiKey_A,false)){std::set<std::string> all;for(const auto& row:s.rows)for(const auto& clip:row.clips)all.insert(clip.id);s.select(command,all,s.tracksFor(all));}
        if(editable&&!selected.empty()&&ImGui::IsKeyPressed(ImGuiKey_Delete,false))s.emit(command,"removeItems",{{"itemIDs",ids(selected)}});
        if(editable&&!selected.empty()&&!io.KeyCtrl&&!io.KeySuper&&ImGui::IsKeyPressed(ImGuiKey_S,false))s.emit(command,"splitItems",{{"itemIDs",ids(selected)},{"seconds",s.editPreview.value_or(edit)}});
    }
    if(s.waves.size()>256)for(auto it=s.waves.begin();it!=s.waves.end();) {
        if(it->second.request==0&&now()-it->second.lastUse>2)it=s.waves.erase(it);else ++it;
    }
    ImGui::PopID();
}
nlohmann::json ImGuiTimeline::mediaDropTarget(const J& snapshot,float x,float y,bool exact) const {
    const auto& s=*impl;
    if(!std::isfinite(x)||!std::isfinite(y)||!s.dropBody.contains({x,y})||s.dropScale<=0||
       s.dropProject!=string(member(snapshot,"project"),"id")||s.dropSong!=string(member(snapshot,"song"),"id")||
       s.dropRevision!=number(snapshot,"revision",-1))return {};
    const auto& song=member(snapshot,"song");
    const auto seconds=s.snapDrop(s.dropOffset+(x-s.dropBody.x)/s.dropScale,song,exact);
    const float rowY=y-s.dropBody.y+s.dropVertical;
    std::string track;
    for(const auto& row:s.rows)if(rowY>=row.y&&rowY<row.y+row.height){track=row.id;break;}
    return {{"projectID",s.dropProject},{"songID",s.dropSong},{"trackID",track},{"seconds",seconds}};
}
}
