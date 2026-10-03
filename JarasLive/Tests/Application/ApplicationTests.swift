import XCTest
import CryptoKit
@testable import JarasApplication
final class ApplicationTests: XCTestCase {
    func testDemoRebrandRetainsAccountAndActiveDevice() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("mock.json")
        let backend = MockBackendClient(file: file)
        let installed = device("Existing Mac")
        let original = try await backend.login(email: "demo@catlive.app", password: "catlive123", device: installed)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var accounts = try XCTUnwrap(json["accounts"] as? [[String: Any]])
        var user = try XCTUnwrap(accounts[0]["user"] as? [String: Any])
        user["email"] = "demo@jaras.live"; user["name"] = "Equipe Jaras"
        accounts[0]["user"] = user
        accounts[0]["passwordHash"] = SHA256.hash(data: Data("jaras123".utf8)).map { String(format: "%02x", $0) }.joined()
        json["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let updated = MockBackendClient(file: file)
        let active = try await updated.device(original.session, installationId: installed.id)
        XCTAssertEqual(active.status, .active)
        let login = try await updated.login(email: "demo@catlive.app", password: "catlive123", device: installed)
        XCTAssertEqual(login.account.id, original.account.id)
        XCTAssertEqual(login.account.name, "Equipe CatLive")
        let devices = try await updated.devices(login.session)
        XCTAssertEqual(devices.filter { $0.status == .active }.count, 1)
    }
    func device(_ name: String) -> AuthorizedDevice { AuthorizedDevice(installationId: UUID(), deviceName: name, platform: "macOS", platformVersion: "13", appVersion: "1.0.0", activatedAt: Date(), lastSeenAt: Date(), status: .active) }
    func testProjectRoundTripAndPaths() throws {
        var project = Project.demo(); try project.validate()
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), project)
        project.songs[0].tracks[0].audioFile = AudioFile(path: "/private/audio.wav")
        XCTAssertThrowsError(try project.validate())
        project.songs[0].tracks[0].audioFile = AudioFile(path: "audio/../private.wav")
        XCTAssertThrowsError(try project.validate())
        project.songs[0].tracks[0].audioFile = AudioFile(path: "audio/song/click.wav")
        try project.validate()
        XCTAssertEqual(project.songs[0].tracks[9].role, .accordion)
    }
    func testLicenseLimitsAndOldestReplacement() async throws {
        for limit in 1...3 {
            let backend = MockBackendClient(); await backend.configure(maxDevices: limit, scenario: .valid)
            let first = try await backend.login(email: "demo@catlive.app", password: "catlive123", device: device("first"))
            var last = first
            for index in 0..<limit { last = try await backend.login(email: "demo@catlive.app", password: "catlive123", device: device("next\(index)")) }
            let devices = try await backend.devices(last.session)
            XCTAssertEqual(devices.filter { $0.status == .active }.count, limit)
            XCTAssertEqual(devices.first { $0.id == first.device.id }?.status, .revoked)
            try await backend.logout(last.session, installationId: last.device.id)
            do { _ = try await backend.devices(last.session); XCTFail("Session must be invalidated") } catch BackendFailure.invalidSession {}
        }
    }
    func testRepeatedInstallationDoesNotConsumeExtraSeat() async throws {
        let backend = MockBackendClient(); let same = device("same")
        _ = try await backend.login(email: "demo@catlive.app", password: "catlive123", device: same)
        let result = try await backend.login(email: "demo@catlive.app", password: "catlive123", device: same)
        let active = try await backend.devices(result.session).filter { $0.status == .active }
        XCTAssertEqual(active.count, 1)
    }
    @MainActor func testPeriodicSessionStorageDoesNotBlockInterface() async throws {
        let backend = MockBackendClient(), store = BackgroundSessionStore()
        let auth = AuthService(backend: backend, store: store, installation: device("Mac"), feature: "desktop")
        await auth.login(email: "demo@catlive.app", password: "catlive123")
        XCTAssertTrue(auth.allowed)
        store.blockNextRead()
        let checking = Task { @MainActor in await auth.revalidate() }
        try await Task.sleep(nanoseconds: 40_000_000)
        // This main-actor continuation must run while the storage call waits.
        store.release.signal()
        await checking.value
        XCTAssertEqual(store.mainCalls, 0)
        XCTAssertFalse(store.timedOut)
        XCTAssertTrue(auth.allowed)
    }
    @MainActor func testSessionRestoreOfflineAndSafeRevocation() async throws {
        let backend = MockBackendClient(); let store = MemorySecureStore(); let installed = device("Mac")
        let auth = AuthService(backend: backend, store: store, installation: installed, feature: "desktop")
        await auth.login(email: "demo@catlive.app", password: "catlive123"); XCTAssertEqual(auth.phase, .authorized)
        let restored = AuthService(backend: backend, store: store, installation: installed, feature: "desktop")
        await restored.restore(); XCTAssertEqual(restored.phase, .offlineAuthorized)
        await backend.setOffline(true); await restored.revalidate(); XCTAssertEqual(restored.phase, .offlineAuthorized)
        await backend.setOffline(false); restored.isPlaying = { true }
        try await backend.revoke(installed.id); await restored.revalidate()
        XCTAssertFalse(restored.revokedPending); XCTAssertFalse(restored.allowed)
        XCTAssertTrue(restored.workspaceAllowed, "Revocation must preserve the project for saving")
        XCTAssertFalse(restored.restriction.isEmpty)
        restored.isPlaying = { false }; restored.transportDidStop(); XCTAssertEqual(restored.phase, .unauthorized)
        await backend.setOffline(true)
        let offlineRestart = AuthService(backend: backend, store: store, installation: installed, feature: "desktop")
        await offlineRestart.restore(); XCTAssertEqual(offlineRestart.phase, .unauthorized)
    }
    @MainActor func testExpiredLicenseSilencesDuringPlaybackAndRenewalRestoresAccess() async throws {
        let backend = MockBackendClient(), store = MemorySecureStore()
        let auth = AuthService(backend: backend, store: store, installation: device("Mac"), feature: "desktop")
        var output = false
        auth.onAudioAuthorization = { output = $0 }
        await auth.login(email: "demo@catlive.app", password: "catlive123")
        XCTAssertTrue(output)
        auth.isPlaying = { true }
        await backend.configure(maxDevices: 2, scenario: .expired)
        await auth.revalidate()
        XCTAssertFalse(output); XCTAssertFalse(auth.allowed)
        XCTAssertTrue(auth.workspaceAllowed)
        XCTAssertFalse(auth.restriction.isEmpty)
        await backend.configure(maxDevices: 2, scenario: .valid)
        await auth.revalidate()
        XCTAssertTrue(output); XCTAssertTrue(auth.allowed)
        XCTAssertTrue(auth.restriction.isEmpty)
    }
    func testOfflineExpiryUsesServerClockAndCannotExtendTrialByLocalClockOffset() async throws {
        let backend = MockBackendClient(), installed = device("Mac")
        var login = try await backend.login(email: "demo@catlive.app", password: "catlive123", device: installed)
        let server = Date(timeIntervalSince1970: 2_000_000_000), local = Date(timeIntervalSince1970: 1_000_000_000)
        login.entitlement.serverTime = server
        login.entitlement.expiresAt = server.addingTimeInterval(100)
        login.entitlement.offlineValidUntil = server.addingTimeInterval(100)
        let cache = SessionCache(login: login, validatedAt: local)
        let service = EntitlementService(backend: backend)
        XCTAssertTrue(service.permitsOffline(cache, installationId: installed.id, feature: "desktop", date: local.addingTimeInterval(99)))
        XCTAssertFalse(service.permitsOffline(cache, installationId: installed.id, feature: "desktop", date: local.addingTimeInterval(101)))
        XCTAssertFalse(service.permitsOffline(cache, installationId: installed.id, feature: "desktop", date: local.addingTimeInterval(-301)))
    }
    func testInstallationPersistsAndWrongLoginFails() async throws {
        let store = MemorySecureStore()
        let one = try DeviceAuthorizationService.installation(store: store, name: "Mac", platform: "macOS")
        let two = try DeviceAuthorizationService.installation(store: store, name: "New name", platform: "macOS")
        XCTAssertEqual(one.id, two.id)
        do { _ = try await MockBackendClient().login(email: "demo@catlive.app", password: "wrong", device: one); XCTFail("Invalid password") } catch BackendFailure.invalidCredentials {}
    }
    func testRefreshPersistenceAndConcurrentSeats() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("mock.json")
        let backend = MockBackendClient(file: file)
        await backend.configure(maxDevices: 3, scenario: .valid)
        let installed = device("Persistent")
        let login = try await backend.login(email: "demo@catlive.app", password: "catlive123", device: installed)
        let refreshed = try await backend.refresh(login.session)
        XCTAssertNotEqual(refreshed.accessToken, login.session.accessToken)
        let restarted = MockBackendClient(file: file)
        let authorized = try await restarted.device(refreshed, installationId: installed.id)
        XCTAssertEqual(authorized.status, .active)
        let clients = (0..<12).map { device("Concurrent \($0)") }
        let sessions = try await withThrowingTaskGroup(of: LoginResult.self) { group in
            for client in clients { group.addTask { try await backend.login(email: "demo@catlive.app", password: "catlive123", device: client) } }
            var results: [LoginResult] = []; for try await result in group { results.append(result) }; return results
        }
        let active = try await backend.devices(sessions.last!.session).filter { $0.status == .active }
        XCTAssertEqual(active.count, 3)
    }

}

private final class BackgroundSessionStore: SecureStore, @unchecked Sendable {
    private let memory = MemorySecureStore(), lock = NSLock()
    let release = DispatchSemaphore(value: 0)
    private var block = false, timeout = false, calls = 0
    var mainCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeout }
    func blockNextRead() { lock.lock(); block = true; lock.unlock() }
    private func noteCall() { lock.lock(); if Thread.isMainThread { calls += 1 }; lock.unlock() }
    func read(_ key: String) throws -> Data? {
        noteCall()
        lock.lock(); let waiting = block; block = false; lock.unlock()
        if waiting, release.wait(timeout: .now() + 1) == .timedOut { lock.lock(); timeout = true; lock.unlock() }
        return memory.read(key)
    }
    func write(_ data: Data, key: String) throws { noteCall(); memory.write(data, key: key) }
    func delete(_ key: String) throws { noteCall(); memory.delete(key) }
}
