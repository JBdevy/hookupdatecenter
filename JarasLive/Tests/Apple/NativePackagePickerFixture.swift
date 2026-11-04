import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum JarasLocalization { static func string(_ key: String) -> String { key } }
extension UTType { static let catLiveProject = UTType(exportedAs: "com.hookdeveloper.jaraslive.project", conformingTo: .data); static let catLivePackage = UTType(exportedAs: "com.hookdeveloper.catlive.ziplive", conformingTo: .zip) }
enum PortableProjectImportPrompt: String, Identifiable {
    case file, destination
    var id: String { rawValue }
    var title: String { self == .file ? "Choose a CatLive project" : "Choose a folder for the imported project" }
    var message: String { "Choose the file or destination in Files." }
    var action: String { self == .file ? "Choose file" : "Choose folder" }
}
@MainActor final class ProjectDocuments: ObservableObject {
    enum NativePicker: String, Identifiable {
        case project, projectFolder, package, packageDestination, stems, trackAudio, trackMedia, storage
        var id: String { rawValue }
    }
    var nativePickerDirectory: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
    @Published var openedName = ""
    init() {
        let file = nativePickerDirectory!.appendingPathComponent("Example.jl")
        try! Data("{}".utf8).write(to: file)
    }
    @Published var nativePicker: NativePicker?
    @Published var nativePackagePrompt: PortableProjectImportPrompt?
    @Published var audioImportError = ""
    @Published var nativeNamePrompt = false
    @Published var nativeProjectName = ""
    @Published var cancellations = 0
    func continueNativePackageImport(_ prompt: PortableProjectImportPrompt) {
        // The production model intentionally requires a live import intent.
        guard nativePackagePrompt == prompt else { return }
        nativePackagePrompt = nil
        nativePicker = prompt == .file ? .package : .packageDestination
    }
    func cancelNativePackageImport() { nativePackagePrompt = nil }
    func cancelNativeProjectName() {}
    func confirmNativeProjectName() {}
    func cancelNativePicker(kind: NativePicker) { nativePicker = nil; cancellations += 1 }
    func receiveNativeFiles(_ urls: [URL], kind: NativePicker) {
        nativePicker = nil
        if kind == .project { openedName = urls.first?.lastPathComponent ?? "" }
        if kind == .package { nativePackagePrompt = .destination }
    }
}

// PRODUCTION_PICKER_PRESENTATION

@main struct NativePickerFixture: App {
    @StateObject private var documents = ProjectDocuments()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 24) {
                Button("Add .ziplive") { documents.nativePackagePrompt = .file }
                Button("Browse recent projects") { documents.nativePicker = .project }
                Button("Choose import destination") { documents.nativePackagePrompt = .destination }
                Text("Opened: \(documents.openedName)")
                Text("Cancellations: \(documents.cancellations)")
            }.modifier(NativeProjectPresentation(documents: documents))
        }
    }
}
