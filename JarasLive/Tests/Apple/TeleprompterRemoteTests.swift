import Foundation

func request(_ url: URL, method: String = "GET", range: String? = nil) -> (Data, HTTPURLResponse) {
    let done = DispatchSemaphore(value: 0)
    let session = URLSession(configuration: .ephemeral)
    var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 3
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    var result: (Data, HTTPURLResponse)?
    session.dataTask(with: request) { data, response, _ in
        if let data, let response = response as? HTTPURLResponse { result = (data, response) }
        done.signal()
    }.resume()
    precondition(done.wait(timeout: .now() + 5) == .success, "HTTP request timed out")
    session.invalidateAndCancel()
    return result!
}
let server = TeleprompterHTTPServer()
precondition(server.path == "/", "The browser must open at the root, without a link code")
let ready = DispatchSemaphore(value: 0)
var port: UInt16 = 0
server.start(port: 0, ready: { port = $0; ready.signal() }, failed: { fatalError($0) })
precondition(ready.wait(timeout: .now() + 5) == .success, "Listener did not start")
let url = URL(string: "http://127.0.0.1:\(port)\(server.path)")!
var payload = TeleprompterRemotePayload()
payload.text = "Lyrics <script>alert(1)</script>"; payload.chords = "Am"; payload.song = "Song 2"
payload.timer = "-00:00:01"; payload.expired = true
payload.blocks = [TeleprompterRemoteBlock(name: "Bloco 01", color: 123, duration: 10, songs: [])]
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let file = folder.appendingPathComponent("video.mp4")
let source = Data((0..<200000).map { UInt8($0 % 251) })
try source.write(to: file); payload.mediaID = "video"; payload.mediaKind = "video"
server.publish(payload, mediaURL: file)
let page = request(url)
precondition(page.1.statusCode == 200 && String(decoding: page.0, as: UTF8.self).contains("textContent"), "Missing browser page")
let state = request(url.appendingPathComponent("state"))
let decoded = try JSONDecoder().decode(TeleprompterRemotePayload.self, from: state.0)
precondition(decoded.song == payload.song && decoded.text == payload.text && decoded.blocks.count == 1 && decoded.expired)
precondition(request(url.appendingPathComponent("unknown")).1.statusCode == 404, "Unknown paths must not expose content")
precondition(request(url.appendingPathComponent("media/../outside")).1.statusCode == 404)
let media = url.appendingPathComponent("media/video")
let partial = request(media, range: "bytes=500-699")
precondition(partial.1.statusCode == 206 && partial.0 == source.subdata(in: 500..<700))
precondition(partial.1.value(forHTTPHeaderField: "Content-Range") == "bytes 500-699/200000")
precondition(request(media, range: "bytes=-5").0 == source.suffix(5))
precondition(request(media, range: "bytes=200000-").1.statusCode == 416)
precondition(request(media).0 == source, "Chunked media content differs")
let head = request(media, method: "HEAD")
precondition(head.0.isEmpty && head.1.value(forHTTPHeaderField: "Content-Length") == "200000")
payload.preview = true; payload.mediaID = nil
server.publish(payload, mediaURL: nil)
precondition(request(media).1.statusCode == 404, "Preview still serves video")
let stopped = DispatchSemaphore(value: 0)
server.stop { stopped.signal() }
precondition(stopped.wait(timeout: .now() + 5) == .success)

print("TP_REMOTE_HTTP_OK: live content, short root link, preview, HEAD, media ranges, streamed file, shutdown")
