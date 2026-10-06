import AppKit

let application = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
let grid = GridSelectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
window.contentView = grid
grid.headerHeight = 71
grid.updateTrackingAreas()
let initialTracking = grid.trackingAreas.first!
for offset in 0..<120 {
    grid.setBoundsOrigin(CGPoint(x: CGFloat(offset) * 0.25, y: 0))
    grid.updateTrackingAreas()
    precondition(grid.trackingAreas.count == 1 && grid.trackingAreas.first === initialTracking,
                 "scrolling retains automatic visible-rect mouse tracking")
}
grid.setBoundsOrigin(.zero)
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
var freeSeeks: [Bool] = []
grid.seek = { x,free in seeks.append(x); freeSeeks.append(free) }
for x in [320.0,500.0,310.0,700.0] {
    let before = seeks.count
    precondition(grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: x,y: 220))))
    precondition(seeks.count == before, "blank grid presses cannot move the cursor before release")
    precondition(grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: x,y: 220))))
}
precondition(seeks == [320,500,310,700], "every blank grid click reaches seek exactly once")
precondition(freeSeeks.allSatisfy { !$0 })
precondition(grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: 321.75,y: 220), modifiers: .shift)))
precondition(grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: 321.75,y: 220), modifiers: .shift)))
precondition(seeks.last == 321.75 && freeSeeks.last == true, "Shift cursor clicks preserve the exact coordinate and bypass snapping using the event's own modifiers")
precondition(!grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 500,y: 40))), "headers retain their own cursor/region gestures")
var moved: [UUID] = []
for modifiers: NSEvent.ModifierFlags in [[], .shift] {
    let before = seeks.count
    precondition(grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: 130,y: 122), modifiers: modifiers)))
    precondition(seeks.count == before, "item presses must leave the cursor unchanged until release")
    precondition(grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: 130,y: 122), modifiers: modifiers)))
    precondition(seeks.count == before + 1 && seeks.last == 130, "item body clicks seek exactly once at the clicked position")
    precondition(freeSeeks.last == modifiers.contains(.shift), "item clicks preserve Shift free positioning")
    precondition(grid.selected == [first], "seeking from an item keeps item selection")
}
let seeksBeforeCancelledGestures = seeks.count
for point in [CGPoint(x: 320, y: 220), CGPoint(x: 130, y: 122), CGPoint(x: 101, y: 122)] {
    _ = grid.handlePointerEvent(event(.leftMouseDown, point))
    _ = grid.handlePointerEvent(event(.leftMouseDragged, CGPoint(x: point.x + 12, y: point.y)))
    _ = grid.handlePointerEvent(event(.leftMouseDragged, point))
    _ = grid.handlePointerEvent(event(.leftMouseUp, point))
    _ = grid.handlePointerEvent(event(.leftMouseDown, point))
    NativeTimelineInputGate.shared.cancelPendingClicks(for: window)
    _ = grid.handlePointerEvent(event(.leftMouseUp, point))
    _ = grid.handlePointerEvent(event(.leftMouseDown, point))
    NativeTimelineInputGate.shared.setBlocked(true, for: window)
    NativeTimelineInputGate.shared.setBlocked(false, for: window)
    _ = grid.handlePointerEvent(event(.leftMouseUp, point))
}
precondition(seeks.count == seeksBeforeCancelledGestures,
             "empty/item/edge drags, return-to-origin, wheel panning, and modal cancellation never seek")
_ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: 320, y: 220)))
_ = grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: 805, y: 220)))
precondition(seeks.count == seeksBeforeCancelledGestures, "release outside the grid cancels the click")
print("GRID_SEEK_ONLY_ON_RELEASE_DRAG_SCROLL_MODAL_AND_OUTSIDE_CANCEL_OK")
grid.move = { id,_,_,_ in moved.append(id) }
precondition(grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 130,y: 122))))
precondition(grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: 250,y: 172))))
NativeTimelineInputGate.shared.cancelPendingClicks(for: window)
precondition(grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: 250,y: 172))))
precondition(moved == [first,first], "wheel panning preserves an existing drag and its original item commit")
precondition(grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 130,y: 122))))
NativeTimelineInputGate.shared.cancelPendingClicks(for: window)
precondition(grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: 250,y: 172))))
precondition(grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: 250,y: 172))))
precondition(moved == [first,first], "panning before a drag starts cancels the latent item move")
var releasePosition: CGFloat = 0
grid.move = { _,_,y,ended in if ended { releasePosition = y } }
precondition(grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: 130,y: 122))))
precondition(grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: 130,y: 650))))
precondition(grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: 130,y: 650))))
precondition(releasePosition.isNaN, "releasing outside the grid cancels a provisional track")

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
precondition(grid.items[0].muteRect!.minX - grid.items[0].rect.minX == 2,
             "header controls start near the left edge with the repeat notch below")
let edgeSeeksBefore = seeks.count
for x in [101.0, 219.0] {
    _ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: x, y: 130)))
    _ = grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: x, y: 130)))
    precondition(seeks.last == x, "stationary edge clicks seek without trimming")
    precondition(grid.pointerCursor(at: CGPoint(x: x, y: 130)) === NSCursor.resizeLeftRight,
                 "the same edge target that trims must always show the resize cursor")
}
precondition(seeks.count == edgeSeeksBefore + 2)
precondition(grid.pointerCursor(at: CGPoint(x: grid.items[0].muteRect!.midX, y: grid.items[0].muteRect!.midY)) === NSCursor.pointingHand)
let edgeResizesBefore = resized.count
for points in [(CGPoint(x: 101,y: 106),CGPoint(x: 80,y: 106)),
               (CGPoint(x: 95,y: 106),CGPoint(x: 80,y: 106)),
               (CGPoint(x: 225,y: 106),CGPoint(x: 240,y: 106))] {
    _ = grid.handlePointerEvent(event(.leftMouseDown, points.0))
    _ = grid.handlePointerEvent(event(.leftMouseDragged, points.1))
    _ = grid.handlePointerEvent(event(.leftMouseUp, points.1))
}
precondition(resized.count == edgeResizesBefore + 6 && resized[edgeResizesBefore].0 && !resized.last!.0,
             "item edges resize from the header and from a narrow grip just outside the item")
var gains: [Double] = []
grid.gain = { _,value,_ in gains.append(value) }
let gainX = grid.items[0].gainKnobRect!.midX
_ = grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: gainX,y: 106)))
_ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: gainX,y: 226)))
_ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: gainX,y: 226)))
precondition(gains.count == 2 && gains.last == 0, "gain knob reaches silence without moving the item")
print("GRID_ITEM_EDGES_AND_GAIN_KNOB_GESTURE_OWNERSHIP_OK")

// Continuous motion updates the original item only; one release commits the gain.
grid.items = [GridSelectionItem(id: first, rect: CGRect(x: 100,y: 100,width: 120,height: 80)),
              GridSelectionItem(id: second, rect: CGRect(x: 100,y: 180,width: 120,height: 80))]
var gainMotions: [(UUID,Double,Bool)] = []
var unexpectedMoves = 0
grid.gain = { gainMotions.append(($0,$1,$2)) }
grid.move = { _,_,_,_ in unexpectedMoves += 1 }
_ = grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: gainX,y: 106)))
for step in 1...100 {
    _ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: gainX,y: 106+Double(step))))
}
_ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: gainX,y: 206)))
precondition(!gainMotions.isEmpty && gainMotions.allSatisfy { $0.0 == first }, "gain ownership stays on the original clip while crossing another item")
precondition(gainMotions.filter { $0.2 }.count == 1 && unexpectedMoves == 0, "gain commits once without moving clips")
precondition(gainMotions.last!.1 == 0, "continuous gain motion reaches silence")
grid.items[0].gain = 0
let knob = grid.items[0].gainKnobRect!
_ = grid.handlePointerEvent(event(.leftMouseDown,CGPoint(x: knob.midX,y: knob.midY)))
_ = grid.handlePointerEvent(event(.leftMouseDragged,CGPoint(x: knob.midX,y: knob.midY-(60.0/84.0*120))))
_ = grid.handlePointerEvent(event(.leftMouseUp,CGPoint(x: knob.midX,y: knob.midY-(60.0/84.0*120))))
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
for rectangle in [header.fxRect!, header.muteRect!] {
    let center = CGPoint(x: rectangle.midX, y: rectangle.midY)
    precondition(grid.handlePointerEvent(event(.leftMouseDown, center)))
    NativeTimelineInputGate.shared.cancelPendingClicks(for: window)
    precondition(grid.handlePointerEvent(event(.leftMouseUp, center)))
}
precondition(effects.count == effectsBeforeCancellation && muted.count == mutedBeforeCancellation,
             "held-left wheel pan consumes the release without activating a pending FX or mute button")
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

