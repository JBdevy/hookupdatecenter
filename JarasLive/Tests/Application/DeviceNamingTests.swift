import XCTest
@testable import JarasApplication

final class DeviceNamingTests: XCTestCase {
    func testNameMustBeVisibleAndFitDiscoveryWithoutTruncation() {
        for name in ["", "   ", "\n\t", "\u{200B}", "PC\nPalco", String(repeating: "á", count: 32)] {
            XCTAssertNil(DeviceDisplayName.validated(name), name)
        }
        XCTAssertEqual(DeviceDisplayName.validated("  PC do palco 🎸  "), "PC do palco 🎸")
        XCTAssertEqual(DeviceDisplayName.validated(String(repeating: "A", count: 63)), String(repeating: "A", count: 63))
    }
    @MainActor func testFirstLoginRequiresNameBeforeActivationAndPersistsForNextLogin() async throws {
        let store = MemorySecureStore(), backend = MockBackendClient()
        let device = try DeviceAuthorizationService.installation(store: store, name: "System name", platform: "macOS")
        let auth = AuthService(backend: backend, store: store, installation: device, feature: "desktop")
        var advertised = ""
        auth.onDeviceNameChanged = { advertised = $0 }
        let first = await auth.beginLogin(email: "demo@catlive.app", password: "catlive123")
        XCTAssertFalse(first)
        XCTAssertTrue(auth.requiresDeviceName)
        XCTAssertFalse(auth.workspaceAllowed)
        XCTAssertFalse(auth.allowed)
        XCTAssertNil(store.read("catlive.production.session"))
        let before = try await backend.credentialDevices(email: "demo@catlive.app", cpf: "catlive123")
        XCTAssertTrue(before.isEmpty, "name prompt must not use a seat or revoke another computer")
        let empty = await auth.completeDeviceNaming("   ")
        XCTAssertFalse(empty)
        XCTAssertTrue(auth.requiresDeviceName)
        let completed = await auth.completeDeviceNaming("  PC do Palco 🎸  ")
        XCTAssertTrue(completed)
        XCTAssertFalse(auth.requiresDeviceName)
        XCTAssertTrue(auth.allowed)
        XCTAssertEqual(auth.installation.deviceName, "PC do Palco 🎸")
        XCTAssertEqual(auth.devices.first?.deviceName, "PC do Palco 🎸")
        XCTAssertEqual(advertised, "PC do Palco 🎸")
        let listed = try await backend.credentialDevices(email: "demo@catlive.app", cpf: "catlive123")
        XCTAssertEqual(listed.first?.deviceName, advertised)
        let reopened = try DeviceAuthorizationService.installation(store: store, name: "Changed OS name", platform: "macOS")
        XCTAssertEqual(reopened.id, device.id)
        XCTAssertEqual(reopened.deviceName, advertised)
        let next = AuthService(backend: backend, store: store, installation: reopened, feature: "desktop")
        let signedIn = await next.beginLogin(email: "demo@catlive.app", password: "catlive123")
        XCTAssertTrue(signedIn)
        XCTAssertFalse(next.requiresDeviceName)
        XCTAssertEqual(next.devices.count, 1)
        await backend.setOffline(true)
        let offline = AuthService(backend: backend, store: store, installation: reopened, feature: "desktop")
        await offline.restore()
        XCTAssertTrue(offline.allowed)
        XCTAssertEqual(offline.loginResult?.device.deviceName, advertised)
    }
    @MainActor func testFailedActivationKeepsMandatoryStepForRetry() async throws {
        let store = MemorySecureStore(), backend = MockBackendClient()
        let device = try DeviceAuthorizationService.installation(store: store, name: "OS name", platform: "macOS")
        let auth = AuthService(backend: backend, store: store, installation: device, feature: "desktop")
        _ = await auth.beginLogin(email: "demo@catlive.app", password: "catlive123")
        await backend.setOffline(true)
        let failed = await auth.completeDeviceNaming("Stage PC")
        XCTAssertFalse(failed); XCTAssertTrue(auth.requiresDeviceName)
        XCTAssertFalse(auth.workspaceAllowed); XCTAssertFalse(auth.allowed)
        XCTAssertNil(try DeviceDisplayName.saved(in: store))
        await backend.setOffline(false)
        let retry = await auth.completeDeviceNaming("Stage PC")
        XCTAssertTrue(retry); XCTAssertEqual(auth.devices.first?.deviceName, "Stage PC")
    }
    @MainActor func testInvalidLoginAndCancelledNamingNeverActivateDevice() async throws {
        let store = MemorySecureStore(), backend = MockBackendClient()
        let device = try DeviceAuthorizationService.installation(store: store, name: "OS name", platform: "macOS")
        let auth = AuthService(backend: backend, store: store, installation: device, feature: "desktop")
        let invalid = await auth.beginLogin(email: "demo@catlive.app", password: "wrong")
        XCTAssertFalse(invalid); XCTAssertFalse(auth.requiresDeviceName)
        _ = await auth.beginLogin(email: "demo@catlive.app", password: "catlive123")
        auth.cancelDeviceNaming()
        let skipped = await auth.completeDeviceNaming("PC do Palco")
        XCTAssertFalse(skipped); XCTAssertFalse(auth.allowed)
        XCTAssertNil(try DeviceDisplayName.saved(in: store))
        XCTAssertNil(store.read("catlive.production.session"))
        let devices = try await backend.credentialDevices(email: "demo@catlive.app", cpf: "catlive123")
        XCTAssertTrue(devices.isEmpty)
    }
}
