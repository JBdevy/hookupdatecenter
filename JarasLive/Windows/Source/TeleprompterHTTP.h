#pragma once
#include "Common.h"
#include <winsock2.h>
#include <BinaryData.h>
namespace catlive {
// The network worker only reads immutable snapshots; no socket or disk access
// is performed by the audio callback or the message-thread publisher.
class TeleprompterHTTP final : private Thread {
  public:
    TeleprompterHTTP() : Thread("CatLive TP web") {}
    ~TeleprompterHTTP() override { stop(); }
    void start(int port, String address="0.0.0.0") {
        stop();listener=std::make_unique<StreamingSocket>();
        if(!listener->createListener(port,address)){listener.reset();throw std::runtime_error("Não foi possível iniciar o TP Remoto nesta porta.");}
        startThread();
    }
    void stop() {signalThreadShouldExit();notify();stopThread(-1);listener.reset();clients.clear();const ScopedLock lock(mutex);snapshot={};}
    bool enabled() const {return isThreadRunning();}
    int port() const {return listener?listener->getBoundPort():0;}
    static String localAddress(const Array<IPAddress> &addresses) {
        String address;
        for (const auto &ip : addresses) {
            // Windows also enumerates multicast memberships on each adapter.
            // Only a unicast interface address is a usable browser destination.
            if (ip.isIPv6 || ip.address[0] == 0 || ip.address[0] == 127 || ip.address[0] >= 224)
                continue;
            const auto value = ip.toString();
            if (address.isEmpty() || address.startsWith("169.254.")) address = value;
        }
        return address;
    }
    String link() const {
        if(!enabled())return {};
        const auto address=localAddress(IPAddress::getAllAddresses());
        return address.isEmpty()?String():"http://"+address+":"+String(port());
    }
    void publish(const var &state, File media={}, Image notice={}) {
        Snapshot next;next.json=JSON::toString(state,true);next.media=std::move(media);next.id=str(state,"mediaID");
        if(notice!=cachedNoticeImage) {
            cachedNoticeImage=notice;cachedNoticePNG.reset();
            if(notice.isValid()) { MemoryOutputStream bytes;PNGImageFormat png;
                if(png.writeImageToStream(notice,bytes))cachedNoticePNG=std::make_shared<const MemoryBlock>(bytes.getMemoryBlock()); }
        }
        next.noticePNG=cachedNoticePNG;next.noticeID=str(get(state,"notice"),"imageID");
        const ScopedLock lock(mutex);snapshot=std::move(next);
    }
  private:
    struct Snapshot {String json="{}",id,noticeID;File media;std::shared_ptr<const MemoryBlock> noticePNG;};
    Image cachedNoticeImage;
    std::shared_ptr<const MemoryBlock> cachedNoticePNG;
    struct Client {
        std::unique_ptr<StreamingSocket> socket;
        String headers;
        MemoryBlock pending;
        size_t sent=0;
        std::unique_ptr<FileInputStream> file;
        int64 remaining=0;
        double progress=Time::getMillisecondCounterHiRes();
        bool routed=false,closed=false;
    };
    CriticalSection mutex;Snapshot snapshot;
    std::unique_ptr<StreamingSocket> listener;
    std::vector<std::unique_ptr<Client>> clients;
    static void queue(Client &c,const String &text){const auto bytes=text.toUTF8();c.pending.append(bytes.getAddress(),(size_t)text.getNumBytesAsUTF8());}
    static void response(Client &c,const String &status,const String &body={},const String &type="text/plain",bool head=false){
        queue(c,"HTTP/1.1 "+status+"\r\nContent-Type: "+type+"\r\nContent-Length: "+String(body.getNumBytesAsUTF8())+"\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n");
        if(!head)queue(c,body);c.routed=true;
    }
    static String mime(const File &file){
        const auto e=file.getFileExtension().toLowerCase();
        if(e==".png")return "image/png";if(e==".jpg"||e==".jpeg")return "image/jpeg";
        if(e==".gif")return "image/gif";if(e==".webp")return "image/webp";if(e==".bmp")return "image/bmp";
        if(e==".mp4"||e==".m4v")return "video/mp4";if(e==".mov")return "video/quicktime";
        if(e==".webm")return "video/webm";return "application/octet-stream";
    }
    void route(Client &c){
        const auto lines=StringArray::fromLines(c.headers);
        const auto first=StringArray::fromTokens(lines[0]," ","");
        if(first.size()<2||(first[0]!="GET"&&first[0]!="HEAD")){response(c,"405 Method Not Allowed");return;}
        const bool head=first[0]=="HEAD";
        const auto path=first[1].upToFirstOccurrenceOf("?",false,false);
        if(path=="/"){response(c,"200 OK",String::fromUTF8(BinaryData::Teleprompter_html,BinaryData::Teleprompter_htmlSize),"text/html; charset=utf-8",head);return;}
        Snapshot state;{const ScopedLock lock(mutex);state=snapshot;}
        if(path=="/state"){response(c,"200 OK",state.json,"application/json; charset=utf-8",head);return;}
        if(state.noticeID.isNotEmpty() && path=="/notice/"+state.noticeID && state.noticePNG) {
            queue(c,"HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: "+String((int64)state.noticePNG->getSize())+"\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n");
            if(!head)c.pending.append(state.noticePNG->getData(),state.noticePNG->getSize());
            c.routed=true;return;
        }
        if(state.id.isEmpty()||path!="/media/"+state.id||!state.media.existsAsFile()){response(c,"404 Not Found");return;}
        c.file=state.media.createInputStream();
        const int64 size=c.file?c.file->getTotalLength():0;
        if(size<=0){response(c,"404 Not Found");return;}
        int64 start=0,end=size-1;bool partial=false;
        auto number=[](const String &value)->std::optional<int64>{
            const auto trimmed=value.trim();if(trimmed.isEmpty()||trimmed.length()>18||trimmed.containsAnyOf("+ -")||trimmed.retainCharacters("0123456789")!=trimmed)return {};
            return trimmed.getLargeIntValue();
        };
        for(const auto &line:lines)if(line.startsWithIgnoreCase("Range:")){
            const auto range=line.fromFirstOccurrenceOf(":",false,false).trim();
            if(!range.startsWith("bytes=")||range.containsChar(',')){response(c,"416 Range Not Satisfiable");return;}
            const auto parts=StringArray::fromTokens(range.substring(6),"-","");
            if(parts.size()!=2){response(c,"416 Range Not Satisfiable");return;}
            if(parts[0].isEmpty()){
                const auto suffix=number(parts[1]);if(!suffix||*suffix<=0){response(c,"416 Range Not Satisfiable");return;}start=std::max<int64>(0,size-*suffix);
            }else{
                const auto offset=number(parts[0]);if(!offset){response(c,"416 Range Not Satisfiable");return;}start=*offset;
                if(parts[1].isNotEmpty()){const auto last=number(parts[1]);if(!last){response(c,"416 Range Not Satisfiable");return;}end=std::min(end,*last);}
            }
            if(start>end){response(c,"416 Range Not Satisfiable");return;}partial=true;
        }
        if(!c.file->setPosition(start)){response(c,"404 Not Found");return;}
        const auto count=end-start+1;
        String header="HTTP/1.1 "+String(partial?"206 Partial Content":"200 OK")+"\r\nContent-Type: "+mime(state.media)+"\r\nContent-Length: "+String(count)+"\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n";
        if(partial)header+="Content-Range: bytes "+String(start)+"-"+String(end)+"/"+String(size)+"\r\n";
        queue(c,header+"\r\n");c.remaining=head?0:count;c.routed=true;
    }
    void poll(Client &c){
        const auto now=Time::getMillisecondCounterHiRes();
        if(now-c.progress>10000){c.closed=true;return;}
        if(!c.routed&&c.socket->waitUntilReady(true,0)>0){
            char data[8192];const int n=c.socket->read(data,sizeof(data),false);
            if(n<=0){c.closed=true;return;}
            c.headers+=String::fromUTF8(data,n);
            if(c.headers.length()>16384)response(c,"431 Request Header Fields Too Large");
            else if(c.headers.contains("\r\n\r\n"))route(c);
        }
        if(!c.routed)return;
        if(c.sent==c.pending.getSize()){
            c.pending.reset();c.sent=0;
            if(c.remaining==0){c.closed=true;return;}
            char data[65536];const int n=c.file->read(data,(int)std::min<int64>(sizeof(data),c.remaining));
            if(n<=0){c.closed=true;return;}c.pending.append(data,(size_t)n);c.remaining-=n;
        }
        if(c.socket->waitUntilReady(false,0)>0){
            const int n=c.socket->write((const char*)c.pending.getData()+c.sent,(int)(c.pending.getSize()-c.sent));
            if(n<0){if(WSAGetLastError()!=WSAEWOULDBLOCK)c.closed=true;}
            else if(n>0){c.sent+=(size_t)n;c.progress=now;}
        }
    }
    void run() override {
        while(!threadShouldExit()){
            if(listener->waitUntilReady(true,0)>0){
                std::unique_ptr<StreamingSocket> socket(listener->waitForNextConnection());
                if(socket&&clients.size()<32){
                    u_long mode=1;
                    if(ioctlsocket((SOCKET)socket->getRawSocketHandle(),FIONBIO,&mode)==0){auto client=std::make_unique<Client>();client->socket=std::move(socket);clients.push_back(std::move(client));}
                }
            }
            for(auto &client:clients)poll(*client);
            clients.erase(std::remove_if(clients.begin(),clients.end(),[](const auto &c){return c->closed;}),clients.end());
            wait(5);
        }
    }
};
}
