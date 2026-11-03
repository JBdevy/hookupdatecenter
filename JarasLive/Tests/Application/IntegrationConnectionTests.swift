import XCTest
@testable import JarasApplication

private final class IntegrationHTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, object) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class IntegrationConnectionTests: XCTestCase {
    func testGrandMA2PlanIsCreatedOnReceiverAndOldReceiverIsRejected() async throws {
        var project = Project.empty(name: "Show")
        project.songs[0].duration = 60
        project.songs[0].parts = [Part(id: UUID(), name: "Song", startTime: 0, endTime: 60)]
        let map = try GrandMA2Map.build(project: project, settings: GrandMA2Settings())
        var settings = ResolumeSettings(); settings.integrationEnabled = true; settings.integrationHost = "192.168.1.20"
        var supported = false, posted = false, operation = ""
        IntegrationHTTPStub.handler = { request in
            switch request.url!.path {
            case "/v1/info": return (200, ["protocol": 1, "features": supported ? ["grandma2-create"] : []])
            case "/v1/connect": return (200, ["protocol": 1, "token": String(repeating: "a", count: 64)])
            case "/v1/grandma2/create":
                let body = try self.body(request); operation = body["requestId"] as! String
                XCTAssertNil(body["destination"])
                let plan = body["plan"] as! [String: Any]
                XCTAssertEqual((plan["regions"] as! [[String: Any]]).count, 1); posted = true
                return (202, [:])
            case "/v1/job": return (200, ["requestId": operation, "state": "done", "file": "receiver/grandMA2/Show"])
            default: return (200, [:])
            }
        }
        let http = session(); defer { http.invalidateAndCancel(); IntegrationHTTPStub.handler = nil }
        let client = IntegrationConnection(settings: settings, name: project.name, session: http)
        do { _ = try await client.createGrandMA2(map: map); XCTFail("Old receiver must not silently succeed") } catch {}
        XCTAssertFalse(posted)
        supported = true
        let folder = try await client.createGrandMA2(map: map)
        XCTAssertEqual(folder, "receiver/grandMA2/Show"); XCTAssertTrue(posted)
        await client.disconnect()
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IntegrationHTTPStub.self]
        return URLSession(configuration: config)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    func testOldProjectsRemainDirectAndRemoteSettingsRoundTrip() throws {
        let original = ResolumeSettings()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        XCTAssertFalse(json.keys.contains { $0.hasPrefix("integration") })
        XCTAssertFalse(try JSONDecoder().decode(ResolumeSettings.self, from: JSONSerialization.data(withJSONObject: json)).usesIntegration)
        json["integrationEnabled"] = true; json["integrationHost"] = "192.168.10.20"
        json["integrationMTCEnabled"] = true; json["integrationMIDIOutput"] = "2:CatLive Integration"
        let remote = try JSONDecoder().decode(ResolumeSettings.self, from: JSONSerialization.data(withJSONObject: json))
        try remote.validate()
        XCTAssertEqual(try JSONDecoder().decode(ResolumeSettings.self, from: JSONEncoder().encode(remote)), remote)
        var bad = remote; bad.integrationHost = "192.168.10.20/path"; XCTAssertThrowsError(try bad.validate())
    }
    func testReceiverCreatesCompositionAndConcurrentTransportSharesOneSession() async throws {
        var project = Project.empty(name: "Show açucar")
        project.songs[0].duration = 60
        project.songs[0].parts = [Part(id: UUID(), name: "Song", startTime: 0, endTime: 60)]
        var settings = ResolumeSettings(); settings.integrationEnabled = true; settings.integrationHost = "192.168.10.20"
        settings.withMarkers = ResolumeMap.build(project: project, settings: settings).assignments
        let lock = NSLock(); var paths: [String] = [], sequences: [Int] = []; var operation = ""
        let token = String(repeating: "a", count: 64)
        IntegrationHTTPStub.handler = { request in
            lock.lock(); defer { lock.unlock() }
            XCTAssertEqual(request.url?.host, settings.integrationHost)
            XCTAssertEqual(request.url?.port, 48726)
            let path = request.url!.lastPathComponent; paths.append(path)
            if path == "connect" { return (200, ["token": token, "protocol": 1]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CatLive-Token"), token)
            if path == "state" { sequences.append(try self.body(request)["sequence"] as! Int); return (200, [:]) }
            if path == "create" {
                let payload = try self.body(request); operation = payload["requestId"] as! String
                XCTAssertNil(payload["file"]); XCTAssertNil(payload["destination"], "The receiver chooses its own local directory")
                let plan = payload["plan"] as! [String: Any]
                XCTAssertFalse((plan["decks"] as! [[String: Any]]).isEmpty)
            }
            if path == "job" { return (200, ["requestId": operation, "state": "done", "file": "C:\\Users\\Receiver\\Documents\\CatLive Integration\\Show.avc"]) }
            return (200, [:])
        }
        let http = session(); defer { http.invalidateAndCancel(); IntegrationHTTPStub.handler = nil }
        let client = IntegrationConnection(settings: settings, name: project.name, session: http)
        async let update: Void = client.update(position: 12, playing: false, deck: 1, column: 1, jump: 0)
        let file = try await client.create(project: project)
        try await update
        try await client.update(position: 13, playing: true, deck: 1, column: 1, jump: 0)
        await client.disconnect()
        XCTAssertTrue(file.hasPrefix("C:")); XCTAssertEqual(paths.filter { $0 == "connect" }.count, 1)
        XCTAssertEqual(Set(sequences), Set([1, 2])); XCTAssertEqual(paths.last, "disconnect")
    }
    func testExpiredSessionReconnectsBeforeNextState() async throws {
        var settings = ResolumeSettings(); settings.integrationEnabled = true; settings.integrationHost = "127.0.0.1"
        var connects = 0, expired = false
        IntegrationHTTPStub.handler = { request in
            if request.url!.lastPathComponent == "connect" { connects += 1; return (200, ["protocol": 1, "token": String(repeating: "b", count: 64)]) }
            if !expired { expired = true; return (401, ["error": "Expired"]) }
            return (200, [:])
        }
        let http = session(); defer { http.invalidateAndCancel(); IntegrationHTTPStub.handler = nil }
        let client = IntegrationConnection(settings: settings, name: "Test", session: http)
        do { try await client.update(position: 0, playing: false, deck: nil, column: nil, jump: 0); XCTFail("Expired session") } catch {}
        try await client.update(position: 1, playing: true, deck: 1, column: 1, jump: 1)
        XCTAssertEqual(connects, 2)
        await client.disconnect()
    }
}

extension IntegrationConnectionTests {
    func testIntegrationRequiresEthernetWithoutPeerToPeerFallback() {
        let parameters = IntegrationEthernetHTTP.parameters()
        XCTAssertEqual(parameters.requiredInterfaceType, .wiredEthernet)
        XCTAssertFalse(parameters.includePeerToPeer)
    }
    func testEthernetResponseHandlesFragmentsAndRejectsTruncationAndOversize() throws {
        let url = URL(string: "http://192.168.1.2:48726/v1/info")!
        let body = Data("{\"name\":\"Conexão\"}".utf8)
        let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        let complete = headers + body
        for size in 0..<complete.count {
            XCTAssertNil(try IntegrationEthernetHTTP.decode(complete.prefix(size), url: url, complete: false))
        }
        let decoded = try XCTUnwrap(IntegrationEthernetHTTP.decode(complete, url: url, complete: false))
        XCTAssertEqual(decoded.0, body)
        XCTAssertEqual((decoded.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertThrowsError(try IntegrationEthernetHTTP.decode(complete.dropLast(), url: url, complete: true))
        XCTAssertThrowsError(try IntegrationEthernetHTTP.decode(complete + Data([0]), url: url, complete: true))
        XCTAssertThrowsError(try IntegrationEthernetHTTP.decode(Data("HTTP/1.1 200 OK\r\nContent-Length: 2097153\r\n\r\n".utf8), url: url, complete: false))
        XCTAssertThrowsError(try IntegrationEthernetHTTP.decode(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 2\r\n\r\n".utf8), url: url, complete: false))
    }
    func testLiveEthernetTransportWhenReceiverIsProvided() async throws {
        guard let host = ProcessInfo.processInfo.environment["CATLIVE_INTEGRATION_TEST_HOST"] else { throw XCTSkip("No wired receiver supplied") }
        let url = URL(string: "http://\(host):48729/v1/info")!
        let (body, response) = try await IntegrationEthernetHTTP.data(for: URLRequest(url: url, timeoutInterval: 1.5))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["transport": "ethernet"])
    }
}
