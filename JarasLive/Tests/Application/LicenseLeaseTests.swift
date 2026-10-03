import XCTest
import CryptoKit
import Combine
@testable import JarasApplication
private func signedLease(_ source: Entitlement, key: Curve25519.Signing.PrivateKey, account: UUID, device: UUID) throws -> Entitlement {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .custom { date, encoder in var c = encoder.singleValueContainer(); try c.encode(formatter.string(from: date)) }
    var data = try JSONSerialization.jsonObject(with: encoder.encode(source)) as! [String: Any]
    data["version"] = 1; data["accountId"] = account.uuidString; data["installationId"] = device.uuidString
    data.removeValue(forKey: "proof")
    let payload = try JSONSerialization.data(withJSONObject: data, options: .sortedKeys)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .custom { try formatter.date(from: $0.singleValueContainer().decode(String.self))! }
    var result = try decoder.decode(Entitlement.self, from: payload)
    result.proof = LicenseLeaseProof(payload: payload.base64EncodedString(), signature: try key.signature(for: payload).base64EncodedString())
    return result
}
private actor SignedTrialBackend: BackendClient {
    var result: LoginResult
    var offline = false
    var failure: BackendFailure?
    func fail(_ value: BackendFailure) { failure = value }
    var requests = 0
    init(result: LoginResult) { self.result = result }
    func setOffline() { offline = true }
    func available() throws { requests += 1; if let failure { throw failure }; if offline { throw BackendFailure.unavailable } }
    func login(email: String, password: String, device: AuthorizedDevice) throws -> LoginResult { try available(); return result }
    func trial(device: AuthorizedDevice, hardwareID: String) throws -> LoginResult { try available(); return result }
    func signup(name: String, email: String, password: String) throws {}
    func resetPassword(email: String) throws {}
    func refresh(_ session: AuthSession) throws -> AuthSession { try available(); return result.session }
    func entitlement(_ session: AuthSession) throws -> Entitlement { try available(); return result.entitlement }
    func device(_ session: AuthSession, installationId: UUID) throws -> AuthorizedDevice { try available(); return result.device }
    func devices(_ session: AuthSession) throws -> [AuthorizedDevice] { try available(); return [result.device] }
    func revokeDevice(_ session: AuthSession, installationId: UUID) throws { try available() }
    func logout(_ session: AuthSession, installationId: UUID) throws {}
}
final class LicenseLeaseTests: XCTestCase {
    func fixture(leaseDuration: Double = 7*86400, plan: String = "trial") throws -> (LoginResult, LicenseLeaseVerifier) {
        let store = MemorySecureStore(), key = Curve25519.Signing.PrivateKey()
        let device = try DeviceAuthorizationService.installation(store: store, name: "Signed trial", platform: "macOS")
        let account = UserAccount(id: UUID(), name: "Trial", email: "test@trial.invalid"), now = Date()
        let lease = Entitlement(status: "active", planId: plan, expiresAt: now.addingTimeInterval(7*86400), offlineValidUntil: now.addingTimeInterval(leaseDuration), serverTime: now, maxDevices: 4, features: ["desktop"])
        return (LoginResult(account: account, session: AuthSession(accessToken: "signed-access", refreshToken: "signed-refresh", expiresAt: now.addingTimeInterval(900)), entitlement: try signedLease(lease, key: key, account: account.id, device: device.id), device: device), LicenseLeaseVerifier(publicKey: key.publicKey.rawRepresentation))
    }
    func testSignatureRejectsEditedDatesPlanSeatsAccountDeviceAndSigningKey() throws {
        let (result, verifier) = try fixture()
        let verify: (Entitlement) -> Bool = { verifier.verify($0, account: result.account.id, installation: result.device.id) }
        XCTAssertTrue(verify(result.entitlement))
        var changed = result.entitlement; changed.expiresAt = .distantFuture; XCTAssertFalse(verify(changed))
        changed = result.entitlement; changed.offlineValidUntil = .distantFuture; XCTAssertFalse(verify(changed))
        changed = result.entitlement; changed.planId = "vitalicio"; XCTAssertFalse(verify(changed))
        changed = result.entitlement; changed.maxDevices = 10; XCTAssertFalse(verify(changed))
        changed = result.entitlement; changed.status = "blocked"; XCTAssertFalse(verify(changed))
        changed = result.entitlement; changed.proof = nil; XCTAssertFalse(verify(changed))
        XCTAssertFalse(verifier.verify(result.entitlement, account: UUID(), installation: result.device.id))
        XCTAssertFalse(verifier.verify(result.entitlement, account: result.account.id, installation: UUID()))
        XCTAssertFalse(LicenseLeaseVerifier(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation).verify(result.entitlement, account: result.account.id, installation: result.device.id))
    }
    @MainActor func testTrialRestartWorksOfflineWithoutAnyNetworkRequests() async throws {
        let (result, verifier) = try fixture(), store = MemorySecureStore(), backend = SignedTrialBackend(result: result)
        let auth = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        await auth.startTrial(hardwareID: "hardware-test")
        XCTAssertTrue(auth.allowed); XCTAssertEqual(auth.trialDaysRemaining, 7)
        let requests = await backend.requests
        await backend.setOffline(); await auth.revalidate()
        XCTAssertTrue(auth.allowed, "an already validated running show keeps its remaining lease")
        let restart = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        await restart.restore()
        XCTAssertTrue(restart.allowed, "signed trial and secure clock survive an offline restart")
        let after = await backend.requests
        XCTAssertEqual(after, requests, "no validation request before trial expiry")
        XCTAssertTrue(restart.workspaceAllowed)
    }
    @MainActor func testModifiedCacheCannotExtendRunningMonotonicLease() async throws {
        let (result, verifier) = try fixture(leaseDuration: 0.4), store = MemorySecureStore(), backend = SignedTrialBackend(result: result)
        let auth = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        await auth.startTrial(hardwareID: "hardware-test"); XCTAssertTrue(auth.allowed)
        auth.isPlaying = { true }
        await backend.setOffline()
        try store.write(JSONEncoder().encode(SessionCache(login: result, validatedAt: .distantFuture)), key: "catlive.production.session")
        await auth.revalidate()
        try await Task.sleep(nanoseconds: 500_000_000)
        auth.checkLocalExpiry()
        XCTAssertFalse(auth.allowed)
        await auth.revalidate()
        XCTAssertFalse(auth.allowed, "offline retries must not reset the monotonic expiry")
    }
    @MainActor func testForgedBackendLeaseNeverEnablesAudio() async throws {
        var (result, verifier) = try fixture(); result.entitlement.expiresAt = .distantFuture
        let backend = SignedTrialBackend(result: result)
        let auth = AuthService(backend: backend, store: MemorySecureStore(), installation: result.device, feature: "desktop", verifier: verifier)
        var enabled = false; auth.onAudioAuthorization = { if $0 { enabled = true } }
        await auth.startTrial(hardwareID: "hardware-test")
        XCTAssertFalse(auth.allowed); XCTAssertFalse(enabled)
    }
    @MainActor func testStableLocalExpiryHeartbeatDoesNotPublishForPaidTrialOrGrace() async throws {
        var services: [(String, AuthService, SignedTrialBackend, Int)] = []
        var publications: [String: Int] = [:], audioCallbacks: [String: Int] = [:]
        var subscriptions: [AnyCancellable] = []
        defer { subscriptions.forEach { $0.cancel() } }
        for state in ["paid", "trial", "grace"] {
            var (result, verifier) = try fixture(plan: state == "trial" ? "trial" : "6-meses")
            if state == "grace" {
                let key = Curve25519.Signing.PrivateKey(), now = Date()
                result.entitlement.status = "overdue"
                result.entitlement.expiresAt = now.addingTimeInterval(-86400)
                result.entitlement.graceStartsAt = now.addingTimeInterval(-86400)
                result.entitlement.graceUntil = now.addingTimeInterval(6*86400)
                result.entitlement.graceReason = "overdue"
                result.entitlement = try signedLease(result.entitlement, key: key, account: result.account.id, device: result.device.id)
                verifier = LicenseLeaseVerifier(publicKey: key.publicKey.rawRepresentation)
            }
            let backend = SignedTrialBackend(result: result)
            let auth = AuthService(backend: backend, store: MemorySecureStore(), installation: result.device, feature: "desktop", verifier: verifier)
            let success: Bool
            if state == "trial" { success = await auth.startTrial(hardwareID: "heartbeat-test") }
            else { success = await auth.login(email: "heartbeat@test.invalid", password: "cpf") }
            XCTAssertTrue(success); XCTAssertTrue(auth.allowed)
            XCTAssertEqual(auth.graceNotice.isEmpty, state != "grace")
            services.append((state, auth, backend, await backend.requests))
            subscriptions.append(auth.objectWillChange.sink { publications[state, default: 0] += 1 })
            auth.onAudioAuthorization = { _ in audioCallbacks[state, default: 0] += 1 }
        }
        // Exercise the real one-second cadence, including the trial clock checkpoint.
        for tick in 0..<3 {
            for (_, auth, _, _) in services { auth.checkLocalExpiry() }
            if tick < 2 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        for (state, auth, backend, initialRequests) in services {
            XCTAssertEqual(publications[state, default: 0], 0, "Stable \(state) must not invalidate observers")
            XCTAssertEqual(audioCallbacks[state, default: 0], 0)
            XCTAssertTrue(auth.allowed); XCTAssertTrue(auth.restriction.isEmpty)
            XCTAssertEqual(auth.graceNotice.isEmpty, state != "grace")
            let requests = await backend.requests
            XCTAssertEqual(requests, initialRequests, "The local heartbeat must remain offline")
        }
    }
}

extension LicenseLeaseTests {
    func testPaidTitleCountsCalendarMonthsThenDaysAndLifetimeDoesNotCountDown() {
        func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T00:00:00Z")! }
        var e = Entitlement(status: "active", planId: "6-meses", expiresAt: date("2026-07-01"), offlineValidUntil: .distantFuture, maxDevices: 4, features: ["desktop"])
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: date("2026-01-01")), "Maria — Acesso 6 meses")
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: date("2026-02-01")), "Maria — Acesso 5 meses")
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: date("2026-06-02")), "Maria — Acesso 29 dias")
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: date("2026-06-03")), "Maria — Acesso 28 dias")
        e.planId = "1-ano"; e.expiresAt = date("2027-01-01")
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: date("2026-01-01")), "Maria — Acesso 12 meses")
        e.planId = "vitalicio"
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: date("2026-01-01")), "Maria — Acesso Vitalício")
    }
    func testGraceBoundaryReasonsAndNoGraceForTrialOrBlockedAccount() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var e = Entitlement(status: "expired", planId: "6-meses", expiresAt: start, offlineValidUntil: start.addingTimeInterval(86400), graceStartsAt: start, graceUntil: start.addingTimeInterval(7*86400), graceReason: "expired", maxDevices: 4, features: ["desktop"])
        XCTAssertTrue(e.permits("desktop", at: start))
        XCTAssertEqual(e.graceDaysRemaining(at: start), 7)
        XCTAssertEqual(e.graceDaysRemaining(at: start.addingTimeInterval(86400)), 6)
        XCTAssertTrue(e.permits("desktop", at: start.addingTimeInterval(7*86400 - 1)))
        XCTAssertFalse(e.permits("desktop", at: start.addingTimeInterval(7*86400)))
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: start), "Maria — 7 dias de tolerância")
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: start.addingTimeInterval(7*86400)), "Maria — Renove sua licença")
        e.status = "overdue"; e.graceReason = "overdue"
        XCTAssertEqual(LicenseDisplay.title(name: "Maria", entitlement: e, at: start.addingTimeInterval(7*86400)), "Maria — Pagamento atrasado")
        e.status = "blocked"; XCTAssertFalse(e.permits("desktop", at: start))
        e.status = "trialExpired"; e.planId = "trial"; XCTAssertFalse(e.permits("desktop", at: start))
    }
    @MainActor func testSignedGracePermitsUntilDeadlineAndShowsNoticeOnEachLaunch() async throws {
        var (result, _) = try fixture()
        let key = Curve25519.Signing.PrivateKey(), now = Date()
        result.account.name = "Maria"; result.entitlement.planId = "6-meses"; result.entitlement.status = "overdue"
        result.entitlement.expiresAt = now.addingTimeInterval(-86400)
        result.entitlement.graceStartsAt = now.addingTimeInterval(-86400)
        result.entitlement.graceUntil = now.addingTimeInterval(0.8)
        result.entitlement.graceReason = "overdue"; result.entitlement.serverTime = now
        result.entitlement.offlineValidUntil = now.addingTimeInterval(0.8)
        result.entitlement = try signedLease(result.entitlement, key: key, account: result.account.id, device: result.device.id)
        let verifier = LicenseLeaseVerifier(publicKey: key.publicKey.rawRepresentation)
        let store = MemorySecureStore(), backend = SignedTrialBackend(result: result)
        let auth = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        var notices: [String] = []
        let noticeSubscription = auth.$graceNotice.dropFirst().sink { notices.append($0) }
        defer { noticeSubscription.cancel() }
        await auth.login(email: "maria@test.invalid", password: "cpf")
        XCTAssertTrue(auth.allowed); XCTAssertFalse(auth.graceNotice.isEmpty)
        XCTAssertEqual(notices, [auth.graceNotice], "Entering grace still publishes its notice")
        XCTAssertTrue(auth.licenseTitle?.contains("Maria — 1 dia de tolerância") == true)
        let restarted = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        await restarted.restore(); XCTAssertTrue(restarted.allowed); XCTAssertFalse(restarted.graceNotice.isEmpty)
        var tampered = result.entitlement; tampered.graceUntil = now.addingTimeInterval(100000)
        XCTAssertFalse(verifier.verify(tampered, account: result.account.id, installation: result.device.id))
        var publications = 0, audioCallbacks: [Bool] = []
        let subscription = auth.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        auth.onAudioAuthorization = { audioCallbacks.append($0) }
        auth.checkLocalExpiry()
        XCTAssertEqual(publications, 0, "An unchanged grace notice must not publish again")
        try await Task.sleep(nanoseconds: 900_000_000)
        auth.checkLocalExpiry(); XCTAssertFalse(auth.allowed); XCTAssertTrue(auth.graceNotice.isEmpty)
        XCTAssertTrue(auth.restriction.contains("atraso"))
        XCTAssertGreaterThan(publications, 0, "Expiry must still invalidate observers")
        XCTAssertEqual(notices.count, 2); XCTAssertEqual(notices.last, "")
        XCTAssertEqual(audioCallbacks, [false], "Expiry must still close the audio gate")
        let expiredPublications = publications
        auth.checkLocalExpiry()
        XCTAssertEqual(publications, expiredPublications, "An already blocked heartbeat must stay quiet")
    }
}

