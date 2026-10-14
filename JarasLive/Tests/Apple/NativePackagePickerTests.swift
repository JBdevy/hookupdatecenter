import Foundation

protocol UIDocumentPickerDelegate: AnyObject { }
final class UIDocumentPickerViewController { }
struct NativeProjectPicker {
    let picked: ([URL]) -> Void
    let cancelled: () -> Void
    // PRODUCTION_COORDINATOR
}
enum PortableProjectImportPrompt { case file, destination }
@MainActor final class TrackRecording {
    static let shared = TrackRecording()
    var recording = false, busy = false
}
@MainActor final class ProjectDocuments {
    enum NativePicker { case package, packageDestination }
    var nativePicker: NativePicker? { didSet { pickerWrites += 1 } }
    var nativePackagePrompt: PortableProjectImportPrompt?
    var nativePendingPackage: URL?
    var nativePackageScope: URL?
    var pickerWrites = 0
    var busy = false
    struct Show { var isPlaying = false }
    let show = Show()
    // PRODUCTION_PACKAGE_METHODS
}

@MainActor func verifyPicker() {
    let model = ProjectDocuments()
    let source = URL(fileURLWithPath: "/tmp/Selected.ziplive")
    let stale = URL(fileURLWithPath: "/tmp/Stale.ziplive")
    model.browsePortablePackage()
    precondition(model.nativePackagePrompt == .file && model.nativePicker == nil)
    model.continueNativePackageImport(.file)
    let writes = model.pickerWrites
    model.continueNativePackageImport(.file)
    precondition(model.pickerWrites == writes, "Repeated alert confirmation cannot present Files twice")
    model.nativePicker = nil // Files has dismissed before delivery.
    var selections = 0, cancellations = 0
    let picker = NativeProjectPicker(picked: { urls in
        selections += 1; model.importPortablePackage(urls[0])
    }, cancelled: { cancellations += 1 })
    let coordinator = NativeProjectPicker.Coordinator(picker)
    let controller = UIDocumentPickerViewController()
    coordinator.documentPicker(controller, didPickDocumentsAt: [source])
    model.continueNativePackageImport(.destination)
    let destinationWrites = model.pickerWrites
    coordinator.documentPicker(controller, didPickDocumentsAt: [stale])
    coordinator.documentPickerWasCancelled(controller)
    model.importPortablePackage(source) // A repeated Open URL event.
    model.browsePortablePackage() // Repeated Add action.
    model.continueNativePackageImport(.destination)
    precondition(selections == 1 && cancellations == 0)
    precondition(model.nativePendingPackage == source && model.nativePicker == .packageDestination)
    precondition(model.nativePackagePrompt == nil && model.pickerWrites == destinationWrites,
                 "The destination picker is presented once and is not replaced by a stale archive event")
    model.cancelNativePackageImport()
    model.nativePicker = nil
    model.browsePortablePackage()
    precondition(model.nativePackagePrompt == .file, "Cancel allows a new import")

    let cancelled = NativeProjectPicker.Coordinator(picker)
    cancelled.documentPickerWasCancelled(controller)
    cancelled.documentPickerWasCancelled(controller)
    cancelled.documentPicker(controller, didPickDocumentsAt: [source])
    precondition(cancellations == 1 && selections == 1, "A cancelled Files instance cannot deliver a late selection")
    print("NATIVE_ZIPLIVE_SINGLE_FILE_SINGLE_DESTINATION_DUPLICATE_CALLBACK_OPEN_URL_AND_CANCEL_OK")
}
Task { @MainActor in verifyPicker(); exit(0) }
dispatchMain()
