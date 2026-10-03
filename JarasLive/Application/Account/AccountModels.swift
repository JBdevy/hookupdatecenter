import Foundation
public struct UserAccount: Codable, Equatable, Sendable { public var id: UUID; public var name: String; public var email: String }
public struct AuthSession: Codable, Equatable, Sendable { public var accessToken: String; public var refreshToken: String; public var expiresAt: Date }
public enum DeviceStatus: String, Codable, Sendable { case active, revoked, loggedOut }
public struct AuthorizedDevice: Codable, Identifiable, Equatable, Sendable {
    public var installationId: UUID; public var deviceName: String; public var platform: String; public var platformVersion: String; public var appVersion: String
    public var activatedAt: Date; public var lastSeenAt: Date; public var status: DeviceStatus
    public var id: UUID { installationId }
}
public struct LicenseLeaseProof: Codable, Equatable, Sendable { public var payload: String; public var signature: String }
public struct Entitlement: Codable, Equatable, Sendable {
    public var status: String, planId: String
    public var expiresAt: Date, offlineValidUntil: Date
    public var serverTime: Date? = nil
    public var proof: LicenseLeaseProof? = nil
    public var graceStartsAt: Date? = nil, graceUntil: Date? = nil
    public var graceReason: String? = nil
    public var maxDevices: Int; public var features: Set<String>
    public var accessExpiresAt: Date {
        guard planId != "trial", ["active", "expired", "overdue"].contains(status),
              let start = graceStartsAt, let end = graceUntil,
              end > start, end.timeIntervalSince(start) <= 7 * 86400 else { return expiresAt }
        return end
    }
    public func graceDaysRemaining(at date: Date) -> Int? {
        guard planId != "trial", ["active", "expired", "overdue"].contains(status),
              let start = graceStartsAt, let end = graceUntil,
              end > start, end.timeIntervalSince(start) <= 7 * 86400,
              start <= date, end > date else { return nil }
        return Int(ceil(end.timeIntervalSince(date) / 86400))
    }
    public func permits(_ feature: String, at date: Date = Date()) -> Bool {
        features.contains(feature) && ((status == "active" && expiresAt > date) || graceDaysRemaining(at: date) != nil)
    }
}
public struct LoginResult: Codable, Sendable { public var account: UserAccount; public var session: AuthSession; public var entitlement: Entitlement; public var device: AuthorizedDevice }
public struct SessionCache: Codable, Sendable { public var login: LoginResult; public var validatedAt: Date }
public enum LaunchPhase: String, Sendable { case launching, checkingSession, unauthenticated, checkingLicense, checkingDevice, authorized, offlineAuthorized, unauthorized, error }
public enum BackendFailure: Error, LocalizedError, Equatable {
    case invalidCredentials, blocked, expired, revoked, unavailable, invalidSession, notConfigured, existingAccount, deviceLimit, rateLimited, trialConsumed, clockChanged
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "E-mail ou CPF inválidos."
        case .blocked: return "Esta conta está bloqueada."
        case .expired: return "A autorização desta conta expirou."
        case .revoked: return "Este dispositivo foi substituído por outro login."
        case .unavailable: return "Não foi possível conectar ao serviço."
        case .invalidSession: return "Entre novamente na sua conta."
        case .notConfigured: return "O backend remoto ainda não está configurado."
        case .deviceLimit: return "Todas as licenças desta conta já estão em uso. Use Gerenciar dispositivos para liberar um computador."
        case .rateLimited: return "Muitas tentativas. Aguarde alguns minutos e tente novamente."
        case .trialConsumed: return "O teste deste computador foi encerrado ao entrar em uma conta. Faça login para continuar."
        case .clockChanged: return "A data do computador mudou. Corrija o relógio e valide sua licença pela internet."
        case .existingAccount: return "Este e-mail já possui uma conta."
        }
    }
}

public enum LicenseDisplay {
    public static func title(name: String, entitlement e: Entitlement, at date: Date) -> String {
        if e.planId == "trial" {
            let days = max(0, Int(ceil(e.expiresAt.timeIntervalSince(date) / 86400)))
            return "Trial Mode — \(days) \(days == 1 ? "dia restante" : "dias restantes")"
        }
        let prefix = name.trimmingCharacters(in: .whitespacesAndNewlines) + " — "
        if let days = e.graceDaysRemaining(at: date) { return prefix + "\(days) \(days == 1 ? "dia" : "dias") de tolerância" }
        if e.status == "blocked" { return prefix + "Acesso bloqueado" }
        if e.status == "overdue" || (e.graceReason == "overdue" && e.expiresAt <= date) { return prefix + "Pagamento atrasado" }
        guard e.status == "active", e.expiresAt > date else { return prefix + "Renove sua licença" }
        if e.planId == "vitalicio" { return prefix + "Acesso Vitalício" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fullMonths = max(0, calendar.dateComponents([.month], from: date, to: e.expiresAt).month ?? 0)
        if fullMonths >= 1 {
            let boundary = calendar.date(byAdding: .month, value: fullMonths, to: date) ?? date
            let months = fullMonths + (boundary < e.expiresAt ? 1 : 0)
            return prefix + "Acesso \(months) \(months == 1 ? "mês" : "meses")"
        }
        let days = max(0, Int(ceil(e.expiresAt.timeIntervalSince(date) / 86400)))
        return prefix + "Acesso \(days) \(days == 1 ? "dia" : "dias")"
    }
}
