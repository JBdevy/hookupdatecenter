import Foundation
public struct UserAccount: Codable, Equatable, Sendable { public var id: UUID; public var name: String; public var email: String }
public struct AuthSession: Codable, Equatable, Sendable { public var accessToken: String; public var refreshToken: String; public var expiresAt: Date }
public enum DeviceStatus: String, Codable, Sendable { case active, revoked, loggedOut }
public struct AuthorizedDevice: Codable, Identifiable, Equatable, Sendable {
    public var installationId: UUID; public var deviceName: String; public var platform: String; public var platformVersion: String; public var appVersion: String
    public var activatedAt: Date; public var lastSeenAt: Date; public var status: DeviceStatus
    public var id: UUID { installationId }
}
public struct Entitlement: Codable, Equatable, Sendable {
    public var status: String, planId: String
    public var expiresAt: Date, offlineValidUntil: Date
    public var maxDevices: Int; public var features: Set<String>
    public func permits(_ feature: String, at date: Date = Date()) -> Bool { status == "active" && expiresAt > date && features.contains(feature) }
}
public struct LoginResult: Codable, Sendable { public var account: UserAccount; public var session: AuthSession; public var entitlement: Entitlement; public var device: AuthorizedDevice }
public struct SessionCache: Codable, Sendable { public var login: LoginResult; public var validatedAt: Date }
public enum LaunchPhase: String, Sendable { case launching, checkingSession, unauthenticated, checkingLicense, checkingDevice, authorized, offlineAuthorized, unauthorized, error }
public enum BackendFailure: Error, LocalizedError, Equatable {
    case invalidCredentials, blocked, expired, revoked, unavailable, invalidSession, notConfigured, existingAccount
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "E-mail ou senha inválidos."
        case .blocked: return "Esta conta está bloqueada."
        case .expired: return "A autorização desta conta expirou."
        case .revoked: return "Este dispositivo foi substituído por outro login."
        case .unavailable: return "Não foi possível conectar ao serviço."
        case .invalidSession: return "Entre novamente na sua conta."
        case .notConfigured: return "O backend remoto ainda não está configurado."
        case .existingAccount: return "Este e-mail já possui uma conta."
        }
    }
}
