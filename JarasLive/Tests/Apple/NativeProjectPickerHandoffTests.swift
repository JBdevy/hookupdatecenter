import Foundation
import Combine
@MainActor enum ProjectDocuments {
    enum NativePicker: CaseIterable { case storage, stems, package, packageDestination, trackAudio, trackMedia }
}
@MainActor private final class NativeProjectPickerSelection {
    let urls: [URL]
    let kind: ProjectDocuments.NativePicker
    init(urls: [URL], kind: ProjectDocuments.NativePicker) { self.urls = urls; self.kind = kind }
}
// PRODUCTION_HANDOFF
@main struct NativeProjectPickerHandoffTests {
    @MainActor static func main() {
        let url = URL(fileURLWithPath: "/tmp/selected-folder")
        func selected(_ result: NativeProjectPickerHandoff.Result?, kind: ProjectDocuments.NativePicker) {
            guard case .selected(let selection) = result else { fatalError("Missing selected folder") }
            precondition(selection.urls == [url] && selection.kind == kind)
        }
        for kind in ProjectDocuments.NativePicker.allCases {
            let normal = NativeProjectPickerHandoff(); normal.begin(kind)
            precondition(normal.selected([url], kind: kind) == nil, "Do not resume creation until Files has closed")
            selected(normal.didDismiss(), kind: kind)
            precondition(normal.didDismiss() == nil && normal.selected([url], kind: kind) == nil, "Selection delivered twice")
            let earlyDismiss = NativeProjectPickerHandoff(); earlyDismiss.begin(kind)
            precondition(earlyDismiss.didDismiss() == nil, "Dismissal alone must not cancel a pending selection")
            selected(earlyDismiss.selected([url], kind: kind), kind: kind)
            precondition(earlyDismiss.cancelled(kind) == nil, "Late dismissal/cancel erased the chosen folder")
            let cancel = NativeProjectPickerHandoff(); cancel.begin(kind)
            precondition(cancel.cancelled(kind) == nil)
            guard case .cancelled(let cancelledKind) = cancel.didDismiss() else { fatalError("Cancel not delivered") }
            precondition(cancelledKind == kind && cancel.didDismiss() == nil)
            cancel.begin(kind)
            precondition(cancel.didDismiss() == nil)
            selected(cancel.selected([url], kind: kind), kind: kind)
        }
        // Empty and REC Multitrack both retain their pending storage continuation.
        for operation in ["empty", "recording", "stems"] {
            let flow = NativeProjectPickerHandoff()
            let kind: ProjectDocuments.NativePicker = operation == "stems" ? .stems : .storage
            flow.begin(kind)
            var resumed = false, cancelled = false
            func deliver(_ result: NativeProjectPickerHandoff.Result?) {
                switch result { case .selected: resumed = true; case .cancelled: cancelled = true; case nil: break }
            }
            deliver(flow.didDismiss())
            precondition(!resumed && !cancelled, "Sheet dismissal cleared pending \(operation)")
            deliver(flow.selected([url], kind: kind))
            precondition(resumed && !cancelled, "Chosen folder did not resume \(operation)")
        }
        print("NATIVE_PICKER_HANDOFF_OK: selection/dismissal in either order, retained creation intent, six picker types, cancellation, retries and exactly-once delivery")
    }
}
