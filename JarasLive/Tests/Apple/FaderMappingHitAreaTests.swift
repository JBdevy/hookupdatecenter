import AppKit

@MainActor func run() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
    window.contentView = host
    let row = RightClickTargetView(frame: host.bounds)
    let fader = MappingClickView(frame: NSRect(x: 60, y: 50, width: 180, height: 27))
    fader.hitHeight = 16
    var mappings = 0, edits = 0
    fader.action = { mappings += 1 }; row.action = { edits += 1 }
    host.addSubview(row); host.addSubview(fader)
    func click(_ x: CGFloat, _ y: CGFloat) {
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(RightClickRouter.shared.handle(event))
    }
    click(150, 63.5)
    precondition(mappings == 1 && edits == 0, "right click on fader maps volume")
    click(150, 51); click(150, 76); click(50, 63.5); click(250, 63.5)
    precondition(mappings == 1 && edits == 4, "clicks outside the actual fader go to the track menu")
    fader.hitHeight = nil
    click(150, 51)
    precondition(mappings == 2, "other mapping controls retain their entire hit area")
    print("FADER_MAPPING_RAIL_ONLY_OUTSIDE_TRACK_MENU_AND_OTHER_CONTROLS_OK")
}
MainActor.assumeIsolated { run() }
