import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif
@MainActor final class AppContainer: ObservableObject {
    let auth: AuthService, show: ShowController, backend: MockBackendClient
    @Published private(set) var starting = true
    @Published private(set) var startupProgress = 0.1
    @Published private(set) var startupStage = "Carregando projeto…"
    private var started = false
    let preview: Bool
    init(preview: Bool = false) throws {
        self.preview = preview
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JarasLive", isDirectory: true)
        backend = MockBackendClient(file: preview ? nil : folder.appendingPathComponent("mock-server.json"))
        let store: any SecureStore = preview ? MemorySecureStore() : KeychainStore(service: "com.hookdeveloper.jaraslive")
        #if os(macOS)
        let platform = "macOS", name = Host.current().localizedName ?? "Mac", feature = "desktop"
        #else
        let platform = "iPadOS", name = UIDevice.current.name, feature = "standalone_mobile"
        #endif
        // A Keychain failure must be visible; never replace the installation silently.
        do {
            let device = try DeviceAuthorizationService.installation(store: store, name: name, platform: platform)
            auth = AuthService(backend: backend, store: store, installation: device, feature: feature)
            let persistence: any ProjectPersistence = preview ? MemoryProjectStore() : ProjectStore(url: folder.appendingPathComponent("last-show.jaras"))
            show = try ShowController(executor: LocalCommandExecutor(), persistence: persistence)
        } catch { throw error }
        auth.isPlaying = { [weak show] in show?.isPlaying ?? false }
        auth.onPendingRevocation = { [weak show] pending in show?.finishCurrentSong(pending) }
        show.canExecute = { [weak auth] in preview || auth?.allowed == true }
        show.onStop = { [weak auth] in auth?.transportDidStop() }
    }
    func start() async {
        guard !preview else { starting = false; return }
        guard !started else { return }
        started = true
        let splashStarted = ProcessInfo.processInfo.systemUptime
        startupProgress = 0.15
        await Task.yield()
        await show.restore()
        startupProgress = 0.55
        startupStage = "Validando acesso…"
        await auth.restore()
        startupProgress = 1
        startupStage = "Pronto"
        // Temporary four-second minimum requested for reviewing the splash artwork.
        let remaining = max(0, 4 - (ProcessInfo.processInfo.systemUptime - splashStarted))
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        starting = false
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            if auth.allowed { await auth.revalidate() }
        }
    }
}
