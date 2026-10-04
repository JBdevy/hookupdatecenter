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
    @Published public private(set) var restriction = ""
    @Published public private(set) var graceNotice = ""
    private var announcedGrace: String?
    @Published public private(set) var workspaceAllowed = false
    @Published public private(set) var installation: AuthorizedDevice
    @Published public private(set) var requiresDeviceName = false
    private var pendingLogin: (email: String, password: String)?
    public var onDeviceNameChanged: (String) -> Void = { _ in }
    private let backend: any BackendClient, store: any SecureStore
    private let entitlements: EntitlementService, authorization: DeviceAuthorizationService
    private let feature: String
    private let verifier: LicenseLeaseVerifier?
    private var trustedCache: SessionCache?
    private var checkingOnlineAccess = false
    private let quarantineNoticeKey = "catlive.production.quarantineNotice"
    private var clockWrite: Task<Void, Error>?
    private var lastClockWrite = 0.0
    private let trialClockKey = "catlive.production.trialClock"
    private let consumedTrialKey = "catlive.production.trialConsumed"
    private var validationWallDate = Date()
    private var audioAllowed = false
    private var deadline = 0.0
    private var earliestDate = Date.distantPast
    private var validationUptime = 0.0
    private var serverDate = Date.distantPast
    public var isPlaying: () -> Bool = { false }
    public var onPendingRevocation: (Bool) -> Void = { _ in }
    public var onAudioAuthorization: (Bool) -> Void = { _ in }
    public var allowed: Bool { audioAllowed }
    public init(backend: any BackendClient, store: any SecureStore, installation: AuthorizedDevice, feature: String, verifier: LicenseLeaseVerifier? = nil) {
        self.backend = backend; self.store = store; self.installation = installation; self.feature = feature; self.verifier = verifier
        entitlements = EntitlementService(backend: backend); authorization = DeviceAuthorizationService(backend: backend)
    }
    private func readSessionData() async throws -> Data? {
        let store = self.store
        return try await Task.detached(priority: .utility) { try store.read("catlive.production.session") }.value
    }
    private func writeSessionData(_ data: Data) async throws {
        let store = self.store
        try await Task.detached(priority: .utility) { try store.write(data, key: "catlive.production.session") }.value
    }
    private func setAudio(_ value: Bool, reason: String = "") {
        audioAllowed = value
        let nextRestriction = value ? "" : reason
        if restriction != nextRestriction { restriction = nextRestriction }
        if !value, !graceNotice.isEmpty { graceNotice = "" }
        onAudioAuthorization(value)
    }
    private var serverNow: Date {
        serverDate.addingTimeInterval(max(0, ProcessInfo.processInfo.systemUptime - validationUptime, Date().timeIntervalSince(validationWallDate)))
    }
    public var trialDaysRemaining: Int? {
        guard let entitlement = loginResult?.entitlement, entitlement.planId == "trial" else { return nil }
        return max(0, Int(ceil(entitlement.expiresAt.timeIntervalSince(serverNow) / 86400)))
    }
    public var licenseTitle: String? {
        guard let result = loginResult else {
            return workspaceAllowed && phase == .unauthorized ? "Entre novamente na sua conta" : nil
        }
        guard (try? requireVerified(result)) != nil else { return "Validação de licença necessária" }
        if result.device.status != .active { return "Dispositivo não autorizado — faça login" }
        if !audioAllowed, result.entitlement.permits(feature, at: serverNow) { return "Validação de licença necessária" }
        return LicenseDisplay.title(name: result.account.name, entitlement: result.entitlement, at: serverNow)
    }
    private func updateGraceNotice() {
        guard audioAllowed, let result = loginResult,
              let days = result.entitlement.graceDaysRemaining(at: serverNow) else {
            // The local expiry heartbeat must not invalidate the UI without a change.
            if !graceNotice.isEmpty { graceNotice = "" }
            return
        }
        let key = result.account.id.uuidString + ":" + String(result.entitlement.graceStartsAt!.timeIntervalSince1970)
        guard announcedGrace != key else { return }
        announcedGrace = key
        let reason = result.entitlement.graceReason == "overdue" ? "Seu pagamento está atrasado." : "Sua licença venceu. Renove sua licença."
        let notice = reason + " Você tem \(days) \(days == 1 ? "dia" : "dias") de tolerância para regularizar. O CatLive continua liberado nesse período. Ao terminar, o áudio e os comandos serão bloqueados até a confirmação do pagamento."
        if graceNotice != notice { graceNotice = notice }
    }
    private func requireVerified(_ result: LoginResult) throws {
        guard result.device.installationId == installation.installationId,
              verifier?.verify(result.entitlement, account: result.account.id, installation: installation.installationId) != false else { throw BackendFailure.invalidSession }
    }
    private func reason(_ entitlement: Entitlement) -> String {
        if entitlement.permits(feature, at: serverNow) {
            return "Conecte-se à internet para validar sua licença. O áudio está desativado até a validação."
        }
        switch entitlement.status {
        case "blocked": return "Esta conta está bloqueada. Entre em contato com o suporte. O áudio está desativado."
        case "overdue": return "Seu pagamento está em atraso. O prazo de tolerância terminou. Regularize sua assinatura para liberar o áudio e os comandos do CatLive."
        default:
            if entitlement.planId == "trial" { return "Seu período de teste acabou. Faça login com uma licença ativa para continuar. O áudio está desativado." }
            return "Renove sua licença. O prazo de tolerância terminou. O áudio e os comandos do CatLive estão bloqueados até a renovação."
        }
    }
    private func accept(_ result: LoginResult, validatedAt: Date, offline: Bool, trustedTime: Date? = nil) {
        guard (try? requireVerified(result)) != nil else {
            setAudio(false, reason: "Não foi possível verificar sua licença. Conecte-se à internet para validar novamente.")
            return
        }
        trustedCache = SessionCache(login: result, validatedAt: validatedAt)
        loginResult = result; workspaceAllowed = true
        phase = offline ? .offlineAuthorized : .authorized
        earliestDate = validatedAt.addingTimeInterval(-300)
        let end = min(result.entitlement.accessExpiresAt, result.entitlement.offlineValidUntil)
        validationWallDate = Date()
        validationUptime = ProcessInfo.processInfo.systemUptime
        serverDate = trustedTime ?? result.entitlement.serverTime.map { $0.addingTimeInterval(max(0, Date().timeIntervalSince(validatedAt))) } ?? Date()
        deadline = validationUptime + max(0, end.timeIntervalSince(serverDate))
        let valid = result.device.status == .active && result.entitlement.permits(feature, at: serverDate) && end > serverDate && Date() >= earliestDate
        setAudio(valid, reason: reason(result.entitlement))
        updateGraceNotice()
        revokedPending = false; onPendingRevocation(false)
        message = offline && valid ? "Autorização offline válida." : ""
    }
    public func checkLocalExpiry() {
        updateGraceNotice()
        if audioAllowed, loginResult?.entitlement.planId == "trial", ProcessInfo.processInfo.systemUptime - lastClockWrite >= 15 {
            let task = checkpointTrial()
            Task { do { try await task?.value } catch { setAudio(false, reason: error.localizedDescription) } }
        }
        guard audioAllowed, let result = loginResult else { return }
        guard result.entitlement.permits(feature, at: serverNow), Date() >= earliestDate,
              result.entitlement.offlineValidUntil > serverNow, ProcessInfo.processInfo.systemUptime < deadline else {
            setAudio(false, reason: reason(result.entitlement)); updateGraceNotice(); return
        }
    }
    public func restore() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        phase = .checkingSession
        do {
            guard let data = try await readSessionData() else {
                phase = .unauthenticated
                if try store.read(quarantineNoticeKey) != nil { message = BackendFailure.quarantined.localizedDescription }
                return
            }
            let cache = try JSONDecoder().decode(SessionCache.self, from: data)
            guard cache.login.device.installationId == installation.installationId else { throw BackendFailure.invalidSession }
            loginResult = cache.login; workspaceAllowed = true; trustedCache = cache
            try requireVerified(cache.login)
            if cache.login.entitlement.planId == "trial" {
                if try store.read(consumedTrialKey) != nil { throw BackendFailure.trialConsumed }
                if let clockData = try store.read(trialClockKey) {
                    let clock = try JSONDecoder().decode(OfflineTrialClock.self, from: clockData)
                    let now = try clock.resume(account: cache.login.account.id, installation: installation.id, expiresAt: cache.login.entitlement.expiresAt)
                    accept(cache.login, validatedAt: cache.validatedAt, offline: true, trustedTime: now)
                    if allowed { try await checkpointTrial()?.value; return }
                }
                // Initial activation / legacy cache migration, or the trial has ended.
                try await validate(cache: cache)
            } else if entitlements.permitsOffline(cache, installationId: installation.installationId, feature: feature) {
                accept(cache.login, validatedAt: cache.validatedAt, offline: true)
            } else { try await validate(cache: cache) }
        } catch { await deny(error) }
    }
    /// Validate credentials before asking for a name, without occupying a seat
    /// or consuming a trial until the user completes the mandatory second step.
    @discardableResult public func beginLogin(email: String, password: String) async -> Bool {
        guard !busy else { return false }
        do {
            if let name = try DeviceDisplayName.saved(in: store) {
                installation.deviceName = name
                return await login(email: email, password: password)
            }
            busy = true; defer { busy = false }
            message = ""
            _ = try await backend.credentialDevices(email: email, cpf: password)
            pendingLogin = (email, password)
            requiresDeviceName = true
            return false
        } catch { message = error.localizedDescription; return false }
    }
    public func cancelDeviceNaming() {
        guard !busy else { return }
        pendingLogin = nil; requiresDeviceName = false; message = ""
    }
    @discardableResult public func completeDeviceNaming(_ value: String) async -> Bool {
        guard !busy, let credentials = pendingLogin else { return false }
        guard let name = DeviceDisplayName.validated(value) else {
            message = "Digite um nome válido e curto para o dispositivo, sem quebras de linha."
            return false
        }
        var device = installation; device.deviceName = name
        return await signIn(email: credentials.email, password: credentials.password, device: device, chosenName: name)
    }
    @discardableResult public func login(email: String, password: String) async -> Bool {
        await signIn(email: email, password: password, device: installation)
    }
    private func signIn(email: String, password: String, device: AuthorizedDevice, chosenName: String? = nil) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        message = ""
        do {
            let result = try await backend.login(email: email, password: password, device: device)
            try requireVerified(result)
            try await prepareTrialState(result)
            if let chosenName {
                guard result.device.deviceName == chosenName else { throw BackendFailure.invalidSession }
                try store.write(Data(chosenName.utf8), key: DeviceDisplayName.storageKey)
            }
            try store.delete(quarantineNoticeKey)
            try await writeSessionData(JSONEncoder().encode(SessionCache(login: result, validatedAt: Date())))
            installation.deviceName = device.deviceName
            pendingLogin = nil; requiresDeviceName = false
            onDeviceNameChanged(device.deviceName)
            accept(result, validatedAt: Date(), offline: false)
            devices = (try? await backend.devices(result.session)) ?? [result.device]
            return true
        } catch { message = error.localizedDescription; if !workspaceAllowed { phase = .unauthenticated }; return false }
    }
    @discardableResult public func startTrial(hardwareID: String) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        message = ""
        do {
            if try store.read(consumedTrialKey) != nil { throw BackendFailure.trialConsumed }
            let result = try await backend.trial(device: installation, hardwareID: hardwareID)
            try requireVerified(result)
            try await prepareTrialState(result)
            try await writeSessionData(JSONEncoder().encode(SessionCache(login: result, validatedAt: Date())))
            accept(result, validatedAt: Date(), offline: false); devices = [result.device]
            return true
        } catch { message = error.localizedDescription; if !workspaceAllowed { phase = .unauthenticated }; return false }
    }
    private func validate(cache: SessionCache) async throws {
        var result = cache.login
        var receivedRestriction = false
        do {
            if result.session.expiresAt <= Date().addingTimeInterval(60) {
                result.session = try await backend.refresh(result.session)
                // Persist rotated credentials before another request can fail.
                try await writeSessionData(JSONEncoder().encode(SessionCache(login: result, validatedAt: cache.validatedAt)))
                loginResult = result
                trustedCache = SessionCache(login: result, validatedAt: cache.validatedAt)
            }
            result.entitlement = try await backend.entitlement(result.session)
            try requireVerified(result)
            try await prepareTrialState(result)
            if !result.entitlement.permits(feature, at: result.entitlement.serverTime ?? Date()) {
                // Never let a later timeout restore an older active lease after
                // the server has already reported nonpayment or expiry.
                receivedRestriction = true
                accept(result, validatedAt: Date(), offline: false)
                try await writeSessionData(JSONEncoder().encode(SessionCache(login: result, validatedAt: Date())))
            }
            result.device = try await authorization.validate(session: result.session, installationId: installation.installationId)
            // Revocation/payment changes take effect before optional device-list I/O.
            accept(result, validatedAt: Date(), offline: false)
            try await writeSessionData(JSONEncoder().encode(SessionCache(login: result, validatedAt: Date())))
            if let list = try? await backend.devices(result.session) { devices = list }
        } catch BackendFailure.unavailable {
            if receivedRestriction { return }
            guard (try? requireVerified(cache.login)) != nil, entitlements.permitsOffline(cache, installationId: installation.installationId, feature: feature) else { throw BackendFailure.unavailable }
            // Do not reset the monotonic deadline on a failed network request.
            loginResult = result
            checkLocalExpiry()
            if audioAllowed { phase = .offlineAuthorized; message = "Autorização offline válida." }
        }
    }
    public func revalidate() async {
        checkLocalExpiry()
        guard !busy, let loginResult else { return }
        if loginResult.entitlement.planId == "trial", allowed { return }
        busy = true; defer { busy = false }
        do {
            let cache = trustedCache ?? SessionCache(login: loginResult, validatedAt: Date())
            try await validate(cache: cache)
        } catch { await deny(error) }
    }
    /// This check can revoke access, never extend a lease or restart a trial.
    /// Network failures leave the existing signed offline authorization intact.
    public func checkOnlineAccess() async {
        guard !busy, !checkingOnlineAccess, let result = loginResult else { return }
        checkingOnlineAccess = true; defer { checkingOnlineAccess = false }
        do { try await backend.accessStatus(result.session) }
        catch {
            guard !busy, loginResult?.session.refreshToken == result.session.refreshToken,
                  let failure = error as? BackendFailure,
                  [.quarantined, .blocked, .revoked, .invalidSession].contains(failure) else { return }
            await deny(failure)
        }
    }
    private func deny(_ error: Error) async {
        message = error.localizedDescription
        phase = .unauthorized; revokedPending = false; onPendingRevocation(false)
        setAudio(false, reason: (error as? BackendFailure) == .quarantined ? error.localizedDescription : loginResult.map { result in
            if !result.entitlement.permits(feature, at: serverNow) { return reason(result.entitlement) }
            return error.localizedDescription + " O áudio está desativado."
        } ?? "")
        if let failure = error as? BackendFailure, [.revoked, .blocked, .quarantined, .expired, .invalidSession].contains(failure), var result = loginResult {
            result.device.status = .revoked; loginResult = result
            trustedCache = SessionCache(login: result, validatedAt: Date())
            if let data = try? JSONEncoder().encode(SessionCache(login: result, validatedAt: Date())) {
                try? await writeSessionData(data)
            }
        }
        if (error as? BackendFailure) == .quarantined {
            try? store.write(Data([1]), key: quarantineNoticeKey)
        }
        if let failure = error as? BackendFailure, [.invalidSession, .quarantined].contains(failure) {
            // The server no longer recognizes these credentials (for example,
            // after deleting the account). Keep the editor alive for saving,
            // but discard its login, devices and old signed plan together.
            loginResult = nil; trustedCache = nil; devices = []
            announcedGrace = nil; deadline = 0
            let store = self.store
            do {
                try await Task.detached(priority: .utility) { try store.delete("catlive.production.session") }.value
            } catch {
                // deny() persisted a revoked cache first, so even a failed
                // deletion cannot restore the previous active offline lease.
                message += " " + error.localizedDescription
            }
        }
    }
    private func handleAccountRequestFailure(_ error: Error) async {
        if let failure = error as? BackendFailure, [.invalidSession, .revoked, .blocked, .quarantined, .expired].contains(failure) {
            await deny(error)
        } else { message = error.localizedDescription }
    }
    public func transportDidStop() { checkLocalExpiry() }
    public func logout() async {
        guard !busy, !isPlaying(), let loginResult else { return }
        busy = true; defer { busy = false }
        do {
            try await backend.logout(loginResult.session, installationId: installation.installationId)
            try store.delete("catlive.production.session")
            graceNotice = ""; announcedGrace = nil
            self.loginResult = nil; trustedCache = nil; devices = []; revokedPending = false; message = ""; workspaceAllowed = false
            setAudio(false); phase = .unauthenticated
        } catch BackendFailure.invalidSession {
            do { try clearLocalLogin() } catch { await deny(error) }
        } catch { await handleAccountRequestFailure(error) }
    }
    private func prepareTrialState(_ result: LoginResult) async throws {
        try await clockWrite?.value
        let store = self.store
        if result.entitlement.planId != "trial" {
            let key = consumedTrialKey
            try await Task.detached(priority: .utility) { try store.write(Data([1]), key: key) }.value
        } else {
            if try store.read(consumedTrialKey) != nil { throw BackendFailure.trialConsumed }
            let now = Date()
            let clock = OfflineTrialClock(account: result.account.id, installation: installation.id, expiresAt: result.entitlement.expiresAt, trustedDate: result.entitlement.serverTime ?? now, wallDate: now, uptime: ProcessInfo.processInfo.systemUptime, boot: OfflineTrialClock.bootID)
            let data = try JSONEncoder().encode(clock), key = trialClockKey
            try await Task.detached(priority: .utility) { try store.write(data, key: key) }.value
        }
    }
    private func checkpointTrial() -> Task<Void, Error>? {
        guard let result = loginResult, result.entitlement.planId == "trial" else { return nil }
        lastClockWrite = ProcessInfo.processInfo.systemUptime
        let clock = OfflineTrialClock(account: result.account.id, installation: installation.id, expiresAt: result.entitlement.expiresAt, trustedDate: serverNow, wallDate: Date(), uptime: lastClockWrite, boot: OfflineTrialClock.bootID)
        let prior = clockWrite, store = self.store, key = trialClockKey
        let task = Task.detached(priority: .utility) {
            try await prior?.value
            try store.write(JSONEncoder().encode(clock), key: key)
        }
        clockWrite = task
        return task
    }
    public func refreshDevices() async {
        guard !busy, var result = loginResult else { return }
        busy = true; defer { busy = false }
        do {
            if result.session.expiresAt <= Date().addingTimeInterval(60) {
                result.session = try await backend.refresh(result.session)
                self.loginResult = result
                try await writeSessionData(JSONEncoder().encode(SessionCache(login: result, validatedAt: trustedCache?.validatedAt ?? Date())))
            }
            devices = try await backend.devices(result.session)
        } catch { await handleAccountRequestFailure(error) }
    }
    public func removeDevice(_ device: AuthorizedDevice) async {
        guard !busy, let result = loginResult else { return }
        busy = true; defer { busy = false }
        do {
            try await backend.revokeDevice(result.session, installationId: device.id)
            devices.removeAll { $0.id == device.id }
            if device.id == installation.id { try clearLocalLogin() }
        } catch { await handleAccountRequestFailure(error) }
    }
    public func removedAtLogin(_ device: AuthorizedDevice, email: String) {
        guard device.id == installation.id, loginResult?.account.email.lowercased() == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return }
        do { try clearLocalLogin() } catch { message = error.localizedDescription }
    }
    private func clearLocalLogin() throws {
        // Stop audio first, even if secure storage is temporarily unavailable.
        setAudio(false)
        if var cached = loginResult {
            cached.device.status = .revoked
            try store.write(JSONEncoder().encode(SessionCache(login: cached, validatedAt: Date())), key: "catlive.production.session")
        }
        try store.delete("catlive.production.session")
        loginResult = nil; trustedCache = nil; devices = []; workspaceAllowed = false
        graceNotice = ""; announcedGrace = nil; message = ""; phase = .unauthenticated
    }
    public func signup(name: String, email: String, password: String) async { message = "O cadastro é realizado pelo administrador ou após a compra." }
    public func resetPassword(email: String) async { message = "Use o e-mail e o CPF cadastrados na compra." }
    public func showLogin() { guard !isPlaying() else { return }; phase = .unauthenticated; message = "" }
}
