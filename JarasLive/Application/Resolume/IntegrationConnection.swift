import Foundation

/// A network worker shared by transport updates and composition requests.
/// The UI submits one latest state at a time; no network work touches audio.
public actor IntegrationConnection {
    public struct Port: Codable, Identifiable, Sendable { public let id: String; public let name: String }
    private struct Failure: LocalizedError { let text: String; var errorDescription: String? { text } }
    private let settings: ResolumeSettings
    private let name: String
    private let session: URLSession
    private var token: String?
    private var connection: Task<String, Error>?
    private var sequence: UInt64 = 0
    private var closed = false
    public init(settings: ResolumeSettings, name: String, session: URLSession = .shared) {
        self.settings = settings; self.name = name; self.session = session
    }
    private func request(_ path: String, body: [String: Any]? = nil, authorized: Bool = true) async throws -> [String: Any] {
        var url = URLComponents(); url.scheme = "http"; url.host = settings.integrationHost; url.port = settings.integrationPort ?? 48726; url.path = "/v1/" + path
        guard let destination = url.url else { throw Failure(text: "Invalid CatLive Integration address") }
        var request = URLRequest(url: destination, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        if authorized { request.setValue(try await connect(), forHTTPHeaderField: "X-CatLive-Token") }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
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
