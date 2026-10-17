import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

/// Exports a committed project snapshot. External plug-ins are removed only
/// from the package copy; the open project and source media stay untouched.
@MainActor struct PortableProjectExportView: View {
    @ObservedObject var documents: ProjectDocuments
    var close: (() -> Void)? = nil
    @ObservedObject private var show: ShowController
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var progress: Double = 0
    @State private var error = ""
    @State private var exported: URL?
    #if os(iOS)
    private struct ExportFile: Identifiable { let url: URL; var id: URL { url } }
    @State private var exportFile: ExportFile?
    @State private var temporaryDirectory: URL?
    #endif
    private var exportTitle: LocalizedStringKey {
        #if os(macOS)
        "Export to CatLive iPadOS"
        #else
        "Export CatLive project"
        #endif
    }
    @State private var worker: Task<Void, Never>?
    init(documents: ProjectDocuments, close: (() -> Void)? = nil) { self.documents = documents; self.show = documents.show; self.close = close }
    private var requiresSave: Bool { !documents.ready || documents.currentURL == nil || show.needsSave }
    private var excluded: [String] { PortableProjectPackage.removedExternalPlugins(in: show.snapshot.project) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(exportTitle).font(.jarasTitle2.bold())
            Text("Create a .ziplive package with this project, its media and native instruments.")
                .font(.jarasCallout).foregroundStyle(JarasTheme.secondary)
            Label("External VST3 plug-ins will not be included. Native effects will be preserved.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(JarasTheme.yellow).fixedSize(horizontal: false, vertical: true)
            if !excluded.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(excluded.enumerated()), id: \.offset) { _, value in Text(verbatim: value).font(.jarasCaption) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
            }
            if requiresSave {
                Text("Save the project before exporting.").foregroundStyle(JarasTheme.yellow)
            }
            if busy { ProgressView(value: progress).tint(JarasTheme.green); Text("Exporting project…").font(.jarasCaption) }
            if let exported {
                Label("Project exported successfully.", systemImage: "checkmark.circle.fill").foregroundStyle(JarasTheme.green)
                #if os(macOS)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }
                #else
                Button("Save to Files") { exportFile = ExportFile(url: exported) }
                #endif
            }
            if !error.isEmpty { Text(LocalizedStringKey(error)).font(.jarasCaption).foregroundStyle(.red).textSelection(.disabled) }
            HStack {
                Button(busy ? "Cancel" : "Close") { if busy { worker?.cancel() } else { if let close { close() } else { dismiss() } } }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if requiresSave {
                    Button("Save") { Task { await show.save() } }.disabled(!documents.ready || show.saving || busy)
                }
                Button(exportTitle, action: export)
                    .disabled(requiresSave || busy || show.saving || documents.busy || TrackRecording.shared.recording)
                    .buttonStyle(StageButtonStyle(color: JarasTheme.green))
            }
        }.padding(24)
            #if os(macOS)
            .frame(width: 540)
            #else
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
            .background(JarasTheme.panel)
            .interactiveDismissDisabled(busy)
            #if os(iOS)
            .sheet(item: $exportFile) { file in
                NativePackageExporter(url: file.url, finished: { exportFile = nil })
            }
            .onDisappear {
                worker?.cancel()
                if let temporaryDirectory, !busy { try? FileManager.default.removeItem(at: temporaryDirectory) }
            }
            #endif
    }
    private func export() {
        guard !requiresSave, !busy, let document = documents.currentURL else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ziplive") ?? .zip]
        panel.nameFieldStringValue = document.deletingPathExtension().lastPathComponent + ".ziplive"
        panel.title = JarasLocalization.string("Export to CatLive iPadOS")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let destination = selected.pathExtension.lowercased() == "ziplive" ? selected : selected.appendingPathExtension("ziplive")
        #else
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CatLive-export-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { self.error = error.localizedDescription; return }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = folder
        let destination = folder.appendingPathComponent(document.deletingPathExtension().lastPathComponent + ".ziplive")
        #endif
        let session = show.projectSessionID
        busy = true; progress = 0; error = ""; exported = nil
        worker = Task {
            defer { busy = false; worker = nil }
            do {
                guard let project = try await ProjectStore(url: document).load() else { throw ProjectError.invalid("Project not found") }
                guard documents.currentURL == document, show.projectSessionID == session, !show.hasUnsavedChanges else {
                    throw ProjectError.invalid("Save the project before exporting.")
                }
                let directory = document.deletingLastPathComponent()
                var instruments: [String: URL] = [:]
                for id in PortableProjectPackage.instrumentIDs(in: project) {
                    guard let file = InstrumentLibrary.shared.resolvedFile(id, projectDirectory: directory) else {
                        throw ProjectError.invalid(String(format: JarasLocalization.string("Download the native instrument before exporting: %@"), id))
                    }
                    instruments[id] = file
                }
                let result = try await PortableProjectPackage.export(project: project, directory: directory, to: destination, instruments: instruments) { value in
                    Task { @MainActor in progress = value }
                }
                exported = result.archive
                #if os(iOS)
                exportFile = ExportFile(url: result.archive)
                #endif
            } catch is CancellationError { error = "Export canceled." }
            catch { self.error = error.localizedDescription }
        }
    }
}

#if os(iOS)
private struct NativePackageExporter: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(_ finished: @escaping () -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
    }
}
#endif
