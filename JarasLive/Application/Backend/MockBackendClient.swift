import Foundation
import CryptoKit
public enum MockScenario: String, CaseIterable, Sendable { case valid, blocked, expired, revoked }
// This actor is the mock SERVER, shared by injected clients. Every login and
// replacement commits as one actor operation, with no suspension mid-transaction.
public actor MockBackendClient: BackendClient {
    private struct Account: Codable {
        var user: UserAccount; var passwordHash: String; var maxDevices: Int
        var devices: [AuthorizedDevice] = []
    }
    private struct Token: Codable { var accountId: UUID; var installationId: UUID; var accessHash: String; var refreshHash: String; var expiresAt: Date }
    private struct State: Codable { var accounts: [Account] = []; var tokens: [Token] = [] }
    private var state: State
    private let file: URL?
    private var scenario: MockScenario = .valid
    private var offline = false
    private var maximum = 2
    public init(file: URL? = nil) {
        self.file = file
        state = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        if state.accounts.isEmpty {
            state.accounts = [Account(user: UserAccount(id: UUID(), name: "Equipe CatLive", email: "demo@catlive.app"), passwordHash: Self.hash("catlive123"), maxDevices: 2)]
        }
        // Keep the existing development account, devices and sessions when
        // updating its displayed demo credentials to the new product name.
        for index in state.accounts.indices where state.accounts[index].user.email == "demo@jaras.live" &&
            state.accounts[index].passwordHash == Self.hash("jaras123") {
            state.accounts[index].user.email = "demo@catlive.app"
            if state.accounts[index].user.name == "Equipe Jaras" { state.accounts[index].user.name = "Equipe CatLive" }
            state.accounts[index].passwordHash = Self.hash("catlive123")
        }
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func persist() throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    public func configure(maxDevices: Int, scenario: MockScenario) { maximum = min(3, max(1, maxDevices)); self.scenario = scenario }
    public func setOffline(_ value: Bool) { offline = value }
    private func check() throws { if offline { throw BackendFailure.unavailable }; if scenario == .blocked { throw BackendFailure.blocked } }
    private func accountIndex(_ session: AuthSession, refresh: Bool = false) throws -> (Int, Int) {
        try check()
        guard let tokenIndex = state.tokens.firstIndex(where: { refresh ? $0.refreshHash == Self.hash(session.refreshToken) : $0.accessHash == Self.hash(session.accessToken) }),
              let index = state.accounts.firstIndex(where: { $0.user.id == state.tokens[tokenIndex].accountId }) else { throw BackendFailure.invalidSession }
        if !refresh && state.tokens[tokenIndex].expiresAt <= Date() { throw BackendFailure.invalidSession }
        return (index, tokenIndex)
    }
    private func grant(_ maxDevices: Int) -> Entitlement {
        let now = Date()
        return Entitlement(status: scenario == .expired ? "expired" : "active", planId: "mock", expiresAt: now.addingTimeInterval(scenario == .expired ? -60 : 86400 * 30), offlineValidUntil: now.addingTimeInterval(scenario == .expired ? -60 : 86400 * 7), maxDevices: maxDevices, features: ["desktop", "standalone_mobile", "live_control", "multitrack", "midi_control"])
    }
    public func login(email: String, password: String, device: AuthorizedDevice) throws -> LoginResult {
        try check()
        guard let index = state.accounts.firstIndex(where: { $0.user.email.lowercased() == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }), state.accounts[index].passwordHash == Self.hash(password) else { throw BackendFailure.invalidCredentials }
        var account = state.accounts[index]
        account.maxDevices = maximum
        let now = Date()
        var installed = device; installed.lastSeenAt = now; installed.status = .active
        if let old = account.devices.first(where: { $0.installationId == device.installationId && $0.status == .active }) { installed.activatedAt = old.activatedAt }
        else { installed.activatedAt = now }
        account.devices.removeAll { $0.installationId == device.installationId }
        while account.devices.filter({ $0.status == .active }).count >= maximum {
            guard let oldest = account.devices.indices.filter({ account.devices[$0].status == .active }).min(by: { account.devices[$0].lastSeenAt < account.devices[$1].lastSeenAt }) else { break }
            account.devices[oldest].status = .revoked
        }
        if scenario == .revoked { installed.status = .revoked }
        account.devices.append(installed)
        let session = AuthSession(accessToken: UUID().uuidString + UUID().uuidString, refreshToken: UUID().uuidString + UUID().uuidString, expiresAt: now.addingTimeInterval(900))
        // Re-login on one installation replaces its old session, without another seat.
        state.tokens.removeAll { $0.accountId == account.user.id && $0.installationId == device.installationId }
        state.tokens.append(Token(accountId: account.user.id, installationId: device.installationId, accessHash: Self.hash(session.accessToken), refreshHash: Self.hash(session.refreshToken), expiresAt: session.expiresAt))
        state.accounts[index] = account
        try persist()
        return LoginResult(account: account.user, session: session, entitlement: grant(maximum), device: installed)
    }
    public func credentialDevices(email: String, cpf: String) async throws -> [AuthorizedDevice] {
        try check()
        guard let account = state.accounts.first(where: { $0.user.email.lowercased() == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
              account.passwordHash == Self.hash(cpf) else { throw BackendFailure.invalidCredentials }
        return account.devices.filter { $0.status == .active }
    }
    public func signup(name: String, email: String, password: String) throws {
        try check()
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), password.count >= 8, !name.isEmpty else { throw BackendFailure.invalidCredentials }
        guard !state.accounts.contains(where: { $0.user.email == email }) else { throw BackendFailure.existingAccount }
        state.accounts.append(Account(user: UserAccount(id: UUID(), name: name, email: email), passwordHash: Self.hash(password), maxDevices: maximum)); try persist()
    }
    public func resetPassword(email: String) throws { try check(); guard email.contains("@") else { throw BackendFailure.invalidCredentials } }
    public func refresh(_ session: AuthSession) throws -> AuthSession {
        let (index, tokenIndex) = try accountIndex(session, refresh: true)
        let token = state.tokens[tokenIndex]
        guard state.accounts[index].devices.contains(where: { $0.installationId == token.installationId && $0.status == .active }) else { throw BackendFailure.revoked }
        let next = AuthSession(accessToken: UUID().uuidString + UUID().uuidString, refreshToken: UUID().uuidString + UUID().uuidString, expiresAt: Date().addingTimeInterval(900))
        state.tokens[tokenIndex].accessHash = Self.hash(next.accessToken); state.tokens[tokenIndex].refreshHash = Self.hash(next.refreshToken); state.tokens[tokenIndex].expiresAt = next.expiresAt
        try persist(); return next
    }
    public func entitlement(_ session: AuthSession) throws -> Entitlement { let (index, _) = try accountIndex(session); return grant(state.accounts[index].maxDevices) }
    public func device(_ session: AuthSession, installationId: UUID) throws -> AuthorizedDevice {
        let (index, tokenIndex) = try accountIndex(session)
        guard state.tokens[tokenIndex].installationId == installationId, let deviceIndex = state.accounts[index].devices.firstIndex(where: { $0.installationId == installationId }) else { throw BackendFailure.revoked }
        guard state.accounts[index].devices[deviceIndex].status == .active, scenario != .revoked else { throw BackendFailure.revoked }
        state.accounts[index].devices[deviceIndex].lastSeenAt = Date(); try persist()
        return state.accounts[index].devices[deviceIndex]
    }
    public func devices(_ session: AuthSession) throws -> [AuthorizedDevice] { let (index, _) = try accountIndex(session); return state.accounts[index].devices }
    public func logout(_ session: AuthSession, installationId: UUID) throws {
        let (index, tokenIndex) = try accountIndex(session, refresh: true)
        guard state.tokens[tokenIndex].installationId == installationId else { throw BackendFailure.invalidSession }
        if let deviceIndex = state.accounts[index].devices.firstIndex(where: { $0.installationId == installationId }) { state.accounts[index].devices[deviceIndex].status = .loggedOut }
        let accountId = state.accounts[index].user.id
        state.tokens.removeAll { $0.installationId == installationId && $0.accountId == accountId }; try persist()
    }
    public func revoke(_ installationId: UUID) throws {
        for index in state.accounts.indices { if let deviceIndex = state.accounts[index].devices.firstIndex(where: { $0.installationId == installationId }) { state.accounts[index].devices[deviceIndex].status = .revoked } }; try persist()
    }
}
