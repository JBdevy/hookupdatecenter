import SwiftUI
import UIKit
struct DAWRemoteState {
 struct Track: Equatable, Identifiable {
  let id:UUID;var name:String;var mute=false;var solo=false;var pan=0.0;var volume=1.0
  var color:UInt32=0x338855;var nameColor:UInt32?=0xffffff;var emphasized:Bool?=false;var silenced:Bool?=false
  var canMeter:Bool?=true;var linkedTrack:UUID?=nil;var peakDB:Double? = -6
  func hasSameMixerControls(as other:Self)->Bool{self==other}
 }
}
enum DAWRemoteCommand { enum Action:String { case pan,volume,mute,solo,resetMeterPeak,tempo,pitch } }
enum TrackKind { case standard,click,chords;var isText:Bool{self == .chords};var isTeleprompter:Bool{false} }
struct Track {let id:UUID;var kind:TrackKind = .standard}
struct Song {var tracks:[Track]}
@MainActor final class ShowController {var current:Song?;init(_ tracks:[Track]){current=Song(tracks:tracks)};func insertClickItems(track:UUID){TouchProbe.shared.log("insert")};var canDrop:Bool{true};func canDropTrack(_ source:UUID,on target:UUID,after:Bool)->Bool{source != target};func dropTrack(_ source:UUID,on target:UUID,before:UUID?){TouchProbe.shared.log("reorder")}}
@MainActor final class TouchProbe:ObservableObject {
 static let shared=TouchProbe();@Published var event="none";@Published var selection=0;@Published var editing=false
 @Published var muted=false;@Published var solo=false
 func log(_ value:String){event=value}
}
struct TrackRecordButton:View {let show:ShowController;let track:Track;var body:some View{Button("REC"){TouchProbe.shared.log("rec")}.buttonStyle(.bordered)}}
enum JarasTheme {static let text=Color.white,green=Color.green,yellow=Color.yellow,mixer=Color(white:0.2)}
func remoteColor(_ color:UInt32)->Color{.white}
enum TrackNameContrast{static func components(_ color:UInt32,emphasized:Bool)->(red:Double,green:Double,blue:Double){(0.2,0.5,0.3)}}
struct GroupTrackConnector:Shape {let last:Bool;func path(in r:CGRect)->Path{Path{p in p.move(to:.zero);p.addLine(to:CGPoint(x:0,y:r.height));p.addLine(to:CGPoint(x:r.width,y:r.height))}}}
@MainActor final class StemAudioPlayback {static let shared=StemAudioPlayback();func meter(for id:UUID)->Int{0}}
struct IpadMixerMeter:View {let meter:Int;var body:some View{Color.green.allowsHitTesting(false)}}
enum DAWRemoteFaderScale {static func decibels(_ gain:Double)->Double{gain>0 ? 20*log10(gain) : -60};static func gain(_ db:Double)->Double{pow(10,db/20)}}
enum JarasLocalization {static func string(_ key:String)->String{key}}

// PRODUCTION_ROW_CODE
@main struct TouchFixtureApp:App {var body:some Scene{WindowGroup{TouchFixtureView()}}}
struct TouchFixtureView:View {
 @ObservedObject var probe=TouchProbe.shared
 @StateObject private var reordering=IpadTrackReorderController()
 let id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
 let click=UUID(uuidString:"00000000-0000-0000-0000-000000000002")!
 let text=UUID(uuidString:"00000000-0000-0000-0000-000000000003")!
 var body:some View {
 let show=ShowController([Track(id:id),Track(id:click,kind:.click),Track(id:text,kind:.chords)])
 VStack {
  RemoteStepFixture()
  Button(probe.editing ? "Done" : "Edit"){probe.editing.toggle()}.accessibilityIdentifier("edit")
  Text(probe.event).accessibilityIdentifier("event")
  Text("Selected: \(probe.selection)").accessibilityIdentifier("selection")
  ScrollView {
   VStack(spacing:12){
    RemoteNativeMixerRow(track:.init(id:id,name:"Normal track",mute:probe.muted,solo:probe.solo),project:id,song:nil,
     number:1,local:true,localShow:show,editing:probe.editing,selected:probe.selection>0,
     select:{probe.selection+=1},selectionMenu:{probe.log("menu")},openPatch:{probe.log("patch")},openFX:{probe.log("fx")}){action,value in
      probe.log(action.rawValue);if action == .mute{probe.muted.toggle()};if action == .solo{probe.solo.toggle()}
    }.frame(width:450,height:90).modifier(IpadTrackReorderModifier(show:show,track:id,enabled:probe.editing,controller:reordering)).modifier(IpadTrackAudioContextMenu(enabled:!probe.editing,openPatch:{probe.log("context-patch")},addAudio:{probe.log("add-audio")})).accessibilityIdentifier("normal-row")
    RemoteNativeMixerRow(track:.init(id:click,name:"Click track"),project:id,song:nil,number:2,local:true,localShow:show,select:{probe.selection+=1}){action,_ in probe.log(action.rawValue)}.frame(width:450,height:90).accessibilityIdentifier("click-row")
    RemoteNativeMixerRow(track:.init(id:text,name:"Text track"),project:id,song:nil,number:3,local:true,localShow:show,select:{probe.selection+=1},addText:{probe.log("text")}){action,_ in probe.log(action.rawValue)}.frame(width:450,height:60)
    ForEach(0..<12){n in Text("Track \(n)").frame(width:450,height:90).background(Color.gray)}
   }
  }.frame(width:470,height:550)
 }.preferredColorScheme(.dark)
 }
}

struct StepFixtureState {var bpm=120.0;var pitchSemitones:Int?=0;var pitchRegion:UUID?=UUID()}
struct RemoteStepFixture:View {
 @State private var state=StepFixtureState()
 @State private var tempoStepPending=false
 @State private var pitchStepPending=false
 @State private var tempoRequests=0
 @State private var pitchRequests=0
 @State private var tempoRequested:Double?
 @State private var pitchRequested:Double?
 let local=true
 var body:some View {
  VStack{
   HStack{bpmControl;tunerControl}.frame(width:300)
   HStack{Text("Tempo requests: \(tempoRequests)").accessibilityIdentifier("tempo-requests");Text("Pitch requests: \(pitchRequests)").accessibilityIdentifier("pitch-requests")}
   Button("Apply values") {if let value=tempoRequested{state.bpm=value};if let value=pitchRequested{state.pitchSemitones=Int(value)}}
  }.onChange(of:state.bpm){_ in tempoStepPending=false}.onChange(of:state.pitchSemitones){_ in pitchStepPending=false}
 }
 private func action(_ command:DAWRemoteCommand.Action,target:UUID?=nil,value:Double){
  if command == .tempo{tempoRequests+=1;tempoRequested=value}else{pitchRequests+=1;pitchRequested=value}
 }
 // PRODUCTION_STEP_CONTROLS
}
