import SwiftUI
import AppKit

// Unused selection adapter dependency: this fixture exercises the native
// workspace, real SwiftUI text fields and divider, not grid-selection behavior.
struct GridSelectionInput { func apply(to view: GridSelectionView) {} }
final class GridSelectionView: NSView {}

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
// Reproduce the grid's cursorUpdate/mouseMoved routing pattern under the real
// workspace host; GridSelectionTests covers individual item cursor decisions.
private final class DynamicGridCursor: NSView {
    var shift: CGFloat = 0
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .arrow) }
    func cursor(_ point: NSPoint) -> NSCursor {
        switch Int((point.x + shift) / 60) % 4 {
        case 0: return .crosshair
        case 1: return .resizeLeftRight
        case 2: return .resizeUpDown
        default: return .arrow
        }
    }
    override func cursorUpdate(with event: NSEvent) { cursor(convert(event.locationInWindow, from: nil)).set() }
    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }
}
private final class ResizeRect: NSView {
    var resetCount = 0
    override func resetCursorRects() { resetCount += 1; addCursorRect(bounds.intersection(visibleRect), cursor: .resizeUpDown) }
}
private final class FixtureNative: NSView {
    let grid = DynamicGridCursor(frame: NSRect(x: 20, y: 20, width: 240, height: 70))
    let resize = ResizeRect(frame: NSRect(x: 20, y: 115, width: 240, height: 12))
    let scroll = NSScrollView(frame: NSRect(x: 20, y: 165, width: 260, height: 160))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 700))
    let field = NSTextField(string: "Native text inside scroll")
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        if #available(macOS 14.0, *) { clipsToBounds = true; grid.clipsToBounds = true; resize.clipsToBounds = true }
        addSubview(grid); addSubview(resize); addSubview(scroll)
        scroll.documentView = document
        field.frame = NSRect(x: 20, y: 560, width: 220, height: 24)
        document.addSubview(field)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 520))
    }
    required init?(coder: NSCoder) { fatalError() }
}
private struct NativeFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> FixtureNative { FixtureNative(frame: .zero) }
    func updateNSView(_ native: FixtureNative, context: Context) {}
}
private final class ExternalFooterView: NSView {
    override func resetCursorRects() { addCursorRect(bounds.intersection(visibleRect), cursor: .pointingHand) }
}
private struct ExternalFooter: NSViewRepresentable {
    func makeNSView(context: Context) -> ExternalFooterView { ExternalFooterView() }
    func updateNSView(_ native: ExternalFooterView, context: Context) {}
}
private struct Fixture: View {
    @State private var leftText = "Track name"
    @State private var rightText = "Search songs"
    let controller = SidebarScrollController()
    var body: some View {
        VStack(spacing: 0) {
        NativeWorkspaceSplit(width: 280, restoreWidth: 280, minimum: 200, scrollController: controller,
                             onToggle: {}, onEnd: { _ in }) {
            VStack(spacing: 0) {
                TextField("Track name", text: $leftText).frame(height: 36).padding(.horizontal, 20)
                NativeFixture()
            }
        } trailing: {
            VStack {
                TextField("Search songs", text: $rightText).frame(height: 36).padding(.horizontal, 20)
                Spacer()
            }
        }
        ExternalFooter().frame(height: 30)
        }
    }
}
private func all<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, $0) }
}
private func cursorName(_ cursor: NSCursor) -> String {
    if cursor === NSCursor.arrow { return "arrow" }
    if cursor === NSCursor.iBeam { return "iBeam" }
    if cursor === NSCursor.resizeLeftRight { return "resizeLeftRight" }
    if cursor === NSCursor.resizeUpDown { return "resizeUpDown" }
    if cursor === NSCursor.crosshair { return "crosshair" }
    if cursor === NSCursor.pointingHand { return "pointingHand" }
    return String(describing: cursor)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.finishLaunching()
    let initialPointer = CGEvent(source: nil)!.location
    let window = NSWindow(contentRect: NSRect(x: 160, y: 180, width: 900, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
    let host = NSHostingView(rootView: Fixture())
    window.contentView = host
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    func pump(_ duration: Double = 0.12) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { app.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001)); app.updateWindows()
        }
    }
    pump(0.7); host.layoutSubtreeIfNeeded(); pump()
    defer {
        window.orderOut(nil); window.close()
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: initialPointer, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    let native = all(FixtureNative.self, host).first!
    let divider = all(MixerDividerView.self, host).first!
    let externalFooter = all(ExternalFooterView.self, host).first!
    let fields = all(NSTextField.self, host).filter { $0 !== native.field }
    require(fields.count >= 2, "real SwiftUI TextFields mounted")
    let split = all(NSView.self, host).first { String(describing: type(of: $0)).contains("WorkspaceSplitView<") }!
    print("ACTIVE \(app.isActive) KEY \(window.isKeyWindow)")
    print("FIELDS \(fields.count), split \(split.frame), grid \(native.grid.frame)")
    func position(_ view: NSView, _ point: NSPoint? = nil) -> CGPoint {
        let local = point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let screen = window.convertPoint(toScreen: view.convert(local, to: nil))
        return CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
    }
    func move(_ view: NSView, _ point: NSPoint? = nil, expecting cursor: NSCursor, _ label: String) {
        let target = position(view, point)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)!.post(tap: .cghidEventTap)
        pump()
        print("\(WorkspaceArrowTestSwitch.enabled ? "arrow" : "baseline") \(label): \(cursorName(NSCursor.current))")
        require(abs(CGEvent(source: nil)!.location.x-target.x) < 2 && abs(CGEvent(source: nil)!.location.y-target.y) < 2, "real pointer reached fixture")
        // Public system-cursor sampling is test-only. It checks what AppKit
        // displays, in addition to logging the application cursor stack.
        let system = NSCursor.currentSystem
        let shown = system.map { $0.image.size == cursor.image.size && $0.hotSpot == cursor.hotSpot } ?? false
        require(shown, "\(label): system cursor shape must match \(cursorName(cursor))")

    }
    func clickToEdit(_ field: NSTextField) {
        let target = position(field)
        for kind in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: target, mouseButton: .left)!
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap); pump(0.08)
        }
        require(window.firstResponder is NSTextView, "native click activates actual field editor")
    }
    for enabled in (CommandLine.arguments.contains("--sheet-only") ? [Bool]() : [false, true]) {
        WorkspaceArrowTestSwitch.enabled = enabled
        window.invalidateCursorRects(for: split); pump()
        move(native, NSPoint(x: 300, y: 40), expecting: .arrow, "mixer blank")
        move(split, NSPoint(x: 760, y: 220), expecting: .arrow, "setlist blank")
        move(externalFooter, expecting: .pointingHand, "external footer keeps its cursor")
        for field in fields {
            clickToEdit(field)
            move(native, NSPoint(x: 300, y: 40), expecting: .arrow, "leave editor")
            move(field, expecting: .iBeam, "SwiftUI TextField \(field.stringValue)")
            move(native, NSPoint(x: 300, y: 40), expecting: .arrow, "leave text to blank")
        }
        move(divider, expecting: .resizeLeftRight, "native workspace divider")
        move(native.resize, expecting: .resizeUpDown, "child resize cursor rect")
        for (x, cursor) in [(CGFloat(20), NSCursor.crosshair), (80, .resizeLeftRight), (140, .resizeUpDown), (200, .arrow)] {
            move(native.grid, NSPoint(x: x, y: 30), expecting: cursor, "dynamic child grid x\(x)")
        }
        clickToEdit(native.field)
        move(native, NSPoint(x: 300, y: 40), expecting: .arrow, "leave native editor")
        move(native.field, expecting: .iBeam, "scroll child native text")
        native.scroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); pump()
        move(native.scroll, NSPoint(x: 110, y: 60), expecting: .arrow, "scroll text away restores blank")
        native.scroll.contentView.scroll(to: NSPoint(x: 0, y: 520)); pump()
        move(native.field, expecting: .iBeam, "scroll text reopens")
        native.resize.setFrameOrigin(NSPoint(x: 50, y: 135)); pump()
        require(native.resize.bounds.contains(native.resize.visibleRect), "fixture resize is clipped to its real bounds")
        move(native, NSPoint(x: 30, y: 121), expecting: .arrow, "resize moved away")
        move(native.resize, expecting: .resizeUpDown, "resize new origin")
        native.resize.setFrameOrigin(NSPoint(x: 20, y: 115))
        window.setContentSize(NSSize(width: 940, height: 500)); pump()
        move(divider, expecting: .resizeLeftRight, "window resize divider")
        clickToEdit(fields.last!)
        move(native, NSPoint(x: 300, y: 40), expecting: .arrow, "leave resized editor")
        move(fields.last!, expecting: .iBeam, "window resize text")
        window.setContentSize(NSSize(width: 900, height: 480)); pump()
    }
    WorkspaceArrowTestSwitch.enabled = true
    window.invalidateCursorRects(for: split); pump()
    let beforeBlock = WorkspaceArrowTestSwitch.registrations
    NativeTimelineInputGate.shared.setBlocked(true, for: window); pump()
    window.invalidateCursorRects(for: split); pump()
    require(WorkspaceArrowTestSwitch.registrations == beforeBlock, "gate prevents parent registration")
    NativeTimelineInputGate.shared.setBlocked(false, for: window); pump()
    move(native, NSPoint(x: 300, y: 40), expecting: .arrow, "gate reopens parent blank")
    require(WorkspaceArrowTestSwitch.registrations > beforeBlock, "gate reopen rebuilds parent rectangle")
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    let sheetField = NSTextField(string: "Sheet owns editing")
    sheetField.frame = NSRect(x: 20, y: 35, width: 180, height: 24)
    sheet.contentView?.addSubview(sheetField)
    print("SHEET BEFORE resets=\(WorkspaceArrowTestSwitch.resets) discards=\(WorkspaceArrowTestSwitch.discards) registers=\(WorkspaceArrowTestSwitch.registrations)")
    window.beginSheet(sheet); pump(0.4)
    print("SHEET OPEN resets=\(WorkspaceArrowTestSwitch.resets) discards=\(WorkspaceArrowTestSwitch.discards) registers=\(WorkspaceArrowTestSwitch.registrations)")
    let beforeSheetReset = WorkspaceArrowTestSwitch.registrations
    window.invalidateCursorRects(for: split); pump()
    require(WorkspaceArrowTestSwitch.registrations == beforeSheetReset, "attached sheet suppresses parent rectangle")
    print("SHEET INVALIDATE resets=\(WorkspaceArrowTestSwitch.resets) discards=\(WorkspaceArrowTestSwitch.discards) registers=\(WorkspaceArrowTestSwitch.registrations)")
    window.endSheet(sheet); sheet.orderOut(nil); sheet.close(); pump(0.4)
    print("SHEET CLOSED resets=\(WorkspaceArrowTestSwitch.resets) discards=\(WorkspaceArrowTestSwitch.discards) registers=\(WorkspaceArrowTestSwitch.registrations) attached=\(window.attachedSheet != nil) key=\(window.isKeyWindow)")
    let beforeRekeyNotifications = WorkspaceArrowTestSwitch.keyNotifications
    window.makeKeyAndOrderFront(nil); pump()
    require(WorkspaceArrowTestSwitch.keyNotifications > beforeRekeyNotifications, "real parent reactivation delivers scoped key notification")
    print("SHEET REKEY resets=\(WorkspaceArrowTestSwitch.resets) discards=\(WorkspaceArrowTestSwitch.discards) registers=\(WorkspaceArrowTestSwitch.registrations) key=\(window.isKeyWindow)")
    move(divider, expecting: .resizeLeftRight, "sheet closes to native divider")
    move(native, NSPoint(x: 300, y: 40), expecting: .arrow, "sheet closes to workspace blank")
    require(WorkspaceArrowTestSwitch.registrations > beforeSheetReset, "sheet close and active parent restore cursor registration")
    require(WorkspaceArrowTestSwitch.registrations > 0, "candidate really registered parent arrow rectangles")
    require(WorkspaceArrowTestSwitch.registeredRects.allSatisfy { $0.minX >= 0 && $0.minY >= 0 && $0.width <= 940 && $0.height <= 500 }, "parent rectangles never escape workspace bounds")
    print(CommandLine.arguments.contains("--sheet-only") ? "WORKSPACE_ARROW_SHEET_KEY_REOPEN_OK" : "WORKSPACE_ARROW_REAL_APPKIT_POINTER_PARENT_CHILD_CURSOR_PRIORITY_OK")
}
