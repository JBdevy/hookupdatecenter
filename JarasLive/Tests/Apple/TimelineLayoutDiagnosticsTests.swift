import SwiftUI
import AppKit

_ = NSApplication.shared
let log = URL(fileURLWithPath: TimelineLayoutDiagnostics.logPath)
defer { try? FileManager.default.removeItem(at: log) }
if !TimelineLayoutDiagnostics.enabled {
    precondition(TimelineLayoutDiagnostics.make("disabled") == nil)
    TimelineLayoutDiagnostics.flush()
    precondition(!FileManager.default.fileExists(atPath: log.path), "normal operation must create no profile file")
    print("LAYOUT_DIAGNOSTICS_DISABLED_NO_PROFILE_OR_FILE_OK")
} else {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let container = NSView(frame: window.contentView!.bounds)
    window.contentView = container
    let horizontal = GridHostingView(rootView: Text("horizontal"))
    let vertical = WorkspaceHostingView(rootView: Text("vertical"))
    horizontal.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    vertical.frame = NSRect(x: 300, y: 0, width: 300, height: 300)
    container.addSubview(horizontal); container.addSubview(vertical)
    horizontal.layoutProfile = TimelineLayoutDiagnostics.make("horizontal")
    vertical.layoutProfile = TimelineLayoutDiagnostics.make("workspace-timeline")
    horizontal.layoutProfile?.rootAssigned(horizontal)
    vertical.layoutProfile?.rootAssigned(vertical)
    horizontal.layoutProfile?.sizeChanged(horizontal, from: horizontal.frame.size, to: horizontal.frame.size)
    horizontal.layoutProfile?.sizeChanged(horizontal, from: horizontal.frame.size, to: NSSize(width: 600, height: 300))
    horizontal.frame.size.width = 600
    horizontal.layout(); horizontal.layout(); vertical.layout()
    let input = TimelineLayoutDiagnostics.make("timeline-input")!
    input.event("zoom-tick", view: horizontal)
    input.event("zoom-publish", view: horizontal, value: 1.25)
    TimelineLayoutDiagnostics.flush()
    let rows = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    let layouts = rows.filter { $0["event"] as? String == "layout" }
    let horizontalLayouts = layouts.filter { $0["role"] as? String == "horizontal" }
    precondition(horizontalLayouts.count >= 2)
    precondition(layouts.contains { $0["role"] as? String == "workspace-timeline" })
    precondition(Set(layouts.compactMap { $0["host"] as? Int }).count == 2)
    precondition(rows.filter { $0["event"] as? String == "root" }.count == 2)
    precondition(rows.filter { $0["event"] as? String == "size" }.count == 1,
                 "unchanged geometry must not count as a resize")
    precondition(horizontalLayouts.contains { ($0["layoutInFrame"] as? Int ?? 0) >= 2 },
                 "multiple layouts before one display callback must remain distinguishable")
    for row in layouts {
        precondition((row["durationMS"] as? Double ?? -1) >= 0)
        precondition(row["window"] as? Int == window.windowNumber)
        precondition(row["timeMS"] != nil && row["bucket60Hz"] != nil && row["frameSource"] != nil)
        precondition(row["rootAssignments"] as? Int == 1)
    }
    precondition(rows.contains { $0["event"] as? String == "zoom-publish" && $0["value"] as? Double == 1.25 })
    let permissions = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as! NSNumber
    precondition(permissions.intValue == 0o600)
    print("LAYOUT_DIAGNOSTICS_DISTINCT_HOSTS_COUNTS_TIMINGS_INPUT_AND_PRIVATE_BUFFERED_LOG_OK")
}
