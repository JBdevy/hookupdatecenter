#if os(macOS)
import AppKit
import CryptoKit
import Combine
import Darwin
import SwiftUI
struct RecognizedPlugin: Codable, Identifiable, Sendable {
    let classID: String, name: String, path: String, vendor: String, category: String
    var id: String { path + "|" + classID }
    var isInstrument: Bool { category.contains("Instrument") }
    var types: [String] {
        let values = category.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return values.isEmpty ? ["Uncategorized"] : values
    }
    func matches(query: String, type: String, vendor: String, allowsInstruments: Bool) -> Bool {
        guard allowsInstruments || !isInstrument else { return false }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return [name, self.vendor, category].contains { $0.localizedStandardContains(query) } }
        return (type.isEmpty || types.contains(type)) && (vendor.isEmpty || self.vendor == vendor)
    }
    var instance: ExternalPlugin { ExternalPlugin(classID: classID, name: name, path: path, category: category) }
}
struct PluginScanRecord: Codable, Sendable {
    let fingerprint: String
    let plugins: [RecognizedPlugin]
    static func fingerprint(_ module: URL) -> String? {
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: module.path, isDirectory: &directory) else { return nil }
        var files = [module]
        if directory.boolValue {
            guard let iterator = fm.enumerator(at: module, includingPropertiesForKeys: nil) else { return nil }
            for case let file as URL in iterator { files.append(file) }
        }
        var entries: [String] = []
        for file in files {
            // URL.resourceValues may retain stale metadata after a bundle update.
            guard let values = try? fm.attributesOfItem(atPath: file.path), let modified = values[.modificationDate] as? Date else { return nil }
            entries.append(file.path + "|" + String((values[.size] as? NSNumber)?.uint64Value ?? 0) + "|" + String(modified.timeIntervalSince1970))
        }
        return SHA256.hash(data: Data(("v1\n" + entries.sorted().joined(separator: "\n")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
@MainActor final class PluginCatalog: ObservableObject {
    static let shared = PluginCatalog()
    @Published private(set) var paths: [String]
    @Published private(set) var plugins: [RecognizedPlugin]
    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    @Published private(set) var scanProgress: Double? = nil
    @Published private(set) var currentPlugin = ""
    @Published private(set) var completedPlugins = 0
    @Published private(set) var totalPlugins = 0
    private var scanCache: [String: PluginScanRecord] = [:]
    private var scanTask: Task<([RecognizedPlugin], [String], Bool), Never>?
    private let defaults: UserDefaults
    private let scannerExecutable: URL?
    init(defaults: UserDefaults = .standard, executable: URL? = Bundle.main.executableURL) {
        self.defaults = defaults; scannerExecutable = executable
        scanCache = defaults.data(forKey: "jaras.plugins.scanCache").flatMap { try? JSONDecoder().decode([String: PluginScanRecord].self, from: $0) } ?? [:]
        paths = defaults.stringArray(forKey: "jaras.plugins.paths") ?? ["/Library/Audio/Plug-Ins/VST3", NSHomeDirectory() + "/Library/Audio/Plug-Ins/VST3"]
        plugins = defaults.data(forKey: "jaras.plugins.catalog").flatMap { try? JSONDecoder().decode([RecognizedPlugin].self, from: $0) } ?? []
    }
    private func saveScanCache() { defaults.set(try? JSONEncoder().encode(scanCache), forKey: "jaras.plugins.scanCache") }
    func cancelScan() { scanTask?.cancel() }
    func addPath() {
        guard !scanning else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let path = panel.url?.standardizedFileURL.path, !paths.contains(path) else { return }
        paths.append(path); savePaths(); scan()
    }
    func removePath(_ path: String) { paths.removeAll { $0 == path }; savePaths(); plugins.removeAll { $0.path.hasPrefix(path + "/") }; saveCatalog() }
    private func savePaths() { defaults.set(paths, forKey: "jaras.plugins.paths") }
    private func saveCatalog() { defaults.set(try? JSONEncoder().encode(plugins), forKey: "jaras.plugins.catalog") }
    func acceptImportedPlugins(_ additions: [RecognizedPlugin]) {
        guard !additions.isEmpty else { return }
        var indexed = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for plugin in additions { indexed[plugin.id] = plugin }
        plugins = indexed.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        saveCatalog()
    }
    func scan() {
        guard !scanning, let executable = scannerExecutable else { return }
        scanning = true; status = "Scanning plugins…"
        scanProgress = nil; currentPlugin = ""; completedPlugins = 0; totalPlugins = 0
        let paths = self.paths, cache = scanCache, previousPlugins = plugins
        let worker = Task.detached(priority: .utility) { () -> ([RecognizedPlugin], [String], Bool) in
                var files = Set<URL>(), found: [RecognizedPlugin] = [], errors: [String] = []
                let fm = FileManager.default
                for path in paths where !Task.isCancelled {
                    let root = URL(fileURLWithPath: path).standardizedFileURL
                    if root.pathExtension.lowercased() == "vst3", fm.fileExists(atPath: path) { files.insert(root); continue }
                    if let enumerator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                        while let url = enumerator.nextObject() as? URL {
                            if Task.isCancelled { break }
                            if url.pathExtension.lowercased() == "vst3" { files.insert(url.standardizedFileURL); enumerator.skipDescendants() }
                        }
                    }
                }
                struct Scan: Decodable { var plugins: [RecognizedPlugin]; var error: String }
                let candidates = files.sorted(by: { $0.path < $1.path })
                await MainActor.run { self.totalPlugins = candidates.count; self.scanProgress = 0 }
                for (index, file) in candidates.enumerated() {
                    if Task.isCancelled { break }
                    await MainActor.run { self.currentPlugin = file.deletingPathExtension().lastPathComponent }
                    let stamp = PluginScanRecord.fingerprint(file)
                    if let stamp, let record = cache[file.path], record.fingerprint == stamp {
                        found += record.plugins
                        await MainActor.run { self.completedPlugins = index + 1; self.scanProgress = Double(index + 1) / Double(candidates.count) }
                        continue
                    }
                    // Adopt the already verified catalog when upgrading to fingerprint caching.
                    // No third-party code is rerun just to establish its initial file baseline.
                    if let stamp, cache[file.path] == nil {
                        let known = previousPlugins.filter { $0.path == file.path }
                        if !known.isEmpty {
                            found += known
                            let record = PluginScanRecord(fingerprint: stamp, plugins: known)
                            await MainActor.run {
                                self.scanCache[file.path] = record; self.saveScanCache()
                                self.completedPlugins = index + 1; self.scanProgress = Double(index + 1) / Double(candidates.count)
                            }
                            continue
                        }
                    }
                    let output = fm.temporaryDirectory.appendingPathComponent("jaras-plugin-scan-" + UUID().uuidString + ".json")
                    let process = Process(); process.executableURL = executable; process.arguments = ["--scan-vst3", file.path, output.path]
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        while process.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
                        try Task.checkCancellation()
                        if process.terminationStatus == 0, let data = try? Data(contentsOf: output), let scan = try? JSONDecoder().decode(Scan.self, from: data) {
                            found += scan.plugins
                            if !scan.error.isEmpty { errors.append(file.lastPathComponent + ": " + scan.error) }
                            else if let stamp, PluginScanRecord.fingerprint(file) == stamp {
                                let record = PluginScanRecord(fingerprint: stamp, plugins: scan.plugins)
                                await MainActor.run { self.scanCache[file.path] = record; self.saveScanCache() }
                            }
                        } else { errors.append(file.lastPathComponent + ": " + JarasLocalization.string("Plugin scan failed.")) }
                    } catch is CancellationError {
                        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                        try? fm.removeItem(at: output)
                        break
                    } catch { errors.append(file.lastPathComponent + ": " + error.localizedDescription) }
                    try? fm.removeItem(at: output)
                    await MainActor.run {
                        self.completedPlugins = index + 1
                        self.scanProgress = Double(index + 1) / Double(candidates.count)
                    }
                }
                return (found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, errors, Task.isCancelled)
        }
        scanTask = worker
        Task {
            let result = await worker.value
            if result.2 { acceptImportedPlugins(result.0) } else { plugins = result.0; saveCatalog(); scanProgress = 1 }
            scanning = false; currentPlugin = ""; scanTask = nil
            status = result.2 ? JarasLocalization.string("Scan cancelled.") : (result.1.isEmpty ? JarasLocalization.string("Scan complete.") : result.1.joined(separator: "\n"))
        }
    }
}
/// One import owns this session on its detached worker. Third-party code is
/// opened in a disposable process, never on the UI or live audio thread.
final class ReaperVST3ImportSession: @unchecked Sendable {
    private let executable: URL
    private var catalog: [RecognizedPlugin]
    private let paths: [String]
    private var scanned = Set<String>()
    private var candidates: [URL]?
    private(set) var discovered: [RecognizedPlugin] = []
    init(executable: URL, catalog: [RecognizedPlugin], paths: [String], reaperConfiguration: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/REAPER/reaper.ini")) {
        self.executable = executable; self.catalog = catalog
        var search = paths + ["/Library/Audio/Plug-Ins/VST3", NSHomeDirectory() + "/Library/Audio/Plug-Ins/VST3"]
        if let text = try? String(contentsOf: reaperConfiguration, encoding: .utf8) {
            for line in text.components(separatedBy: .newlines) {
                let fields = line.split(separator: "=", maxSplits: 1).map(String.init)
                if fields.count == 2, ["vstpath_arm64", "vstpath64", "vstpath"].contains(fields[0].lowercased()) {
                    search += fields[1].split(separator: ";").map { NSString(string: String($0).trimmingCharacters(in: .whitespaces)).expandingTildeInPath }
                }
            }
        }
        self.paths = Array(Set(search.filter { !$0.isEmpty })).sorted()
    }
    private func pluginFiles() throws -> [URL] {
        if let candidates { return candidates }
        let fm = FileManager.default
        var found = Set<URL>()
        for path in paths {
            try Task.checkCancellation()
            let root = URL(fileURLWithPath: path).standardizedFileURL
            if root.pathExtension.lowercased() == "vst3", fm.fileExists(atPath: root.path) { found.insert(root); continue }
            if let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in iterator {
                    try Task.checkCancellation()
                    if url.pathExtension.lowercased() == "vst3" { found.insert(url.standardizedFileURL); iterator.skipDescendants() }
                }
            }
        }
        let result = found.sorted { $0.path < $1.path }; candidates = result
        return result
    }
    private func run(_ arguments: [String], output: URL) throws -> Data {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        while process.isRunning {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw ProjectError.invalid("VST3 import inspection failed or the plugin process crashed.") }
        return try Data(contentsOf: output)
    }
    func resolve(_ request: ReaperProjectImporter.VST3Request) throws -> ReaperProjectImporter.VST3Resolution? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("catlive-vst3-import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.json")
        let classID = request.plugin.classID.uppercased()
        var match = catalog.first { $0.classID.uppercased() == classID && fm.fileExists(atPath: $0.path) }
        if match == nil {
            let original = request.plugin.path.replacingOccurrences(of: "\\", with: "/")
            let basename = URL(fileURLWithPath: original).lastPathComponent
            var files = try pluginFiles()
            if original.hasPrefix("/"), URL(fileURLWithPath: original).pathExtension.lowercased() == "vst3", fm.fileExists(atPath: original) {
                files.insert(URL(fileURLWithPath: original), at: 0)
            }
            files.sort { left, right in
                let lm = left.lastPathComponent.caseInsensitiveCompare(basename) == .orderedSame
                let rm = right.lastPathComponent.caseInsensitiveCompare(basename) == .orderedSame
                return lm == rm ? left.path < right.path : lm
            }
            struct Scan: Decodable { var plugins: [RecognizedPlugin]; var error: String }
            var scanErrors: [String] = []
            for file in files where !scanned.contains(file.path) {
                try Task.checkCancellation(); scanned.insert(file.path)
                do {
                    let data = try run(["--scan-vst3", file.path, output.path], output: output)
                    let result = try JSONDecoder().decode(Scan.self, from: data)
                    catalog += result.plugins; discovered += result.plugins
                    if let found = result.plugins.first(where: { $0.classID.uppercased() == classID }) { match = found; break }
                    if !result.error.isEmpty, file.lastPathComponent.caseInsensitiveCompare(basename) == .orderedSame { scanErrors.append(result.error) }
                } catch is CancellationError { throw CancellationError() }
                catch { if file.lastPathComponent.caseInsensitiveCompare(basename) == .orderedSame { scanErrors.append(error.localizedDescription) } }
                try? fm.removeItem(at: output)
            }
            if match == nil, !scanErrors.isEmpty { throw ProjectError.invalid(scanErrors.joined(separator: "\n")) }
        }
        guard let match else { return nil }
        var plugin = request.plugin; plugin.path = match.path
        if !match.category.isEmpty { plugin.category = match.category }
        let input = directory.appendingPathComponent("request.json")
        var spec = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plugin)) as! [String: Any]
        spec["strictImportState"] = true
        try JSONSerialization.data(withJSONObject: spec).write(to: input)
        try? fm.removeItem(at: output)
        struct Inspection: Decodable {
            struct Parameter: Decodable { var index: Int; var id: UInt32; var readOnly: Bool }
            var parameters: [Parameter]; var error: String
        }
        let data = try run(["--inspect-vst3", input.path, output.path], output: output)
        let inspection = try JSONDecoder().decode(Inspection.self, from: data)
        guard inspection.error.isEmpty else { throw ProjectError.invalid(inspection.error) }
        let mapping = Dictionary(inspection.parameters.filter { !$0.readOnly }.map { ($0.index, $0.id) }, uniquingKeysWith: { first, _ in first })
        return .init(plugin: plugin, parameterIDs: mapping)
    }
}

