#if os(macOS)
import SwiftUI
import AppKit
import Network
import CoreImage
import UniformTypeIdentifiers
import Darwin

struct TeleprompterRemoteSong: Codable {
    var name: String
    var color: UInt32
    var duration: Double
}
struct TeleprompterRemoteBlock: Codable {
    var name: String
    var color: UInt32
    var duration: Double
    var songs: [TeleprompterRemoteSong]
}
struct TeleprompterRemotePayload: Codable {
    var text = "", chords = "", song = "", queued = ""
    var progress = 0.0, preview = false
    var blocks: [TeleprompterRemoteBlock] = []
    var settings = TeleprompterSettings()
    var timer = "00:00:00", expired = false
    var localTime = ""
    var mediaID: String?, mediaKind: String?
    var mediaTime = 0.0, mediaRate = 0.0
    var mediaStretch = false
}

/// The audio callback never touches networking. The worker serves immutable
/// snapshots and streams media in bounded chunks without decoding any frames.
final class TeleprompterHTTPServer {
    private let queue = DispatchQueue(label: "jaras.teleprompter.network", qos: .utility)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var waitingForHeaders: Set<ObjectIdentifier> = []
    private var state = Data("{}".utf8)
    private var media: (id: String, url: URL)?
    private var stopped = false
    func start(port: UInt16 = 10101, ready: @escaping (UInt16) -> Void, failed: @escaping (String) -> Void) {
        queue.async { [self] in
            do {
                let listener = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] value in
                    guard let self, !self.stopped else { return }
                    switch value {
                    case .ready: if let port = listener?.port { ready(port.rawValue) }
                    case .failed(let error): self.stopOnQueue(); failed(error.localizedDescription)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, !self.stopped, self.connections.count < 32 else { connection.cancel(); return }
                    self.connections[ObjectIdentifier(connection)] = connection
                    self.waitingForHeaders.insert(ObjectIdentifier(connection))
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        guard let self, let connection else { return }
                        if case .cancelled = state { self.connections.removeValue(forKey: ObjectIdentifier(connection)); self.waitingForHeaders.remove(ObjectIdentifier(connection)) }
                        if case .failed = state { connection.cancel() }
                    }
                    connection.start(queue: self.queue)
                    self.receive(connection, accumulated: Data())
                    self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
                        guard let self, let connection, self.waitingForHeaders.contains(ObjectIdentifier(connection)) else { return }
                        connection.cancel()
                    }
                }
                listener.start(queue: queue)
            } catch { failed(error.localizedDescription) }
        }
    }
    func stop(completion: (() -> Void)? = nil) { queue.async { [self] in stopOnQueue(); completion?() } }
    private func stopOnQueue() {
        stopped = true; listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll(); waitingForHeaders.removeAll(); media = nil
    }
    var path: String { "/" }
    func publish(_ payload: TeleprompterRemotePayload, mediaURL: URL?) {
        queue.async { [self] in
            guard !stopped, let data = try? JSONEncoder().encode(payload) else { return }
            state = data
            media = payload.mediaID.flatMap { id in mediaURL.map { (id, $0) } }
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = accumulated; if let data { request.append(data) }
            guard request.count <= 16384 else { self.respond(connection, status: "431 Request Header Fields Too Large", body: Data()); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { self.route(connection, request: String(decoding: request, as: UTF8.self)) }
            else if complete { connection.cancel() }
            else { self.receive(connection, accumulated: request) }
        }
    }
    private func route(_ connection: NWConnection, request: String) {
        waitingForHeaders.remove(ObjectIdentifier(connection))
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count >= 2, first[0] == "GET" || first[0] == "HEAD" else {
            respond(connection, status: "405 Method Not Allowed", body: Data()); return
        }
        let endpoint = String(first[1]).components(separatedBy: "?")[0]
        let head = first[0] == "HEAD"
        if endpoint == path {
            respond(connection, body: Data(Self.page.utf8), type: "text/html; charset=utf-8", head: head)
        } else if endpoint == path + "state" {
            respond(connection, body: state, type: "application/json; charset=utf-8", head: head)
        } else if let media, endpoint == path + "media/" + media.id {
            stream(connection, url: media.url, headers: lines, head: head)
        } else { respond(connection, status: "404 Not Found", body: Data()) }
    }
    private func respond(_ connection: NWConnection, status: String = "200 OK", body: Data, type: String = "text/plain", head: Bool = false) {
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        var data = Data(headers.utf8); if !head { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func stream(_ connection: NWConnection, url: URL, headers: [String], head: Bool) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
              let file = try? FileHandle(forReadingFrom: url) else {
            respond(connection, status: "404 Not Found", body: Data()); return
        }
        var start: UInt64 = 0, end = UInt64(size - 1), partial = false
        if let range = headers.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let parts = range.components(separatedBy: "bytes=").last?.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false) ?? []
            guard parts.count == 2 else { try? file.close(); respond(connection, status: "416 Range Not Satisfiable", body: Data()); return }
            if parts[0].isEmpty, let suffix = UInt64(parts[1]), suffix > 0 { start = UInt64(size) - min(UInt64(size), suffix) }
            else if let value = UInt64(parts[0]) { start = value; if let last = UInt64(parts[1]) { end = min(end, last) } }
            else { try? file.close(); respond(connection, status: "416 Range Not Satisfiable", body: Data()); return }
            guard start <= end else { try? file.close(); respond(connection, status: "416 Range Not Satisfiable", body: Data()); return }
            partial = true
        }
        let count = end - start + 1
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(type)\r\nContent-Length: \(count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if partial { header += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        header += "\r\n"
        do { try file.seek(toOffset: start) } catch { try? file.close(); connection.cancel(); return }
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard !head, error == nil, let self else { try? file.close(); connection.cancel(); return }
            self.sendFile(file, remaining: count, connection: connection)
        })
    }
    private func sendFile(_ file: FileHandle, remaining: UInt64, connection: NWConnection) {
        guard remaining > 0, !stopped else { try? file.close(); connection.cancel(); return }
        do {
            guard let data = try file.read(upToCount: Int(min(65536, remaining))), !data.isEmpty else { try? file.close(); connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { try? file.close(); connection.cancel(); return }
                self.sendFile(file, remaining: remaining - UInt64(data.count), connection: connection)
            })
        } catch { try? file.close(); connection.cancel() }
    }
    private static let page = #"""
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>CatLive Teleprompter</title>
<style>
*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000;color:white;font-family:Arial,sans-serif}
#screen{position:relative;display:flex;flex-direction:column;height:100dvh;padding:6px;border:2px solid transparent;border-radius:6px}
#top,#bottom{position:relative;z-index:2;flex-shrink:0}#content{position:relative;z-index:2;flex:1;min-height:0;display:flex;align-items:center;justify-content:center;overflow:hidden}
#lyrics{white-space:pre-wrap;line-height:1.16;padding:6px;border:2px solid transparent;border-radius:6px;max-width:100%}
.row{display:flex;align-items:center;gap:8px}.timer,.clock{padding:5px 10px;border:2px solid transparent;border-radius:6px;font-weight:bold;white-space:nowrap;font-variant-numeric:tabular-nums}
.clock{padding:5px;border-width:1px;line-height:1.15}
.title,.chords{text-align:center;padding:4px;overflow:hidden}.title{white-space:nowrap;text-overflow:ellipsis}.chords{border:1px solid transparent;border-radius:6px;white-space:pre-wrap}
.progress{height:5px;background:#ffffff20}.progress div{height:100%}#blocks{display:none;width:100%;height:100%;gap:8px;align-items:start}.block{padding:6px;border:1px solid;border-radius:6px;overflow:hidden}
video,img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;z-index:0}#connection{position:absolute;bottom:10px;right:10px;z-index:4;color:#ffdc52;font-size:12px;display:none}
@keyframes blink{0%,49%{opacity:1}50%,100%{opacity:.25}}.expired{animation:blink 1s infinite}
</style></head><body><div id="screen"><video id="video" muted playsinline></video><img id="image" hidden><div id="top"></div><div id="content"><div id="lyrics"></div><div id="blocks"></div></div><div id="bottom"></div><div id="connection">Connecting…</div></div>
<script>
const $=id=>document.getElementById(id),hex=n=>'#'+Number(n).toString(16).padStart(6,'0');
const fonts={system:'Arial,sans-serif',arial:'Arial,sans-serif',mono:'monospace',georgia:'Georgia,serif',verdana:'Verdana,sans-serif',tahoma:'Tahoma,sans-serif',impact:'Impact,sans-serif',trebuchet:'Trebuchet MS,sans-serif',segoe:'Segoe UI,sans-serif',bahnschrift:'Bahnschrift,sans-serif'};
let current=null,lastBody='',mediaID='',lastStamp=performance.now();
function color(n,rgb){return rgb?'hsl('+((Date.now()/6000*360)%360)+',90%,55%)':hex(n)}
function duration(v){let n=Math.ceil(v);return (n>=3600?Math.floor(n/3600)+':':'')+String(Math.floor(n/60)%60).padStart(2,'0')+':'+String(n%60).padStart(2,'0')}
function applyCase(v,s){return s.textCase==='uppercase'?v.toUpperCase():s.textCase==='lowercase'?v.toLowerCase():v}
function textNode(tag,cls,text){const e=document.createElement(tag);e.className=cls;e.textContent=text;return e}
function decorations(d,position){const s=d.settings,host=$(position);host.replaceChildren();if(s.clearMode)return;
 const clockHere=s.clockEnabled&&s.clockPosition.endsWith(position),localHere=s.localClockEnabled&&(s.clockEnabled?clockHere:position==='top');
 if(clockHere||localHere){const row=document.createElement('div');row.className='row';
 const timerFont=Math.max(innerHeight>innerWidth?15:18,Math.min((innerWidth-16)/11,innerHeight/8)*s.clockScale/100);
 if(clockHere){const e=textNode('div','timer'+(d.expired?' expired':''),d.timer);e.style.color=hex(d.expired?s.clockExpiredColor:s.clockColor);e.style.fontSize=timerFont+'px';if(s.clockBorderEnabled)e.style.borderColor=color(s.clockBorderColor,s.rgbClockBorderEnabled);if(d.expired)e.style.animationDelay='-'+Date.now()%1000+'ms';row.append(e)}
 if(localHere){const e=textNode('div','clock',d.localTime);e.style.color=hex(s.localClockColor);const side=clockHere&&!s.clockPosition.startsWith('center');e.style.fontSize=(side?Math.max(innerHeight>innerWidth?15:18,Math.min((innerWidth-16)/11,innerHeight/8)*s.localClockScale/100):Math.max(10,Math.min(24,innerHeight/28)*s.localClockScale/100))+'px';if(s.localClockBorderEnabled)e.style.borderColor=hex(s.localClockBorderColor);if(s.localClockPosition==='left')row.prepend(e);else row.append(e)}
 row.style.justifyContent=s.clockPosition.startsWith('left')?'flex-start':s.clockPosition.startsWith('right')?'flex-end':'center';
 if(clockHere&&localHere){const timer=row.querySelector('.timer'),clock=row.querySelector('.clock');if(s.clockPosition.startsWith('center')){clock.style.position='absolute';clock.style[s.localClockPosition==='left'?'left':'right']='0';clock.style[s.clockPosition.endsWith('bottom')?'bottom':'top']='0';clock.style.maxWidth='calc((100% - '+(timer.textContent.length*parseFloat(timer.style.fontSize)*.65+36)+'px) / 2 - 8px)';clock.style.overflow='hidden'}else{row.replaceChildren(...(s.clockPosition.startsWith('right')?[clock,timer]:[timer,clock]));for(const e of [timer,clock]){e.style.flex='1';e.style.textAlign='center'}}}
 else if(localHere){row.style.justifyContent=s.localClockPosition==='left'?'flex-start':'flex-end'}
 const side=clockHere&&localHere&&!s.clockPosition.startsWith('center');
 row.style.height=Math.max(28,(side?Math.max(timerFont,parseFloat(row.querySelector('.clock').style.fontSize)):timerFont)+(side?10:18))+'px';
 host.append(row)}
 for(const [enabled,pos,value,col,scale,font] of [[s.songNameEnabled,s.songNamePosition,d.song,s.songNameColor,s.songNameScale,s.songNameFontFamily],[s.queueNameEnabled,s.queueNamePosition,d.queued,s.queueNameColor,s.queueNameScale,s.queueNameFontFamily]])if(enabled&&value&&pos===position){const e=textNode('div','title',applyCase(value,s));e.style.color=hex(col);e.style.fontSize=22*scale/100+'px';e.style.fontFamily=fonts[font];host.append(e)}
 if(!d.preview&&s.chordsEnabled&&d.chords&&s.chordPosition===position){const e=textNode('div','chords',applyCase(d.chords,s));e.style.color=hex(s.chordColor);e.style.fontSize=s.chordScale+'px';e.style.fontFamily=fonts[s.chordFontFamily];e.style.borderColor=color(s.chordColor,s.rgbChordBorderEnabled);host.append(e)}
 if(s.progressEnabled&&s.progressPosition===position){const e=document.createElement('div');e.className='progress';const fill=document.createElement('div');fill.style.width=Math.max(0,Math.min(1,d.progress))*100+'%';fill.style.background=hex(s.progressColor);e.append(fill);host.append(e)}
}
function render(d){current=d;const s=d.settings;$('screen').style.borderColor=!s.clearMode&&s.windowBorderEnabled?color(s.borderColor,s.rgbWindowBorderEnabled):'transparent';decorations(d,'top');decorations(d,'bottom');
 $('lyrics').style.display=s.clearMode||d.preview?'none':'block';$('blocks').style.display=!s.clearMode&&d.preview?'grid':'none';$('lyrics').textContent=applyCase(d.text,s);
 $('lyrics').style.color=hex(s.textColor);$('lyrics').style.fontFamily=fonts[s.fontFamily];$('lyrics').style.textAlign=s.textAlignment;
 $('lyrics').style.borderColor=s.textBoxEnabled&&d.text?color(s.textBoxColor,s.rgbTextBoxBorderEnabled):'transparent';
 $('content').style.justifyContent=s.textAlignment==='left'?'flex-start':s.textAlignment==='right'?'flex-end':'center';
 const lines=d.text.split('\n'),longest=Math.max(1,...lines.map(v=>v.length));$('lyrics').style.fontSize=Math.max(9,Math.min(120,($('content').clientWidth-20)/(longest*.64),($('content').clientHeight-20)/(lines.length*1.2))*s.textScale/100)+'px';
 $('blocks').replaceChildren();$('blocks').style.gridTemplateColumns='repeat('+Math.max(1,d.blocks.length)+',minmax(0,1fr))';
 const maxSongs=Math.max(1,...d.blocks.map(b=>b.songs.length+(b.name?1:0)));const font=Math.max(9,Math.min((innerWidth/Math.max(1,d.blocks.length)-20)/13,($('content').clientHeight-20)/maxSongs/1.1)*s.previewScale/100);
 for(const b of d.blocks){const e=document.createElement('div');e.className='block';e.style.borderColor=hex(b.color);e.style.fontSize=font+'px';e.style.fontFamily=fonts[s.previewFontFamily];if(b.name){const t=textNode('div','',applyCase(b.name,s)+(s.previewBlockDurationEnabled&&b.duration?' • '+duration(b.duration):''));t.style.color=hex(b.color);e.append(t)}for(const song of b.songs){const t=textNode('div','',applyCase(song.name,s)+(s.previewSongDurationEnabled?' • '+duration(song.duration):''));t.style.color=hex(song.color);if(s.previewUnderlineEnabled)t.style.textDecoration='underline';e.append(t)}$('blocks').append(e)}
 const v=$('video'),im=$('image');v.hidden=(d.preview&&!s.clearMode)||d.mediaKind!=='video';im.hidden=(d.preview&&!s.clearMode)||d.mediaKind!=='image';
 v.style.objectFit=d.mediaStretch?'fill':'contain';for(const media of [v,im])media.style.transform='scale('+(s.clearMode?1:s.mediaScale/100)+')';
 if((d.preview&&!s.clearMode)||!d.mediaID){v.pause();if(mediaID){v.removeAttribute('src');v.load();im.removeAttribute('src');mediaID=''}}
 else if(mediaID!==d.mediaID){mediaID=d.mediaID;if(d.mediaKind==='video'){v.src='media/'+encodeURIComponent(mediaID);v.load()}else {v.pause();im.src='media/'+encodeURIComponent(mediaID)}}
 if(!v.hidden){if(v.readyState>=1&&Math.abs(v.currentTime-d.mediaTime)>.3)v.currentTime=d.mediaTime;if(d.mediaRate>0){v.playbackRate=d.mediaRate;v.play().catch(()=>{})}else v.pause()}
}
async function poll(){try{const r=await fetch('state',{cache:'no-store'});if(!r.ok)throw Error();const body=await r.text(),d=JSON.parse(body);if(!d.settings)throw Error();$('connection').style.display='none';lastStamp=performance.now();if(body!==lastBody){lastBody=body;render(d)}}catch{ $('connection').style.display='block';$('video').pause()}finally{setTimeout(poll,250)}}
addEventListener('resize',()=>{if(current)render(current)});addEventListener('dblclick',()=>{if(document.fullscreenElement)document.exitFullscreen();else document.documentElement.requestFullscreen().catch(()=>{})});
$('video').addEventListener('loadedmetadata',()=>{if(current)$('video').currentTime=current.mediaTime});poll();
setInterval(()=>{if(!current)return;const s=current.settings;if(s.clearMode)return;
 if(s.windowBorderEnabled&&s.rgbWindowBorderEnabled)$('screen').style.borderColor=color(s.borderColor,true);
 const timer=document.querySelector('.timer'),chords=document.querySelector('.chords');
 if(timer&&s.clockBorderEnabled&&s.rgbClockBorderEnabled)timer.style.borderColor=color(s.clockBorderColor,true);
 if(s.textBoxEnabled&&s.rgbTextBoxBorderEnabled&&current.text)$('lyrics').style.borderColor=color(s.textBoxColor,true);
 if(chords&&s.rgbChordBorderEnabled)chords.style.borderColor=color(s.chordColor,true);
},200);
</script></body></html>
"""#
}

@MainActor final class TeleprompterRemote: ObservableObject {
    static let shared = TeleprompterRemote()
    @Published private(set) var enabled = false
    @Published private(set) var link = ""
    @Published private(set) var message = ""
    @Published private(set) var qrCode: NSImage?
    private var server: TeleprompterHTTPServer?
    private var refresh: (() -> Void)?
    private var directory: URL?
    private var payload = TeleprompterRemotePayload()
    private var mediaURL: URL?
    private var heartbeat: Timer?
    private var lastPublish = 0.0
    func configure(directory: URL?, refresh: @escaping () -> Void) { self.directory = directory; self.refresh = refresh }
    func setDirectory(_ directory: URL?) { self.directory = directory; clear() }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if !value {
            enabled = false; server?.stop(); server = nil
            heartbeat?.invalidate(); heartbeat = nil; link = ""; qrCode = nil; message = ""
            payload = TeleprompterRemotePayload(); mediaURL = nil
            return
        }
        enabled = true; message = ""; lastPublish = 0
        let service = TeleprompterHTTPServer(); server = service
        service.start(ready: { [weak self, weak service] port in
            Task { @MainActor in
                guard let self, let service, self.server === service, self.enabled else { return }
                let address = Self.networkAddress()
                self.link = "http://\(address ?? "127.0.0.1"):\(port)"
                self.qrCode = Self.qr(self.link)
                if address == nil { self.message = "Connect to a local network to use TP Remote." }
                self.refresh?(); self.publish()
            }
        }, failed: { [weak self, weak service] error in
            Task { @MainActor in
                guard let self, self.server === service else { return }
                self.setEnabled(false); self.message = error
            }
        })
        heartbeat = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh?(); self?.publish() }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        refresh?(); publish()
    }
    func clear() { payload = TeleprompterRemotePayload(); mediaURL = nil; publish() }
    func update(text: String, chords: String, song: String, queued: String, progress: Double, preview: Bool, blocks: [TeleprompterRemoteBlock], snapshot: ShowSnapshot) {
        guard enabled, ProcessInfo.processInfo.systemUptime - lastPublish >= 0.1 else { return }
        payload.text = text; payload.chords = chords; payload.song = song; payload.queued = queued
        payload.progress = progress; payload.preview = preview; payload.blocks = blocks
        payload.mediaStretch = TeleprompterPreferences.shared.settings.stretchesMedia
        mediaURL = nil; payload.mediaID = nil; payload.mediaKind = nil
        let t = snapshot.transport, position = t.playing || t.paused == true ? t.position : t.editPosition ?? t.position
        if !preview || TeleprompterPreferences.shared.settings.isClear, let directory,
           let song = snapshot.project.songs.first(where: { $0.id == t.songId }),
           let clip = song.tracks.lazy.filter({ $0.kind == .teleprompt && !$0.mute }).flatMap(\.clips).first(where: { $0.isProjectionMedia && $0.muted != true && position >= $0.startTime && position < $0.startTime + $0.duration }),
           let file = clip.audioFile {
            mediaURL = directory.appendingPathComponent(file.path)
            payload.mediaID = clip.id.uuidString
            payload.mediaKind = UTType(filenameExtension: mediaURL!.pathExtension)?.conforms(to: .image) == true ? "image" : "video"
            payload.mediaTime = max(0, clip.sourceOffset + (position - clip.startTime) * clip.audioRate)
            payload.mediaRate = t.playing ? clip.audioRate : 0
        }
        publish()
    }
    private func publish() {
        guard enabled else { return }
        payload.settings = TeleprompterPreferences.shared.settings
        payload.timer = TeleprompterTimerController.shared.displayText(spaced: true)
        payload.expired = TeleprompterTimerController.shared.expired()
        let values = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        payload.localTime = String(format: "%02d:%02d:%02d", values.hour ?? 0, values.minute ?? 0, values.second ?? 0)
        lastPublish = ProcessInfo.processInfo.systemUptime
        server?.publish(payload, mediaURL: mediaURL)
    }
    private static func qr(_ link: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(link.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, let bitmap = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: bitmap, size: output.extent.size)
    }
    private static func networkAddress() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var candidates: [(String, String)] = [], cursor = addresses
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((name, String(cString: host)))
            }
        }
        return candidates.sorted { ($0.0.hasPrefix("en") ? 0 : 1, $0.0) < ($1.0.hasPrefix("en") ? 0 : 1, $1.0) }.first?.1
    }
}

struct TeleprompterRemoteView: View {
    let close: () -> Void
    @ObservedObject private var remote = TeleprompterRemote.shared
    @AppStorage("jaras.language") private var language = "en"
    @State private var copied = false
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("TP Remoto").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { remote.enabled }, set: { remote.setEnabled($0); copied = false })).toggleStyle(.switch).tint(JarasTheme.green).accessibilityLabel("Enabled")
            }
            if let image = remote.qrCode {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 190, height: 190).padding(10).background(Color.white).cornerRadius(6)
            } else {
                Image(systemName: "qrcode").font(.system(size: 100)).foregroundStyle(JarasTheme.secondary).frame(width: 210, height: 210)
            }
            Text(remote.enabled ? "Open this link on a device connected to the same network." : "Enable TP Remote to share the teleprompter.")
                .font(.caption).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Text(remote.link.isEmpty ? "—" : remote.link).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(JarasTheme.display).cornerRadius(5)
                Button(copied ? "Copied" : "Copy link") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(remote.link, forType: .string); copied = true
                }.disabled(remote.link.isEmpty)
            }
            if !remote.message.isEmpty { Text(LocalizedStringKey(remote.message)).font(.caption).foregroundStyle(JarasTheme.yellow) }
            HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 420).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark)
    }
}
#endif
