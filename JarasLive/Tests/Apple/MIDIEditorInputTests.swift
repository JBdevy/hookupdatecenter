import AppKit
import SwiftUI
_ = NSApplication.shared
let canvas = MIDIPianoCanvas()
let scroll = MIDIPianoScrollView(frame:CGRect(x:0,y:0,width:900,height:480));scroll.documentView=canvas
final class MIDIEditorTestWindow: NSWindow { override var isKeyWindow: Bool { true } }
let window=MIDIEditorTestWindow(contentRect:scroll.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=scroll
var clip=AudioClip(id:UUID(),name:"MIDI",startTime:0,duration:8,midi:MIDIItem())
var selected=Set<UUID>(), commits=0
canvas.commit={clip.midi!.notes=$0;commits+=1};canvas.selectionChanged={selected=$0}
func update() {canvas.update(clip:clip,selected:selected,scale:100,cursor:0,width:900);scroll.contentView.scroll(to:CGPoint(x:0,y:1100));window.contentView?.layoutSubtreeIfNeeded()}
func event(_ type:NSEvent.EventType,_ beat:Double,_ pitch:Int,flags:NSEvent.ModifierFlags=[], clicks:Int=1)->NSEvent {
 let p=CGPoint(x:64+beat*100,y:24+CGFloat(127-pitch)*18+9)
 return NSEvent.mouseEvent(with:type,location:canvas.convert(p,to:nil),modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:clicks,pressure:1)!
}
update()
canvas.mouseDown(with:event(.leftMouseDown,0.11,60));canvas.mouseUp(with:event(.leftMouseUp,0.11,60))
precondition(commits == 0 && clip.midi!.notes.isEmpty)
canvas.mouseDown(with:event(.leftMouseDown,0.11,60,clicks:2));canvas.mouseDragged(with:event(.leftMouseDragged,1.12,60));canvas.mouseUp(with:event(.leftMouseUp,1.12,60))
precondition(commits==1&&clip.midi!.notes.count==1&&clip.midi!.notes[0].start==0&&clip.midi!.notes[0].length==1)
precondition(clip.midi!.notes[0].velocity == 100, "A new note starts at velocity 100")
update()
canvas.mouseDown(with:event(.leftMouseDown,0.99,60));canvas.mouseDragged(with:event(.leftMouseDragged,1.365,60,flags:.shift));canvas.mouseUp(with:event(.leftMouseUp,1.365,60,flags:.shift))
precondition(abs(clip.midi!.notes[0].length-1.375)<1e-9,"Shift resizes freely using the original press offset")
update()
canvas.mouseDown(with:event(.leftMouseDown,0.5,60));canvas.mouseDragged(with:event(.leftMouseDragged,1.18,62,flags:.shift));canvas.mouseUp(with:event(.leftMouseUp,1.18,62,flags:.shift))
precondition(abs(clip.midi!.notes[0].start-0.68)<1e-9&&clip.midi!.notes[0].pitch==62)
update()
let delete=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:51)!
canvas.keyDown(with:delete);precondition(clip.midi!.notes.isEmpty)
print("MIDI_PIANO_NATIVE_CREATE_DRAG_RESIZE_SHIFT_MOVE_PITCH_DELETE_AND_SINGLE_COMMIT_OK")

let channelOne=MIDINote(start:0,length:1,pitch:60,channel:1)
let channelTwo=MIDINote(start:0,length:1,pitch:60,channel:2)
let channelSixteen=MIDINote(start:2,length:1,pitch:64,channel:16)
clip.midi=MIDIItem(notes:[channelOne,channelTwo,channelSixteen])
selected=[channelOne.id,channelTwo.id,channelSixteen.id]
canvas.channelFilter=1;update()
precondition(canvas.visibleNotes == [channelOne],"the channel filter changes visible notes without removing hidden MIDI data")
canvas.mouseDown(with:event(.leftMouseDown,0.5,60));canvas.mouseUp(with:event(.leftMouseUp,0.5,60))
precondition(selected == [channelOne.id],"hit testing cannot select an overlapping note from a hidden channel")
let selectAll=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"a",charactersIgnoringModifiers:"a",isARepeat:false,keyCode:0)!
canvas.keyDown(with:selectAll)
precondition(selected == [channelOne.id],"Select All only selects the displayed channel")
canvas.keyDown(with:delete)
precondition(clip.midi!.notes == [channelTwo,channelSixteen],"Delete preserves hidden notes, including a stale hidden selection")
canvas.channelFilter=2;update()
canvas.rightMouseDown(with:event(.rightMouseDown,0.1,64))
canvas.rightMouseDragged(with:event(.rightMouseDragged,3.5,58))
canvas.rightMouseUp(with:event(.rightMouseUp,3.5,58))
precondition(selected == [channelTwo.id],"marquee selection excludes hidden channels")
canvas.channelFilter=16;selected=[];update()
canvas.mouseDown(with:event(.leftMouseDown,4,62,clicks:2));canvas.mouseUp(with:event(.leftMouseUp,4,62))
precondition(clip.midi!.notes.last?.channel == 16,"new notes use the selected channel")
precondition(clip.midi!.notes.contains(channelTwo),"creating notes does not replace another channel")
canvas.channelFilter=0;update()
precondition(canvas.visibleNotes == clip.midi!.notes,"All restores every channel without changing the MIDI item")
canvas.keyDown(with:selectAll)
precondition(selected == Set(clip.midi!.notes.map(\.id)))
for channel in 1...16 {
    canvas.channelFilter=channel;update()
    precondition(canvas.visibleNotes.allSatisfy{$0.channel == channel})
}
print("MIDI_PIANO_CHANNELS_ALL_1_TO_16_FILTER_HIT_TEST_MARQUEE_SELECT_ALL_DELETE_CREATE_OK")

