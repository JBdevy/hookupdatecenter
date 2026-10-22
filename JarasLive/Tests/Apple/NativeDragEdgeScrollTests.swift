import AppKit
@MainActor func verifyDragEdges() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -5000,y:-5000,width:300,height:400), styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let scroll = GridNativeScrollView(frame:NSRect(x:0,y:0,width:300,height:400))
    final class Flipped: NSView { override var isFlipped: Bool { true } }
    let document = Flipped(frame:NSRect(x:0,y:0,width:300,height:2000))
    let source=NSView(frame:NSRect(x:0,y:10,width:300,height:40));document.addSubview(source)
    scroll.documentView=document;window.contentView=scroll
    let drag=NativeDragEdgeScroll(); drag.begin(from:source)
    var time=ProcessInfo.processInfo.systemUptime
    func tick(_ y:CGFloat, buttons:Int=1) {
        let clip=scroll.contentView
        let local=NSPoint(x:clip.bounds.midX,y:clip.bounds.minY+y)
        let pointer=window.convertPoint(toScreen:clip.convert(local,to:nil))
        time += 1.0/60;drag.step(pointer:pointer,pressedButtons:buttons,time:time)
    }
    for _ in 0..<60 { tick(scroll.contentView.bounds.height-2) }
    let down=scroll.contentView.bounds.minY
    precondition(down>500 && down<650,"Stationary edge drag must keep scrolling")
    for _ in 0..<10 {tick(200)}
    precondition(scroll.contentView.bounds.minY==down,"Center must stop scrolling")
    for _ in 0..<240 {tick(2)}
    precondition(scroll.contentView.bounds.minY==0,"Top boundary must clamp")
    for _ in 0..<300 {tick(scroll.contentView.bounds.height-2)}
    precondition(scroll.contentView.bounds.maxY<=document.bounds.maxY)
    precondition(scroll.contentView.bounds.minX==0,"Vertical drag cannot move horizontal scroll")
    let final=scroll.contentView.bounds
    tick(2,buttons:0);for _ in 0..<30 {tick(2)}
    precondition(scroll.contentView.bounds==final,"Dropping must stop the edge timer")
    window.close()
    print("NATIVE_DND_STATIONARY_EDGES_BOTH_DIRECTIONS_BOUNDS_CENTER_RELEASE_OK")
}
MainActor.assumeIsolated { verifyDragEdges() }