@MainActor private final class LicenseCommandExecutor: CommandExecutor {
    var project = Project.empty(name: "License commands")
    var commands: [ShowCommand] = []
    func load(_ project: Project) throws { self.project = project }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws { commands.append(command) }
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))) }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: try playbackSnapshot().transport) }
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}
extension LicenseLeaseTests {
    @MainActor func testExpiredLicenseBlocksPlaySubPlayAndNewTracksButAllowsSaving() async throws {
        let (result, verifier) = try fixture(leaseDuration: 0.25)
        let auth = AuthService(backend: SignedTrialBackend(result: result), store: MemorySecureStore(), installation: result.device, feature: "desktop", verifier: verifier)
        let engine = LicenseCommandExecutor(), persistence = MemoryProjectStore()
        let show = try ShowController(executor: engine, persistence: persistence, initialProject: engine.project)
        show.canExecute = { auth.allowed }
        await auth.startTrial(hardwareID: "test-hardware")
        XCTAssertEqual(show.addTracks(name: "Allowed", role: .keys, count: 1).count, 1)
        show.send(.play); XCTAssertTrue(engine.commands.contains(.play))
        try await Task.sleep(nanoseconds: 300_000_000); auth.checkLocalExpiry()
        XCTAssertFalse(auth.allowed)
        let commandCount = engine.commands.count, tracks = show.snapshot.project.songs[0].tracks.count
        show.send(.play); show.send(.subPlay)
        XCTAssertEqual(engine.commands.count, commandCount)
        XCTAssertTrue(show.addTracks(name: "Blocked", role: .keys, count: 1).isEmpty)
        XCTAssertEqual(show.snapshot.project.songs[0].tracks.count, tracks)
        try await show.saveForClosing()
        XCTAssertFalse(show.hasUnsavedChanges)
        let saved = try await persistence.load(); XCTAssertNotNil(saved)
    }
}


