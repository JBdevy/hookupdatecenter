import XCTest
@testable import JarasApplication
final class ApplicationTests: XCTestCase {
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
            let first = try await backend.login(email: "demo@jaras.live", password: "jaras123", device: device("first"))
            var last = first
            for index in 0..<limit { last = try await backend.login(email: "demo@jaras.live", password: "jaras123", device: device("next\(index)")) }
            let devices = try await backend.devices(last.session)
            XCTAssertEqual(devices.filter { $0.status == .active }.count, limit)
            XCTAssertEqual(devices.first { $0.id == first.device.id }?.status, .revoked)
            try await backend.logout(last.session, installationId: last.device.id)
            do { _ = try await backend.devices(last.session); XCTFail("Session must be invalidated") } catch BackendFailure.invalidSession {}
        }
    }
    func testRepeatedInstallationDoesNotConsumeExtraSeat() async throws {
        let backend = MockBackendClient(); let same = device("same")
        _ = try await backend.login(email: "demo@jaras.live", password: "jaras123", device: same)
        let result = try await backend.login(email: "demo@jaras.live", password: "jaras123", device: same)
        let active = try await backend.devices(result.session).filter { $0.status == .active }
        XCTAssertEqual(active.count, 1)
    }
    @MainActor func testSessionRestoreOfflineAndSafeRevocation() async throws {
        let backend = MockBackendClient(); let store = MemorySecureStore(); let installed = device("Mac")
        let auth = AuthService(backend: backend, store: store, installation: installed, feature: "desktop")
        await auth.login(email: "demo@jaras.live", password: "jaras123"); XCTAssertEqual(auth.phase, .authorized)
        let restored = AuthService(backend: backend, store: store, installation: installed, feature: "desktop")
        await restored.restore(); XCTAssertEqual(restored.phase, .authorized)
        await backend.setOffline(true); await restored.revalidate(); XCTAssertEqual(restored.phase, .offlineAuthorized)
        await backend.setOffline(false); restored.isPlaying = { true }
        try await backend.revoke(installed.id); await restored.revalidate()
        XCTAssertTrue(restored.revokedPending); XCTAssertTrue(restored.allowed)
        restored.isPlaying = { false }; restored.transportDidStop(); XCTAssertEqual(restored.phase, .unauthorized)
        await backend.setOffline(true)
        let offlineRestart = AuthService(backend: backend, store: store, installation: installed, feature: "desktop")
        await offlineRestart.restore(); XCTAssertEqual(offlineRestart.phase, .unauthorized)
    }
    func testInstallationPersistsAndWrongLoginFails() async throws {
        let store = MemorySecureStore()
        let one = try DeviceAuthorizationService.installation(store: store, name: "Mac", platform: "macOS")
        let two = try DeviceAuthorizationService.installation(store: store, name: "New name", platform: "macOS")
        XCTAssertEqual(one.id, two.id)
        do { _ = try await MockBackendClient().login(email: "demo@jaras.live", password: "wrong", device: one); XCTFail("Invalid password") } catch BackendFailure.invalidCredentials {}
    }
    func testRefreshPersistenceAndConcurrentSeats() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("mock.json")
        let backend = MockBackendClient(file: file)
        await backend.configure(maxDevices: 3, scenario: .valid)
        let installed = device("Persistent")
        let login = try await backend.login(email: "demo@jaras.live", password: "jaras123", device: installed)
        let refreshed = try await backend.refresh(login.session)
        XCTAssertNotEqual(refreshed.accessToken, login.session.accessToken)
        let restarted = MockBackendClient(file: file)
        let authorized = try await restarted.device(refreshed, installationId: installed.id)
        XCTAssertEqual(authorized.status, .active)
        let clients = (0..<12).map { device("Concurrent \($0)") }
        let sessions = try await withThrowingTaskGroup(of: LoginResult.self) { group in
            for client in clients { group.addTask { try await backend.login(email: "demo@jaras.live", password: "jaras123", device: client) } }
            var results: [LoginResult] = []; for try await result in group { results.append(result) }; return results
        }
        let active = try await backend.devices(sessions.last!.session).filter { $0.status == .active }
        XCTAssertEqual(active.count, 3)
    }

}
