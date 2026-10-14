import XCTest
@testable import JarasApplication

private final class ResolumeHTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let object = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class ResolumeCompositionTests: XCTestCase {
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResolumeHTTPStub.self]
        return URLSession(configuration: config)
    }
    func project() -> Project {
        var p = Project.empty(name: "Test Show")
        p.songs[0].duration = 60
        p.songs[0].parts = [Part(id: UUID(), name: "One", startTime: 0, endTime: 20), Part(id: UUID(), name: "Two", startTime: 25, endTime: 40)]
        return p
    }
    func testCompositionWithMediaIsNeverDeletedOrSaved() async throws {
        let p = project(); var settings = ResolumeSettings()
        settings.withMarkers = ResolumeMap.build(project: p, settings: settings).assignments
        var paths: [String] = []
        ResolumeHTTPStub.handler = { request in
            let path = request.url!.path; paths.append(request.httpMethod! + path)
            if path.hasSuffix("/product") { return ["name": "Arena", "major": 7, "minor": 27] }
            return ["decks": [["id": 1, "name": ["value": "Empty"], "selected": ["value": true]]], "layers": [["clips": [["video": ["file": "valuable.mov"]]]]]]
        }
        let session = session(); defer { session.invalidateAndCancel(); ResolumeHTTPStub.handler = nil }
        do {
            try await ResolumeComposition(settings: settings, session: session).create(project: p, destination: URL(fileURLWithPath: "/tmp/not-written.avc"))
            XCTFail("Existing media must be protected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("contains media")) }
        XCTAssertFalse(paths.contains { $0.hasPrefix("DELETE") || $0.hasSuffix("/save") || $0.hasSuffix("/add") })
    }
    func testTimedOutDeckPostIsConfirmedWithoutDuplicateAndCompositionIsSaved() async throws {
        let p = project(); var settings = ResolumeSettings()
        settings.withMarkers = ResolumeMap.build(project: p, settings: settings).assignments
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Show.avc")
        var deckNames = ["Empty"], selected = 1, compositionName = "Untitled", columnName = "Column 1", posts = 0
        func body(_ request: URLRequest) throws -> [String: Any] {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        ResolumeHTTPStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/product") { return ["name": "Arena", "major": 7, "minor": 27] }
            if path.hasSuffix("/decks/add") { posts += 1; deckNames.append("Empty"); throw URLError(.timedOut) }
            if path.hasSuffix("/select") { selected = Int(path.split(separator: "/").dropLast().last!)! }
            if path.hasSuffix("/composition"), request.httpMethod == "PUT" {
                let json = try body(request)
                compositionName = (json["name"] as! [String: String])["value"]!
                deckNames = (json["decks"] as! [[String: Any]]).map { ($0["name"] as! [String: String])["value"]! }
            }
            if path.hasSuffix("/columns/1"), request.httpMethod == "PUT" { columnName = ((try body(request))["name"] as! [String: String])["value"]! }
            if path.hasSuffix("/save") { try Data("Saved composition".utf8).write(to: file) }
            return ["name": ["value": compositionName], "decks": deckNames.enumerated().map { index, name in ["id": index + 1, "name": ["value": name], "selected": ["value": selected == index + 1]] as [String: Any] }, "columns": [["id": 1, "name": ["value": columnName]]], "layers": []]
        }
        let session = session(); defer { session.invalidateAndCancel(); ResolumeHTTPStub.handler = nil }
        try await ResolumeComposition(settings: settings, session: session).create(project: p, destination: file)
        XCTAssertEqual(posts, 1); XCTAssertEqual(deckNames, ["One", "Two"])
        XCTAssertEqual(selected, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