struct ExternalPluginBrowser: View {
    @Binding var selected: String?
    let allowsInstruments: Bool
    let close: () -> Void
    @ObservedObject private var catalog = PluginCatalog.shared
    @State private var search = ""
    @State private var selectedType = ""
    @State private var selectedVendor = ""
    private var availablePlugins: [RecognizedPlugin] { catalog.plugins.filter { allowsInstruments || !$0.isInstrument } }
    private var types: [String] { Set(availablePlugins.flatMap(\.types)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var vendors: [String] { Set(availablePlugins.map(\.vendor).filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    @FocusState private var searching: Bool
    private var matches: [RecognizedPlugin] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.plugins.filter {
            $0.matches(query: query, type: selectedType, vendor: selectedVendor, allowsInstruments: allowsInstruments)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("External (VST3)").font(.jarasHeadline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).jarasHelp("Close")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(JarasTheme.secondary)
                TextField("Search plugins", text: $search).textFieldStyle(.plain).focused($searching)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).jarasHelp("Clear") }
            }.padding(10).background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(JarasTheme.line))
            HStack(spacing: 16) {
                Picker("Type", selection: $selectedType) {
                    Text(verbatim: "All").tag("")
                    ForEach(types, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                Picker("Company", selection: $selectedVendor) {
                    Text(verbatim: "All").tag("")
                    ForEach(vendors, id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }.disabled(!search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(matches) { plugin in
                        Button { selected = plugin.id; close() } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: plugin.name).font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: plugin.vendor).font(.jarasSystem(size: 10)).foregroundStyle(JarasTheme.secondary).lineLimit(1)
                            }.padding(6).frame(maxWidth: .infinity).frame(height: 56)
                                .background(selected == plugin.id ? JarasTheme.green.opacity(0.16) : JarasTheme.display, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == plugin.id ? JarasTheme.green : JarasTheme.line))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).jarasHelp(plugin.name + " · " + plugin.vendor)
                    }
                }
            }.frame(height: 248)
                .overlay { if matches.isEmpty { Text(catalog.scanning ? "Scanning plugins…" : "No plugins found").foregroundStyle(JarasTheme.secondary) } }
            if catalog.scanning { PluginScanProgress(catalog: catalog) }
            HStack {
                Button(catalog.scanning ? "Cancel scan" : "Scan plugins") { if catalog.scanning { catalog.cancelScan() } else { catalog.scan() } }
                if catalog.scanning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 680).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { searching = true }
            .onChange(of: types) { values in if !selectedType.isEmpty && !values.contains(selectedType) { selectedType = "" } }
            .onChange(of: vendors) { values in if !selectedVendor.isEmpty && !values.contains(selectedVendor) { selectedVendor = "" } }
    }
}

