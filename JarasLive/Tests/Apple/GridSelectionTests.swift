import AppKit

let application = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
let grid = GridSelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
window.contentView = grid
grid.headerHeight = 71
let first = UUID(), second = UUID(), third = UUID()
grid.items = [GridSelectionItem(id: first, rect: CGRect(x: 100,y: 100,width: 60,height: 30)),
              GridSelectionItem(id: second, rect: CGRect(x: 230,y: 150,width: 60,height: 30)),
              GridSelectionItem(id: third, rect: CGRect(x: 400,y: 300,width: 80,height: 30))]
var selections: [Set<UUID>] = []
grid.selectionChanged = { selections.append($0) }
func event(_ type: NSEvent.EventType, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: grid.convert(point, to: nil), modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
}
func drag(_ from: CGPoint, _ to: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
    precondition(grid.handlePointerEvent(event(.rightMouseDown, from, modifiers: modifiers)))
    precondition(grid.handlePointerEvent(event(.rightMouseDragged, to, modifiers: modifiers)))
    // A delayed hosting update must not overwrite an in-progress selection.
    grid.updateSelection([])
    precondition(grid.handlePointerEvent(event(.rightMouseUp, to, modifiers: modifiers)))
}
for pair in [(CGPoint(x: 90,y: 90),CGPoint(x: 300,y: 190)),
             (CGPoint(x: 300,y: 190),CGPoint(x: 90,y: 90)),
             (CGPoint(x: 90,y: 190),CGPoint(x: 300,y: 90)),
             (CGPoint(x: 300,y: 90),CGPoint(x: 90,y: 190))] {
    drag(pair.0,pair.1)
    precondition(grid.selected == [first,second], "marquee works in all four diagonal directions")
}
for pair in [(CGPoint(x: 90,y: 115),CGPoint(x: 180,y: 115)),
             (CGPoint(x: 180,y: 115),CGPoint(x: 90,y: 115)),
             (CGPoint(x: 120,y: 90),CGPoint(x: 120,y: 140)),
             (CGPoint(x: 120,y: 140),CGPoint(x: 120,y: 90))] {
    drag(pair.0,pair.1)
    precondition(grid.selected == [first], "flat horizontal/vertical selection works in both directions")
}
grid.updateSelection([third])
drag(CGPoint(x: 300,y: 190),CGPoint(x: 90,y: 90),modifiers: .control)
precondition(grid.selected == [first,second,third], "Control adds to the selection")
var seeks: [CGFloat] = []
grid.seek = { seeks.append($0) }
for x in [320.0,500.0,310.0,700.0] {
    precondition(grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: x,y: 220))))
    precondition(grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: x,y: 220))))
}
precondition(seeks == [320,500,310,700], "every blank grid click reaches seek exactly once")
precondition(!grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 500,y: 40))), "headers retain their own cursor/region gestures")
var moved: [UUID] = []
grid.move = { id,_,_,_ in moved.append(id) }
precondition(grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 130,y: 122))))
precondition(grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: 250,y: 172))))
precondition(grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: 250,y: 172))))
precondition(moved == [first,first], "drag ownership stays with the initial item")

// Reproduce a scroll occurring before SwiftUI has delivered its next offset.
final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
let outer = GridNativeScrollView(frame: NSRect(x: 0,y: 0,width: 800,height: 600))
let column = FlippedDocument(frame: NSRect(x: 0,y: 0,width: 800,height: 1200))
let inner = GridNativeScrollView(frame: NSRect(x: 100,y: 0,width: 700,height: 1200))
let document = FlippedDocument(frame: NSRect(x: 0,y: 0,width: 2400,height: 1200))
window.contentView = outer
outer.documentView = column; column.addSubview(inner); inner.documentView = document
grid.removeFromSuperview(); document.addSubview(grid)
grid.frame = NSRect(x: 0,y: 0,width: 700,height: 600)
grid.timelineOrigin = .zero
inner.contentView.scroll(to: CGPoint(x: 200,y: 0))
outer.contentView.scroll(to: CGPoint(x: 0,y: 100))
let viewport = grid.convert(inner.contentView.bounds, from: inner.contentView).intersection(grid.convert(outer.contentView.bounds, from: outer.contentView))
let click = CGPoint(x: viewport.minX+320,y: viewport.minY+220)
precondition(grid.handlePointerEvent(event(.leftMouseDown,click)))
precondition(grid.handlePointerEvent(event(.leftMouseUp,click)))
precondition(seeks.last == 520, "seek uses native scroll bounds, even while the hosted offset is stale")
grid.items = [GridSelectionItem(id: first, rect: CGRect(x: 300,y: 220,width: 60,height: 30))]
drag(CGPoint(x: viewport.minX+180,y: viewport.minY+165),CGPoint(x: viewport.minX+90,y: viewport.minY+110))
precondition(grid.selected == [first], "reverse selection uses the same scrolled coordinates as drawing")
print("GRID_SELECTION_ALL_DIRECTIONS_CLICK_DRAG_AND_NATIVE_SCROLL_OK")

