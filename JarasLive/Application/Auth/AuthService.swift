import Foundation
import Combine
@MainActor
public final class AuthService: ObservableObject {
    @Published public private(set) var phase: LaunchPhase = .launching
    @Published public private(set) var loginResult: LoginResult?
    @Published public private(set) var devices: [AuthorizedDevice] = []
    @Published public private(set) var revokedPending = false
    @Published public private(set) var message = ""
    @Published public private(set) var busy = false
    public let installation: AuthorizedDevice
    private let backend: any BackendClient, store: any SecureStore
    private let entitlements: EntitlementService, authorization: DeviceAuthorizationService
    private let feature: String
    public var isPlaying: () -> Bool = { false }
    public var onPendingRevocation: (Bool) -> Void = { _ in }
    public var allowed: Bool { phase == .authorized || phase == .offlineAuthorized }
    public init(backend: any BackendClient, store: any SecureStore, installation: AuthorizedDevice, feature: String) {
        self.backend = backend; self.store = store; self.installation = installation; self.feature = feature
        entitlements = EntitlementService(backend: backend); authorization = DeviceAuthorizationService(backend: backend)
    }
    public func restore() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        phase = .checkingSession
        do {
            guard let data = try store.read("session") else { phase = .unauthenticated; return }
            let cache = try JSONDecoder().decode(SessionCache.self, from: data)
            guard cache.login.device.installationId == installation.installationId else { throw BackendFailure.invalidSession }
            loginResult = cache.login
            try await validate(cache: cache)
        } catch { deny(error) }
    }
    public func login(email: String, password: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        message = ""; phase = .checkingSession
        do {
            let result = try await backend.login(email: email, password: password, device: installation)
            loginResult = result
            try await validate(cache: SessionCache(login: result, validatedAt: Date()))
        } catch { deny(error) }
    }
    private func validate(cache: SessionCache, foreground: Bool = true) async throws {
        var result = cache.login
        do {
            if result.session.expiresAt <= Date().addingTimeInterval(60) { result.session = try await backend.refresh(result.session) }
            if foreground { phase = .checkingLicense }
            result.entitlement = try await entitlements.validate(result.session, feature: feature)
            if foreground { phase = .checkingDevice }
            result.device = try await authorization.validate(session: result.session, installationId: installation.installationId)
            let activeDevices = try await backend.devices(result.session)
            try store.write(JSONEncoder().encode(SessionCache(login: result, validatedAt: Date())), key: "session")
            loginResult = result; devices = activeDevices
            revokedPending = false; onPendingRevocation(false); message = ""; phase = .authorized
        } catch BackendFailure.unavailable {
            guard entitlements.permitsOffline(cache, installationId: installation.installationId, feature: feature) else { throw BackendFailure.expired }
            loginResult = cache.login; phase = .offlineAuthorized; message = "Autorização offline válida."
        }
    }
    public func revalidate() async {
        guard !busy, let loginResult else { return }
        busy = true; defer { busy = false }
        do {
            let cache = try store.read("session").map { try JSONDecoder().decode(SessionCache.self, from: $0) } ?? SessionCache(login: loginResult, validatedAt: Date())
            // Preserve the show UI while checking in the background.
            try await validate(cache: cache, foreground: false)
        } catch { deny(error) }
    }
    private func deny(_ error: Error) {
        message = error.localizedDescription
        if let failure = error as? BackendFailure, [.revoked, .blocked, .expired, .invalidSession].contains(failure),
           let data = try? store.read("session"), var cache = try? JSONDecoder().decode(SessionCache.self, from: data) {
            cache.login.device.status = .revoked
            if let encoded = try? JSONEncoder().encode(cache) { try? store.write(encoded, key: "session") }
        }
        if isPlaying() {
            revokedPending = true; onPendingRevocation(true); phase = .authorized
        } else {
            phase = error is BackendFailure ? .unauthorized : .error
        }
    }
    public func transportDidStop() {
        guard revokedPending else { return }; revokedPending = false; onPendingRevocation(false); phase = .unauthorized
    }
    public func logout() async {
        guard !busy, !isPlaying(), let loginResult else { return }
        busy = true; defer { busy = false }
        do {
            // Do not claim a slot was released when the server is unreachable.
            try await backend.logout(loginResult.session, installationId: installation.installationId)
            try store.delete("session")
            self.loginResult = nil; devices = []; revokedPending = false; message = ""; phase = .unauthenticated
        } catch { message = error.localizedDescription }
    }
    public func signup(name: String, email: String, password: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await backend.signup(name: name, email: email, password: password); message = "Conta mock criada. Entre para continuar."; phase = .unauthenticated } catch { message = error.localizedDescription }
    }
    public func resetPassword(email: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await backend.resetPassword(email: email); message = "Solicitação simulada. O mock não envia e-mail." } catch { message = error.localizedDescription }
    }
    public func showLogin() { guard !isPlaying() else { return }; phase = .unauthenticated; message = "" }
}
