import Foundation
import Combine
import AppKit
import SwiftUI

final class MetronomeLayoutProbe { var bodies = 0 }
struct UnrelatedMetronomeSettingsRow: View {
    @AppStorage("test.metronome.unrelatedSetting") private var value = 0
    let probe: MetronomeLayoutProbe
    var body: some View {
        let _ = { probe.bodies += 1 }()
        Text("\(value)")
    }
}

@MainActor func verify() {
    UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)
    let settings = MetronomeSettings.shared
    let originalGain = UserDefaults.standard.object(forKey: "jaras.metronome.gainA") as? NSNumber
    precondition(!settings.enabled, "Existing enabled preference migrates into the isolated domain")
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let probe = MetronomeLayoutProbe()
    let host = NSHostingView(rootView: VStack {
        ForEach(0..<40) { _ in UnrelatedMetronomeSettingsRow(probe: probe) }
    })
    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 240, height: 800),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12)); host.layoutSubtreeIfNeeded() }
    settle()
    let baseline = probe.bodies
    settings.enabled.toggle(); settle(); settings.enabled.toggle(); settle()
    precondition(probe.bodies == baseline, "Metronome persistence invalidates unrelated AppStorage controls")
    window.close()
    var preparations = 0, toggles: [Bool] = []
    settings.changed = { preparations += 1 }
    settings.enabledChanged = { toggles.append($0) }
    let revision = settings.soundRevision
    let writerBlocked = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let writesFinished = DispatchSemaphore(value: 0)
    MetronomePreferences.persistenceQueue.async {
        writerBlocked.signal()
        _ = releaseWriter.wait(timeout: .now() + 5)
    }
    precondition(writerBlocked.wait(timeout: .now() + 2) == .success)
    let began = ProcessInfo.processInfo.systemUptime
    for _ in 0..<100 { settings.enabled.toggle() }
    precondition(ProcessInfo.processInfo.systemUptime - began < 1,
                 "Toggling cannot wait for the preferences writer")
    precondition(toggles.count == 100 && preparations == 0)
    precondition(settings.soundRevision == revision)
    precondition(toggles.enumerated().allSatisfy { $0.element == $0.offset.isMultiple(of: 2) })
    settings.gainA = -2
    precondition(preparations == 1 && toggles.count == 100)
    releaseWriter.signal()
    MetronomePreferences.persistenceQueue.async { writesFinished.signal() }
    let deadline = Date(timeIntervalSinceNow: 3)
    var completed = false
    while Date() < deadline {
        if writesFinished.wait(timeout: .now()) == .success { completed = true; break }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    precondition(completed, "Serial preferences writer failed to drain")
    precondition(MetronomePreferences.storage.double(forKey: "jaras.metronome.gainA") == -2)
    precondition(UserDefaults.standard.object(forKey: "jaras.metronome.gainA") as? NSNumber == originalGain,
                 "New preference writes cannot return to the general UI domain")
    settings.changed = nil; settings.enabledChanged = nil
    print("METRONOME_TOGGLE_ATOMIC_CALLBACK_NO_PREPARATION_OR_REVISION_OK")
    print("METRONOME_MIGRATION_ISOLATED_PERSISTENCE_NO_UNRELATED_LAYOUT_OK")
    print("METRONOME_UI_TOGGLE_DOES_NOT_WAIT_FOR_BLOCKED_PREFERENCES_WRITER_OK")
}
MainActor.assumeIsolated { verify() }