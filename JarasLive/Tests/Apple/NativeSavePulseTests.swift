import SwiftUI
import AppKit
let app = NSApplication.shared
let host = NativeSavePulseHost(rootView: Text("Save").frame(width: 60, height: 26))
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 26), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = host; window.orderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
host.setPulse(true)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
let initial = host.layoutCount
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
precondition(host.layer!.animation(forKey: "savePulse") != nil)
precondition(host.layer!.opacity == 1)
precondition(host.layoutCount == initial, "save pulse must not schedule hosting layouts per animation frame")
precondition(host.hitTest(.zero) == nil)
host.setPulse(false); precondition(host.layer!.animation(forKey: "savePulse") == nil)
print("NATIVE_SAVE_PULSE_ANIMATES_WITHOUT_SWIFTUI_LAYOUT_AND_PRESERVES_BUTTON_HIT_OK")
