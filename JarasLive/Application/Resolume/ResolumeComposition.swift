import Foundation

/// Resolume's REST mutations run off the UI/audio thread and verify their effect.
/// A timed-out POST is never blindly repeated (it may already have created a deck).
public actor ResolumeComposition {
    private let settings: ResolumeSettings
    private let session: URLSession
    public init(settings: ResolumeSettings, session: URLSession = .shared) { self.settings = settings; self.session = session }
    private struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
    private struct HTTPFailure: Error { let status: Int }
    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, text: String? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        var components = URLComponents(); components.scheme = "http"; components.host = settings.host; components.port = settings.webPort
        components.path = "/api/v1" + path
        guard let url = components.url else { throw Failure(text: "Invalid Resolume address") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = method
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let text { request.httpBody = Data(text.utf8); request.setValue("text/plain", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure(text: "Invalid Resolume response") }
        guard (200..<300).contains(response.statusCode) else { throw HTTPFailure(status: response.statusCode) }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    private func array(_ json: [String: Any], _ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }
    private func name(_ json: [String: Any]) -> String { (json["name"] as? [String: Any])?["value"] as? String ?? "" }
    private func blank(_ json: [String: Any]) -> Bool {
        let name = name(json).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty || name.range(of: "^empty(?: [0-9]+)?$", options: .regularExpression) != nil
    }
    private func wait(seconds: Double = 15, _ predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            try Task.checkCancellation()
            do {
                let value = try await request("/composition")
                if predicate(value) { return value }
            } catch let error as HTTPFailure where [404, 412].contains(error.status) { /* Arena is switching decks. */ }
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        throw Failure(text: "Resolume did not confirm the operation. Check the composition before trying again.")
    }
    private func mutate(_ path: String, method: String, json: [String: Any]? = nil, predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        for attempt in 0..<4 {
            do { _ = try await request(path, method: method, json: json) }
            catch let error as HTTPFailure where error.status == 412 {
                if let applied = try? await wait(seconds: 2, predicate) { return applied }
                if attempt == 3 { throw error }
                try await Task.sleep(nanoseconds: 400_000_000); continue
            } catch let error as URLError where error.code == .timedOut {
                return try await wait(seconds: 30, predicate)
            }
            return try await wait(predicate)
        }
        throw Failure(text: "Resolume is busy. Try again after the current operation finishes.")
    }
    private func select(_ index: Int) async throws -> [String: Any] {
        try await mutate("/composition/decks/\(index)/select", method: "POST") { value in
            let decks = self.array(value, "decks")
            return decks.indices.contains(index - 1) && (decks[index - 1]["selected"] as? [String: Any])?["value"] as? Bool == true
        }
    }
    public func create(project: Project, destination: URL) async throws {
        try settings.validate()
        let map = ResolumeMap.build(project: project, settings: settings, createMissing: false)
        let regions = map.cues.filter(\.isRegion)
        guard let count = regions.map(\.deck).max(), count > 0, count <= 1000 else { throw Failure(text: "Create a Resolume map with song regions first (maximum 1000 decks).") }
        let product = try await request("/product")
        let major = product["major"] as? Int ?? 0, minor = product["minor"] as? Int ?? 0
        guard (product["name"] as? String ?? "").lowercased().contains("arena"), major > 7 || (major == 7 && minor >= 22) else {
            throw Failure(text: "Automatic composition creation requires Resolume Arena 7.22 or later.")
        }
        var composition = try await request("/composition")
        guard !array(composition, "decks").isEmpty, array(composition, "decks").allSatisfy(blank) else {
            throw Failure(text: "Open a new empty composition in Resolume before creating the project.")
        }
        // Inspect every deck before deleting anything, including media in an inactive deck.
        for index in 1...array(composition, "decks").count {
            composition = try await select(index)
            for layer in array(composition, "layers") {
                for clip in array(layer, "clips") {
                    let audio = clip["audio"], video = clip["video"]
                    let connected = (clip["connected"] as? [String: Any])?["value"] as? String
                    guard (audio == nil || audio is NSNull), (video == nil || video is NSNull), connected == nil || connected == "Empty" else {
                        throw Failure(text: "The Resolume composition contains media. Open a new empty composition first.")
                    }
                }
            }
        }
        // Keep one empty deck: Arena refuses deletion of the last remaining deck.
        while array(composition, "decks").count > 1 {
            let before = array(composition, "decks").count
            composition = try await mutate("/composition/decks/\(before)", method: "DELETE") { self.array($0, "decks").count == before - 1 }
        }
        while array(composition, "decks").count < count {
            let before = array(composition, "decks").count
            composition = try await mutate("/composition/decks/add", method: "POST") { self.array($0, "decks").count == before + 1 }
        }
        let deckNames = (1...count).map { index in regions.first { $0.deck == index }?.deckName ?? "Reserved \(index)" }
        let decks: [[String: Any]] = array(composition, "decks").enumerated().map { index, deck in
            ["id": deck["id"] ?? NSNull(), "name": ["value": deckNames[index]]]
        }
        composition = try await mutate("/composition", method: "PUT", json: ["name": ["value": project.name], "decks": decks]) {
            self.name($0) == project.name && self.array($0, "decks").map(self.name) == deckNames
        }
        for index in 1...count {
            composition = try await select(index)
            let cues = map.cues.filter { $0.deck == index }, columns = cues.map(\.column).max() ?? 1
            if array(composition, "columns").count < columns {
                composition = try await mutate("/composition/grow-to", method: "POST", json: ["column_count": columns]) { self.array($0, "columns").count >= columns }
            }
            while array(composition, "columns").count > columns {
                let before = array(composition, "columns").count
                composition = try await mutate("/composition/columns/\(before)", method: "DELETE") { self.array($0, "columns").count == before - 1 }
            }
            for cue in cues where !cue.name.isEmpty {
                composition = try await mutate("/composition/columns/\(cue.column)", method: "PUT", json: ["name": ["value": cue.name]]) {
                    let values = self.array($0, "columns")
                    return values.indices.contains(cue.column - 1) && self.name(values[cue.column - 1]) == cue.name
                }
            }
        }
        _ = try await select(1)
        let before = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        do { _ = try await request("/composition/save", method: "POST", text: destination.absoluteString) }
        catch let error as URLError where error.code == .timedOut { /* Verify the file, never repeat the save blindly. */ }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let now = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               (now.fileSize ?? 0) > 0, before == nil || now.contentModificationDate != before?.contentModificationDate || now.fileSize != before?.fileSize { return }
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        throw Failure(text: "Resolume did not confirm saving the .avc file. Check its Webserver and save the composition in Resolume.")
    }
}
