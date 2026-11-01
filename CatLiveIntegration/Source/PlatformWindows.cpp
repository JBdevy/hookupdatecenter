#include "Bridge.h"
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <mmsystem.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <thread>
namespace integration {
struct TimecodeClock::Impl {
    HANDLE timer=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
    bool fallbackResolution=false;
    Impl(){if(!timer)fallbackResolution=timeBeginPeriod(1)==TIMERR_NOERROR;}
    ~Impl(){if(timer)CloseHandle(timer);if(fallbackResolution)timeEndPeriod(1);}
};
TimecodeClock::TimecodeClock():impl(std::make_unique<Impl>()){}
TimecodeClock::~TimecodeClock()=default;
void TimecodeClock::waitUntil(Clock::time_point deadline) {
    auto remaining=std::chrono::duration_cast<std::chrono::nanoseconds>(deadline-Clock::now()).count();
    if(remaining<=0)return;
    LARGE_INTEGER due;due.QuadPart=-std::max<int64_t>(1,(remaining+99)/100);
    if(impl->timer && SetWaitableTimer(impl->timer,&due,0,nullptr,nullptr,FALSE)) {
        WaitForSingleObject(impl->timer,100);return;
    }
    std::this_thread::sleep_until(deadline);
}

static std::string utf(const wchar_t* value) {
    if(!value) return {}; int n=WideCharToMultiByte(CP_UTF8,0,value,-1,nullptr,0,nullptr,nullptr);
    std::string result(n,'\0'); WideCharToMultiByte(CP_UTF8,0,value,-1,result.data(),n,nullptr,nullptr); if(!result.empty()) result.pop_back(); return result;
}
std::vector<Adapter> adapters() {
    ULONG size=16384; std::vector<uint8_t> bytes(size); ULONG code;
    for(int n=0;n<3;++n) { code=GetAdaptersAddresses(AF_INET,GAA_FLAG_SKIP_ANYCAST|GAA_FLAG_SKIP_MULTICAST|GAA_FLAG_SKIP_DNS_SERVER,nullptr,(IP_ADAPTER_ADDRESSES*)bytes.data(),&size); if(code!=ERROR_BUFFER_OVERFLOW) break; bytes.resize(size); }
    std::vector<Adapter> result; if(code!=NO_ERROR) return result;
    for(auto p=(IP_ADAPTER_ADDRESSES*)bytes.data();p;p=p->Next) if(p->IfType==IF_TYPE_ETHERNET_CSMACD && p->OperStatus==IfOperStatusUp)
        for(auto a=p->FirstUnicastAddress;a;a=a->Next) if(a->Address.lpSockaddr->sa_family==AF_INET) { auto addr=((sockaddr_in*)a->Address.lpSockaddr)->sin_addr; auto raw=(uint8_t*)&addr; result.push_back({p->AdapterName,utf(p->FriendlyName),std::to_string(raw[0])+"."+std::to_string(raw[1])+"."+std::to_string(raw[2])+"."+std::to_string(raw[3])}); }
    return result;
}
std::filesystem::path documents() {
    PWSTR path=nullptr; if(FAILED(SHGetKnownFolderPath(FOLDERID_Documents,0,nullptr,&path))) throw std::runtime_error("Documents folder unavailable");
    std::filesystem::path result(path); CoTaskMemFree(path); return result;
}
std::string secureToken() {
    uint8_t bytes[32]; if(BCryptGenRandom(nullptr,bytes,sizeof(bytes),BCRYPT_USE_SYSTEM_PREFERRED_RNG)!=0) throw std::runtime_error("Random source unavailable");
    std::string result; const char* hex="0123456789abcdef"; for(auto b:bytes) {result+=hex[b>>4];result+=hex[b&15];} return result;
}
std::vector<MIDIPort> midiPorts() {
    std::vector<MIDIPort> result;
    for(UINT i=0;i<midiOutGetNumDevs();++i) { MIDIOUTCAPSW caps{}; if(midiOutGetDevCapsW(i,&caps,sizeof(caps))==MMSYSERR_NOERROR && caps.wTechnology!=MOD_MAPPER && caps.wTechnology!=MOD_SWSYNTH && caps.wTechnology!=MOD_SYNTH) result.push_back({std::to_string(i)+":"+utf(caps.szPname),utf(caps.szPname)}); }
    return result;
}
struct MIDIOutput::Impl { HMIDIOUT output=nullptr; };
MIDIOutput::MIDIOutput():impl(std::make_unique<Impl>()){}
MIDIOutput::~MIDIOutput(){close();}
void MIDIOutput::close() { if(impl->output) {midiOutReset(impl->output);midiOutClose(impl->output);impl->output=nullptr;} }
void MIDIOutput::open(const std::string& id) {
    close(); std::string selected=id;
    if(selected.empty()) for(auto& port:midiPorts()) if(port.name=="CatLive Integration") {selected=port.id;break;}
    bool found=false; for(auto& port:midiPorts()) if(port.id==selected) {found=true;break;}
    if(!found || midiOutOpen(&impl->output,UINT(std::stoul(selected)),0,0,CALLBACK_NULL)!=MMSYSERR_NOERROR) throw std::runtime_error("Select a MIDI output on CatLive. For grandMA2 onPC, create a CatLive Integration port in loopMIDI.");
}
void MIDIOutput::send(const std::vector<uint8_t>& bytes) {
    if(!impl->output || bytes.empty()) return;
    if(bytes[0]!=0xf0) { DWORD message=0; for(size_t i=0;i<bytes.size() && i<3;++i) message|=DWORD(bytes[i])<<(8*i); midiOutShortMsg(impl->output,message); return; }
    auto copy=bytes; MIDIHDR header{}; header.lpData=(LPSTR)copy.data(); header.dwBufferLength=DWORD(copy.size());
    if(midiOutPrepareHeader(impl->output,&header,sizeof(header))!=MMSYSERR_NOERROR) return;
    if(midiOutLongMsg(impl->output,&header,sizeof(header))==MMSYSERR_NOERROR) { int wait=0; while(!(header.dwFlags&MHDR_DONE) && wait++<100) Sleep(1); if(!(header.dwFlags&MHDR_DONE)) midiOutReset(impl->output); }
    midiOutUnprepareHeader(impl->output,&header,sizeof(header));
}
}
