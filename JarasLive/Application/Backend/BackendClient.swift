import Foundation
public protocol BackendClient: Sendable {
    func login(email: String, password: String, device: AuthorizedDevice) async throws -> LoginResult
    func trial(device: AuthorizedDevice, hardwareID: String) async throws -> LoginResult
    func signup(name: String, email: String, password: String) async throws
    func resetPassword(email: String) async throws
    func refresh(_ session: AuthSession) async throws -> AuthSession
    func accessStatus(_ session: AuthSession) async throws
    func entitlement(_ session: AuthSession) async throws -> Entitlement
    func device(_ session: AuthSession, installationId: UUID) async throws -> AuthorizedDevice
    func devices(_ session: AuthSession) async throws -> [AuthorizedDevice]
    func credentialDevices(email: String, cpf: String) async throws -> [AuthorizedDevice]
    func revokeDevice(email: String, cpf: String, installationId: UUID) async throws
    func revokeDevice(_ session: AuthSession, installationId: UUID) async throws
    func logout(_ session: AuthSession, installationId: UUID) async throws
}
public extension BackendClient {
    func accessStatus(_ session: AuthSession) async throws {}
    func credentialDevices(email: String, cpf: String) async throws -> [AuthorizedDevice] { throw BackendFailure.notConfigured }
    func revokeDevice(email: String, cpf: String, installationId: UUID) async throws { throw BackendFailure.notConfigured }
    func revokeDevice(_ session: AuthSession, installationId: UUID) async throws { throw BackendFailure.notConfigured }
    func trial(device: AuthorizedDevice, hardwareID: String) async throws -> LoginResult { throw BackendFailure.notConfigured }
}
public struct RemoteBackendClient: BackendClient {
    public let baseURL: URL
    private let session: URLSession
    public init(baseURL: URL, session: URLSession = .shared) { self.baseURL = baseURL; self.session = session }
    private struct Failure: Decodable { let error: String }
    private struct OK: Decodable { let ok: Bool }
    private func call<Response: Decodable>(_ route: String, body: [String: Any] = [:], token: String? = nil) async throws -> Response {
        guard baseURL.scheme == "https" || baseURL.host == "127.0.0.1" || baseURL.host == "localhost" else { throw BackendFailure.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/" + route))
        request.httpMethod = "POST"; request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw BackendFailure.unavailable }
        guard let http = response as? HTTPURLResponse else { throw BackendFailure.unavailable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw BackendFailure.unavailable }; return date
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? decoder.decode(Failure.self, from: data))?.error
            switch code {
            case "invalidCredentials": throw BackendFailure.invalidCredentials
            case "invalidSession": throw BackendFailure.invalidSession
            case "trialConsumed": throw BackendFailure.trialConsumed
            case "revoked": throw BackendFailure.revoked
            case "blocked": throw BackendFailure.blocked
            case "quarantined": throw BackendFailure.quarantined
            case "deviceLimit": throw BackendFailure.deviceLimit
            case "rateLimited": throw BackendFailure.rateLimited
            default: throw BackendFailure.unavailable
            }
        }
        do { return try decoder.decode(Response.self, from: data) } catch { throw BackendFailure.unavailable }
    }
    private func deviceBody(_ device: AuthorizedDevice) -> [String: Any] {
        ["installationId": device.installationId.uuidString, "deviceName": device.deviceName,
         "platform": device.platform, "platformVersion": device.platformVersion, "appVersion": device.appVersion]
    }
    public func login(email: String, password: String, device: AuthorizedDevice) async throws -> LoginResult {
        try await call("login", body: ["email": email, "cpf": password, "hardwareID": DeviceAuthorizationService.hardwareID(fallback: device.id), "device": deviceBody(device)])
    }
    public func trial(device: AuthorizedDevice, hardwareID: String) async throws -> LoginResult {
        try await call("trial", body: ["device": deviceBody(device), "hardwareID": hardwareID])
    }
    public func credentialDevices(email: String, cpf: String) async throws -> [AuthorizedDevice] {
        try await call("login/devices", body: ["email": email, "cpf": cpf])
    }
    public func revokeDevice(email: String, cpf: String, installationId: UUID) async throws {
        let _: OK = try await call("login/revoke-device", body: ["email": email, "cpf": cpf, "installationId": installationId.uuidString])
    }
    public func revokeDevice(_ session: AuthSession, installationId: UUID) async throws {
        let _: OK = try await call("revoke-device", body: ["refreshToken": session.refreshToken, "installationId": installationId.uuidString])
    }
    public func signup(name: String, email: String, password: String) async throws { throw BackendFailure.notConfigured }
    public func resetPassword(email: String) async throws { throw BackendFailure.notConfigured }
    public func refresh(_ session: AuthSession) async throws -> AuthSession { try await call("refresh", body: ["refreshToken": session.refreshToken]) }
    public func accessStatus(_ session: AuthSession) async throws {
        let _: OK = try await call("access-status", body: ["refreshToken": session.refreshToken])
    }
    public func entitlement(_ session: AuthSession) async throws -> Entitlement { try await call("entitlement", token: session.accessToken) }
    public func device(_ session: AuthSession, installationId: UUID) async throws -> AuthorizedDevice {
        try await call("device", body: ["installationId": installationId.uuidString], token: session.accessToken)
    }
    public func devices(_ session: AuthSession) async throws -> [AuthorizedDevice] { try await call("devices", token: session.accessToken) }
    public func logout(_ session: AuthSession, installationId: UUID) async throws {
        let _: OK = try await call("logout", body: ["refreshToken": session.refreshToken])
    }
}