let boostedItem = GridSelectionItem(id: UUID(), rect: CGRect(x: 0, y: 0, width: 200, height: 60), gain: 1)
precondition(abs(boostedItem.draggingGain(by: -120) - pow(10, 24.0 / 20)) < 0.000001, "item knob reaches +24 dB")
precondition(GridSelectionItem(id: UUID(), rect: .zero, gain: pow(10,24.0/20)).gainPosition == 1)
print("GRID_ITEM_GAIN_PLUS24_DB_AND_SILENCE_OK")

// A grid click must retire text-editing/Setlist focus before keyboard routing.
let staleEditor = NSTextField(frame: NSRect(x: 0, y: 0, width: 30, height: 20))
grid.addSubview(staleEditor)
window.makeFirstResponder(staleEditor)
_ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: 150, y: 130)))
_ = grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: 150, y: 130)))
precondition(window.firstResponder === grid && window.firstResponder is any TimelineGridKeyboardTarget, "Item clicks claim keyboard focus for Delete even after editing text")
window.makeFirstResponder(staleEditor)
drag(CGPoint(x: 90, y: 90), CGPoint(x: 250, y: 180))
precondition(window.firstResponder === grid, "Marquee selection claims Delete focus as well")
staleEditor.removeFromSuperview()
print("GRID_ITEM_AND_MARQUEE_SELECTION_CLAIM_DELETE_FOCUS_OK")

_ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: 150, y: 130)))
precondition(grid.heldItemGuide != nil, "item boundary guides appear on press, before drag threshold")
_ = grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: 150, y: 130)))
precondition(grid.heldItemGuide == nil, "release removes both guides")
_ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: 150, y: 130)))
grid.timelineInputGateChanged(blocked: true)
precondition(grid.heldItemGuide == nil, "modal cancellation removes guides without waiting for mouse-up")
print("GRID_ITEM_GUIDES_PRESS_RELEASE_AND_MODAL_CANCELLATION_OK")

let longHeader = GridSelectionItem(id: UUID(), rect: CGRect(x: 100, y: 100, width: 10000, height: 60), name: "LONG ITEM")
let nameWidth = ("LONG ITEM" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold)]).width
for left in [0.0, 500.0, 5000.0, 9800.0] {
    let viewport = CGRect(x: left, y: 0, width: 800, height: 600)
    let displayed = longHeader.visibleLeftHeader(in: viewport, titleWidth: nameWidth)
    let visible = longHeader.rect.intersection(viewport)
    precondition(abs(displayed.headerRect.minX - visible.minX) < 0.001)
    precondition(displayed.headerRect.minX >= visible.minX && displayed.headerRect.maxX <= visible.maxX)
    precondition(displayed.rect == longHeader.rect, "repositioning controls never changes the item's trim edges")
}
grid.items = [longHeader]; grid.timelineOrigin = CGPoint(x: 5000, y: 0)
let visibleHeader = longHeader.visibleLeftHeader(in: CGRect(x: 5000, y: 0, width: 800, height: 600), titleWidth: nameWidth)
var visibleMuteCount = 0
grid.mute = { id in precondition(id == longHeader.id); visibleMuteCount += 1 }
let mutePoint = CGPoint(x: visibleHeader.muteRect!.midX - 5000, y: visibleHeader.muteRect!.midY)
_ = grid.handlePointerEvent(event(.leftMouseDown, mutePoint))
_ = grid.handlePointerEvent(event(.leftMouseUp, mutePoint))
precondition(visibleMuteCount == 1, "left-pinned controls remain clickable with the original item start offscreen")
print("GRID_VISIBLE_ITEM_HEADER_LEFT_SCROLL_AND_CLICK_ALIGNMENT_OK")

