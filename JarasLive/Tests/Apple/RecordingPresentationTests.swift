import Foundation
import Combine

@MainActor private final class RecordingPresentationHarness: ObservableObject {
    /* RECORDING_PROPERTIES */
    var reconciles = 0
    func reconcileArming() { reconciles += 1 }
    func mode(_ mode: RecordingArmState.Mode, _ tracks: Set<UUID>) { armState.set(mode, tracks: tracks) }
    /* RECORDING_SELECTION */
}

MainActor.assumeIsolated {
 let recorder=RecordingPresentationHarness();var count=0
 let token=recorder.objectWillChange.sink { count+=1 }
 let ids=(0..<145).map { _ in UUID() }
 for id in ids { recorder.selectionChanged([id]) }
 precondition(count==0 && recorder.reconciles==0)
 precondition(recorder.armState.selected==[ids.last!])
 recorder.mode(.manual,[ids[0]])
 precondition(count==1)
 recorder.selectionChanged([ids[1]])
 precondition(count==1 && recorder.reconciles==0 && recorder.armState.armed==[ids[0]])
 recorder.mode(.automatic,[ids[1],ids[2]])
 precondition(count==2 && recorder.armState.armed==[ids[0],ids[1]])
 recorder.selectionChanged([ids[2]])
 precondition(count==3 && recorder.reconciles==1 && recorder.armState.armed==[ids[0],ids[2]])
 recorder.selectionChanged([ids[2],ids[10]])
 precondition(count==3 && recorder.reconciles==1 && recorder.armState.selected==[ids[2],ids[10]])
 recorder.selectionChanged([])
 precondition(count==4 && recorder.reconciles==2 && recorder.armState.armed==[ids[0]])
 recorder.mode(.off,[ids[1],ids[2]])
 precondition(count==5)
 print("RECORDING_SELECTION_145_UNCHANGED_TRACKS_ZERO_PUBLICATIONS_AND_CAPTURE_RECONFIGURATIONS_OK")
 print("RECORDING_MANUAL_MODE_AUTOMATIC_HANDOFF_CLEAR_SELECTION_AND_OFF_PUBLICATIONS_OK")
 withExtendedLifetime(token){}
}
