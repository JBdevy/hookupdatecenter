import Foundation
public protocol BackendClient: Sendable {
    func login(email: String, password: String, device: AuthorizedDevice) async throws -> LoginResult
    func signup(name: String, email: String, password: String) async throws
    func resetPassword(email: String) async throws
    func refresh(_ session: AuthSession) async throws -> AuthSession
    func entitlement(_ session: AuthSession) async throws -> Entitlement
    func device(_ session: AuthSession, installationId: UUID) async throws -> AuthorizedDevice
    func devices(_ session: AuthSession) async throws -> [AuthorizedDevice]
    func logout(_ session: AuthSession, installationId: UUID) async throws
}
// Deliberately unconfigured: production must supply verified endpoint contracts,
// token handling and server-side atomic device authorization. No embedded secrets.
public struct RemoteBackendClient: BackendClient {
    public let baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }
    public func login(email: String, password: String, device: AuthorizedDevice) async throws -> LoginResult { throw BackendFailure.notConfigured }
    public func signup(name: String, email: String, password: String) async throws { throw BackendFailure.notConfigured }
    public func resetPassword(email: String) async throws { throw BackendFailure.notConfigured }
    public func refresh(_ session: AuthSession) async throws -> AuthSession { throw BackendFailure.notConfigured }
    public func entitlement(_ session: AuthSession) async throws -> Entitlement { throw BackendFailure.notConfigured }
    public func device(_ session: AuthSession, installationId: UUID) async throws -> AuthorizedDevice { throw BackendFailure.notConfigured }
    public func devices(_ session: AuthSession) async throws -> [AuthorizedDevice] { throw BackendFailure.notConfigured }
    public func logout(_ session: AuthSession, installationId: UUID) async throws { throw BackendFailure.notConfigured }
}