extension LicenseLeaseTests {
    func testTrialCheckpointDetectsRollbackAndCountsUptimeAndReboots() throws {
        let account = UUID(), installation = UUID(), wall = Date(), end = wall.addingTimeInterval(7*86400)
        let c = OfflineTrialClock(account: account, installation: installation, expiresAt: end, trustedDate: wall, wallDate: wall, uptime: 100, boot: "boot-A")
        XCTAssertThrowsError(try c.resume(account: account, installation: installation, expiresAt: end, wall: wall.addingTimeInterval(-301), uptime: 110, boot: "boot-A"))
        XCTAssertEqual(try c.resume(account: account, installation: installation, expiresAt: end, wall: wall, uptime: 3700, boot: "boot-A"), wall.addingTimeInterval(3600))
        XCTAssertEqual(try c.resume(account: account, installation: installation, expiresAt: end, wall: wall.addingTimeInterval(86400), uptime: 20, boot: "boot-B"), wall.addingTimeInterval(86400))
        XCTAssertThrowsError(try c.resume(account: UUID(), installation: installation, expiresAt: end))
    }
    @MainActor func testConsumedTrialCannotRestoreOrRestartAfterPaidLogin() async throws {
        let (result, verifier) = try fixture(), store = MemorySecureStore(), backend = SignedTrialBackend(result: result)
        let auth = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        await auth.startTrial(hardwareID: "test-hardware")
        store.write(Data([1]), key: "catlive.production.trialConsumed")
        let restart = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        let requests = await backend.requests
        await restart.restore(); XCTAssertFalse(restart.allowed)
        await restart.startTrial(hardwareID: "test-hardware"); XCTAssertFalse(restart.allowed)
        let after = await backend.requests; XCTAssertEqual(after, requests)
        XCTAssertTrue(restart.message.contains("encerrado"))
    }
    @MainActor func testFailedLoginDuringTrialDoesNotReportSuccess() async throws {
        let (result, verifier) = try fixture(), backend = SignedTrialBackend(result: result)
        let auth = AuthService(backend: backend, store: MemorySecureStore(), installation: result.device, feature: "desktop", verifier: verifier)
        await auth.startTrial(hardwareID: "test-hardware"); await backend.setOffline()
        let success = await auth.login(email: "wrong", password: "wrong")
        XCTAssertFalse(success); XCTAssertTrue(auth.allowed)
    }
}

