#if os(macOS)
import Foundation
import Network

/// Decimal components are compared as strings to avoid overflow or floating
/// point rounding. Backend releases use X.XX; installed bundles may add .0.
struct DesktopUpdateVersion: Equatable, Comparable {
    private let components: [String]
    init?(_ text: String, backend: Bool = false) {
        guard !text.isEmpty, text.utf8.count <= 128 else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...16).contains(parts.count), !backend || (parts.count == 2 && parts[1].count == 2),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        var normalized = parts.map { part -> String in
            let digits = part.drop(while: { $0 == "0" })
            return digits.isEmpty ? "0" : String(digits)
        }
        while normalized.count > 2 && normalized.last == "0" { normalized.removeLast() }
        components = normalized
    }
    var queryValue: String {
        var parts = components
        if parts[1].count == 1 { parts[1] = "0" + parts[1] }
        return parts.joined(separator: ".")
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : "0"
            let right = index < rhs.components.count ? rhs.components[index] : "0"
            if left != right { return left.count == right.count ? left < right : left.count < right.count }
        }
        return false
    }
}

struct DesktopUpdateNotice: Equatable {
    let version: String
    let url: URL
    static func validatedURL(_ text: String) -> URL? {
        guard !text.isEmpty, text.utf8.count <= 8192,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !text.contains("\\"),
              let decoded = text.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              parts.user == nil, parts.password == nil,
              let url = parts.url, url.baseURL == nil else { return nil }
        return url
    }
}

enum DesktopUpdateNoticeError: Error { case invalidVersion, invalidResponse, invalidLink, httpStatus }

struct DesktopUpdateNoticeClient {
    static let endpoint = URL(string: "https://backcatlive.up.railway.app/api/desktop-update")!
    let installedVersion: String
    let session: URLSession
    var endpoint: URL = Self.endpoint
    init(installedVersion: String, session: URLSession = Self.makeSession()) {
        self.installedVersion = installedVersion; self.session = session
    }
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
    func request() throws -> URLRequest {
        guard let current = DesktopUpdateVersion(installedVersion),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw DesktopUpdateNoticeError.invalidVersion }
        components.queryItems = [URLQueryItem(name: "platform", value: "macos"), URLQueryItem(name: "version", value: current.queryValue)]
        guard let url = components.url else { throw DesktopUpdateNoticeError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    func fetch() async throws -> DesktopUpdateNotice? {
        let (data, response) = try await session.data(for: request())
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw DesktopUpdateNoticeError.httpStatus }
        return try Self.decode(data, installedVersion: installedVersion)
    }
    static func decode(_ data: Data, installedVersion: String) throws -> DesktopUpdateNotice? {
        guard data.count <= 65_536, let current = DesktopUpdateVersion(installedVersion) else { throw DesktopUpdateNoticeError.invalidVersion }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.enabled else { return nil }
        guard let text = response.version, let version = DesktopUpdateVersion(text, backend: true) else { throw DesktopUpdateNoticeError.invalidVersion }
        guard let textURL = response.url, let url = DesktopUpdateNotice.validatedURL(textURL) else { throw DesktopUpdateNoticeError.invalidLink }
        return version > current ? DesktopUpdateNotice(version: version.queryValue, url: url) : nil
    }
    private struct Response: Decodable {
        let enabled: Bool
        let version: String?
        let url: String?
        enum CodingKeys: String, CodingKey { case enabled, version, url }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decode(Bool.self, forKey: .enabled)
            version = enabled ? try values.decode(String.self, forKey: .version) : nil
            url = enabled ? try values.decode(String.self, forKey: .url) : nil
        }
    }
}

@MainActor protocol DesktopUpdateNoticeObserver: AnyObject {
    func desktopUpdateNoticeChanged(_ notice: DesktopUpdateNotice?)
}

/// Independent of login, licensing and playback. Only weak native titlebar
/// observers are notified, and only when the effective notice changes.
@MainActor final class DesktopUpdateNoticeService {
    static let shared: DesktopUpdateNoticeService = {
        let client = DesktopUpdateNoticeClient(installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        return DesktopUpdateNoticeService { try await client.fetch() }
    }()
    private struct Observer { weak var value: DesktopUpdateNoticeObserver? }
    private let fetch: () async throws -> DesktopUpdateNotice?
    private var observers: [Observer] = []
    private var timer: Timer?
    private var monitor: NWPathMonitor?
    private var online: Bool?
    private var started = false
    private var checking = false
    private(set) var notice: DesktopUpdateNotice?
    init(fetch: @escaping () async throws -> DesktopUpdateNotice?) { self.fetch = fetch }
    func observe(_ observer: DesktopUpdateNoticeObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        observers.append(Observer(value: observer))
        observer.desktopUpdateNoticeChanged(notice)
    }
    func start() {
        guard !started else { return }; started = true
        Task { await check() }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let reconnected = self.online == false && connected
                self.online = connected
                if reconnected { await self.check() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "catlive.desktop-update.connectivity", qos: .utility))
        self.monitor = monitor
    }
    func check() async {
        guard !checking else { return }; checking = true
        defer { checking = false }
        // Errors, an absent endpoint and temporary disconnection retain the
        // last valid response in memory. An explicit false removes the alert.
        do { publish(try await fetch()) } catch { return }
    }
    private func publish(_ next: DesktopUpdateNotice?) {
        guard notice != next else { return }; notice = next
        observers.removeAll { $0.value == nil }
        for observer in observers { observer.value?.desktopUpdateNoticeChanged(next) }
    }
    deinit { timer?.invalidate(); monitor?.cancel() }
}
#endif
