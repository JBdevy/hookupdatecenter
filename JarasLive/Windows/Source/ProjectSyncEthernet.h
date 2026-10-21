#pragma once
#include "Common.h"
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <shellapi.h>
namespace catlive::remote {
// Enumeration and the optional OS authorization stay off the UI/audio threads.
// Only physical, connected Ethernet adapters can carry Project Sync.
class SyncEthernet final : private Thread {
public:
    struct Interface {
        ULONG index = 0; String address, hardware, name; bool connected=false;
        bool operator==(const Interface &other) const { return index == other.index && address == other.address && hardware == other.hardware; }
        bool operator!=(const Interface &other) const { return !(*this == other); }
    };
    SyncEthernet() : Thread("CatLive Ethernet") {}
    ~SyncEthernet() override { stop(); }
    void start() { if (!isThreadRunning()) startThread(); }
    void stop() { signalThreadShouldExit(); notify(); stopThread(-1); const ScopedLock lock(mutex); current = {}; }
    Interface currentInterface() const { const ScopedLock lock(mutex); return current; }
    std::vector<Interface> adapters() const {const ScopedLock lock(mutex);return available;}
    void select(const String &hardware) {const ScopedLock lock(mutex);selected=hardware;notify();}
    bool busy() const { return preparing.load(); }
    String preparationError() const { const ScopedLock lock(mutex); return error; }
    void prepare() { { const ScopedLock lock(mutex); error.clear(); } prepareRequested=true; notify(); }
    // Runs in a separate, elevated process. Never elevates the audio application.
    static DWORD prepareElevated(ULONG index, const String &hardware) {
        const auto values=interfaces();
        const auto found=std::find_if(values.begin(),values.end(),[&](const auto &item){return item.index==index && item.hardware==hardware && item.connected;});
        if(found==values.end())return ERROR_NOT_FOUND;
        if(found->address.startsWith("169.254."))return NO_ERROR;
        const auto hash=(uint32)hardware.hashCode();
        for(unsigned attempt=0;attempt<4;++attempt) {
            const auto address="169.254."+String(1+((hash>>8)+attempt*31)%254)+"."+String(1+(hash+attempt*17)%254);
            MIB_UNICASTIPADDRESS_ROW row{}; InitializeUnicastIpAddressEntry(&row);
            row.InterfaceIndex=index; row.Address.si_family=AF_INET;
            row.OnLinkPrefixLength=16; row.PrefixOrigin=IpPrefixOriginManual; row.SuffixOrigin=IpSuffixOriginManual;
            InetPtonA(AF_INET,address.toRawUTF8(),&row.Address.Ipv4.sin_addr);
            // Adds a volatile secondary address. Existing DHCP, DNS and default
            // routes remain intact; removing the adapter removes this address.
            const auto result=CreateUnicastIpAddressEntry(&row);
            if(result!=NO_ERROR && result!=ERROR_OBJECT_ALREADY_EXISTS)return result;
            for(int retry=0;retry<30;++retry) {
                Sleep(200);
                if(GetUnicastIpAddressEntry(&row)!=NO_ERROR)break;
                if(row.DadState==IpDadStatePreferred)return NO_ERROR;
                if(row.DadState==IpDadStateDuplicate)break;
            }
            if(result==NO_ERROR)DeleteUnicastIpAddressEntry(&row);
        }
        return ERROR_DUP_NAME;
    }
private:
    mutable CriticalSection mutex;
    Interface current;
    String error,selected;
    std::vector<Interface> available;
    std::atomic<bool> prepareRequested{false},preparing{false};
    static std::vector<Interface> interfaces() {
        ULONG length=16384;
        std::vector<uint8_t> bytes(length);
        auto read=[&]{return GetAdaptersAddresses(AF_INET,GAA_FLAG_SKIP_ANYCAST|GAA_FLAG_SKIP_MULTICAST|GAA_FLAG_SKIP_DNS_SERVER,
            nullptr,reinterpret_cast<IP_ADAPTER_ADDRESSES*>(bytes.data()),&length);};
        auto result=read();
        if(result==ERROR_BUFFER_OVERFLOW && length<=1024*1024){bytes.resize(length);result=read();}
        std::vector<Interface> values;
        if(result!=NO_ERROR)return values;
        for(auto *adapter=reinterpret_cast<IP_ADAPTER_ADDRESSES*>(bytes.data());adapter;adapter=adapter->Next) {
            if(adapter->IfType!=IF_TYPE_ETHERNET_CSMACD)continue;
            MIB_IF_ROW2 row{};row.InterfaceIndex=adapter->IfIndex;
            if(GetIfEntry2(&row)!=NO_ERROR || !row.InterfaceAndOperStatusFlags.HardwareInterface)continue;
            Interface value{adapter->IfIndex,{},String::toHexString(adapter->PhysicalAddress,adapter->PhysicalAddressLength,0),String(adapter->FriendlyName),adapter->OperStatus==IfOperStatusUp && row.MediaConnectState==MediaConnectStateConnected};
            for(auto *unicast=adapter->FirstUnicastAddress;unicast;unicast=unicast->Next) {
                if(!unicast->Address.lpSockaddr || unicast->Address.lpSockaddr->sa_family!=AF_INET || unicast->DadState!=IpDadStatePreferred)continue;
                char address[INET_ADDRSTRLEN]{};
                const auto *ipv4=reinterpret_cast<sockaddr_in*>(unicast->Address.lpSockaddr);
                if(!InetNtopA(AF_INET,&ipv4->sin_addr,address,sizeof(address)))continue;
                if(value.address.isEmpty() || String(address).startsWith("169.254."))value.address=address;
            }
            values.push_back(value);
        }
        return values;
    }
    void authorizePreparation(const Interface &adapter) {
        if(!adapter.index || adapter.address.startsWith("169.254."))return;
        preparing=true;
        const auto executable=File::getSpecialLocation(File::currentExecutableFile).getFullPathName();
        const auto args="--prepare-project-sync-cable "+String(adapter.index)+" "+adapter.hardware;
        SHELLEXECUTEINFOW info{};info.cbSize=sizeof(info);info.fMask=SEE_MASK_NOCLOSEPROCESS|SEE_MASK_NOASYNC;
        info.lpVerb=L"runas";info.lpFile=executable.toWideCharPointer();info.lpParameters=args.toWideCharPointer();info.nShow=SW_HIDE;
        DWORD result=NO_ERROR;
        if(!ShellExecuteExW(&info))result=GetLastError();
        else if(info.hProcess) {
            while(!threadShouldExit() && WaitForSingleObject(info.hProcess,200)==WAIT_TIMEOUT) {}
            GetExitCodeProcess(info.hProcess,&result);CloseHandle(info.hProcess);
        }
        if(result!=NO_ERROR) {
            const ScopedLock lock(mutex);
            error=result==ERROR_CANCELLED?String::fromUTF8("A preparação do cabo não foi autorizada. Busque novamente para tentar."):String::fromUTF8("Não foi possível preparar o cabo Ethernet (")+String(result)+").";
        }
        preparing=false;
    }
    void run() override {
        while(!threadShouldExit()) {
            const auto previous=currentInterface();
            const auto values=interfaces();
            Interface next;
            {const ScopedLock lock(mutex);
                available=values;
                for(const auto &value:values)if(value.connected && (selected.isEmpty() || value.hardware==selected) && (!next.index || value.index==previous.index))next=value;
                current=next;
            }
            if(prepareRequested.exchange(false))authorizePreparation(next);
            wait(500);
        }
    }
};
}
