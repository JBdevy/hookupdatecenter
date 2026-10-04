import XCTest
@testable import JarasApplication

private actor QuarantineBackend: BackendClient {
    let base = MockBackendClient()
    var failure: BackendFailure?
    var delayed = false
    var waiting: CheckedContinuation<Void, Error>?
    var checks = 0
    func setFailure(_ value: BackendFailure?) { failure = value }
    func delayCheck() { delayed = true }
    func finishDelayedCheck() { waiting?.resume(throwing: BackendFailure.quarantined); waiting = nil }
    func login(email: String, password: String, device: AuthorizedDevice) async throws -> LoginResult {
        if failure == .quarantined { throw BackendFailure.quarantined }
        return try await base.login(email: email, password: password, device: device)
    }
    func credentialDevices(email: String, cpf: String) async throws -> [AuthorizedDevice] { try await base.credentialDevices(email: email, cpf: cpf) }
    func accessStatus(_ session: AuthSession) async throws {
        checks += 1
        if delayed { try await withCheckedThrowingContinuation { waiting = $0 }; return }
        if let failure { throw failure }
    }
    func signup(name: String, email: String, password: String) async throws {}
    func resetPassword(email: String) async throws {}
    func refresh(_ session: AuthSession) async throws -> AuthSession { try await base.refresh(session) }
    func entitlement(_ session: AuthSession) async throws -> Entitlement { try await base.entitlement(session) }
    func device(_ session: AuthSession, installationId: UUID) async throws -> AuthorizedDevice { try await base.device(session, installationId: installationId) }
    func devices(_ session: AuthSession) async throws -> [AuthorizedDevice] { try await base.devices(session) }
    func logout(_ session: AuthSession, installationId: UUID) async throws { try await base.logout(session, installationId: installationId) }
}
final class QuarantineAccessTests: XCTestCase {
    @MainActor func testOnlineQuarantineCutsAudioLogsOutAndPersistsNoticeAcrossOfflineRestart() async throws {
        let backend = QuarantineBackend(), store = MemorySecureStore()
        store.write(Data("Stage PC".utf8), key: DeviceDisplayName.storageKey)
        let device = try DeviceAuthorizationService.installation(store: store, name: "System", platform: "macOS")
        let auth = AuthService(backend: backend, store: store, installation: device, feature: "desktop")
        var audio = false
        auth.onAudioAuthorization = { audio = $0 }
        let login = await auth.beginLogin(email: "demo@catlive.app", password: "catlive123")
        XCTAssertTrue(login); XCTAssertTrue(audio)
        await backend.setFailure(.quarantined)
        await auth.checkOnlineAccess()
        XCTAssertFalse(audio); XCTAssertFalse(auth.allowed)
        XCTAssertNil(auth.loginResult); XCTAssertTrue(auth.devices.isEmpty)
        XCTAssertTrue(auth.workspaceAllowed, "the editor remains available for saving the user's project")
        XCTAssertEqual(auth.restriction, BackendFailure.quarantined.localizedDescription)
        XCTAssertNil(store.read("catlive.production.session"))
        let restarted = AuthService(backend: backend, store: store, installation: device, feature: "desktop")
        await restarted.restore()
        XCTAssertFalse(restarted.allowed); XCTAssertNil(restarted.loginResult)
        XCTAssertEqual(restarted.message, BackendFailure.quarantined.localizedDescription)
        let stillBlocked = await restarted.beginLogin(email: "demo@catlive.app", password: "catlive123")
        XCTAssertFalse(stillBlocked)
        await backend.setFailure(nil)
        let released = await restarted.beginLogin(email: "demo@catlive.app", password: "catlive123")
        XCTAssertTrue(released)
        XCTAssertNil(store.read("catlive.production.quarantineNotice"))
        XCTAssertEqual(restarted.installation.deviceName, "Stage PC")
    }
    @MainActor func testNetworkFailureCannotRevokeOrExtendOfflineLicense() async throws {
        let backend = QuarantineBackend(), store = MemorySecureStore()
        let device = try DeviceAuthorizationService.installation(store: store, name: "Test", platform: "macOS")
        let auth = AuthService(backend: backend, store: store, installation: device, feature: "desktop")
        _ = await auth.login(email: "demo@catlive.app", password: "catlive123")
        let cached = store.read("catlive.production.session"), deadline = auth.loginResult?.entitlement.offlineValidUntil
        await backend.setFailure(.unavailable)
        await auth.checkOnlineAccess()
        XCTAssertTrue(auth.allowed); XCTAssertEqual(store.read("catlive.production.session"), cached)
        XCTAssertEqual(auth.loginResult?.entitlement.offlineValidUntil, deadline)
    }
    @MainActor func testDelayedReplyCannotLogOutANewerSession() async throws {
        let backend = QuarantineBackend(), store = MemorySecureStore()
        let device = try DeviceAuthorizationService.installation(store: store, name: "Test", platform: "macOS")
        let auth = AuthService(backend: backend, store: store, installation: device, feature: "desktop")
        _ = await auth.login(email: "demo@catlive.app", password: "catlive123")
        await backend.delayCheck()
        let check = Task { await auth.checkOnlineAccess() }
        while await backend.checks == 0 { await Task.yield() }
        _ = await auth.login(email: "demo@catlive.app", password: "catlive123")
        await backend.finishDelayedCheck(); await check.value
        XCTAssertTrue(auth.allowed); XCTAssertNotNil(auth.loginResult)
    }
}