/// Shared by both scan entry points; all values are published on the main actor.
struct PluginScanProgress: View {
    @ObservedObject var catalog: PluginCatalog
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: catalog.currentPlugin).lineLimit(1).accessibilityHint(Text(verbatim: catalog.currentPlugin))
                Spacer()
                Text(verbatim: "\(catalog.completedPlugins) / \(catalog.totalPlugins)").monospacedDigit()
            }.font(.jarasCaption)
            if let progress = catalog.scanProgress { ProgressView(value: progress).progressViewStyle(.linear) }
            else { ProgressView().progressViewStyle(.linear) }
        }.frame(maxWidth: .infinity)
    }
}

struct PluginSettings: View {
    @ObservedObject private var catalog = PluginCatalog.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VST3 paths").font(.jarasHeadline)
            ForEach(catalog.paths, id: \.self) { path in
                HStack { Text(verbatim: path).lineLimit(2).font(.jarasCaption); Spacer(); Button { catalog.removePath(path) } label: { Image(systemName: "minus.circle") }.disabled(catalog.scanning) }
            }
            HStack { Button("Add path") { catalog.addPath() }.disabled(catalog.scanning); Button(catalog.scanning ? "Cancel scan" : "Scan plugins") { if catalog.scanning { catalog.cancelScan() } else { catalog.scan() } }; if catalog.scanning { ProgressView().controlSize(.small) } }
            if catalog.scanning { PluginScanProgress(catalog: catalog) }
            if !catalog.status.isEmpty { Text(verbatim: JarasLocalization.string(catalog.status)).font(.jarasCaption).foregroundStyle(JarasTheme.secondary) }
        }
    }
}

