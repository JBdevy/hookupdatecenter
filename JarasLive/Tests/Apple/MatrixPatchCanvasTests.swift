let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 968, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Matrix Patch · Visual check"
private let surface = MatrixPatchSurface(frame: NSRect(x: 0,y: 0,width: 968,height: 520))
let names = ["CLICK", "GUIA", "BATERIA", "BAIXO", "GUITARRA BASE", "GUITARRA SOLO", "TECLADOS", "VOZ", "REGÊNCIA / VIOLÃO", "REVERB"]
let ids = names.map { _ in UUID() }
surface.model.rows = [MatrixPatchRow(id: nil, number: "M", name: "Master", color: 0x68df97, sends: false, master: false, outputs: [.stereo], destinations: [])]
surface.model.columns = [MatrixPatchColumn(destination: .output(.master), name: "Master", badge: "M", color: 0x68df97, available: true)]
for patch in OutputPatch.choices(channels: 4, includeMaster: false) {
 surface.model.columns.append(MatrixPatchColumn(destination: .output(patch), name: "Output " + patch.title, badge: patch.title, color: 0x67b9ee, available: true))
}
for i in names.indices {
 surface.model.rows.append(MatrixPatchRow(id: ids[i], number: String(i+1), name: names[i], color: i < 3 ? 0xe0bc68 : 0x68aacb, sends: true, master: true, outputs: [.master], destinations: i == 4 ? [ids[9]] : []))
 surface.model.columns.append(MatrixPatchColumn(destination: .track(ids[i]), name: names[i], badge: String(i+1), color: i < 3 ? 0xe0bc68 : 0x68aacb, available: true))
}
window.contentView = surface
window.center();window.orderFront(nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
 surface.layoutSubtreeIfNeeded(); surface.updateContent();surface.setHover(row: 5,column: 16)
 surface.display()
 let image = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
 surface.cacheDisplay(in: surface.bounds, to: image)
 // Headers must never paint over the cells (NSView clipping defaults changed in macOS 14).
 let pixelScale = CGFloat(image.pixelsWide) / surface.bounds.width
 let pixel = image.colorAt(x: Int((surface.scroll.frame.minX + 10) * pixelScale), y: Int((surface.scroll.frame.minY + 32 + 10) * pixelScale))!.usingColorSpace(.deviceRGB)!
 assert(pixel.greenComponent > pixel.redComponent + 0.1, "An active route must remain visible under the frozen headers")
 if let path = ProcessInfo.processInfo.environment["MATRIX_PATCH_CAPTURE"] {
  try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
 }
 var clicked = false
 surface.toggle = {row,col in clicked = row.name == "GUITARRA BASE" && col.name == "REVERB" }
 let body = surface.scroll.documentView!
 let local = NSPoint(x: 16 * 38 + 19, y: 5 * 32 + 16)
 let location = body.convert(local, to: nil)
 let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
 body.mouseDown(with: event)
 assert(clicked, "Cell hit must match the displayed source and destination")
 // Both headers must retain the same source/destination mapping after scrolling.
 window.setContentSize(NSSize(width: 700, height: 430))
 surface.layoutSubtreeIfNeeded();surface.updateContent();surface.scroll.tile()
 surface.scroll.contentView.scroll(to: NSPoint(x: body.bounds.width - surface.scroll.contentSize.width,y: 70));surface.scroll.reflectScrolledClipView(surface.scroll.contentView)
 assert(surface.scroll.contentView.bounds.minX > 0 && surface.scroll.contentView.bounds.minY > 0, "The fixture must actually scroll on both axes")
 assert(surface.scroll.horizontalScroller?.isHidden == false, "Overflowing destinations must expose the horizontal scrollbar without a gesture")
 assert(body.visibleRect.contains(local), "The target route must be visible after scrolling")
 clicked = false
 let scrolled = body.convert(local, to: nil)
 let scrolledEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: scrolled, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
 body.mouseDown(with: scrolledEvent);assert(clicked)
 print("Matrix canvas: rendering, crosshair, cell hit and scrolled hit passed")
 window.orderOut(nil);exit(0)
}
app.run()
