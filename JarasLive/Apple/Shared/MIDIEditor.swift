#if os(macOS)
import SwiftUI
import AppKit

@MainActor final class MIDIEditorWindows: NSObject, NSWindowDelegate {
    static let shared = MIDIEditorWindows()
    private var windows: [UUID: NSWindow] = [:]
    func open(show: ShowController, item: UUID) {
        guard let song = show.current, song.tracks.contains(where: { $0.clips.contains { $0.id == item && $0.midi != nil } }) else { return }
        if let window = windows[item] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: CGRect(x: 120, y: 160, width: 980, height: 610), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "CatLive — Piano Roll"; window.minSize = CGSize(width: 760,height: 440)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: MIDIEditor(show: show, project: show.snapshot.project.id, item: item, close: { [weak window] in window?.close() }))
        windows[item] = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

private struct MIDIEditor: View {
    @ObservedObject var show: ShowController
    let project: UUID
    let item: UUID
    let close: () -> Void
    @State private var selected = Set<UUID>()
    @State private var scale = 100.0
    @State private var strength = 1.0
    @State private var quantizeLengths = false
    @State private var quantizeOpen = false
    @State private var velocity = 100
    @State private var channel = 0
    private var row: Track? { show.current?.tracks.first { $0.clips.contains { $0.id == item } } }
    private var clip: AudioClip? { row?.clips.first { $0.id == item } }
    private func gridBinding<T>(_ key: WritableKeyPath<MIDIGrid,T>, _ fallback: T) -> Binding<T> {
        Binding(get: { clip?.midi?.grid[keyPath: key] ?? fallback }, set: { value in
            guard var midi = clip?.midi else { return }; midi.grid[keyPath:key] = value; show.setMIDIItem(item,midi:midi)
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            if let clip, let midi = clip.midi {
                let visibleNotes = midi.notes.filter { channel == 0 || $0.channel == channel }
                let visibleSelection = selected.intersection(visibleNotes.map(\.id))
                let quantizeTargets = visibleSelection.isEmpty ? Set(visibleNotes.map(\.id)) : visibleSelection
                HStack(spacing: 10) {
                    Image(systemName: "pianokeys").foregroundStyle(JarasTheme.green)
                    Text(row?.name ?? "MIDI").fontWeight(.semibold).lineLimit(1)
                    Text(clip.name).foregroundStyle(JarasTheme.secondary).lineLimit(1)
                    Spacer()
                    Button("FX da pista") { if let row { FXWindows.shared.open(show: show, track: row.id, effect: "Chain", language: UserDefaults.standard.string(forKey:"jaras.language") ?? "pt") } }
                    Button { show.undo() } label: { Image(systemName:"arrow.uturn.backward") }.help("Desfazer")
                    Button { show.redo() } label: { Image(systemName:"arrow.uturn.forward") }.help("Refazer")
                    Button(show.snapshot.transport.playing ? "Pausar" : "Play") { show.send(show.snapshot.transport.playing ? .pause : .play) }
                }.padding(10)
                Divider()
                HStack(spacing: 12) {
                    Picker("Grade",selection:gridBinding(\.division,16)) { ForEach(MIDIGrid.divisions,id:\.self) { Text($0 == 1 ? "1" : "1/\($0)").tag($0) } }.frame(width:120)
                    Picker("",selection:gridBinding(\.mode,.straight)) { ForEach(MIDIGridMode.allCases,id:\.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width:108)
                    if midi.grid.mode == .swing {
                        Slider(value:gridBinding(\.swing,0.5),in:0...0.95).frame(width:85)
                        Text("\(Int(midi.grid.swing*100))%").monospacedDigit().frame(width:36)
                    }
                    Button("Quantizar…") { quantizeOpen = true }.disabled(visibleNotes.isEmpty).popover(isPresented:$quantizeOpen) {
                        VStack(alignment:.leading,spacing:12) {
                            Text(channel == 0 && visibleSelection.isEmpty ? "Quantizar todas as notas" : "Quantizar \(quantizeTargets.count) notas").font(.headline)
                            HStack { Text("Força"); Slider(value:$strength,in:0...1); Text("\(Int(strength*100))%").monospacedDigit().frame(width:38) }
                            Toggle("Quantizar também o final das notas",isOn:$quantizeLengths)
                            HStack { Button("Cancelar") { quantizeOpen = false }; Spacer(); Button("Aplicar") {
                                var next=midi; next.notes=midi.grid.quantize(midi.notes,selected:quantizeTargets,strength:strength,lengths:quantizeLengths)
                                show.setMIDIItem(item,midi:next); quantizeOpen=false
                            }.keyboardShortcut(.defaultAction) }
                        }.padding(16).frame(width:320)
                    }
                    Spacer()
                    Text("Zoom"); Slider(value:$scale,in:24...360).frame(width:110)
                }.padding(.horizontal,10).padding(.vertical,8)
                MIDIPianoRoll(clip:clip,selected:$selected,scale:scale,velocity:velocity,channel:max(1,channel),channelFilter:channel,
                    cursor:show.snapshot.transport.position, enabled:show.canExecute(),
                    segments:show.current?.tempoAudioSegments(clip) ?? [clip],
                    commit:{ notes in var next=midi; next.notes=notes; show.setMIDIItem(item,midi:next) },
                    seek:{ show.send(show.snapshot.transport.playing ? .seek : .editSeek,value:$0) },
                    undo:{ show.undo() },redo:{ show.redo() })
                    .jarasHelp("Click the ruler to set the playback position")
                HStack(spacing:10) {
                    Text("Shift: mover e redimensionar sem encaixe").foregroundStyle(JarasTheme.secondary)
                    Spacer()
                    Text("Velocity")
                    Stepper(value:$velocity,in:1...127) { Text("\(velocity)").monospacedDigit().frame(width:30) }.frame(width:75)
                    Button("Aplicar") { var next=midi; for i in next.notes.indices where visibleSelection.contains(next.notes[i].id) { next.notes[i].velocity=velocity }; show.setMIDIItem(item,midi:next) }.disabled(visibleSelection.isEmpty)
                    Picker(selection:$channel) {
                        Text(verbatim:JarasLocalization.string("All channels")).tag(0)
                        ForEach(1...16,id:\.self) { Text("\($0)").tag($0) }
                    } label: { Text(verbatim:JarasLocalization.string("Channel")) }
                        .frame(width:132).jarasHelp("Show notes from all channels or only the selected channel")
                    Text(channel == 0 ? "\(midi.notes.count) notas" : "\(visibleNotes.count)/\(midi.notes.count) notas").foregroundStyle(JarasTheme.secondary)
                }.font(.caption).padding(10)
                if row?.fx?.instrumentKeys.isEmpty != false && row?.fx?.externalPlugins?.isEmpty != false {
                    Text("Escolha um instrumento no FX da pista para ouvir as notas.").font(.caption).foregroundStyle(JarasTheme.secondary).padding(.bottom,7)
                }
            } else { Text("O item MIDI foi removido.").padding(); Button("Fechar",action:close) }
        }.background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .onChange(of:channel) { value in
                selected.formIntersection((clip?.midi?.notes ?? []).filter { value == 0 || $0.channel == value }.map(\.id))
            }
            .onChange(of:show.snapshot.project.id) { if $0 != project { close() } }
    }
}

private struct MIDIPianoRoll: NSViewRepresentable {
    let clip: AudioClip
    @Binding var selected: Set<UUID>
    let scale: Double
    let velocity: Int
    let channel: Int
    let channelFilter: Int
    let cursor: Double
    let enabled: Bool
    let segments: [AudioClip]
    let commit: ([MIDINote]) -> Void
    let seek: (Double) -> Void
    let undo: () -> Void
    let redo: () -> Void
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=MIDIPianoScrollView(); scroll.hasHorizontalScroller=true; scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true
        scroll.backgroundColor=NSColor(JarasTheme.background); scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        let canvas=MIDIPianoCanvas(); scroll.documentView=canvas
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let canvas=scroll.documentView as? MIDIPianoCanvas else{return}
        canvas.commit=commit; canvas.selectionChanged={ selected=$0 };canvas.undoEdit=undo;canvas.redoEdit=redo;canvas.seek=seek
        canvas.velocity=velocity;canvas.channel=channel;canvas.channelFilter=channelFilter;canvas.isEditable=enabled
        canvas.update(clip:clip,selected:selected,scale:scale,cursor:cursor,width:scroll.contentSize.width,segments:segments)
        if !canvas.initialScroll, let scroll=scroll as? MIDIPianoScrollView {
            let pitches=canvas.visibleNotes.map(\.pitch)
            scroll.initialPitch=CGFloat((pitches.min() ?? 60)+(pitches.max() ?? 60))/2
            scroll.needsLayout=true
        }
    }
}

/// Wait for the actual viewport before centering; SwiftUI's first update can be zero-sized.
private final class MIDIPianoScrollView: NSScrollView {
    var initialPitch: CGFloat?
    private var drawnBounds=CGRect.null
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if drawnBounds != clipView.bounds {
            drawnBounds=clipView.bounds
            documentView?.needsDisplay=true // Keyboard/ruler stay pinned while content scrolls.
        }
    }
    override func layout() {
        super.layout()
        guard let pitch=initialPitch, contentSize.height>40,
              let canvas=documentView as? MIDIPianoCanvas, !canvas.initialScroll else { return }
        initialPitch=nil; canvas.initialScroll=true
        let center=canvas.rulerHeight+(127-pitch)*canvas.keyHeight+canvas.keyHeight/2
        contentView.scroll(to:CGPoint(x:0,y:max(0,center-contentSize.height/2)))
        reflectScrolledClipView(contentView)
        canvas.needsDisplay=true
    }
}

/// A single native canvas: dragging notes never rebuilds a SwiftUI view tree.
final class MIDIPianoCanvas: NSView {
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    let keyHeight:CGFloat=18, keyboardWidth:CGFloat=64, rulerHeight:CGFloat=24
    var initialScroll=false
    var isEditable=true
    var velocity=100, channel=1
    var channelFilter=0 {
        didSet {
            guard channelFilter != oldValue else { return }
            if edit != nil { notes=originals;edit=nil;box=nil }
            selected.formIntersection(visibleNotes.map(\.id));needsDisplay=true
        }
    }
    var commit:([MIDINote])->Void={_ in}
    var seek:(Double)->Void={_ in}
    var selectionChanged:(Set<UUID>)->Void={_ in}
    var undoEdit:()->Void={}, redoEdit:()->Void={}
    private(set) var notes:[MIDINote]=[]
    var visibleNotes:[MIDINote] { channelFilter == 0 ? notes : notes.filter { $0.channel == channelFilter } }
    private var selected=Set<UUID>(), scale:CGFloat=100, grid=MIDIGrid(), sourceStart=0.0, sourceEnd=16.0, cursorBeat=0.0
    private var dragOrigin=CGPoint.zero, originals:[MIDINote]=[], edit:Edit?, box:CGRect?
    private var sourceBPM=120.0, playbackSegments:[AudioClip]=[]
    private var rulerPress:CGPoint?, rulerDragged=false
    private enum Edit { case create(UUID),move(UUID),left(UUID),right(UUID),select }
    func update(clip:AudioClip,selected:Set<UUID>,scale:Double,cursor:Double,width:CGFloat,segments:[AudioClip] = []) {
        guard let midi=clip.midi else{return}
        if edit == nil { notes=midi.notes; self.selected=selected.intersection(visibleNotes.map(\.id)) }
        self.scale=scale;grid=midi.grid
        sourceBPM=midi.sourceBPM;playbackSegments=segments.isEmpty ? [clip] : segments
        sourceStart=clip.sourceOffset*midi.sourceBPM/60
        sourceEnd=sourceStart+clip.duration*clip.audioRate*midi.sourceBPM/60
        cursorBeat=sourceStart+(cursor-clip.startTime)*clip.audioRate*midi.sourceBPM/60
        if let last=segments.last { sourceEnd=(last.sourceOffset+last.duration*last.audioRate)*midi.sourceBPM/60 }
        if let active=segments.last(where:{$0.startTime<=cursor}) ?? segments.first {
            cursorBeat=(active.sourceOffset+(cursor-active.startTime)*active.audioRate)*midi.sourceBPM/60
        }
        let end=max(sourceEnd,midi.notes.map(\.end).max() ?? 0)
        setFrameSize(CGSize(width:max(width,keyboardWidth+CGFloat(end+4)*scale),height:128*keyHeight+rulerHeight))
        needsDisplay=true
    }
    private func point(_ event:NSEvent)->CGPoint { convert(event.locationInWindow,from:nil) }
    private func beat(_ p:CGPoint)->Double { max(0,Double((p.x-keyboardWidth)/scale)) }
    private func pitch(_ p:CGPoint)->Int { min(127,max(0,127-Int((p.y-rulerHeight)/keyHeight))) }
    private func rect(_ n:MIDINote)->CGRect { CGRect(x:keyboardWidth+CGFloat(n.start)*scale,y:rulerHeight+CGFloat(127-n.pitch)*keyHeight+1,width:max(2,CGFloat(n.length)*scale),height:keyHeight-2) }
    private var rulerRect:CGRect { CGRect(x:visibleRect.minX+keyboardWidth,y:visibleRect.minY,width:max(0,visibleRect.width-keyboardWidth),height:rulerHeight) }
    private func seekFromRuler(_ point:CGPoint,free:Bool) {
        guard let first=playbackSegments.first,let last=playbackSegments.last,sourceBPM>0 else{return}
        let source=grid.snap(beat(point),bypass:free)*60/sourceBPM
        let bounded=min(last.sourceOffset+last.duration*last.audioRate,max(first.sourceOffset,source))
        guard let segment=playbackSegments.last(where:{$0.sourceOffset<=bounded}) ?? playbackSegments.first,
              segment.audioRate>0 else{return}
        let position=min(segment.startTime+segment.duration,max(segment.startTime,segment.startTime+(bounded-segment.sourceOffset)/segment.audioRate))
        guard position.isFinite else{return}
        cursorBeat=bounded*sourceBPM/60;seek(position);needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        let visible=visibleRect
        NSColor(JarasTheme.background).setFill();dirtyRect.fill()
        let first=max(0,Int((visible.minY-rulerHeight)/keyHeight)),last=min(127,Int((visible.maxY-rulerHeight)/keyHeight))
        if first<=last {for row in first...last {
            let note=127-row,black=[1,3,6,8,10].contains(note%12), y=rulerHeight+CGFloat(row)*keyHeight
            NSColor(white:black ? 0.105:0.145,alpha:1).setFill();CGRect(x:keyboardWidth,y:y,width:bounds.width-keyboardWidth,height:keyHeight).fill()
            NSColor(white:note%12==0 ? 0.32:0.20,alpha:1).setFill();CGRect(x:keyboardWidth,y:y+keyHeight-0.5,width:bounds.width-keyboardWidth,height:0.5).fill()
        }}
        let a=max(0,Int(beat(CGPoint(x:visible.minX,y:0))/grid.step)-2),b=max(a,Int(beat(CGPoint(x:visible.maxX,y:0))/grid.step)+2)
        let strideValue=max(1,Int(ceil(4/(grid.step*Double(scale)))))
        for i in stride(from:a,through:b,by:strideValue) {
            let beat=grid.line(i),x=keyboardWidth+CGFloat(beat)*scale
            let bar=abs(beat/4-(beat/4).rounded())<0.000001
            NSColor(JarasTheme.green).withAlphaComponent(bar ? 0.48:0.18).setFill()
            CGRect(x:x,y:visible.minY,width:bar ? 1:0.5,height:visible.height).fill()
        }
        for note in visibleNotes {let r=rect(note);guard r.intersects(visible) else{continue}
            NSColor(JarasTheme.green).withAlphaComponent(selected.contains(note.id) ? 1:0.55+Double(note.velocity)/127*0.25).setFill()
            NSBezierPath(roundedRect:r,xRadius:2,yRadius:2).fill()
            if selected.contains(note.id) {NSColor.white.setStroke();let border=NSBezierPath(rect:r.insetBy(dx:0.5,dy:0.5));border.lineWidth=1;border.stroke()}
            if r.width>30 {("\(note.pitch)" as NSString).draw(at:CGPoint(x:r.minX+4,y:r.minY+1),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.black])}
        }
        // Trim boundaries and transport cursor share the same source transform.
        for (value,color) in [(sourceStart,NSColor.yellow),(sourceEnd,NSColor.yellow),(cursorBeat,NSColor(JarasTheme.green))] {
            let x=keyboardWidth+CGFloat(value)*scale;color.setFill();CGRect(x:x,y:visible.minY,width:1,height:visible.height).fill()
        }
        if let box {NSColor(JarasTheme.green).withAlphaComponent(0.15).setFill();box.fill();NSColor(JarasTheme.green).setStroke();NSBezierPath(rect:box).stroke()}
        // Pin keyboard and ruler inside the native scroll viewport.
        NSColor(white:0.12,alpha:1).setFill();CGRect(x:visible.minX,y:visible.minY,width:keyboardWidth,height:visible.height).fill()
        if first<=last {for row in first...last {
            let note=127-row,black=[1,3,6,8,10].contains(note%12),y=rulerHeight+CGFloat(row)*keyHeight
            NSColor(white:black ? 0.10:0.78,alpha:1).setFill();CGRect(x:visible.minX,y:y,width:keyboardWidth-1,height:keyHeight-1).fill()
            if note%12==0 {("C\(note/12-1)" as NSString).draw(at:CGPoint(x:visible.minX+32,y:y+2),withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor.black])}
        }}
        NSColor(white:0.09,alpha:1).setFill();CGRect(x:visible.minX,y:visible.minY,width:visible.width,height:rulerHeight).fill()
        let firstBeat=max(0,Int(beat(CGPoint(x:visible.minX+keyboardWidth,y:0))/4)*4)
        for value in stride(from:firstBeat,through:Int(beat(CGPoint(x:visible.maxX,y:0)))+4,by:4) {
            let x=keyboardWidth+CGFloat(value)*scale
            if x>=visible.minX+keyboardWidth {("\(value/4+1)" as NSString).draw(at:CGPoint(x:x+3,y:visible.minY+5),withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor(JarasTheme.green)])}
        }
        let cursorX=keyboardWidth+CGFloat(cursorBeat)*scale
        if cursorX>=rulerRect.minX,cursorX<=rulerRect.maxX {
            NSColor(JarasTheme.green).setFill()
            let head=NSBezierPath();head.move(to:CGPoint(x:cursorX-5,y:visible.minY));head.line(to:CGPoint(x:cursorX+5,y:visible.minY));head.line(to:CGPoint(x:cursorX,y:visible.minY+7));head.close();head.fill()
        }
    }
    override func mouseDown(with event:NSEvent) {
        guard isEditable else { return }
        window?.makeFirstResponder(self)
        let p=point(event)
        if rulerRect.contains(p) { rulerPress=p;rulerDragged=false;return }
        guard p.x>=visibleRect.minX+keyboardWidth,p.y>=visibleRect.minY+rulerHeight else{return}
        dragOrigin=p; originals=notes
        if let n=visibleNotes.reversed().first(where:{rect($0).contains(p)}) {
            if event.modifierFlags.contains(.command) {if selected.contains(n.id){selected.remove(n.id)}else{selected.insert(n.id)}}
            else if !selected.contains(n.id) {selected=[n.id]}
            let r=rect(n),edge=min(6,r.width/3)
            edit=p.x<=r.minX+edge ? .left(n.id):p.x>=r.maxX-edge ? .right(n.id):.move(n.id)
        } else {
            let n=MIDINote(start:grid.snap(beat(p),bypass:event.modifierFlags.contains(.shift)),length:grid.step,pitch:pitch(p),velocity:velocity,channel:channelFilter == 0 ? channel : channelFilter)
            notes.append(n);selected=[n.id];edit = .create(n.id)
        }
        selectionChanged(selected);needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent) {
        if let press=rulerPress {
            let p=point(event)
            if abs(p.x-press.x)>3 || abs(p.y-press.y)>3 { rulerDragged=true }
            return
        }
        guard let edit else{return};autoscroll(with:event)
        let p=point(event),free=event.modifierFlags.contains(.shift),minimum=1.0/960
        switch edit {
        case .create(let id):
            if let i=notes.firstIndex(where:{$0.id==id}) {notes[i].length=max(minimum,grid.snap(beat(p),bypass:free)-notes[i].start);notes[i].pitch=pitch(p)}
        case .move(let id),.left(let id),.right(let id):
            guard let anchor=originals.first(where:{$0.id==id}) else{return}
            let raw=Double((p.x-dragOrigin.x)/scale)
            let isRight:Bool;if case .right=edit {isRight=true}else{isRight=false}
            let base=isRight ? anchor.end:anchor.start
            var delta=grid.snap(base+raw,bypass:free)-base
            let chosen=originals.filter{selected.contains($0.id)}
            if case .move=edit {
                delta=max(delta,-(chosen.map(\.start).min() ?? 0))
                let pitchDelta=min(127-(chosen.map(\.pitch).max() ?? 127),max(-(chosen.map(\.pitch).min() ?? 0),pitch(p)-pitch(dragOrigin)))
                notes=originals.map { n in var v=n;if selected.contains(n.id){v.start+=delta;v.pitch+=pitchDelta};return v }
            } else if case .left=edit {
                delta=max(-(chosen.map(\.start).min() ?? 0),min(delta,(chosen.map(\.length).min() ?? 0)-minimum))
                notes=originals.map { n in var v=n;if selected.contains(n.id){v.start+=delta;v.length-=delta};return v }
            } else {
                delta=max(delta,minimum-(chosen.map(\.length).min() ?? minimum))
                notes=originals.map { n in var v=n;if selected.contains(n.id){v.length+=delta};return v }
            }
        case .select:
            box=CGRect(x:min(p.x,dragOrigin.x),y:min(p.y,dragOrigin.y),width:abs(p.x-dragOrigin.x),height:abs(p.y-dragOrigin.y))
            selected=Set(visibleNotes.filter{rect($0).intersects(box!)}.map(\.id));selectionChanged(selected)
        }
        needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        if let press=rulerPress {
            defer { rulerPress=nil;rulerDragged=false }
            let p=point(event)
            if isEditable,!rulerDragged,abs(p.x-press.x)<=3,abs(p.y-press.y)<=3,rulerRect.contains(p) {
                seekFromRuler(p,free:event.modifierFlags.contains(.shift))
            }
            return
        }
        if edit != nil,notes != originals {commit(notes)};edit=nil;box=nil;needsDisplay=true
    }
    override func rightMouseDown(with event:NSEvent) {
        let p=point(event)
        guard isEditable,p.x>=visibleRect.minX+keyboardWidth,p.y>=visibleRect.minY+rulerHeight else{return}
        window?.makeFirstResponder(self);dragOrigin=p;originals=notes;edit = .select;selected=[];selectionChanged(selected)
    }
    override func rightMouseDragged(with event:NSEvent) {mouseDragged(with:event)}
    override func rightMouseUp(with event:NSEvent) {edit=nil;box=nil;needsDisplay=true}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p=point(event)
        if rulerRect.contains(p) { NSCursor.pointingHand.set();return }
        if let note=visibleNotes.reversed().first(where:{rect($0).contains(p)}) {
            let r=rect(note), edge=min(6,r.width/3)
            (p.x<=r.minX+edge || p.x>=r.maxX-edge ? NSCursor.resizeLeftRight : NSCursor.openHand).set()
        } else { NSCursor.crosshair.set() }
    }
    override func mouseExited(with event:NSEvent) {NSCursor.arrow.set()}
    override func keyDown(with event:NSEvent) {
        guard isEditable else { return }
        if event.keyCode==51 || event.keyCode==117 {
            let before=notes
            notes.removeAll{selected.contains($0.id) && (channelFilter == 0 || $0.channel == channelFilter)}
            selected=[];selectionChanged(selected);if notes != before {commit(notes)};needsDisplay=true;return
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":selected=Set(visibleNotes.map(\.id));selectionChanged(selected);needsDisplay=true;return
            case "z":if event.modifierFlags.contains(.shift){redoEdit()}else{undoEdit()};return
            default:break
            }
        }
        if event.keyCode==53,rulerPress != nil {rulerPress=nil;rulerDragged=false;return}
        if event.keyCode==53, edit != nil {notes=originals;edit=nil;box=nil;needsDisplay=true;return}
        super.keyDown(with:event)
    }
}
#endif