// Native pinning must not require a SwiftUI render or updated timelineOrigin.
let pinnedSelection = NativeTimelinePinnedView(frame: document.bounds)
pinnedSelection.pinHorizontally = true
pinnedSelection.host = grid
grid.removeFromSuperview(); pinnedSelection.addSubview(grid); document.addSubview(pinnedSelection)
let pinnedHeader = NativeTimelinePinnedView(frame: document.bounds)
let headerHost = FlippedDocument(frame: NSRect(x: 0,y: 0,width: document.frame.width,height: grid.headerHeight))
pinnedHeader.host = headerHost
pinnedHeader.addSubview(headerHost); document.addSubview(pinnedHeader)
pinnedSelection.observeScroll(); pinnedHeader.observeScroll()
grid.timelineOrigin = CGPoint(x: -23,y: -44) // Deliberately stale hosted state.
precondition(grid.frame.origin == CGPoint(x: 200,y: 100) && headerHost.frame.origin == CGPoint(x: 0,y: 100))
let fixedHeaderWindowY = headerHost.convert(CGPoint.zero, to: nil).y
let fixedSelectionWindowOrigin = grid.convert(CGPoint.zero, to: nil)
for origin in [CGPoint(x: 420,y: 160),CGPoint(x: 800,y: 400),CGPoint(x: 780,y: 300)] {
    inner.contentView.scroll(to: CGPoint(x: origin.x,y: 0))
    outer.contentView.scroll(to: CGPoint(x: 0,y: origin.y))
    // Bounds notifications pin synchronously, before a run-loop or hosting pass.
    precondition(grid.frame.origin == origin,"selection host follows both live native clips without per-pixel SwiftUI publication")
    precondition(headerHost.frame.origin == CGPoint(x: 0,y: origin.y),"ruler host pins vertically while retaining its horizontal timeline coordinates")
    precondition(abs(headerHost.convert(CGPoint.zero,to: nil).y - fixedHeaderWindowY) < 0.001,"vertical scrolling never moves the ruler on screen")
    precondition(grid.convert(CGPoint.zero,to: nil) == fixedSelectionWindowOrigin,"the viewport-sized input host stays at one window position")
}
let liveOrigin = CGPoint(x: 780,y: 300)
grid.items = [GridSelectionItem(id: first,rect: CGRect(x: liveOrigin.x+160,y: liveOrigin.y+230,width: 120,height: 50))]
let blank = CGPoint(x: 340,y: 210)
precondition(grid.handlePointerEvent(event(.leftMouseDown,blank)))
precondition(grid.handlePointerEvent(event(.leftMouseUp,blank)))
precondition(seeks.last == liveOrigin.x+blank.x,"blank clicks use live native scroll bounds despite a deliberately stale SwiftUI origin")
let body = CGPoint(x: 200,y: 250)
precondition(grid.handlePointerEvent(event(.leftMouseDown,body)))
precondition(grid.handlePointerEvent(event(.leftMouseUp,body)) && grid.selected == [first],"item hit-testing follows both native clip offsets immediately")
precondition(!grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 200,y: 40))),"the pinned ruler keeps exclusive control of its full header band after scrolling")
grid.updateSelection([])
drag(CGPoint(x: 100,y: 200),CGPoint(x: 300,y: 290))
precondition(grid.selected == [first],"marquee selection uses the same live native coordinates as the pinned drawing surface")
precondition(grid.timelineOrigin == CGPoint(x: -23,y: -44),"all native scroll interactions succeeded without a hosted offset update")
print("GRID_NATIVE_PINNED_HEADER_BOTH_AXES_INPUT_AND_STALE_HOSTED_ORIGIN_OK")

