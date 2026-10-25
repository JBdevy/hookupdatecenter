import Foundation
import Combine
import Darwin

// The real session is extracted by test-catstem-session.sh. Only its renderer
// is held at a deterministic boundary, reproducing cancellation before cleanup.
final class AudioExportCancellation: @unchecked Sendable {
 private let lock=NSLock();private var value=false
 var cancelled:Bool{lock.lock();defer{lock.unlock()};return value}
 func cancel(){lock.lock();value=true;lock.unlock()}
}
enum ProjectError:Error{case invalid(String)}
enum Kind{case standard}
struct AudioClip{var id=UUID();var duration=1.0}
struct Track{var kind=Kind.standard;var clips:[AudioClip]=[]}
struct Song{var id=UUID();var tracks:[Track]=[]}
struct Project{var id=UUID()}
struct Snapshot{var project=Project()}
struct CatStemRequest{let project:Project;let song:Song;let track:Track;let clip:AudioClip;let directory:URL}
enum AudioSeparation{static func accepts(_ clip:AudioClip,on track:Track)->Bool{true}}
enum AudioDestinationSpace{
 static func availableBytes(at:URL)->Int64?{nil}
 static func confirm(at:URL)->Bool{true}
}
@MainActor final class ProjectDocuments:ObservableObject{
 var busy=false;var presentsOwnProgress=false;var status="Importing 1/1: previous.mp3"
 var showsBlockingProgress:Bool{busy && !presentsOwnProgress}
 var currentURL:URL?=URL(fileURLWithPath:"/tmp/test.jl")
}
@MainActor final class ShowController{
 var current:Song?;var snapshot=Snapshot();var insertions=0
 func canControl()->Bool{true}
 func insertSeparatedStems(_ tracks:[Track],song:UUID,sourceTrack:UUID,original:AudioClip,project:UUID)throws{insertions+=1}
}
// Track has an ID in the real model.
extension Track{var id:UUID{UUID(uuidString:"00000000-0000-0000-0000-000000000001")!}}
final class RenderBoundary:@unchecked Sendable{
 let ready=DispatchSemaphore(value:0);let finish=DispatchSemaphore(value:0)
 var fail=false
}
enum CatStemRenderer{
 static var boundary=RenderBoundary()
 static func interpreter(in runtime:URL)->URL{URL(fileURLWithPath:"/bin/sh")}
 static func run(_ request:CatStemRequest,runtime:URL,worker:URL,cancellation:AudioExportCancellation,progress:@escaping @Sendable(Double,String)->Void)throws->([URL],[Track]){
  let gate=boundary;gate.ready.signal();guard gate.finish.wait(timeout: .now()+5) == .success else{throw ProjectError.invalid("test timed out")}
  if cancellation.cancelled{throw CancellationError()};if gate.fail{throw ProjectError.invalid("render failed")}
  return ([],Array(repeating:Track(),count:5))
 }
}
// INSERT_SESSION

@main struct LifecycleRegression{
 @MainActor static func main()async throws{
  let resource=Bundle.main.resourceURL!.appendingPathComponent("StemSeparationRuntime")
  try FileManager.default.createDirectory(at:resource,withIntermediateDirectories:true)
  FileManager.default.createFile(atPath:resource.appendingPathComponent("5c90dfd2-34c22ccb.th").path,contents:Data([0]))
  let session=CatStemSession(),docs=ProjectDocuments(),show=ShowController()
  let request=CatStemRequest(project:show.snapshot.project,song:Song(),track:Track(),clip:AudioClip(),directory:resource)
  func waitUntilFinished()async throws{
   for _ in 0..<300{if !session.running{return};try await Task.sleep(nanoseconds:10_000_000)}
   fatalError("Cancelled operation did not finish cleanup")
  }
  session.start(request,show:show,documents:docs)
  precondition(session.running && docs.busy)
  precondition(!docs.showsBlockingProgress && docs.presentsOwnProgress && docs.status.isEmpty,
               "Separation must own progress without a stale import overlay disabling Cancel")
  session.cancel()
  precondition(!docs.busy,"Cancel must release transport/project admission before renderer cleanup")
  precondition(!docs.presentsOwnProgress,"Cancel must release dedicated progress ownership")
  docs.busy=true // Another operation was admitted after cancellation.
  precondition(docs.showsBlockingProgress,"Subsequent imports must retain their normal overlay")
  CatStemRenderer.boundary.finish.signal();try await waitUntilFinished()
  precondition(docs.busy,"Cancelled cleanup released another operation's busy state")
  precondition(show.insertions==0,"Cancelled separation modified the project")
  docs.busy=false;CatStemRenderer.boundary=RenderBoundary()
  session.start(request,show:show,documents:docs)
  precondition(docs.busy && session.running)
  CatStemRenderer.boundary.finish.signal();try await waitUntilFinished()
  precondition(!docs.busy && !docs.presentsOwnProgress && show.insertions==1 && session.progress==1)
  CatStemRenderer.boundary=RenderBoundary();CatStemRenderer.boundary.fail=true
  session.start(request,show:show,documents:docs)
  CatStemRenderer.boundary.finish.signal();try await waitUntilFinished()
  precondition(!docs.busy && !docs.presentsOwnProgress && !session.error.isEmpty && show.insertions==1)
  print("CATSTEM_SESSION_CANCEL_IMMEDIATE_ADMISSION_NO_STALE_RELEASE_NO_CANCELLED_COMMIT_SUCCESS_ERROR_OK")
 }
}
