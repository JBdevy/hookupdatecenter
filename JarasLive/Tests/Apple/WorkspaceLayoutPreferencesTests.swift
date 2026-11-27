import Foundation
#if os(macOS)
import SwiftUI
#endif

@main struct WorkspaceLayoutPreferencesTests {
    @MainActor static func main() {
        let sourceName = "catlive.layout-test.source." + UUID().uuidString
        let targetName = "catlive.layout-test.target." + UUID().uuidString
        let source = UserDefaults(suiteName: sourceName)!, target = UserDefaults(suiteName: targetName)!
        defer {
            source.removePersistentDomain(forName: sourceName)
            target.removePersistentDomain(forName: targetName)
        }
        source.set(0, forKey: "jaras.trackColumnWidth")
        source.set(312, forKey: "jaras.trackColumnRestoreWidth")
        source.set(280, forKey: "jaras.remote.trackColumnWidth")
        source.set(false, forKey: "jaras.layout.mixer.open")
        source.set(true, forKey: "jaras.layout.setlist.detached")
        source.set("left", forKey: "jaras.layout.setlist.dockSide")
        source.set(420.0, forKey: "jaras.footerMixerHeight")
        source.set("pt-BR", forKey: "jaras.language")
        WorkspaceLayoutPreferences.migrate(from: source, to: target)
        precondition(target.object(forKey: "jaras.layout.mixer.open") as? Bool == false)
        precondition(target.object(forKey: "jaras.trackColumnWidth") as? Int == 0)
        precondition(target.integer(forKey: "jaras.trackColumnRestoreWidth") == 312)
        precondition(target.integer(forKey: "jaras.remote.trackColumnWidth") == 280)
        precondition(target.bool(forKey: "jaras.layout.setlist.detached"))
        precondition(target.string(forKey: "jaras.layout.setlist.dockSide") == "left")
        precondition(target.double(forKey: "jaras.footerMixerHeight") == 420)
        precondition(target.object(forKey: "jaras.language") == nil)
        target.set(350, forKey: "jaras.trackColumnWidth")
        target.set(true, forKey: "jaras.layout.mixer.open")
        WorkspaceLayoutPreferences.migrate(from: source, to: target)
        let reopened = UserDefaults(suiteName: targetName)!
        precondition(reopened.integer(forKey: "jaras.trackColumnWidth") == 350)
        precondition(reopened.bool(forKey: "jaras.layout.mixer.open"))
        precondition(source.integer(forKey: "jaras.trackColumnWidth") == 0)
        precondition(!source.bool(forKey: "jaras.layout.mixer.open"))
        #if os(macOS)
        _ = NSApplication.shared
        checkObservation(in: target, suite: targetName)
        #endif
        print("LAYOUT_MIGRATION_COLLAPSED_RESTORE_REMOTE_REOPEN_OK")
    }
    #if os(macOS)
    @MainActor private static func checkObservation(in store: UserDefaults, suite: String) {
        let key = "jaras.layout.mixer.open"
        let observed = Counter()
        let host = NSHostingView(rootView: PreferenceProbe(key: key, store: store, observed: observed))
        let window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: 100, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        settle()
        let before = observed.calls
        precondition(before > 0 && observed.last)
        store.set(123, forKey: "jaras.another.panel")
        settle()
        precondition(observed.calls == before, "An unrelated panel must leave the hosting root alone")

        let sameSuite = UserDefaults(suiteName: suite)!
        let sameKey = WorkspacePreference(wrappedValue: false, key, store: sameSuite)
        sameKey.projectedValue.wrappedValue = false
        settle()
        precondition(!observed.last && observed.calls > before)
        let after = observed.calls
        sameSuite.set(false, forKey: key)
        settle()
        precondition(observed.calls == after)

        let defaultTrue = WorkspacePreference(wrappedValue: true, key, store: store)
        sameSuite.removeObject(forKey: key)
        settle()
        precondition(defaultTrue.wrappedValue && !sameKey.wrappedValue)

        let width = WorkspacePreference(wrappedValue: 248.0, "jaras.trackColumnWidth", store: store)
        store.set("312.5", forKey: "jaras.trackColumnWidth")
        precondition(width.wrappedValue == 312.5)
        let placement = WorkspacePreference(wrappedValue: Placement.right, "jaras.layout.setlist.dockSide", store: store)
        precondition(placement.wrappedValue == .left)
        placement.wrappedValue = .right
        precondition(store.string(forKey: "jaras.layout.setlist.dockSide") == "right")
        store.set("unknown", forKey: "jaras.layout.setlist.dockSide")
        precondition(placement.wrappedValue == .right)
        window.orderOut(nil)
        print("WORKSPACE_PREFERENCES_ONLY_INVALIDATE_CHANGED_KEYS_OK")
    }

    private enum Placement: String { case left, right }
    private final class Counter {
        var calls = 0
        var last = false
    }
    private struct PreferenceProbe: View {
        @WorkspacePreference var open: Bool
        let observed: Counter
        init(key: String, store: UserDefaults, observed: Counter) {
            _open = WorkspacePreference(wrappedValue: false, key, store: store)
            self.observed = observed
        }
        var body: some View {
            observed.calls += 1
            observed.last = open
            return Text(open ? "Open" : "Closed")
        }
    }
    #endif

}
