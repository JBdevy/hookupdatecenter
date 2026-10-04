import XCTest
@testable import JarasApplication
private final class BackendURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200
        var payload: [String: Any] = [:]
        if path == "/api/entitlement" {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-test")
            payload = ["status":"active","planId":"trial","expiresAt":"2026-10-09T06:00:00.000Z",
                       "offlineValidUntil":"2026-10-03T06:00:00.000Z","serverTime":"2026-10-02T06:00:00.000Z",
                       "maxDevices":4,"features":["desktop"]]
        } else if path == "/api/access-status" {
            status = 403; payload = ["error":"quarantined"]
        } else if path == "/api/login" {
            status = 409; payload = ["error":"deviceLimit"]
        } else if path == "/api/refresh" {
            payload = ["accessToken":"rotated-access","refreshToken":"rotated-refresh","expiresAt":"2026-10-02T06:15:00Z"]
        } else { status = 503; payload = ["error":"unavailable"] }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class RemoteBackendTests: XCTestCase {
    func testHTTPContractDatesBearerRefreshAndSeatFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let backend = RemoteBackendClient(baseURL: URL(string: "https://backcatlive.up.railway.app")!, session: session)
        let credentials = AuthSession(accessToken: "access-test", refreshToken: "refresh-test", expiresAt: Date())
        do { try await backend.accessStatus(credentials); XCTFail("quarantine must reach the client") }
        catch BackendFailure.quarantined {}
        let entitlement = try await backend.entitlement(credentials)
        XCTAssertEqual(entitlement.maxDevices, 4)
        XCTAssertEqual(entitlement.planId, "trial")
        XCTAssertEqual(entitlement.expiresAt.timeIntervalSince(entitlement.serverTime!), 7 * 86400)
        let rotated = try await backend.refresh(credentials)
        XCTAssertEqual(rotated.refreshToken, "rotated-refresh")
        let device = try DeviceAuthorizationService.installation(store: MemorySecureStore(), name: "Test", platform: "macOS")
        do { _ = try await backend.login(email: "test@example.com", password: "52998224725", device: device); XCTFail("fifth seat rejected") }
        catch BackendFailure.deviceLimit {}
    }
}
private actor RestrictionThenTimeoutBackend: BackendClient {
    let base = MockBackendClient()
    var restricted = false
    func restrict() { restricted = true }
    func login(email: String, password: String, device: AuthorizedDevice) async throws -> LoginResult { try await base.login(email: email, password: password, device: device) }
    func signup(name: String, email: String, password: String) async throws {}
    func resetPassword(email: String) async throws {}
    func refresh(_ session: AuthSession) async throws -> AuthSession { try await base.refresh(session) }
    func entitlement(_ session: AuthSession) async throws -> Entitlement {
        var result = try await base.entitlement(session)
        if restricted { result.status = "overdue" }
        return result
    }
    func device(_ session: AuthSession, installationId: UUID) async throws -> AuthorizedDevice {
        if restricted { throw BackendFailure.unavailable }
        return try await base.device(session, installationId: installationId)
    }
    func devices(_ session: AuthSession) async throws -> [AuthorizedDevice] { try await base.devices(session) }
    func logout(_ session: AuthSession, installationId: UUID) async throws {}
}
extension RemoteBackendTests {
    @MainActor func testNonpaymentCannotFallBackToOlderLeaseAfterTimeoutOrRestart() async throws {
        let backend = RestrictionThenTimeoutBackend(), store = MemorySecureStore()
        let installation = try DeviceAuthorizationService.installation(store: store, name: "Mac", platform: "macOS")
        let auth = AuthService(backend: backend, store: store, installation: installation, feature: "desktop")
        await auth.login(email: "demo@catlive.app", password: "catlive123")
        XCTAssertTrue(auth.allowed)
        auth.isPlaying = { true }
        await backend.restrict()
        await auth.revalidate()
        XCTAssertFalse(auth.allowed)
        XCTAssertTrue(auth.restriction.contains("atraso"))
        let restart = AuthService(backend: backend, store: store, installation: installation, feature: "desktop")
        await restart.restore()
        XCTAssertFalse(restart.allowed)
        XCTAssertTrue(restart.workspaceAllowed)
        XCTAssertTrue(restart.restriction.contains("atraso"))
    }
}