// Fade handles sit below the title/control strip; the remaining edge still trims.
grid.timelineOrigin = .zero
grid.items = [GridSelectionItem(id: first, rect: CGRect(x: 100, y: 100, width: 400, height: 80), duration: 10)]
let fadeLayout = grid.items[0]
for side in [true, false] {
    precondition(fadeLayout.fadeHandleRect(side)!.minY == 114, "fade grip must sit below the control strip")
}
precondition(fadeLayout.fadeSide(at: CGPoint(x: 102, y: 102)) == nil, "title/controls must never initiate fade")
precondition(fadeLayout.fadeSide(at: CGPoint(x: 498, y: 102)) == nil, "right title edge must never initiate fade")
var fades: [(Bool, Double, Bool)] = []
grid.fade = { _, left, seconds, ended in fades.append((left, seconds, ended)) }
for pair in [(CGPoint(x: 102, y: 116), CGPoint(x: 502, y: 116)),
             (CGPoint(x: 498, y: 116), CGPoint(x: 98, y: 116))] {
    _ = grid.handlePointerEvent(event(.leftMouseDown, pair.0))
    _ = grid.handlePointerEvent(event(.leftMouseDragged, pair.1))
    _ = grid.handlePointerEvent(event(.leftMouseUp, pair.1))
}
precondition(fades.count == 4 && fades[0].0 && !fades[2].0 && fades.allSatisfy { $0.1 == 10 }, "both fades can span the entire expanded item")
precondition(fades[1].2 && fades[3].2, "release commits once per fade gesture")
precondition(grid.pointerCursor(at: CGPoint(x: 102, y: 116)) === NSCursor.crosshair)
precondition(grid.pointerCursor(at: CGPoint(x: 102, y: 130)) === NSCursor.resizeLeftRight)
grid.updateSelection([])
precondition(grid.hitTest(grid.convert(CGPoint(x: 102, y: 130), to: grid.superview)) === grid,
             "the grid body must own native cursor updates rather than falling through to the hosting view")
precondition(grid.hitTest(grid.convert(CGPoint(x: 102, y: 40), to: grid.superview)) == nil,
             "ruler input remains outside the body hit target")
grid.mouseEntered(with: event(.mouseMoved, CGPoint(x: 102, y: 130)))
precondition(NSCursor.current == NSCursor.resizeLeftRight && grid.selected.isEmpty,
             "unselected item edges expose a native resize cursor immediately")
grid.resetCursorRects()
grid.cursorUpdate(with: event(.mouseMoved, CGPoint(x: 498, y: 130)))
precondition(NSCursor.current == NSCursor.resizeLeftRight,
             "right edges keep the resize cursor after AppKit cursor-rect resets")
grid.mouseMoved(with: event(.mouseMoved, CGPoint(x: 102, y: 116)))
precondition(NSCursor.current == NSCursor.crosshair,
             "below-header fades use their distinct cursor instead of the trim cursor")
print("GRID_FADE_CORNERS_FULL_ITEM_LENGTH_PREVIEW_COMMIT_AND_EDGE_CURSOR_OK")

