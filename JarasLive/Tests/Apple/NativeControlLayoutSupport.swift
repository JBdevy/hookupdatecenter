import SwiftUI
// Original opacity-based blinking was transparent to layout. Cadence and
// interaction are tested separately by NativeControlPulseTests.
private struct BaselineJarasBlink: ViewModifier {
 let active: Bool; var interval = 0.5; var lowOpacity = 0.4
 func body(content: Content) -> some View { content.opacity(1) }
}
// Before native hosting, Save's opacity animation also preserved its natural
// width and height. Keep that sizing contract independently of git HEAD.
private struct BaselineJarasSavePulse: ViewModifier {
 let active: Bool
 func body(content: Content) -> some View { content.opacity(1) }
}
enum GeometryCommand {case playStop,subPlayStop,toggleTeleprompter,toggleVideo}
final class ControlMappings {static let shared=ControlMappings();func shortcutHelp(_ c:GeometryCommand)->String{"help"};func begin(track:UUID?,command:String){}}
@MainActor final class ShowPresentationObserver:ObservableObject {}
@MainActor extension ShowController {
 var presentationObserver:ShowPresentationObserver {ShowPresentationObserver()}
 var current: Song? {snapshot.project.songs.first}
 var tempoControlBPM:Double {120}
 func tapTempo() {}; func resetTapTempo() {};func adjustTempo(_ d:Double){};func setMeterBeats(_ d:Int){};func setMeterUnit(_ d:Int){};func setTempo(_ d:Double){}
}
struct GeometrySubPlay {var playing=false}
struct GeometryTransport {var playing=true;var subPlay=GeometrySubPlay()}
@MainActor final class TrackRecording:ObservableObject {static let shared=TrackRecording();@Published var recording=false;@Published var busy=false;func toggle(show:ShowController){}}
@MainActor final class TeleprompterWindow:ObservableObject {
 static let shared=TeleprompterWindow();static let second=TeleprompterWindow()
 @Published var visible=false;@Published var previewActive=false;var previewPage=0
 func toggle(show:ShowController){};func showSettings(){};func showRemote(show:ShowController,directory:URL?){};func togglePreview(){};func selectPreviewPage(_ i:Int){}
}
final class TPNoticeController {static let shared=TPNoticeController();func open(){}}
@MainActor final class VideoPlayback:ObservableObject {static let shared=VideoPlayback();@Published var visible=false;var stretch=false;func toggle(){};func setStretch(_ b:Bool){}}
@MainActor final class DAWRemoteSession:ObservableObject {static let shared=DAWRemoteSession();@Published var enabled=false;@Published var connected=false;func setHostEnabled(_ b:Bool){}}
@MainActor enum DAWRemoteHostBridge {static func bind(_ show:ShowController){}}
struct DAWRemoteHostView:View {var body:some View{Text("Settings")}}
@MainActor final class TeleprompterTimerController:ObservableObject {
 static let shared=TeleprompterTimerController();@Published var targetSeconds=300.0;@Published var mode="timer";@Published var running=false;var targetText="00:05:00"
 func displayText()->String{targetText};func expired()->Bool{false};func displayOpacity()->Double{1};func showConfiguration(){};func stopAndReset(){};func start(){};func setTargetText(_ s:String)->Bool{true}
}
