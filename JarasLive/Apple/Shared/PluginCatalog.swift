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
struct ExternalPluginBrowser: View {
    @Binding var selected: String?
    let allowsInstruments: Bool
    let close: () -> Void
    @ObservedObject private var catalog = PluginCatalog.shared
    @State private var search = ""
    @FocusState private var searching: Bool
    private var matches: [RecognizedPlugin] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.plugins.filter {
            (allowsInstruments || !$0.isInstrument) && (query.isEmpty || [$0.name, $0.vendor, $0.category].contains { $0.localizedStandardContains(query) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("External").font(.headline)
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
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(matches) { plugin in
                        Button { selected = plugin.id; close() } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: plugin.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: plugin.vendor).font(.system(size: 10)).foregroundStyle(JarasTheme.secondary).lineLimit(1)
                            }.padding(10).frame(maxWidth: .infinity).frame(height: 80)
                                .background(selected == plugin.id ? JarasTheme.green.opacity(0.16) : JarasTheme.display, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == plugin.id ? JarasTheme.green : JarasTheme.line))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).jarasHelp(plugin.name + " · " + plugin.vendor)
                    }
                }
            }.frame(height: 344)
                .overlay { if matches.isEmpty { Text(catalog.scanning ? "Scanning plugins…" : "No plugins found").foregroundStyle(JarasTheme.secondary) } }
            HStack {
                Button("Scan plugins") { catalog.scan() }.disabled(catalog.scanning)
                if catalog.scanning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 760).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { searching = true }
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
                let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 760, height: 490),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                panel.title = JarasLocalization.string("External")
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.minSize = CGSize(width: 680, height: 390)
                panel.delegate = coordinator
                panel.contentView = NSHostingView(rootView: ExternalPluginBrowser(selected: selected, allowsInstruments: allowed) {
                    coordinator.close()
                }.environment(\.locale, Locale(identifier: UserDefaults.standard.string(forKey: "jaras.language") ?? "en"))
                    .preferredColorScheme(.dark))
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
        var presented: Binding<Bool>?
        var opening = false
        func close() {
            guard let panel else { return }
            self.panel = nil
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