extension LicenseLeaseTests {
    @MainActor func testRemovingCurrentDeviceStopsAudioAndClearsSavedLogin() async throws {
        let (result, verifier) = try fixture(), store = MemorySecureStore(), backend = SignedTrialBackend(result: result)
        let auth = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        await auth.startTrial(hardwareID: "test-hardware"); XCTAssertTrue(auth.allowed)
        auth.isPlaying = { true }
        var audioStopped = false
        auth.onAudioAuthorization = { if !$0 { audioStopped = true } }
        await auth.removeDevice(result.device)
        XCTAssertTrue(audioStopped); XCTAssertFalse(auth.allowed); XCTAssertNil(auth.loginResult)
        XCTAssertNil(store.read("catlive.production.session")); XCTAssertNotNil(store.read("catlive.production.trialClock"))
    }
}


extension LicenseLeaseTests {
    @MainActor func testDeletedLifetimeAccountClearsLoginTitleDevicesAndOfflineCache() async throws {
        for request in ["validate", "devices", "removeDevice"] {
            let (result, verifier) = try fixture(plan: "vitalicio")
            let store = MemorySecureStore(), backend = SignedTrialBackend(result: result)
            let auth = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
            let success = await auth.login(email: "test@example.invalid", password: "cpf")
            XCTAssertTrue(success)
            XCTAssertTrue(auth.licenseTitle?.contains("Acesso Vitalício") == true)
            XCTAssertFalse(auth.devices.isEmpty)
            await backend.fail(.invalidSession)
            if request == "validate" { await auth.revalidate() }
            else if request == "devices" { await auth.refreshDevices() }
            else { await auth.removeDevice(result.device) }
            XCTAssertFalse(auth.allowed)
            XCTAssertNil(auth.loginResult)
            XCTAssertTrue(auth.devices.isEmpty)
            XCTAssertEqual(auth.licenseTitle, "Entre novamente na sua conta")
            XCTAssertFalse(auth.restriction.isEmpty)
            XCTAssertTrue(auth.workspaceAllowed, "keep the open editor available for saving")
            XCTAssertNil(store.read("catlive.production.session"))
            XCTAssertNotNil(store.read("catlive.production.trialConsumed"), "deleting an account cannot reset the trial")
            let restart = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
            await backend.setOffline()
            await restart.restore()
            XCTAssertFalse(restart.allowed)
            XCTAssertNil(restart.loginResult)
            XCTAssertNil(restart.licenseTitle)
            XCTAssertEqual(restart.phase, .unauthenticated)
        }
    }
    @MainActor func testRevokedDeviceCannotAdvertiseLifetimeAndNetworkOutageKeepsValidLease() async throws {
        let (result, verifier) = try fixture(plan: "vitalicio")
        let store = MemorySecureStore(), backend = SignedTrialBackend(result: result)
        let auth = AuthService(backend: backend, store: store, installation: result.device, feature: "desktop", verifier: verifier)
        _ = await auth.login(email: "test@example.invalid", password: "cpf")
        await backend.setOffline(); await auth.revalidate()
        XCTAssertTrue(auth.allowed)
        XCTAssertTrue(auth.licenseTitle?.contains("Acesso Vitalício") == true)
        await backend.fail(.revoked); await auth.revalidate()
        XCTAssertFalse(auth.allowed)
        XCTAssertFalse(auth.licenseTitle?.contains("Acesso Vitalício") == true)
        XCTAssertEqual(auth.licenseTitle, "Dispositivo não autorizado — faça login")
    }
}