// Item edges and mini gain knob own their drag until release, regardless of crossing another item.
grid.timelineOrigin = .zero
outer.documentView = nil; window.contentView = grid; grid.frame = NSRect(x: 0,y: 0,width: 800,height: 600)
grid.items = [GridSelectionItem(id: first, rect: CGRect(x: 100,y: 100,width: 120,height: 60))]
var resized: [(Bool,Bool)] = []
grid.resize = { _,left,_,ended in resized.append((left,ended)) }
for points in [(CGPoint(x: 102,y: 130),CGPoint(x: 80,y: 130)),(CGPoint(x: 218,y: 130),CGPoint(x: 260,y: 130))] {
    _ = grid.handlePointerEvent(event(.leftMouseDown,points.0))
    _ = grid.handlePointerEvent(event(.leftMouseDragged,points.1))
    _ = grid.handlePointerEvent(event(.leftMouseUp,points.1))
}
precondition(resized.count == 4 && resized[0].0 && !resized[2].0 && resized[3].1)
var gains: [Double] = []
grid.gain = { _,value,_ in gains.append(value) }
_ = grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 147,y: 106)))
_ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: 147,y: 226)))
_ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: 147,y: 226)))
precondition(gains.count == 2 && gains.last == 0, "gain knob reaches silence without moving the item")
print("GRID_ITEM_EDGES_AND_GAIN_KNOB_GESTURE_OWNERSHIP_OK")

// Continuous motion updates the original item only; one release commits the gain.
grid.items = [GridSelectionItem(id: first, rect: CGRect(x: 100,y: 100,width: 120,height: 80)),
              GridSelectionItem(id: second, rect: CGRect(x: 100,y: 180,width: 120,height: 80))]
var gainMotions: [(UUID,Double,Bool)] = []
var unexpectedMoves = 0
grid.gain = { gainMotions.append(($0,$1,$2)) }
grid.move = { _,_,_,_ in unexpectedMoves += 1 }
_ = grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 147,y: 106)))
for step in 1...100 {
    _ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: 147,y: 106+Double(step))))
}
_ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: 147,y: 206)))
precondition(!gainMotions.isEmpty && gainMotions.allSatisfy { $0.0 == first }, "gain ownership stays on the original clip while crossing another item")
precondition(gainMotions.filter { $0.2 }.count == 1 && unexpectedMoves == 0, "gain commits once without moving clips")
precondition(gainMotions.last!.1 == 0, "continuous gain motion reaches silence")
grid.items[0].gain = 0
let knob = grid.items[0].gainKnobRect!
_ = grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: knob.midX,y: knob.midY)))
_ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: knob.midX,y: knob.midY-100)))
_ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: knob.midX,y: knob.midY-100)))
precondition(abs(gainMotions.last!.1-1) < 0.000001, "the next drag starts at the new saved gain and returns to 0 dB")
print("GRID_CONTINUOUS_GAIN_SINGLE_COMMIT_AND_UPDATED_DRAG_ANCHOR_OK")

