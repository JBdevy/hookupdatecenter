import AppKit
import SwiftUI
import Combine
@testable import JarasApplication

@MainActor private final class Presentation { let objectWillChange = ObservableObjectPublisher() }
@MainActor private final class ShowController {
    var snapshot: ShowSnapshot
    var current: Song? { snapshot.project.songs.first }
    let projectPresentation = Presentation()
    init(_ project: Project) {
        snapshot = ShowSnapshot(project: project, transport: TransportState(playing:false,songId:project.songs[0].id,position:0,queue:QueueState(),loop:LoopState(enabled:false),subPlay:SubPlayState(playing:false,position:0)))
    }
    func rename(_ id: UUID, _ name: String) {
        let index = snapshot.project.songs[0].tracks.firstIndex { $0.id == id }!
        snapshot.project.songs[0].tracks[index].name = name
        projectPresentation.objectWillChange.send()
    }
}
@MainActor private final class NativeSidebarResizeActivity {
    static let shared = NativeSidebarResizeActivity()
    func contentDidChange() {}
}
private func mixerMetadata(_ source: Track) -> Track { var value = source; value.clips = []; value.heightScale = nil; return value }
private final class Label: NSView { var track: UUID?; var name = ""; var color: UInt32? }
private struct Probe: NSViewRepresentable {
    let track: Track
    func makeNSView(context: Context) -> Label { Label() }
    func updateNSView(_ view: Label, context: Context) { view.track = track.id; view.name = track.name; view.color = track.color }
}
private struct OriginalRetainedRow: View {
    @StateObject private var updates: TimelineMixerRowUpdates<Track>
    init(show: ShowController,track: Track,index: Int) {
        _updates = StateObject(wrappedValue: TimelineMixerRowUpdates(value:track,publisher:show.projectPresentation.objectWillChange) { [weak show] in show?.current?.tracks.first { $0.id == track.id } })
    }
    var body: some View { Probe(track:updates.value) }
}
private func labels(_ view: NSView) -> [Label] { (view as? Label).map { [$0] } ?? view.subviews.flatMap(labels) }
@MainActor private func run() {
_ = NSApplication.shared
var project = Project.empty(name:"Recycled mixer")
project.songs[0].tracks = (0..<120).map { index in Track(id:UUID(),name:"Track \(index)",role:.other,color:UInt32(index+1)) }
let show = ShowController(project)
let window = NSWindow(contentRect:NSRect(x:0,y:0,width:280,height:64),styleMask:[.titled],backing:.buffered,defer:false)
window.isReleasedWhenClosed = false
let host = NSHostingView(rootView:AnyView(Color.clear));window.contentView = host
func settle() { host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01));host.layoutSubtreeIfNeeded() }
func content(_ track: Track,_ index:Int,_ fixed:Bool) -> AnyView {
    if fixed { return AnyView(TimelineLiveMixerRow(show:show,track:track,index:index){Probe(track:$0)}.frame(width:280,height:64)) }
    return AnyView(OriginalRetainedRow(show:show,track:track,index:index).frame(width:280,height:64))
}
host.rootView = content(project.songs[0].tracks[0],0,false);settle()
host.rootView = content(project.songs[0].tracks[119],119,false);settle()
precondition(labels(host).first?.track == project.songs[0].tracks[0].id,"Baseline must reproduce the retained observer identity bug")
print("MIXER_REUSE_PREVIOUS_TRACK_OBSERVER_BUG_REPRODUCED")
var retainedControl: Label?
for index in [0,119,1,118,2,117,3,116,30,90,0,119] {
    let track = show.current!.tracks[index]
    host.rootView = content(track,index,true);settle()
    let label = labels(host).first!
    if let retainedControl { precondition(label === retainedControl,"Recycling must retain native controls") } else { retainedControl = label }
    precondition(label.track == track.id && label.name == track.name && label.color == track.color,"A recycled row showed another track's identity/name/color")
    show.rename(track.id,"Updated \(index)");settle()
    precondition(labels(host).first?.name == "Updated \(index)","Recycled observer did not subscribe to the new track")
    let other = index == 0 ? 119 : 0
    show.rename(show.current!.tracks[other].id,"Other \(other)");settle()
    precondition(labels(host).first?.track == track.id && labels(host).first?.name == "Updated \(index)","A previous track update leaked into the recycled row")
}
print("MIXER_RECYCLED_ROWS_KEEP_TRACK_NAMES_COLORS_AND_OBSERVATIONS_OK")
window.close()

}
MainActor.assumeIsolated { run() }
