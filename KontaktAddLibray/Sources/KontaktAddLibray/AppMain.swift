import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import KontaktLibraryCore
#endif

private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

@MainActor final class LibraryModel: ObservableObject {
    @Published var entries: [ImportEntry] = []
    @Published var problems: [String] = []
    @Published var busy = false
    @Published var folder: URL?
    @Published var status = "Escolha uma pasta para começar."
    @Published var scanning = false
    private var cancellation = Cancellation()
    private var workspace: URL?
    private var timer: Timer?
    var onIdle: (() -> Void)?
    var completed: Int { entries.filter { ["added", "failed", "cancelled"].contains($0.state) }.count }

    func chooseFolder() {
        guard !busy, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let panel = NSOpenPanel()
        panel.title = "Adicionar bibliotecas Kontakt"
        panel.message = "As subpastas também serão pesquisadas."
        panel.prompt = "Adicionar"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.start(url) }
        }
    }
    private func start(_ url: URL) {
        folder = url.resolvingSymlinksInPath(); entries = []; problems = []
        cancellation = Cancellation(); busy = true; scanning = true; status = "Procurando bibliotecas…"
        let token = cancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try LibraryScanner.scan(url, cancelled: { token.cancelled }, progress: { name in
                    DispatchQueue.main.async { self?.status = "Lendo \(name)…" }
                })
                DispatchQueue.main.async { self?.didScan(result) }
            } catch {
                DispatchQueue.main.async {
                    self?.status = error is CancellationError ? "Importação cancelada." : error.localizedDescription
                    self?.finish()
                }
            }
        }
    }
    private func didScan(_ result: ScanResult) {
        scanning = false; problems = result.errors; entries = result.libraries.map(ImportEntry.init)
        if cancellation.cancelled { status = "Importação cancelada."; finish(); return }
        guard !entries.isEmpty, let folder else {
            status = "Nenhuma biblioteca compatível encontrada nesta pasta."
            finish(); return
        }
        do {
            guard let helpers = Bundle.main.executableURL?.deletingLastPathComponent(),
                  FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent("KontaktLibraryInstaller").path) else {
                throw LibraryFailure("O instalador não foi encontrado dentro do aplicativo.")
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("KontaktAddLibray-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workspace = work
            let request = work.appendingPathComponent("request.json")
            try JSONEncoder().encode(ImportRequest(folder: folder, libraries: result.libraries)).write(to: request, options: .atomic)
            let helper = helpers.appendingPathComponent("KontaktLibraryInstaller")
            func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let command = shellQuote(helper.path) + " --install " + shellQuote(request.path)
            let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            status = "Autorize o macOS para adicionar \(entries.count) biblioteca(s)."
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.readProgress() }
            }
            let process = Process(), errors = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
            process.standardError = errors; process.standardOutput = output
            process.terminationHandler = { [weak self] task in
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.readProgress()
                    if task.terminationStatus != 0 {
                        let cancelled = message.contains("-128") || self.cancellation.cancelled
                        self.status = cancelled ? "Importação cancelada." : "Não foi possível concluir a importação."
                        if !cancelled { self.problems.append(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        for i in self.entries.indices where ["pending", "working"].contains(self.entries[i].state) {
                            self.entries[i].state = cancelled ? "cancelled" : "failed"
                            self.entries[i].detail = cancelled ? "Cancelado" : "Não adicionada"
                        }
                    } else {
                        let added = self.entries.filter { $0.state == "added" }.count
                        let failed = self.entries.filter { $0.state == "failed" }.count + self.problems.count
                        self.status = "\(added) biblioteca(s) adicionada(s)" + (failed > 0 ? " · \(failed) aviso(s)." : ".")
                    }
                    self.finish()
                }
            }
            try process.run()
        } catch { status = error.localizedDescription; finish() }
    }
    private func readProgress() {
        guard let path = workspace?.appendingPathComponent("status.json"), let data = try? Data(contentsOf: path),
              let progress = try? JSONDecoder().decode(ImportStatus.self, from: data) else { return }
        entries = progress.entries
        if let item = entries.first(where: { $0.state == "working" }) { status = "Adicionando \(item.name)…" }
    }
    func cancel() {
        cancellation.cancel(); status = "Cancelando…"
        if let workspace { try? Data().write(to: workspace.appendingPathComponent("cancel"), options: .atomic) }
    }
    private func finish() {
        timer?.invalidate(); timer = nil; busy = false; scanning = false
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        workspace = nil
        let completion = onIdle; onIdle = nil; completion?()
    }
}

private struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    private let green = Color(red: 0.40, green: 0.87, blue: 0.57)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "pianokeys").font(.system(size: 28)).foregroundColor(green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kontakt Add Libray").font(.system(size: 22, weight: .semibold))
                    Text("Suas bibliotecas, em um só lugar.").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: model.chooseFolder) {
                    Label("Add", systemImage: "plus").font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black).padding(.horizontal, 19).padding(.vertical, 10)
                        .background(green.opacity(model.busy ? 0.35 : 1)).cornerRadius(9)
                }.buttonStyle(.plain).disabled(model.busy).help("Selecionar pasta e adicionar bibliotecas")
            }.padding(24)
            if let folder = model.folder {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundColor(green)
                    Text(folder.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 24).padding(.bottom, 15)
            }
            if model.entries.isEmpty && model.problems.isEmpty {
                VStack(spacing: 15) {
                    Spacer()
                    Image(systemName: model.scanning ? "magnifyingglass" : "folder.badge.plus")
                        .font(.system(size: 48, weight: .light)).foregroundColor(green.opacity(0.8))
                    Text(model.scanning ? "Procurando bibliotecas" : "Adicione suas bibliotecas")
                        .font(.system(size: 17, weight: .medium))
                    Text("Clique em Add e escolha a pasta.\nAs bibliotecas nas subpastas também serão adicionadas.")
                        .font(.system(size: 13)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.entries) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.state == "added" ? "checkmark.circle.fill" : item.state == "failed" ? "exclamationmark.circle" : item.state == "working" ? "arrow.down.circle" : "pianokeys")
                                    .foregroundColor(item.state == "failed" ? .orange : item.state == "added" ? green : .secondary)
                                    .font(.system(size: 19)).frame(width: 22).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).font(.system(size: 13, weight: .semibold))
                                    Text(item.detail).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
                                    if item.state == "working" { ProgressView().progressViewStyle(.linear).tint(green).frame(height: 3).padding(.top, 4) }
                                }
                                Spacer(minLength: 0)
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.045)).cornerRadius(9)
                        }
                        ForEach(Array(model.problems.enumerated()), id: \.offset) { _, issue in
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.circle").foregroundColor(.orange)
                                Text(issue).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 18)
                }
            }
            VStack(spacing: 12) {
                if model.busy {
                    if model.scanning || model.completed == 0 {
                        ProgressView().progressViewStyle(.linear).tint(green).frame(height: 3)
                    } else {
                        ProgressView(value: Double(model.completed), total: Double(max(1, model.entries.count)))
                            .progressViewStyle(.linear).tint(green).frame(height: 3)
                    }
                } else { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                HStack {
                    Text(model.status).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    if model.busy { Button("Cancelar", action: model.cancel).buttonStyle(.bordered) }
                    else { Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.00")).font(.system(size: 11)).foregroundColor(.secondary) }
                }
            }.padding(.horizontal, 24).padding(.bottom, 18)
        }.frame(minWidth: 600, minHeight: 420).background(Color(red: 0.085, green: 0.09, blue: 0.10))
            .foregroundColor(.white).preferredColorScheme(.dark)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = LibraryModel()
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sobre Kontakt Add Libray", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Sair de Kontakt Add Libray", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
        NSApp.mainMenu = menu
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 470), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "Kontakt Add Libray"; panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: LibraryView(model: model))
        panel.contentMinSize = NSSize(width: 600, height: 420); panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.center(); panel.makeKeyAndOrderFront(nil); window = panel
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        model.onIdle = { sender.reply(toApplicationShouldTerminate: true) }; model.cancel(); return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.busy else { return true }
        model.onIdle = { NSApp.terminate(nil) }; model.cancel(); return false
    }
}

@main struct KontaktAddLibrayMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