// Header buttons use their whole painted rectangle and never move or seek the item.
var effects: [UUID] = [], muted: [UUID] = []
grid.fx = { id,_ in effects.append(id) }; grid.mute = { muted.append($0) }
let header = grid.items[0]
for rectangle in [header.fxRect!,header.muteRect!] {
    for point in [CGPoint(x: rectangle.minX+0.5,y: rectangle.minY+0.5),CGPoint(x: rectangle.maxX-0.5,y: rectangle.maxY-0.5)] {
        let effectsBefore = effects.count, mutedBefore = muted.count
        _ = grid.handlePointerEvent(event(.leftMouseDown,point))
        precondition(effects.count == effectsBefore && muted.count == mutedBefore, "header controls wait until mouse-up")
        _ = grid.handlePointerEvent(event(.leftMouseUp,point))
    }
}
precondition(effects == [first,first] && muted == [first,first] && unexpectedMoves == 0)
let effectsBeforeCancellation = effects.count, mutedBeforeCancellation = muted.count
for rectangle in [header.fxRect!,header.muteRect!] {
    let center = CGPoint(x: rectangle.midX,y: rectangle.midY)
    _ = grid.handlePointerEvent(event(.leftMouseDown,center))
    _ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: rectangle.maxX+2,y: rectangle.midY)))
    _ = grid.handlePointerEvent(event(.leftMouseDown,center))
    _ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: center.x+4,y: center.y)))
    _ = grid.handlePointerEvent(event(.leftMouseDragged,center))
    _ = grid.handlePointerEvent(event(.leftMouseUp,center))
}
precondition(effects.count == effectsBeforeCancellation && muted.count == mutedBeforeCancellation && unexpectedMoves == 0, "outside releases and small drags cancel without activating another item")
let testSheet = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 120,height: 80),styleMask: [.titled],backing: .buffered,defer: false)
testSheet.isReleasedWhenClosed = false
var sheetOpenings = 0
grid.fx = { id,_ in precondition(id == first); sheetOpenings += 1; window.beginSheet(testSheet) }
let fxCenter = CGPoint(x: header.fxRect!.midX,y: header.fxRect!.midY)
precondition(grid.handlePointerEvent(event(.leftMouseDown,fxCenter)) && window.attachedSheet == nil)
precondition(grid.handlePointerEvent(event(.leftMouseUp,fxCenter)) && window.attachedSheet === testSheet && sheetOpenings == 1, "the FX opener consumes the release even when its callback immediately opens a sheet")
window.endSheet(testSheet); testSheet.orderOut(nil)
precondition(!grid.handlePointerEvent(event(.leftMouseUp,fxCenter)) && sheetOpenings == 1, "a completed header press cannot activate twice")
grid.fx = { id,_ in effects.append(id) }
print("GRID_ITEM_HEADER_ACTIONS_ON_RELEASE_CANCEL_AND_SHEET_EVENT_CONSUMPTION_OK")
var bypassClicks: [Bool] = []
grid.fx = { id,bypass in precondition(id == first); bypassClicks.append(bypass) }
for modifiers: NSEvent.ModifierFlags in [[], .option] {
    _ = grid.handlePointerEvent(event(.leftMouseDown,fxCenter,modifiers: modifiers))
    _ = grid.handlePointerEvent(event(.leftMouseUp,fxCenter,modifiers: modifiers))
}
precondition(bypassClicks == [false,true], "Option-click toggles the whole item chain without opening its editor")
print("GRID_ITEM_FX_OPTION_CLICK_ALL_EFFECTS_BYPASS_OK")
let beforeReset = gainMotions.count
_ = grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: knob.midX,y: knob.midY),clicks: 2))
_ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: knob.midX,y: knob.midY),clicks: 2))
precondition(gainMotions.count == beforeReset+1 && gainMotions.last!.1 == 1 && gainMotions.last!.2, "double click resets the mini knob to 0 dB once")
let small = GridSelectionItem(id: UUID(),rect: CGRect(x: 0,y: 0,width: 25,height: 30))
precondition(small.fxRect == nil && small.gainKnobRect == nil && small.titleInset < small.rect.width, "controls collapse before item titles overflow")
print("GRID_ITEM_FX_MUTE_HIT_AREAS_AND_MINI_KNOB_RESET_OK")