// The same immutable scene must support consecutive zoom scales without
// rebuilding all item rectangles, including fixed-width minimum-size items.
let indexedID = UUID(), microscopicID = UUID()
let timedItems = [
    GridSelectionItem(id: indexedID, rect: CGRect(x: 10, y: 100, width: 40, height: 80), name: "INDEXED ITEM", duration: 40),
    GridSelectionItem(id: microscopicID, rect: CGRect(x: 60, y: 220, width: 0.00001, height: 58), duration: 0.00001)
]
let indexedLayout = GridSelectionLayout(items: timedItems, timeCoordinates: true)
for scale in [1.0, 8.0, 12.0, 0.001, 20000.0] {
    grid.updateLayout(indexedLayout, pixelsPerSecond: scale)
    let projected = indexedLayout.projectedItem(at: 0, pixelsPerSecond: scale)
    precondition(projected.rect == CGRect(x: 10 * scale + 1, y: 100, width: max(2, 40 * scale - 2), height: 80))
    let tiny = indexedLayout.projectedItem(at: 1, pixelsPerSecond: scale)
    let tip = CGRect(x: tiny.rect.maxX - 0.1, y: 230, width: 0.01, height: 1)
    precondition(indexedLayout.candidates(in: tip, pixelsPerSecond: scale).contains(1), "culling includes the fixed minimum pixel width even far beyond the source duration")
}
var indexedResizes: [(Bool, CGFloat, Bool)] = []
grid.resize = { id, left, delta, ended in precondition(id == indexedID); indexedResizes.append((left, delta, ended)) }
grid.updateLayout(indexedLayout, pixelsPerSecond: 12)
precondition(grid.pointerCursor(at: CGPoint(x: 121, y: 140)) === NSCursor.resizeLeftRight)
_ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: 121, y: 140)))
_ = grid.handlePointerEvent(event(.leftMouseDragged, CGPoint(x: 141, y: 140)))
_ = grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: 141, y: 140)))
precondition(indexedResizes.count == 2 && indexedResizes.allSatisfy { $0.0 && $0.1 == 20 } && indexedResizes.last!.2,
             "trim hit testing and deltas use the latest zoom while metadata remains shared")
grid.updateLayout(indexedLayout, pixelsPerSecond: 8)
drag(CGPoint(x: 75, y: 95), CGPoint(x: 402, y: 185))
precondition(grid.selected == [indexedID], "marquee after a zoom uses projected item bounds")
grid.timelineOrigin = CGPoint(x: 160, y: 0)
let indexedVisible = indexedLayout.projectedItem(at: 0, pixelsPerSecond: 8)
    .visibleLeftHeader(in: CGRect(x: 160, y: 0, width: 800, height: 600), titleWidth: 100)
var indexedMuteCount = 0
grid.mute = { id in precondition(id == indexedID); indexedMuteCount += 1 }
let indexedMutePoint = CGPoint(x: indexedVisible.muteRect!.midX - 160, y: indexedVisible.muteRect!.midY)
_ = grid.handlePointerEvent(event(.leftMouseDown, indexedMutePoint))
_ = grid.handlePointerEvent(event(.leftMouseUp, indexedMutePoint))
precondition(indexedMuteCount == 1, "the indexed long item's controls stay pinned and clickable after a native viewport move")
grid.timelineOrigin = .zero
print("GRID_INDEXED_ITEM_ZOOM_MARQUEE_TRIM_MINIMUM_WIDTH_AND_PINNED_CONTROLS_OK")

// Compare the spatial index with the brute-force geometry oracle across
// overlapping clips, unsorted source order, different row heights and zooms.
var indexedSources: [GridSelectionItem] = []
for row in 0..<18 {
    for column in (0..<35).reversed() {
        indexedSources.append(GridSelectionItem(id: UUID(), rect: CGRect(x: Double(column) * 4.3,
            y: Double(row) * 37, width: column % 5 == 0 ? 30 : 3, height: 28 + Double(column % 4) * 6)))
    }
}
let indexedScene = GridSelectionLayout(items: indexedSources, timeCoordinates: true)
for scale in [0.003, 0.25, 12.3, 1000.0] {
    for step in 0..<35 {
        let area = CGRect(x: Double(step) * 1.3 * scale, y: Double(step) * 11.5, width: 51, height: 63)
        let actual = indexedScene.candidates(in: area, pixelsPerSecond: scale).filter {
            indexedScene.projectedItem(at: $0, pixelsPerSecond: scale).rect.intersects(area)
        }
        let expected = indexedSources.indices.filter {
            indexedScene.projectedItem(at: $0, pixelsPerSecond: scale).rect.intersects(area)
        }
        precondition(Set(actual) == Set(expected), "the index cannot cull a visible or selectable item")
        precondition(actual == expected, "overlapping items keep their original per-row interaction order")
    }
}
print("GRID_SPATIAL_INDEX_MATCHES_BRUTE_FORCE_OVERLAP_AND_ZOOM_ORACLE_OK")

