import Foundation
import Network

/// A network worker shared by transport updates and composition requests.
/// The UI submits one latest state at a time; no network work touches audio.
public actor IntegrationConnection {
    public struct Port: Codable, Identifiable, Sendable { public let id: String; public let name: String }
    private struct Failure: LocalizedError { let text: String; var errorDescription: String? { text } }
    private let settings: ResolumeSettings
    private let name: String
    private let session: URLSession?
    private var token: String?
    private var connection: Task<String, Error>?
    private var sequence: UInt64 = 0
    private var closed = false
    public init(settings: ResolumeSettings, name: String, session: URLSession? = nil) {
        self.settings = settings; self.name = name; self.session = session
    }
    private func request(_ path: String, body: [String: Any]? = nil, authorized: Bool = true) async throws -> [String: Any] {
        var url = URLComponents(); url.scheme = "http"; url.host = settings.integrationHost; url.port = settings.integrationPort ?? 48726; url.path = "/v1/" + path
        guard let destination = url.url else { throw Failure(text: "Invalid CatLive Integration address") }
        var request = URLRequest(url: destination, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        if authorized { request.setValue(try await connect(), forHTTPHeaderField: "X-CatLive-Token") }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data, response: URLResponse
        if let session { (data, response) = try await session.data(for: request) }
        else { (data, response) = try await IntegrationEthernetHTTP.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw Failure(text: "Invalid Integration response") }
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { token = nil; connection = nil }
            throw Failure(text: value["error"] as? String ?? "CatLive Integration HTTP \(http.statusCode)")
        }
        return value
    }
    private func connect() async throws -> String {
        guard !closed else { throw CancellationError() }
        if let token { return token }
        if let connection { return try await connection.value }
        let task = Task<String, Error> {
            let value = try await self.request("connect", body: ["protocol": 1, "name": self.name,
                "resolume": self.settings.enabled, "oscPort": self.settings.oscPort, "webPort": self.settings.webPort,
                "mtc": self.settings.integrationMTCEnabled == true, "midiOutput": self.settings.integrationMIDIOutput ?? ""], authorized: false)
            guard value["protocol"] as? Int == 1, let token = value["token"] as? String, token.count == 64 else { throw Failure(text: "Incompatible CatLive Integration version") }
            return token
        }
        connection = task
        do { let value = try await task.value; token = value; connection = nil; return value }
        catch { connection = nil; throw error }
    }
    public func ports() async throws -> [Port] {
        let value = try await request("info", authorized: false)
        guard value["protocol"] as? Int == 1 else { throw Failure(text: "Incompatible CatLive Integration version") }
        return try JSONDecoder().decode([Port].self, from: JSONSerialization.data(withJSONObject: value["midiOutputs"] ?? []))
    }
    public func update(position: Double, playing: Bool, deck: Int?, column: Int?, jump: UInt64) async throws {
        sequence += 1
        _ = try await request("state", body: ["sequence": sequence, "position": position, "playing": playing,
            "deck": deck ?? 0, "column": column ?? 0, "jump": jump])
    }
    public func disconnect() async {
        // Wait for an in-flight handshake, then revoke its token before a new
        // project connects. Cancelling only the client can leave a live lease.
        if let connection { token = try? await connection.value }
        guard !closed else { return }
        if token != nil { _ = try? await request("disconnect", body: [:]) }
        closed = true; token = nil; connection = nil
    }
    public func create(project: Project) async throws -> String {
        let map = ResolumeMap.build(project: project, settings: settings, createMissing: false)
        let grouped = Dictionary(grouping: map.cues, by: \.deck)
        let decks: [[String: Any]] = grouped.keys.sorted().map { deck in
            let cues = grouped[deck]!
            return ["number": deck, "name": cues.first?.deckName ?? "Musica",
                    "columns": cues.sorted { $0.column < $1.column }.map { ["number": $0.column, "name": $0.name] as [String: Any] }]
        }
        guard !decks.isEmpty else { throw Failure(text: "Create a Resolume map with song regions first (maximum 1000 decks).") }
        return try await createFiles(path: "resolume/create", plan: ["name": LightingExportName.clean(project.name, fallback: "Projeto CatLive"), "decks": decks])
    }
    public func createGrandMA2(map: GrandMA2Map) async throws -> String {
        guard map.plan.regions.contains(where: \.selected) else { throw Failure(text: "Select at least one song for grandMA2") }
        let info = try await request("info", authorized: false)
        guard (info["features"] as? [String])?.contains("grandma2-create") == true else {
            throw Failure(text: "Update CatLive Integration to create grandMA2 macros.")
        }
        let plan = try JSONSerialization.jsonObject(with: JSONEncoder().encode(map.plan)) as! [String: Any]
        return try await createFiles(path: "grandma2/create", plan: plan)
    }
    private func createFiles(path: String, plan: [String: Any]) async throws -> String {
        let requestID = UUID().uuidString
        _ = try await request(path, body: ["requestId": requestID, "plan": plan])
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try Task.checkCancellation()
            let job = try await request("job")
            guard job["requestId"] as? String == requestID else { throw Failure(text: "The Integration operation changed") }
            if job["state"] as? String == "done" { return job["file"] as? String ?? "" }
            if job["state"] as? String == "failed" { throw Failure(text: job["message"] as? String ?? "Composition creation failed") }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw Failure(text: "Integration did not confirm saving the files")
    }
}

