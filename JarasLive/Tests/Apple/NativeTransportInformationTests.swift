import Foundation

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let view = NativeTransportInformationView(frame: NSRect(x: 0, y: 0, width: 240, height: 25))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view; window.orderFront(nil)
    var phase: Int? = 0
    view.configure(message: "Loop Ativo", steady: false, cornerRadius: 0) { phase }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let text = view.layer!.sublayers!.first as! CATextLayer
    precondition(text.string as? String == "Loop Ativo")
    precondition(text.foregroundColor == NSColor(Color.red).cgColor)
    precondition(view.layer!.backgroundColor == NSColor(JarasTheme.yellow).cgColor)
    let layouts = view.layoutCount
    let textBounds = text.frame
    phase = 1
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    precondition(text.foregroundColor == NSColor(JarasTheme.green).cgColor)
    phase = 3
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    precondition(text.foregroundColor == NSColor(JarasTheme.yellow).cgColor)
    precondition(view.layoutCount == layouts && text.frame == textBounds,
                 "beat pulses reuse geometry and do not schedule layout")
    precondition(view.layerContentsRedrawPolicy == .never && view.hitTest(.zero) == nil)
    view.configure(message: "This song has an active multiloop", steady: true, cornerRadius: 4) { nil }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    precondition(text.string as? String == "This song has an active multiloop")
    precondition(text.foregroundColor == NSColor(JarasTheme.green).cgColor)
    precondition(view.layer!.backgroundColor == NSColor(JarasTheme.display).cgColor)
    view.configure(message: "", steady: false, cornerRadius: 0) { nil }
    precondition(text.string as? String == "")
    view.stop(); window.orderOut(nil)
    print("NATIVE_LOOP_NOTICE_BEAT_COLORS_STATIC_MESSAGE_NO_LAYOUT_AND_PASS_THROUGH_OK")
}