let menuGrid = GridSelectionView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
let contextAudibleID = UUID(), contextMutedID = UUID(), contextVideoID = UUID(), contextTextID = UUID()
menuGrid.items = [
    GridSelectionItem(id: contextAudibleID, rect: CGRect(x: 0, y: 0, width: 100, height: 30)),
    GridSelectionItem(id: contextMutedID, rect: CGRect(x: 0, y: 40, width: 100, height: 30), muted: true),
    GridSelectionItem(id: contextVideoID, rect: CGRect(x: 0, y: 80, width: 100, height: 30), editable: false, audioExportable: false),
    GridSelectionItem(id: contextTextID, rect: CGRect(x: 0, y: 120, width: 100, height: 30), editable: false, contextActions: false, audioExportable: false)
]
menuGrid.updateSelection([contextAudibleID, contextMutedID, contextVideoID, contextTextID])
var exported = Set<UUID>(), toggled: [UUID] = []
menuGrid.export = { exported = $0 }; menuGrid.mute = { toggled.append($0) }
func invoke(_ menu: NSMenu, _ name: String) {
    let item = menu.items.first { $0.action == NSSelectorFromString(name) }!
    precondition(item.isEnabled)
    precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
}
let mixedMenu = menuGrid.itemContextMenu(for: contextTextID)
precondition(mixedMenu.items.last?.action == NSSelectorFromString("exportSelection"))
invoke(mixedMenu, "exportSelection")
precondition(exported == [contextAudibleID, contextMutedID], "special items cannot enter audio export, even when right-clicked inside a mixed selection")
invoke(mixedMenu, "muteSelection")
precondition(toggled == [contextAudibleID], "mixed mute states become muted, without unmuting an already muted item")
menuGrid.updateSelection([contextMutedID]); toggled = []
invoke(menuGrid.itemContextMenu(for: contextMutedID), "muteSelection")
precondition(toggled == [contextMutedID], "a muted selection can be unmuted")
menuGrid.updateSelection([contextVideoID, contextTextID])
precondition(menuGrid.itemContextMenu(for: contextVideoID).items.last?.isEnabled == false, "no audio means no export")
print("ITEM_CONTEXT_MUTE_UNMUTE_AND_LAST_EXPORT_FILTER_MIXED_SELECTION_OK")

menuGrid.updateSelection([contextAudibleID])
let audioContext = menuGrid.itemContextMenu(for: contextAudibleID)
precondition(!audioContext.items.contains { $0.action == NSSelectorFromString("separateSelection") }, "CatStem lives inside FX, never in the item context menu")
precondition(audioContext.items.last?.action == NSSelectorFromString("exportSelection"))
print("CATSTEM_REMOVED_FROM_CONTEXT_AND_EXPORT_REMAINS_LAST_OK")