/// The insertion menu is narrow and may sit at the screen edge. Give the
/// searchable catalog its own centered window so all four columns stay visible.
struct ExternalPluginBrowserPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var selected: String?
    let allowsInstruments: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.presented = $isPresented
        if isPresented {
            guard coordinator.panel == nil, !coordinator.opening else { return }
            coordinator.opening = true
            let selected = $selected, allowed = allowsInstruments
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let coordinator, coordinator.presented?.wrappedValue == true else { return }
                coordinator.opening = false
                let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 680, height: 560),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                panel.title = JarasLocalization.string("External (VST3)")
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.minSize = CGSize(width: 620, height: 390)
                panel.delegate = coordinator
                panel.contentView = NSHostingView(rootView: ExternalPluginBrowser(selected: selected, allowsInstruments: allowed) {
                    coordinator.close()
                }.environment(\.locale, Locale(identifier: UserDefaults.standard.string(forKey: "jaras.language") ?? "en"))
                    .preferredColorScheme(.dark))
                coordinator.scanObserver = PluginCatalog.shared.$scanning.removeDuplicates().sink { [weak panel] scanning in
                    guard let panel else { return }
                    panel.setContentSize(NSSize(width: 680, height: scanning ? 620 : 560))
                    if let screen = panel.screen { panel.setFrame(panel.constrainFrameRect(panel.frame, to: screen), display: true) }
                }
                let owner = view?.window?.parent ?? NSApp.windows.first(where: { $0.title.hasPrefix("FX ·") && $0.isVisible }) ?? NSApp.mainWindow
                if let screen = owner?.screen ?? NSScreen.main {
                    let frame = screen.visibleFrame
                    let main = NSApp.windows.first { !($0 is NSPanel) && $0.isVisible && $0.frame.width > 900 }
                    let center = main?.frame.center ?? CGPoint(x: frame.midX, y: frame.midY)
                    panel.setFrameOrigin(CGPoint(x: min(frame.maxX - panel.frame.width, max(frame.minX, center.x - panel.frame.width / 2)),
                                                y: min(frame.maxY - panel.frame.height, max(frame.minY, center.y - panel.frame.height / 2))))
                } else { panel.center() }
                coordinator.panel = panel
                owner?.addChildWindow(panel, ordered: .above)
                panel.makeKeyAndOrderFront(nil)
            }
        } else if coordinator.panel != nil { coordinator.close() }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        var panel: NSPanel?
        var scanObserver: AnyCancellable?
        var presented: Binding<Bool>?
        var opening = false
        func close() {
            guard let panel else { return }
            self.panel = nil; scanObserver = nil
            panel.parent?.removeChildWindow(panel)
            panel.delegate = nil
            panel.close()
            presented?.wrappedValue = false
        }
        func windowWillClose(_ notification: Notification) { close() }
    }
}
private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

#endif
