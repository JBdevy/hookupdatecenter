import Foundation

@main struct WorkspaceLayoutPreferencesTests {
    static func main() {
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
        print("LAYOUT_MIGRATION_COLLAPSED_RESTORE_REMOTE_REOPEN_OK")
    }
}
