#pragma once
#include "Appearance.h"
#include "SMK37Firmware.h"
#include <deque>
#include <map>
namespace catlive {
// Control-thread bridge. No network, filesystem or firmware work in the MIDI callback.
class SMK37Connection final : private MidiInputCallback, private AsyncUpdater {
public:
    static bool deviceName(const String &name) { return name.toUpperCase().retainCharacters("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains("SMK37"); }
    using Bytes=std::vector<uint8_t>;
    std::function<void(int)> action; // 0..15 DAW pads
    std::function<void(int)> previewStep,playlistStep,padBusVolume;
    std::function<void(bool)> fadeout;
    std::function<void(int)> choosePreset;
    std::function<void(const ID&,int,int)> padDown;
    std::function<void(const ID&)> padUp;
    SMK37Connection(AudioDeviceManager &d, Appearance &p):devices(d),preferences(p) {
        devices.addMidiInputDeviceCallback({},this);
        SMK37FirmwareTask::shared()->beforeStart[this]=[this]{disconnect();};
    }
    ~SMK37Connection() override { SMK37FirmwareTask::shared()->beforeStart.erase(this); devices.removeMidiInputDeviceCallback({},this);cancelPendingUpdate();disconnect(); }
    void shutdown() { devices.removeMidiInputDeviceCallback({},this);cancelPendingUpdate();disconnect();action={};previewStep={};playlistStep={};padBusVolume={};fadeout={};choosePreset={};padDown={};padUp={}; }
    bool claims(MidiInput *input,const MidiMessage &m) const {
        const ScopedLock lock(mutex);
        return linked.load() && mode.load()!=2 && input && input->getIdentifier()==source && m.isController() && ((m.getControllerNumber()>=102 && m.getControllerNumber()<=117) || (mode.load()==0 && m.getControllerNumber()==23));
    }
    static Bytes frame(int command,Bytes data={}) {
        Bytes b{240,125,67,76,83,1,(uint8_t)command};b.insert(b.end(),data.begin(),data.end());int sum=0;for(size_t i=1;i<b.size();++i)sum+=b[i];b.push_back((128-sum%128)%128);b.push_back(247);return b;
    }
    static bool valid(const Bytes &b) { if(b.size()<9||b.size()>96||b[0]!=240||b[1]!=125||b[2]!=67||b[3]!=76||b[4]!=83||b[5]!=1||b.back()!=247)return false;int sum=0;for(size_t i=1;i+1<b.size();++i){if(b[i]>127)return false;sum+=b[i];}return sum%128==0; }
    static Bytes textBytes(const String &s) { Bytes b;for(auto c:s){if(b.size()==64)break;b.push_back(c>=32&&c<=126?(uint8_t)c:32);}return b; }
    static Bytes colour(uint32_t rgb) { Bytes b;for(int i=20;i>=0;i-=4)b.push_back((rgb>>i)&15);return b; }
    static Bytes named(int command,Bytes prefix,uint32_t rgb,const String &name) { auto c=colour(rgb),t=textBytes(name);prefix.insert(prefix.end(),c.begin(),c.end());prefix.insert(prefix.end(),t.begin(),t.end());return frame(command,prefix); }
    void feedback(const String &s,uint32_t rgb=0xeeeeee) { pending.erase("navigation");queue("action",named(19,{},rgb,s),true);flush(); }
    static Bytes navigationFrame(int kind,const std::vector<String> &names,int selected) {
        if(kind<1||kind>3||selected<0||selected>=(int)names.size())return {};
        Bytes data{(uint8_t)kind};
        for(int row=0;row<5;++row){const int i=selected+row-2,limit=row==2?24:14;auto text=i>=0&&i<(int)names.size()?textBytes(names[(size_t)i]):Bytes{};
            if(text.size()>(size_t)limit){text.resize((size_t)limit-3);text.insert(text.end(),{46,46,46});}
            data.push_back((uint8_t)text.size());data.insert(data.end(),text.begin(),text.end());}
        return frame(23,data);
    }
    void navigation(int kind,const std::vector<String> &names,int selected) {
        auto bytes=navigationFrame(kind,names,selected);if(bytes.empty())return;
        pending.erase("action");queue("navigation",bytes,true);flush();
    }
    static Bytes playbackFrame(double position,double start,double end) {
        if(!std::isfinite(position)||!std::isfinite(start)||!std::isfinite(end)||end<=start)return frame(24,Bytes(8,0));
        double duration=end-start,elapsed=jlimit(0.,duration,position-start);int progress=(int)std::round(elapsed/duration*200.);
        Bytes data{(uint8_t)(progress&127),(uint8_t)(progress>>7)};
        for(double seconds:{elapsed,duration}){unsigned n=(unsigned)std::min(2097151.,seconds);data.insert(data.end(),{(uint8_t)(n&127),(uint8_t)((n>>7)&127),(uint8_t)((n>>14)&127)});}
        return frame(24,data);
    }
    void playback(double position,double start,double end){queue("playback",playbackFrame(position,start,end));}
    void selectedPad(int pad) { lastPad=pad;lastPadPreset=preset;serial=(serial+1)&127; }
    void library(const var &value) {
        preset=jlimit(0,5,(int)num(value,"selectedPreset"));if(lastPadPreset!=preset)lastPad=127;
        const auto banks=list(get(value,"presets"));if(banks.size()!=6)return;
        int active=0;
        for(int p=0;p<6;++p){queue("preset"+String(p),named(16,{(uint8_t)p},(uint32_t)num(banks[p],"color"),str(banks[p],"name")));
            if(p!=preset)continue;const auto pads=list(get(banks[p],"pads"));if(pads.size()!=16)return;
            for(int n=0;n<16;++n){queue("pad"+String(p)+":"+String(n),named(17,{(uint8_t)p,(uint8_t)n},(uint32_t)num(pads[n],"color"),str(pads[n],"name")));if(flag(pads[n],"active"))active|=1<<n;}}
        queue("selection",frame(18,{(uint8_t)preset,(uint8_t)lastPad,(uint8_t)serial,(uint8_t)(active&127),(uint8_t)((active>>7)&127),(uint8_t)((active>>14)&3)}));
    }
    void transport(bool paused,bool recording,bool loop,bool automatic,bool preview,bool playing,bool queued,const String &name,uint32_t rgb) {
        queue("transport",frame(20,{(uint8_t)((paused?1:0)|(recording?2:0)|(loop?4:0)|(automatic?8:0)|(preview?16:0)|(playing?32:0)|(queued?64:0))}));queue("loop",named(21,{},rgb,name));
    }
    void fadeoutProgress(bool active,double remaining,double duration) {
        if(!active || !std::isfinite(remaining) || !std::isfinite(duration) || duration<=0) {queue("fadeout",frame(22,{0,0,0}));return;}
        auto tenths=(uint8_t)std::ceil(jlimit(0.,5.,remaining)*10.-.000001);
        auto fraction=(uint8_t)std::round(jlimit(0.,1.,remaining/duration)*127.);
        queue("fadeout",frame(22,{1,tenths,fraction}));
    }
    void poll() {
        if(SMK37FirmwareTask::shared()->busy)return;
        const auto now=Time::getMillisecondCounterHiRes()/1000.;
        if(now-lastRefresh>=1){lastRefresh=now;refresh();}
        if(!output)return;
        if(linked.load()&&now-response>=3){release();linked=false;sent.clear();pending.clear();}
        if(now-hello>=1){send(frame(1));hello=now;}flush();
    }
private:
    AudioDeviceManager &devices;Appearance &preferences;
    mutable CriticalSection mutex;String source;std::unique_ptr<MidiOutput> output;
    struct Message {std::array<uint8_t,96> bytes{};int size=0;};std::deque<Message> incoming;bool overflow=false;
    std::atomic<bool> linked{false};std::atomic<int> mode{0};int preset=0,lastPad=127,lastPadPreset=-1,serial=0;
    double hello=-1e10,response=-1e10,lastRefresh=-1e10;
    std::map<int,ID> held;std::set<int> down;std::map<String,Bytes> sent,pending;
    void release(){if(padUp)for(const auto &p:held)padUp(p.second);held.clear();down.clear();}
    void disconnect(){if(output)send(frame(2));release();linked=false;output.reset();{const ScopedLock lock(mutex);source.clear();incoming.clear();}pending.clear();sent.clear();}
    void refresh(){
        String candidate;
        for(const auto &d:MidiInput::getAvailableDevices())if(devices.isMidiInputDeviceEnabled(d.identifier)&&deviceName(d.name)){candidate=d.identifier;break;}
        if(candidate.isEmpty()){disconnect();return;}
        {const ScopedLock lock(mutex);if(source==candidate&&output)return;}
        String inputName;for(const auto &d:MidiInput::getAvailableDevices())if(d.identifier==candidate)inputName=d.name;
        String destination;int count=0;for(const auto &d:MidiOutput::getAvailableDevices())if(d.name.trim()==inputName.trim()){destination=d.identifier;++count;}
        if(count!=1){disconnect();return;}
        disconnect();output=MidiOutput::openDevice(destination);if(output){const ScopedLock lock(mutex);source=candidate;hello=-1e10;}
    }
    void handleIncomingMidiMessage(MidiInput *input,const MidiMessage &m) override {
        if(!input||m.getRawDataSize()>96)return;const ScopedLock lock(mutex);
        if(source.isEmpty()||input->getIdentifier()!=source)return;
        if(!m.isSysEx()&&!m.isController())return;
        if(incoming.size()==128){overflow=true;triggerAsyncUpdate();return;}
        Message copy;copy.size=m.getRawDataSize();std::copy_n(m.getRawData(),copy.size,copy.bytes.begin());incoming.push_back(copy);triggerAsyncUpdate();
    }
    void handleAsyncUpdate() override {
        std::deque<Message> messages;bool lost=false;{const ScopedLock lock(mutex);messages.swap(incoming);lost=overflow;overflow=false;}
        if(lost){release();linked=false;return;}
        for(const auto &m:messages){Bytes b(m.bytes.begin(),m.bytes.begin()+m.size);
            if(b[0]==240){if(!valid(b))continue;const int c=b[6],n=(int)b.size()-9;
                if(c==65&&n==3&&b[7]<6&&b[8]<16&&b[9]<3){if(mode!=b[9])release();if(!linked.load()){sent.clear();pending.clear();}mode=b[9];linked=true;response=Time::getMillisecondCounterHiRes()/1000.;}
                else if(linked.load()&&mode!=2&&c==32&&n==2&&b[7]<6&&b[8]<16){preset=b[7];if(choosePreset)choosePreset(preset);}
                else if(linked.load()&&c==34&&n==3&&b[7]<3&&b[8]<6&&b[9]<16){release();mode=b[7];preset=b[8];}
                else if(linked.load()&&mode==1&&c==35&&n==1&&b[7]>0&&b[7]!=64){if(previewStep)previewStep((int)b[7]-64);}
                else if(linked.load()&&mode==1&&c==36&&n==1&&b[7]>0&&b[7]!=64){if(playlistStep)playlistStep((int)b[7]-64);}
                else if(linked.load()&&mode==1&&c==37&&n==1&&b[7]<2){if(fadeout)fadeout(b[7]==1);}
            }else if(linked.load()&&mode==0&&m.size==3&&(b[0]&240)==176&&b[1]==23&&b[2]<128){if(padBusVolume)padBusVolume(b[2]);
            }else if(linked.load()&&mode!=2&&m.size==3&&(b[0]&240)==176&&b[1]>=102&&b[1]<=117){const int pad=b[1]-102,key=(b[0]&15)*16+pad;
                if(!b[2]){down.erase(key);auto it=held.find(key);if(it!=held.end()){if(padUp)padUp(it->second);held.erase(it);}continue;}
                if(!down.insert(key).second)continue;
                if(mode==1){if(action)action(pad);}else{auto token=Uuid().toString().toStdString();held[key]=token;selectedPad(pad);if(padDown)padDown(token,preset,pad);}
            }}
    }
    void queue(const String &key,const Bytes &b,bool force=false){if(!linked.load())return;if(force||sent[key]!=b)pending[key]=b;else pending.erase(key);}
    void send(const Bytes &b){if(output)output->sendMessageNow(MidiMessage(b.data(),(int)b.size(),0));}
    void flush(){if(!linked.load())return;int count=0;for(const auto *key:{"action","navigation","transport","fadeout","playback","loop","selection"}){auto it=pending.find(key);if(it!=pending.end()){send(it->second);sent[it->first]=it->second;pending.erase(it);++count;}}while(count++<4&&!pending.empty()){auto it=pending.begin();send(it->second);sent[it->first]=it->second;pending.erase(it);}}
};
}
