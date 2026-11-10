import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor struct PartialProjectTransferView: View {
    enum Mode { case inventory, export, importPackage }
    @ObservedObject var documents: ProjectDocuments
    let mode: Mode
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var progress = 0.0
    @State private var error = ""
    @State private var completed = false
    @State private var worker: Task<Void, Never>?
    @State private var baseline: URL?
    @State private var summary = ""
    @State private var picking = false
    @State private var temporary: URL?
    private struct Exported: Identifiable { let url: URL; var id: URL { url } }
    @State private var exported: Exported?
    @State private var sharing = false
    private var title: String { mode == .importPackage ? "Import Partial" : "Export Partial" }
    private var unavailable: Bool { !documents.ready || documents.currentURL == nil || documents.busy || documents.show.saving || TrackRecording.shared.recording || TrackRecording.shared.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: title).font(.jarasTitle2.bold())
            Text(mode == .inventory
                 ? "Exporte o estado atual deste projeto para o desktop comparar e enviar somente as novidades. Áudios e vídeos não são copiados para o .jlpartial."
                 : mode == .export
                 ? "Escolha o .jlpartial exportado no iPad. O pacote levará apenas o conteúdo e os FX nativos novos."
                 : "Adicione o .ziplivepartial ao projeto aberto. Os ajustes existentes do iPad serão preservados; somente conteúdo e FX novos serão acrescentados.")
                .font(.jarasCallout).foregroundStyle(JarasTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if mode == .export {
                Text("Plugins VST3 externos não são compatíveis com o nativo e não serão incluídos.").font(.jarasCaption).foregroundStyle(JarasTheme.yellow)
                #if os(macOS)
                Button("Escolher .jlpartial…", action: chooseBaseline).disabled(busy || unavailable)
                #endif
                if let baseline { Text(verbatim: baseline.lastPathComponent).font(.jarasCaption) }
                if !summary.isEmpty { Text(verbatim: summary).font(.jarasCaption) }
            }
            if documents.currentURL == nil { Text("Salve o projeto antes de continuar.").foregroundStyle(JarasTheme.yellow) }
            if busy { ProgressView(value: progress).progressViewStyle(JarasProgressBarStyle()); Text("Processando…").font(.jarasCaption) }
            if completed { Label("Concluído", systemImage: "checkmark.circle.fill").foregroundStyle(JarasTheme.green) }
            if !error.isEmpty { Text(verbatim: error).foregroundStyle(.red).font(.jarasCaption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(busy ? "Cancelar" : "Fechar") { if busy { worker?.cancel() } else { finish() } }
                Spacer()
                if let exported {
                    #if os(macOS)
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported.url]) }
                    #else
                    Button("Salvar em Arquivos") { sharing = true }
                    #endif
                }
                Button(action: start) { Text(verbatim: title) }.buttonStyle(StageButtonStyle(color: JarasTheme.green))
                    .disabled(busy || unavailable || (mode == .export && baseline == nil))
            }
        }.padding(24)
            #if os(macOS)
            .frame(width: 560)
            #else
            .frame(maxWidth: .infinity, alignment: .leading)
            .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "ziplivepartial") ?? .data]) { result in
                switch result { case .success(let url): runImport(url); case .failure(let failure): error = failure.localizedDescription }
            }
            .sheet(isPresented: $sharing) {
                if let exported { PartialFileExporter(url: exported.url) { sharing = false } }
            }
            #endif
            .background(JarasTheme.panel).interactiveDismissDisabled(busy)
            .onDisappear { worker?.cancel(); if let temporary, !busy { try? FileManager.default.removeItem(at: temporary) } }
    }
    private func finish() { if let close { close() } else { dismiss() } }
    #if os(macOS)
    private func chooseBaseline() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [UTType(filenameExtension: "jlpartial") ?? .data]
        picker.allowsMultipleSelection = false; picker.canChooseDirectories = false; picker.title = "Escolha o .jlpartial do iPad"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let inventory = try PartialProjectPackage.readSnapshot(url)
            let delta = try PartialProjectPackage.additions(from: documents.show.snapshot.project, baseline: inventory)
            let tracks = delta.project.songs.flatMap(\.tracks).filter { !delta.existingTracks.contains($0.id) }.count
            let items = delta.project.songs.flatMap(\.tracks).flatMap(\.clips).filter { !delta.existingClips.contains($0.id) }.count
            let regions = delta.project.songs.flatMap(\.parts).count
            summary = "\(tracks) pistas novas · \(regions) regiões novas · \(items) itens novos"
            baseline = url; error = ""; completed = false
        } catch { baseline = nil; summary = ""; self.error = error.localizedDescription }
    }
    #endif
    private func start() {
        guard !unavailable, !busy, let document = documents.currentURL else { return }
        if mode == .importPackage { picking = true; return }
        let ext = mode == .inventory ? "jlpartial" : "ziplivepartial"
        let name = PartialProjectPackage.fileName(document.deletingPathExtension().lastPathComponent, extension: ext)
        let destination: URL
        #if os(macOS)
        let picker = NSSavePanel(); picker.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        picker.nameFieldStringValue = name; picker.canCreateDirectories = true; picker.title = title
        guard picker.runModal() == .OK, let selected = picker.url else { return }
        destination = selected.pathExtension.lowercased() == ext ? selected : selected.appendingPathExtension(ext)
        #else
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CatLive-partial-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { self.error = error.localizedDescription; return }
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = folder; destination = folder.appendingPathComponent(name)
        #endif
        busy = true; progress = 0; error = ""; completed = false; exported = nil
        let session = documents.show.projectSessionID, baseline = baseline, mode = mode
        worker = Task {
            defer { busy = false; worker = nil }
            do {
                try await documents.show.flushProject()
                guard documents.currentURL == document, documents.show.projectSessionID == session, !documents.show.hasUnsavedChanges,
                      let project = try await ProjectStore(url: document).load() else { throw ProjectError.invalid("O projeto mudou. Tente exportar novamente.") }
                let directory = document.deletingLastPathComponent()
                let relevant = mode == .inventory ? project : try PartialProjectPackage.additions(from: project, baseline: PartialProjectPackage.readSnapshot(baseline!)).project
                let instruments = try documents.partialInstruments(relevant, directory: directory)
                let job = Task.detached(priority: .userInitiated) {
                    let update: @Sendable (Double) -> Void = { value in Task { @MainActor in progress = value } }
                    if mode == .inventory { try PartialProjectPackage.exportSnapshot(project: project, directory: directory, instruments: instruments, to: destination, progress: update) }
                    else { try PartialProjectPackage.export(project: project, directory: directory, baselineURL: baseline!, instruments: instruments, to: destination, progress: update) }
                }
                try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                completed = true; exported = Exported(url: destination)
                #if os(iOS)
                sharing = true
                #endif
            } catch is CancellationError { error = "Operação cancelada." }
            catch { self.error = error.localizedDescription }
        }
    }
    private func runImport(_ url: URL) {
        guard !busy, !unavailable else { return }
        busy = true; progress = 0; error = ""; completed = false
        worker = Task {
            defer { busy = false; worker = nil }
            do {
                try await documents.importPartialPackage(url) { progress = $0 }
                completed = true; progress = 1
            } catch is CancellationError { error = "Importação cancelada." }
            catch { self.error = error.localizedDescription }
        }
    }
}
#if os(iOS)
private struct PartialFileExporter: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ view: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(_ finished: @escaping () -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
    }
}
#endif