let contextMIDI = UUID(), contextMIDIMuted = UUID()
menuGrid.items += [
    GridSelectionItem(id: contextMIDI, rect: CGRect(x: 0, y: 160, width: 100, height: 30), audioExportable: false, midiEditable: true),
    GridSelectionItem(id: contextMIDIMuted, rect: CGRect(x: 0, y: 200, width: 100, height: 30), audioExportable: false, midiEditable: true, muted: true)
]
menuGrid.updateSelection([contextMIDI, contextMIDIMuted, contextAudibleID])
let midiContext = menuGrid.itemContextMenu(for: contextMIDI)
precondition(midiContext.items.count == 4)
precondition(midiContext.items.map(\.title) == ["Mute items", "Convert Mono", "Convert Stereo", "Unify items"])
toggled = []; invoke(midiContext, "muteMIDISelection")
precondition(toggled == [contextMIDI], "MIDI context actions must preserve selected audio items")
var frozen = Set<UUID>(), frozenChannels = 0
menuGrid.freezeMIDI = { frozen = $0; frozenChannels = $1 }
for channels in [1, 2] {
    let option = midiContext.items.first { $0.tag == channels }!
    precondition(NSApp.sendAction(option.action!, to: option.target, from: option))
    precondition(frozen == [contextMIDI, contextMIDIMuted] && frozenChannels == channels)
}
menuGrid.updateSelection([contextMIDIMuted]); toggled = []
let unmuteMIDI = menuGrid.itemContextMenu(for: contextMIDIMuted)
precondition(unmuteMIDI.items.first?.title == "Unmute items")
invoke(unmuteMIDI, "muteMIDISelection")
precondition(toggled == [contextMIDIMuted])
print("MIDI_CONTEXT_ONLY_MUTE_UNMUTE_MONO_STEREO_AND_MIXED_SELECTION_FILTER_OK")

var glued = Set<UUID>()
menuGrid.glue = { glued = $0 }
menuGrid.updateSelection([contextMIDI, contextAudibleID, contextVideoID, contextTextID])
invoke(menuGrid.itemContextMenu(for: contextMIDI), "glueSelection")
precondition(glued == [contextMIDI, contextAudibleID], "Glue preserves selected audio and MIDI across tracks for atomic validation")
menuGrid.updateSelection([contextAudibleID])
invoke(menuGrid.itemContextMenu(for: contextAudibleID), "glueSelection")
precondition(glued == [contextAudibleID], "A single audio item can also be unified")
print("AUDIO_MIDI_GLUE_MENU_COMPLETE_SELECTION_AND_SINGLE_ITEM_OK")

// Header phase and pan never start item movement or a timeline seek.
grid.removeFromSuperview(); window.contentView = grid
grid.frame = NSRect(x: 0, y: 0, width: 800, height: 600); grid.timelineOrigin = .zero
grid.headerHeight = 71; grid.interactionBlocked = false
NativeTimelineInputGate.shared.setBlocked(false, for: window)
grid.items = [GridSelectionItem(id: first, rect: CGRect(x: 100, y: 100, width: 240, height: 50))]
var phaseClicks: [UUID] = [], panEdits: [(UUID, Double, Bool)] = []
grid.phase = { phaseClicks.append($0) }; grid.pan = { panEdits.append(($0,$1,$2)) }
let phaseRect = grid.items[0].phaseRect!, panRect = grid.items[0].panKnobRect!
precondition(phaseRect.maxX < panRect.minX && panRect.maxX < grid.items[0].gainKnobRect!.minX && grid.items[0].gainLabelRect!.minX > grid.items[0].gainKnobRect!.maxX,
             "volume is the last knob, immediately before its dB value")
let beforeMixSeeks = seeks.count
_ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: phaseRect.midX, y: phaseRect.midY)))
_ = grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: phaseRect.midX, y: phaseRect.midY)))
precondition(phaseClicks == [first])
_ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: panRect.midX, y: panRect.midY)))
_ = grid.handlePointerEvent(event(.leftMouseDragged, CGPoint(x: panRect.midX, y: panRect.midY - 60)))
_ = grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: panRect.midX, y: panRect.midY - 60)))
precondition(panEdits.last!.0 == first && panEdits.last!.1 == 1 && panEdits.last!.2)
precondition(panEdits.filter { $0.2 }.count == 1 && seeks.count == beforeMixSeeks)
_ = grid.handlePointerEvent(event(.leftMouseDown, CGPoint(x: panRect.midX, y: panRect.midY), clicks: 2))
_ = grid.handlePointerEvent(event(.leftMouseUp, CGPoint(x: panRect.midX, y: panRect.midY), clicks: 2))
precondition(panEdits.last!.1 == 0 && panEdits.last!.2)
print("ITEM_HEADER_PHASE_PAN_ORDER_DRAG_COMMIT_AND_CENTER_OK")
