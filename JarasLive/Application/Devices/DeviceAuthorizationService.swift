import Foundation
public struct DeviceAuthorizationService: Sendable {
    public let backend: any BackendClient
    public init(backend: any BackendClient) { self.backend = backend }
    public func validate(session: AuthSession, installationId: UUID) async throws -> AuthorizedDevice {
        let device = try await backend.device(session, installationId: installationId)
        guard device.status == .active else { throw BackendFailure.revoked }; return device
    }
    public static func installation(store: any SecureStore, name: String, platform: String) throws -> AuthorizedDevice {
        let id: UUID
        if let data = try store.read("installation"), let saved = String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:)) { id = saved }
        else { id = UUID(); try store.write(Data(id.uuidString.utf8), key: "installation") }
        return AuthorizedDevice(installationId: id, deviceName: name, platform: platform, platformVersion: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: "1.0.0", activatedAt: Date(), lastSeenAt: Date(), status: .active)
    }
}
