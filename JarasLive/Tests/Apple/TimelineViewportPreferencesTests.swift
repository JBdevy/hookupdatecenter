import AppKit
import SwiftUI

let defaults = UserDefaults.standard
let store = TimelineViewportPreferences.storage
let key = TimelineViewportPreferences.zoomKey
let previous = defaults.object(forKey: key)
defer {
    if let previous { defaults.set(previous, forKey: key) }
    else { defaults.removeObject(forKey: key) }
    store.removeObject(forKey: key)
}
defaults.set(0.2, forKey: key)
precondition(TimelineViewportPreferences.zoom == 0.2, "preserve the existing zoom on first launch")
TimelineViewportPreferences.saveZoom(0.35)
precondition(TimelineViewportPreferences.zoom == 0.35 && defaults.double(forKey: key) == 0.2)
TimelineViewportPreferences.saveZoom(-1)
precondition(TimelineViewportPreferences.zoom == TimelineZoomLimits.minimum)
TimelineViewportPreferences.saveZoom(Double.greatestFiniteMagnitude)
precondition(TimelineViewportPreferences.zoom == TimelineZoomLimits.maximum)
TimelineViewportPreferences.saveZoom(.nan)
precondition(TimelineViewportPreferences.zoom == TimelineZoomLimits.maximum)
store.set(Double.infinity, forKey: key)
precondition(TimelineViewportPreferences.zoom == 1)
print("VIEWPORT_ZOOM_RESTORE_CLAMP_AND_INVALID_VALUES_OK")

final class Updates { var bodies = 0; var layouts = 0 }
struct SettingsRow: View {
    @AppStorage("test.unrelatedSetting") private var value = 0
    let updates: Updates
    var body: some View {
        let _ = { updates.bodies += 1 }()
        Text("\(value)").frame(width: 200, height: 16)
    }
}
struct SettingsPanel: View {
    let updates: Updates
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<40) { _ in SettingsRow(updates: updates) }
        }
    }
}
final class SettingsHost: NSHostingView<SettingsPanel> {
    let updates: Updates
    init(_ updates: Updates) { self.updates = updates; super.init(rootView: SettingsPanel(updates: updates)) }
    required init(rootView: SettingsPanel) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { updates.layouts += 1; super.layout() }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 240, height: 680),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let updates = Updates(), host = SettingsHost(Updates())
let observed = host.updates
window.contentView = host
window.orderBack(nil)
func settle() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
    host.layoutSubtreeIfNeeded()
}
settle()
let beforeStandard = observed.bodies
defaults.set(0.25, forKey: key)
settle()
precondition(observed.bodies > beforeStandard, "positive control must reproduce unrelated standard-defaults invalidation")
let beforeIsolated = (observed.bodies, observed.layouts)
for zoom in [0.4, 0.45, 0.5, 0.55] { TimelineViewportPreferences.saveZoom(zoom); settle() }
precondition(observed.bodies == beforeIsolated.0 && observed.layouts == beforeIsolated.1,
             "saving completed zoom gestures must not redraw unrelated settings controls")
precondition(TimelineViewportPreferences.zoom == 0.55 && defaults.double(forKey: key) == 0.25)
print("ZOOM_PERSISTENCE_NO_UNRELATED_APPSTORAGE_BODY_OR_LAYOUT_UPDATES_OK")
window.close()
