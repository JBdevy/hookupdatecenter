// The production divider and width preferences run inside a real AppKit window.
// The two column contents stand in for the catalog and editor.
enum WorkspaceLayoutPreferences {
    static let storage = UserDefaults(suiteName: "CatLive.LibraryDividerTests." + UUID().uuidString)!
}
enum JarasInterfaceTheme: String {
    case dark
    static let preferenceKey = "CatLive.Tests.InterfaceTheme"
    static let defaultTheme = Self.dark
    var panelHex: UInt32 { 0x0f0f0f }
    var line: Color { .gray }
    var display: Color { .black }
}
enum JarasTheme { static let setlistQueuedYellow: UInt32 = 0x807219 }
struct NativeLibraryTrackDrop {
    static let type = NSPasteboard.PasteboardType("catlive.test.librarydrop")
    func operation(for sender: NSDraggingInfo, in view: NSView) -> NSDragOperation { [] }
    func perform(_ sender: NSDraggingInfo, in view: NSView) -> Bool { false }
}
final class ShowController { var catalogBuilds = 0 }
struct WorkspaceLibrary: View {
    // Library width limits
    let theme: JarasInterfaceTheme
    let show: ShowController
    var body: some View {
        let _ = { show.catalogBuilds += 1 }()
        LibraryColumns(theme: theme, folders: StatefulControl(role: "folders", revision: 0),
                       entries: StatefulControl(role: "entries", revision: 0))
    }
}

MainActor.assumeIsolated {
    let store = WorkspaceLayoutPreferences.storage
    let widthKey = "jaras.layout.library.width"
    store.set(344.0, forKey: widthKey)
    store.set(146.0, forKey: WorkspaceLibrary.folderWidthKey)
    let show = ShowController()
    let root = NSHostingView(rootView: HStack(spacing: 0) {
        DesktopLibraryPane(theme: .dark, show: show, available: 510)
        Color.clear
    })
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    settle(root)
    let handles = descendants(MixerDividerView.self, in: root).sorted { $0.convert(.zero as CGPoint, to: nil).x < $1.convert(.zero as CGPoint, to: nil).x }
    let entry = descendants(WorkspaceControl.self, in: root).first { $0.role == "entries" }!
    precondition(handles.count == 2 && window.makeFirstResponder(entry))
    for (handle, key, initial, delta) in [(handles[1], widthKey, 344.0, 100.0), (handles[0], WorkspaceLibrary.folderWidthKey, 146.0, 55.0)] {
        let initialPosition = handle.convert(CGPoint(x: 3, y: 30), to: nil)
        let builds = show.catalogBuilds
        func event(_ kind: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: CGPoint(x: initialPosition.x + dx, y: initialPosition.y),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown, 0))
        for point in 1...200 { handle.mouseDragged(with: event(.leftMouseDragged, delta * Double(point) / 200)) }
        settle(root)
        precondition(store.double(forKey: key) == initial, "mouse movement must not write width preferences")
        precondition(show.catalogBuilds == builds, "dragging a divider must not rebuild the catalog")
        handle.mouseUp(with: event(.leftMouseUp, delta))
        settle(root)
        precondition(abs(store.double(forKey: key) - initial - delta) < 0.1)
        precondition(abs(handle.convert(CGPoint(x: 3, y: 30), to: nil).x - initialPosition.x - delta) < 0.1)
        precondition(window.firstResponder === entry, "the details editor must retain keyboard focus")
    }
    print("LIBRARY_BOTH_DIVIDERS_APPLY_FINAL_WIDTH_ONLY_PRESERVE_EDITOR_AND_CATALOG_OK")
    window.close()
}