func rulerEvent(_ type:NSEvent.EventType,_ beat:Double,flags:NSEvent.ModifierFlags=[],y:CGFloat?=nil)->NSEvent {
    let p=CGPoint(x:64+beat*100,y:y ?? canvas.visibleRect.minY+12)
    return NSEvent.mouseEvent(with:type,location:canvas.convert(p,to:nil),modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
}
func rulerClick(_ beat:Double,flags:NSEvent.ModifierFlags=[]) {
    canvas.mouseDown(with:rulerEvent(.leftMouseDown,beat,flags:flags))
    canvas.mouseUp(with:rulerEvent(.leftMouseUp,beat,flags:flags))
}
var seeks:[Double]=[]
canvas.seek={seeks.append($0)}
clip=AudioClip(id:UUID(),name:"Trimmed MIDI",startTime:10,duration:4,sourceOffset:1,playbackRate:2,midi:MIDIItem(notes:[channelOne,channelTwo],sourceBPM:120))
canvas.channelFilter=0;selected=[channelOne.id];update()
let beforeRulerNotes=clip.midi!,beforeRulerCommits=commits,beforeRulerSelection=selected
canvas.mouseDown(with:rulerEvent(.leftMouseDown,6))
precondition(seeks.isEmpty,"ruler presses wait for release")
canvas.mouseUp(with:rulerEvent(.leftMouseUp,6))
precondition(seeks == [11],"source beat 6 at120BPM, offset1s, rate2 and itemstart10 seeks to11s")
rulerClick(6.13)
precondition(abs(seeks.last!-11.0625)<1e-9,"ruler clicks snap in the MIDI source grid")
rulerClick(6.13,flags:.shift)
precondition(abs(seeks.last!-11.0325)<1e-9,"Shift chooses an exact playback position")
rulerClick(0.5)
precondition(seeks.last == 10,"trimmed-away source positions clamp to the item start")
scroll.contentView.scroll(to:CGPoint(x:1300,y:900));window.contentView?.layoutSubtreeIfNeeded()
rulerClick(20)
precondition(seeks.last == 14,"positions beyond the source item clamp to its end after horizontal scroll")
precondition(clip.midi == beforeRulerNotes && commits == beforeRulerCommits && selected == beforeRulerSelection,
             "ruler seeking never changes notes, selection, grid or edit history")

scroll.contentView.scroll(to:CGPoint(x:200,y:1050));window.contentView?.layoutSubtreeIfNeeded()
let beforeCanceled=seeks.count
canvas.mouseDown(with:rulerEvent(.leftMouseDown,6))
canvas.mouseDragged(with:rulerEvent(.leftMouseDragged,6.5))
canvas.mouseDragged(with:rulerEvent(.leftMouseDragged,6))
canvas.mouseUp(with:rulerEvent(.leftMouseUp,6))
precondition(seeks.count == beforeCanceled,"dragging away and back on the ruler cannot seek or create notes")
canvas.mouseDown(with:rulerEvent(.leftMouseDown,6))
canvas.mouseUp(with:rulerEvent(.leftMouseUp,6,y:canvas.visibleRect.minY+80))
precondition(seeks.count == beforeCanceled,"releasing outside the ruler cancels the click")
canvas.isEditable=false;rulerClick(6);canvas.isEditable=true
precondition(seeks.count == beforeCanceled,"blocked editing cannot seek")

var tempoSong=Project.empty(name:"Tempo MIDI editor").songs[0]
tempoSong.timeSettings=ProjectTimeSettings();tempoSong.timeSettings?.timebase = .relative
tempoSong.markers=[TimelineMarker(id:UUID(),name:"TEMPO",position:2,color:0x999999,tempoBPM:240)]
clip=AudioClip(id:UUID(),name:"Tempo MIDI",startTime:0,duration:4,midi:MIDIItem(notes:[channelOne],sourceBPM:120))
selected=[]
canvas.update(clip:clip,selected:[],scale:100,cursor:0,width:900,segments:tempoSong.tempoAudioSegments(clip))
scroll.contentView.scroll(to:CGPoint(x:300,y:1100));window.contentView?.layoutSubtreeIfNeeded()
rulerClick(8)
precondition(seeks.last == 3,"source beat8 maps to3s across the tempo change instead of4s")
precondition(commits == beforeRulerCommits,"tempo-aware ruler seeking never commits MIDI edits")
print("MIDI_PIANO_RULER_SEEK_SOURCE_OFFSET_RATE_TEMPO_SEGMENTS_SNAP_SHIFT_SCROLL_AND_CANCEL_OK")
func wheel(_ dx: Int32, _ dy: Int32, flags: CGEventFlags = []) {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                        wheel1: dy, wheel2: dx, wheel3: 0)!
    event.flags = flags
    scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
}
let zoomBeforeWheel = canvas.scale
wheel(0,1)
precondition(canvas.scale > zoomBeforeWheel, "Vertical wheel must zoom the piano roll")
let zoomAfterWheel = canvas.scale
scroll.contentView.scroll(to: CGPoint(x: 250,y: 500))
let beforeOption = scroll.contentView.bounds.origin
wheel(0,-1,flags:.maskAlternate)
precondition(scroll.contentView.bounds.minY != beforeOption.y && canvas.scale == zoomAfterWheel)
let beforeHorizontal = scroll.contentView.bounds.minX
wheel(-1,0)
precondition(scroll.contentView.bounds.minX != beforeHorizontal && canvas.scale == zoomAfterWheel)
let heightBeforeWheel = canvas.keyHeight
wheel(0, 1, flags: .maskCommand)
precondition(canvas.keyHeight > heightBeforeWheel && canvas.scale == zoomAfterWheel)
precondition(MIDINote.label(pitch: 63, velocity: 96) == "D#4 - 96")
print("MIDI_PIANO_WHEEL_ZOOM_HORIZONTAL_SCROLL_AND_OPTION_VERTICAL_OK")

