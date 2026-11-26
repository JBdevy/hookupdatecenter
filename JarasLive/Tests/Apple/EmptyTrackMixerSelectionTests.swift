import AppKit
import SwiftUI

@MainActor private final class NativeTimelineInputGate {
    static let shared = NativeTimelineInputGate()
    var blocked = false
    func isBlocked(_ window: NSWindow?) -> Bool { blocked }
}
@MainActor private final class ControlMappings {
    static let shared = ControlMappings()
    var editing: UUID?
}
@MainActor private final class EditorSelectionRouter {
    enum Scope { case tracks, grid }
    static let shared = EditorSelectionRouter()
    var scope = Scope.grid
    func activate(_ scope: Scope, in window: NSWindow) { self.scope = scope }
}

// PRODUCTION_EMPTY_MIXER_INPUT

@MainActor private func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory); app.finishLaunching()
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    let tail = TimelineEmptyMixerView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    root.addSubview(tail); window.contentView = root
    defer { window.close() }
    var tracks: Set<Int> = [1, 2], anchor: Int? = 1, clears = 0, additions = 0
    tail.clearSelection = { tracks.removeAll(); anchor = nil; clears += 1 }
    tail.addTrack = { additions += 1 }
    func event(_ count: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: clears + 1, clickCount: count, pressure: 1)!
    }
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    expect(root.hitTest(NSPoint(x: 20, y: 20)) === tail, "Empty mixer pixels must reach the clear surface")
    expect(root.hitTest(NSPoint(x: 20, y: 160)) !== tail, "Rows must remain outside the clear surface")
    tail.mouseDown(with: event())
    expect(tracks.isEmpty && anchor == nil && clears == 1, "Mouse-down must clear selection before Delete or mouse-up")
    expect(EditorSelectionRouter.shared.scope == .tracks && window.firstResponder === tail,
           "The empty mixer must own keyboard actions instead of the previously focused panel")
    tail.mouseDown(with: event(2))
    expect(additions == 1, "Double click must still create one track")
    tail.mouseDown(with: event(flags: .control))
    expect(clears == 2, "Context click must not clear selection")
    NativeTimelineInputGate.shared.blocked = true
    tail.mouseDown(with: event())
    expect(clears == 2, "A modal input gate must block the background")
    NativeTimelineInputGate.shared.blocked = false
    ControlMappings.shared.editing = UUID()
    tail.mouseDown(with: event())
    expect(clears == 2, "MIDI learn must retain its input ownership")
    ControlMappings.shared.editing = nil
    tail.mouseDown(with: event())
    expect(clears == 3 && additions == 1, "The background must recover after a modal closes")
    print("EMPTY_TRACK_MIXER_IMMEDIATE_CLEAR_KEYBOARD_SCOPE_DOUBLE_CLICK_AND_INPUT_GATES_OK")
}
MainActor.assumeIsolated { run() }