let textID = UUID()
grid.items = [GridSelectionItem(id: textID, rect: CGRect(x: 100,y: 100,width: 120,height: 60), editable: false, contextActions: false, textEditable: true)]
let textItem = grid.items[0]
precondition(textItem.muteRect == nil && textItem.fxRect == nil && textItem.gainKnobRect == nil && textItem.editRect != nil)
var editedText: [UUID] = []
grid.editText = { editedText.append($0) }
let editCenter = CGPoint(x: textItem.editRect!.midX,y: textItem.editRect!.midY)
precondition(grid.handlePointerEvent(event(.leftMouseDown,editCenter)) && editedText.isEmpty)
precondition(grid.handlePointerEvent(event(.leftMouseUp,editCenter)) && editedText == [textID], "text Edit consumes release and only opens one editor")
_ = grid.handlePointerEvent(event(.leftMouseDown,editCenter))
_ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: editCenter.x+10,y: editCenter.y)))
_ = grid.handlePointerEvent(event(.leftMouseUp,editCenter))
precondition(editedText == [textID], "dragging a text Edit button cancels rather than opening the dialog")
print("GRID_TEXT_ITEM_EDIT_EXCLUSIVE_RELEASE_AND_CANCEL_OK")
grid.interactionBlocked = true
let seeksWhileEditing = seeks.count
precondition(!grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 320,y: 220))))
precondition(!grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: 320,y: 220))))
precondition(seeks.count == seeksWhileEditing, "floating text and track editors receive clicks without the timeline seeking behind them")
grid.interactionBlocked = false
print("GRID_FLOATING_EDITOR_POINTER_EVENTS_PASS_TO_EDITOR_OK")

let inputGate = NativeTimelineInputGate.shared
let gateView = NativeTimelineModalGateView(frame: .zero)
grid.addSubview(gateView)
let seeksBeforeGate = seeks.count
gateView.blocked = true
precondition(inputGate.isBlocked(window))
precondition(!grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 320,y: 220))))
precondition(!grid.handlePointerEvent(event(.rightMouseDown,editCenter)))
precondition(!grid.handlePointerEvent(event(.rightMouseUp,editCenter)))
precondition(seeks.count == seeksBeforeGate, "a native window gate blocks pointer actions without an environment update")
gateView.blocked = false
_ = grid.handlePointerEvent(event(.leftMouseDown,editCenter))
gateView.blocked = true
gateView.blocked = false
precondition(!grid.handlePointerEvent(event(.leftMouseUp,editCenter)) && editedText == [textID], "a modal cancels a latent header press before reopening")
gateView.blocked = true
let otherWindow = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 100,height: 100),styleMask: [.titled],backing: .buffered,defer: false)
precondition(!inputGate.isBlocked(otherWindow), "blocking one document never blocks another window")
gateView.removeFromSuperview()
precondition(!inputGate.isBlocked(window), "removing the modal gate releases its window")
print("GRID_NATIVE_MODAL_GATE_POINTER_CANCEL_WINDOW_ISOLATION_AND_REMOVAL_OK")

// Timecode exposes only edge duration changes; it has no controls, menu or move gesture.
let timecode = UUID()
grid.items = [GridSelectionItem(id: timecode, rect: CGRect(x: 100,y: 100,width: 120,height: 60),
                                editable: false, movable: false, contextActions: false)]
precondition(grid.items[0].muteRect == nil && grid.items[0].fxRect == nil && grid.items[0].gainKnobRect == nil)
var timecodeResizes: [(Bool,Bool)] = []
grid.resize = { id,left,_,ended in precondition(id == timecode); timecodeResizes.append((left,ended)) }
let movesBeforeTimecode = unexpectedMoves
for pair in [(CGPoint(x: 102,y: 130),CGPoint(x: 80,y: 130)),(CGPoint(x: 218,y: 130),CGPoint(x: 260,y: 130))] {
    _ = grid.handlePointerEvent(event(.leftMouseDown,pair.0))
    _ = grid.handlePointerEvent(event(.leftMouseDragged,pair.1))
    _ = grid.handlePointerEvent(event(.leftMouseUp,pair.1))
}
precondition(timecodeResizes.count == 4 && timecodeResizes[0].0 && !timecodeResizes[2].0)
_ = grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 150,y: 130)))
_ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: 180,y: 200)))
_ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: 180,y: 200)))
precondition(unexpectedMoves == movesBeforeTimecode, "Timecode cannot move out of its region")
_ = grid.handlePointerEvent(event(.rightMouseDown,CGPoint(x: 150,y: 130)))
_ = grid.handlePointerEvent(event(.rightMouseUp,CGPoint(x: 150,y: 130)))
precondition(grid.selected == [timecode] && window.attachedSheet == nil, "Timecode right click selects without showing a context menu")
print("GRID_TIMECODE_BOTH_EDGES_ONLY_NO_MOVE_CONTROLS_OR_MENU_OK")