clip = AudioClip(id: UUID(), name: "Note height", startTime: 0, duration: 8, midi: MIDIItem())
selected = []
canvas.update(clip: clip, selected: selected, scale: 100, keyHeight: 26, cursor: 0, width: 900)
scroll.contentView.scroll(to: CGPoint(x: 0, y: 1500))
window.contentView?.layoutSubtreeIfNeeded()
canvas.creationVelocity = 73
let notePoint = CGPoint(x: 64 + 1.2 * 100, y: 24 + CGFloat(127 - 61) * 26 + 13)
func noteEvent(_ type: NSEvent.EventType, clicks: Int = 2) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: canvas.convert(notePoint, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
        clickCount: clicks, pressure: 1)!
}
canvas.mouseDown(with: noteEvent(.leftMouseDown)); canvas.mouseUp(with: noteEvent(.leftMouseUp))
precondition(clip.midi!.notes.count == 1 && clip.midi!.notes[0].pitch == 61 && clip.midi!.notes[0].velocity == 73)
let origin = canvas.rescaledOrigin(CGPoint(x: 100, y: 900), viewportHeight: 416, previousScale: 200, previousHeight: 18)
precondition(abs(origin.x - 50) < 1e-9 && abs((origin.y + 196) / 26 - (900 + 196) / 18) < 1e-9,
             "Changing zoom and note height preserves the time at the left edge and the pitch at the center")
print("MIDI_PIANO_CREATION_VELOCITY_AND_VERTICAL_SCALE_OK")

let viewport = canvas.visibleRect
let cursorPoint = CGPoint(x: viewport.minX + 350, y: viewport.minY + 70)
let hover = NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(cursorPoint, to: nil),
    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
    eventNumber: 1, clickCount: 0, pressure: 0)!
precondition(canvas.pointerCursor(at: cursorPoint) === NSCursor.crosshair)
precondition(canvas.pointerCursor(at: CGPoint(x: viewport.minX + 4, y: cursorPoint.y)) === NSCursor.arrow)
canvas.updateTrackingAreas()
let tracking = canvas.trackingAreas.last!
canvas.updateTrackingAreas()
precondition(canvas.trackingAreas.contains { $0 === tracking }, "Layout updates must preserve the mouse exit tracking area")
canvas.mouseMoved(with: hover)
precondition(NSCursor.current === NSCursor.crosshair)
canvas.mouseExited(with: hover)
precondition(NSCursor.current === NSCursor.arrow, "Leaving the grid restores the arrow while the editor stays open")
canvas.mouseMoved(with: hover)
NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
precondition(NSCursor.current === NSCursor.arrow, "Changing the active window releases the grid cursor")
canvas.isEditable = false
precondition(canvas.pointerCursor(at: cursorPoint) === NSCursor.arrow)
print("MIDI_PIANO_CURSOR_TRACKING_EXIT_WINDOW_FOCUS_AND_READ_ONLY_OK")


let melodic = InstrumentParameters()
let drums = InstrumentParameters(drums: true)
precondition(melodic.release == 0.16 && drums.release == 20)
var custom = InstrumentParameters()
custom.release = 0.72
let reopened = try JSONDecoder().decode(InstrumentParameters.self, from: JSONEncoder().encode(custom))
precondition(reopened.release == 0.72)
print("NATIVE_INSTRUMENT_DEFAULT_160MS_RELEASE_AND_DRUMS_AND_SAVED_VALUES_OK")
window.close()
