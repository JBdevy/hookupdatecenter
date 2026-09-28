#if os(macOS)
import AppKit
import SwiftUI
struct RecognizedPlugin: Codable, Identifiable, Sendable {
    let classID: String, name: String, path: String, vendor: String, category: String
    var id: String { path + "|" + classID }
    var isInstrument: Bool { category.contains("Instrument") }
    var instance: ExternalPlugin { ExternalPlugin(classID: classID, name: name, path: path, category: category) }
}
@MainActor final class PluginCatalog: ObservableObject {
    static let shared = PluginCatalog()
    @Published private(set) var paths: [String]
    @Published private(set) var plugins: [RecognizedPlugin]
    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    init() {
        paths = UserDefaults.standard.stringArray(forKey: "jaras.plugins.paths") ?? ["/Library/Audio/Plug-Ins/VST3", NSHomeDirectory() + "/Library/Audio/Plug-Ins/VST3"]
        plugins = UserDefaults.standard.data(forKey: "jaras.plugins.catalog").flatMap { try? JSONDecoder().decode([RecognizedPlugin].self, from: $0) } ?? []
    }
    func addPath() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let path = panel.url?.standardizedFileURL.path, !paths.contains(path) else { return }
        paths.append(path); savePaths(); scan()
    }
    func removePath(_ path: String) { paths.removeAll { $0 == path }; savePaths(); plugins.removeAll { $0.path.hasPrefix(path + "/") }; saveCatalog() }
    private func savePaths() { UserDefaults.standard.set(paths, forKey: "jaras.plugins.paths") }
    private func saveCatalog() { UserDefaults.standard.set(try? JSONEncoder().encode(plugins), forKey: "jaras.plugins.catalog") }
    func scan() {
        guard !scanning, let executable = Bundle.main.executableURL else { return }
        scanning = true; status = "Scanning plugins…"
        let paths = self.paths
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([RecognizedPlugin], [String]) in
                var files = Set<URL>(), found: [RecognizedPlugin] = [], errors: [String] = []
                let fm = FileManager.default
                for path in paths {
                    if let enumerator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                        for case let url as URL in enumerator where url.pathExtension.lowercased() == "vst3" { files.insert(url.standardizedFileURL); enumerator.skipDescendants() }
                    }
                }
                struct Scan: Decodable { var plugins: [RecognizedPlugin]; var error: String }
                for file in files.sorted(by: { $0.path < $1.path }) {
                    let output = fm.temporaryDirectory.appendingPathComponent("jaras-plugin-scan-" + UUID().uuidString + ".json")
                    let process = Process(); process.executableURL = executable; process.arguments = ["--scan-vst3", file.path, output.path]
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        let deadline = Date().addingTimeInterval(30)
                        while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                        if process.isRunning { process.terminate(); errors.append(file.lastPathComponent + ": " + JarasLocalization.string("Scan timed out.")) }
                        else if let data = try? Data(contentsOf: output), let scan = try? JSONDecoder().decode(Scan.self, from: data) {
                            found += scan.plugins; if !scan.error.isEmpty { errors.append(file.lastPathComponent + ": " + scan.error) }
                        } else { errors.append(file.lastPathComponent + ": " + JarasLocalization.string("Plugin scan failed.")) }
                    } catch { errors.append(file.lastPathComponent + ": " + error.localizedDescription) }
                    try? fm.removeItem(at: output)
                }
                return (found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, errors)
            }.value
            plugins = result.0; saveCatalog(); scanning = false
            status = result.1.isEmpty ? JarasLocalization.string("Scan complete.") : result.1.joined(separator: "\n")
        }
    }
}
struct PluginSettings: View {
    @ObservedObject private var catalog = PluginCatalog.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VST3 paths").font(.headline)
            ForEach(catalog.paths, id: \.self) { path in
                HStack { Text(verbatim: path).lineLimit(2).font(.caption); Spacer(); Button { catalog.removePath(path) } label: { Image(systemName: "minus.circle") }.disabled(catalog.scanning) }
            }
            HStack { Button("Add path") { catalog.addPath() }; Button("Scan plugins") { catalog.scan() }.disabled(catalog.scanning); if catalog.scanning { ProgressView().controlSize(.small) } }
            if !catalog.status.isEmpty { Text(verbatim: JarasLocalization.string(catalog.status)).font(.caption).foregroundStyle(JarasTheme.secondary) }
            ForEach(catalog.plugins) { plugin in HStack { Text(verbatim: plugin.name); Spacer(); Text(verbatim: plugin.vendor).foregroundStyle(JarasTheme.secondary) }.font(.caption) }
        }
    }
}
#endif