/// A separate transport for the desktop Integration link. Remote app sessions
/// continue to use their existing Wi-Fi-capable networking.
enum IntegrationEthernetHTTP {
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let value = NWParameters(tls: nil, tcp: tcp)
        value.requiredInterfaceType = .wiredEthernet
        value.includePeerToPeer = false
        return value
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    static func decode(_ bytes: Data, url: URL, complete: Bool) throws -> (Data, URLResponse)? {
        guard bytes.count <= 2 * 1024 * 1024 + 16384 else { throw Failure("Integration response too large") }
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if complete || bytes.count > 16384 { throw Failure("Invalid Integration response") }
            return nil
        }
        guard boundary.lowerBound <= 16384,
              let text = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw Failure("Invalid Integration headers") }
        let lines = text.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ")
        guard status.count >= 2, status[0] == "HTTP/1.1" || status[0] == "HTTP/1.0",
              let code = Int(status[1]), (200...599).contains(code) else { throw Failure("Invalid Integration status") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { throw Failure("Invalid Integration header") }
            let name = line[..<separator].lowercased()
            guard headers[name] == nil else { throw Failure("Duplicate Integration header") }
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        // Integration returns bounded JSON with Content-Length. Never follow a
        // redirect, use a proxy, or change interfaces to fetch another response.
        guard headers["transfer-encoding"] == nil,
              let rawLength = headers["content-length"], let length = Int(rawLength),
              (0...2 * 1024 * 1024).contains(length) else { throw Failure("Invalid Integration content length") }
        let body = bytes[boundary.upperBound...]
        if body.count < length, !complete { return nil }
        guard body.count == length,
              let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: String(status[0]), headerFields: headers) else { throw Failure("Incomplete Integration response") }
        return (Data(body), response)
    }
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 48726)) else { throw Failure("Invalid Integration address") }
        let exchange = Exchange(request: request, connection: NWConnection(host: .init(host), port: port, using: parameters()))
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await exchange.run()
        }, onCancel: { exchange.cancel() })
    }
    private final class Exchange: @unchecked Sendable {
        let request: URLRequest, connection: NWConnection
        let queue = DispatchQueue(label: "CatLive Integration Ethernet")
        var completion: CheckedContinuation<(Data, URLResponse), Error>?
        var timeout: DispatchWorkItem?, bytes = Data(), finished = false
        init(request: URLRequest, connection: NWConnection) { self.request = request; self.connection = connection }
        func run() async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if self.finished { continuation.resume(throwing: CancellationError()); return }
                    self.completion = continuation
                    let timeout = DispatchWorkItem { self.finish(.failure(Failure("CatLive Integration requires an Ethernet cable. Check the adapter and IP address."))) }
                    self.timeout = timeout
                    self.queue.asyncAfter(deadline: .now() + self.request.timeoutInterval, execute: timeout)
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: self.send()
                        case .failed(let error): self.finish(.failure(error))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                }
            }
        }
        func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
        func finish(_ result: Result<(Data, URLResponse), Error>) {
            guard !finished else { return }; finished = true
            timeout?.cancel(); timeout = nil
            connection.stateUpdateHandler = nil; connection.cancel()
            completion?.resume(with: result); completion = nil
        }
        func send() {
            let url = request.url!, body = request.httpBody ?? Data()
            var text = "\(request.httpMethod ?? "GET") \(url.path) HTTP/1.1\r\nHost: \(url.host!):\(url.port ?? 48726)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
            for (key, value) in request.allHTTPHeaderFields ?? [:] where !["host", "connection", "content-length"].contains(key.lowercased()) {
                guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else { finish(.failure(Failure("Invalid Integration request"))); return }
                text += "\(key): \(value)\r\n"
            }
            var packet = Data((text + "\r\n").utf8); packet.append(body)
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { self.finish(.failure(error)) } else { self.receive() }
            })
        }
        func receive() {
            guard !finished else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, complete, error in
                guard !self.finished else { return }
                if let error { self.finish(.failure(error)); return }
                if let data { self.bytes.append(data) }
                do {
                    if let response = try IntegrationEthernetHTTP.decode(self.bytes, url: self.request.url!, complete: complete) { self.finish(.success(response)) }
                    else { self.receive() }
                } catch { self.finish(.failure(error)) }
            }
        }
    }
}
