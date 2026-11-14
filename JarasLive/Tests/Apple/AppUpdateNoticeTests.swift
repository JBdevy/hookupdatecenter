import AppKit
import Foundation

private final class UpdateURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor private final class UpdateObserver: DesktopUpdateNoticeObserver {
    var values: [DesktopUpdateNotice?] = []
    func desktopUpdateNoticeChanged(_ notice: DesktopUpdateNotice?) { values.append(notice) }
}
@main struct AppUpdateNoticeTests {
    static func payload(_ version: String, url: String = "https://catlive.com/download") -> Data {
        try! JSONSerialization.data(withJSONObject: ["enabled": true, "version": version, "url": url])
    }
    @MainActor static func main() async {
        precondition(DesktopUpdateVersion("1.35") == DesktopUpdateVersion("1.35.0"))
        precondition(DesktopUpdateVersion("1.35")! > DesktopUpdateVersion("1.09")!)
        precondition(DesktopUpdateVersion("2.00")! > DesktopUpdateVersion("1.99")!)
        precondition(DesktopUpdateVersion("999999999999999999999999999999.00")! > DesktopUpdateVersion("2.00")!)
        precondition(DesktopUpdateVersion("1.35.0.0")!.queryValue == "1.35")
        precondition(DesktopUpdateVersion("1.9")!.queryValue == "1.09")
        for version in ["1.9", "1.35.0", "1.350", "1", "1.", ".35", "1.-1", "1.3a", "1.35-beta", "1.35+2", " 1.35", "1.35\n", "１.35"] {
            precondition(DesktopUpdateVersion(version, backend: true) == nil, "Invalid backend version: \(version)")
        }
        for version in ["1.35", "1.34", "1.09"] {
            let notice = try! DesktopUpdateNoticeClient.decode(payload(version), installedVersion: "1.35.0")
            precondition(notice == nil, "Same or older version must remain hidden")
        }
        let update = try! DesktopUpdateNoticeClient.decode(payload("1.36"), installedVersion: "1.35.0")!
        precondition(update.version == "1.36")
        precondition(try! DesktopUpdateNoticeClient.decode(Data(#"{"enabled":false}"#.utf8), installedVersion: "1.35") == nil)
        precondition(try! DesktopUpdateNoticeClient.decode(Data(#"{"enabled":false,"url":{},"version":null}"#.utf8), installedVersion: "1.35") == nil)
        for body in [#"{}"#, #"{"enabled":1}"#, #"{"enabled":true,"url":"https://example.com"}"#, #"{"enabled":true,"version":"1.36"}"#, #"{"enabled":true,"version":"1.9","url":"https://example.com"}"#] {
            do { _ = try DesktopUpdateNoticeClient.decode(Data(body.utf8), installedVersion: "1.35"); fatalError("Invalid response accepted") } catch {}
        }
        for url in ["https://example.com/update", "http://example.com/update?platform=macos", "https://example.com/a%20b"] {
            precondition(DesktopUpdateNotice.validatedURL(url) != nil)
        }
        for url in ["", "/download", "//example.com", "file:///tmp/app", "javascript:alert(1)", "https:example.com", "https://", "https://user:pass@example.com", "https://user@example.com", "https://example.com/\nupdate", "https://example.com/%0D%0Aupdate", "https://example%20.com/", "https://example.com\\@evil.com", " https://example.com", "https://example.com/a b"] {
            precondition(DesktopUpdateNotice.validatedURL(url) == nil, "Invalid link accepted: \(url)")
            do { _ = try DesktopUpdateNoticeClient.decode(payload("1.36", url: url), installedVersion: "1.35"); fatalError("Invalid link decoded") } catch {}
        }

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdateURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = DesktopUpdateNoticeClient(installedVersion: "1.35.0", session: session)
        UpdateURLProtocol.handler = { request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            precondition(parts.path == "/api/desktop-update")
            precondition(parts.queryItems == [URLQueryItem(name: "platform", value: "macos"), URLQueryItem(name: "version", value: "1.35")])
            precondition(request.timeoutInterval == 5 && request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, payload("1.36"))
        }
        let fetched = try! await client.fetch()
        precondition(fetched == update)
        for status in [204, 404, 500] {
            UpdateURLProtocol.handler = { _ in (status, payload("1.36")) }
            do { _ = try await client.fetch(); fatalError("HTTP \(status) accepted") } catch {}
        }
        UpdateURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await client.fetch(); fatalError("Network failure ignored") } catch {}
        session.invalidateAndCancel()

        var next: Result<DesktopUpdateNotice?, Error> = .success(update)
        var calls = 0
        let service = DesktopUpdateNoticeService { calls += 1; return try next.get() }
        let observer = UpdateObserver(); service.observe(observer)
        precondition(observer.values.count == 1 && observer.values[0] == nil)
        await service.check(); await service.check()
        precondition(calls == 2 && observer.values.count == 2 && service.notice == update, "Unchanged response must not redraw")
        next = .failure(URLError(.timedOut)); await service.check()
        precondition(service.notice == update && observer.values.count == 2, "Failure erased a valid notice")
        next = .success(nil); await service.check()
        precondition(service.notice == nil && observer.values.count == 3, "Disabled/equal response failed to clear")
        var continuation: CheckedContinuation<DesktopUpdateNotice?, Error>?
        var overlappingCalls = 0
        let pending = DesktopUpdateNoticeService {
            overlappingCalls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let first = Task { await pending.check() }
        while continuation == nil { await Task.yield() }
        await pending.check()
        precondition(overlappingCalls == 1, "Overlapping network checks")
        continuation?.resume(returning: update); await first.value
        precondition(pending.notice == update)

        _ = NSApplication.shared
        var opened: [URL] = []
        let title = ProjectTitlebarVersionView(service: service, startsService: false, openURL: { opened.append($0) })
        let baseWidth = title.preferredWidth
        var widthChanges = 0; title.widthChanged = { widthChanges += 1 }
        next = .success(update); await service.check()
        precondition(title.preferredWidth == baseWidth + 68 && widthChanges == 1)
        title.setFrameSize(NSSize(width: title.preferredWidth, height: 22)); title.layoutSubtreeIfNeeded()
        let button = title.subviews.compactMap { $0 as? NSButton }.first!
        let label = title.subviews.compactMap { $0 as? NSTextField }.first!
        precondition(!button.isHidden && button.title == "Update" && button.frame.maxX < label.frame.minX)
        precondition(title.containsUpdateButton(at: NSPoint(x: button.frame.minX + 1, y: button.frame.midY)))
        button.performClick(nil)
        precondition(opened == [update.url] && service.notice == update && !button.isHidden, "Click must only open the link")
        next = .success(nil); await service.check()
        precondition(button.isHidden && title.preferredWidth == baseWidth && widthChanges == 2)
        print("DESKTOP_UPDATE_NOTICE_OK: version gate, invalid payload/URL, HTTP/error handling, no overlap, offline retention, native titlebar layout and click")
    }
}
