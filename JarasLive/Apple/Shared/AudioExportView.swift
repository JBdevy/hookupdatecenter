import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@MainActor private final class AudioExportSession: ObservableObject {
    @Published var running = false
    @Published var finished = false
    @Published var error = ""
    @Published var progress: AudioExportProgress?
    private var cancellation = AudioExportCancellation()
    func cancel() { cancellation.cancel() }
    func start(project: Project, song: Song, plan: AudioExportPlan, media: URL, output: URL, rate: Double, encoding: AudioExportEncoding, secondaryEncoding: AudioExportEncoding?) {
        guard !running else { return }
        cancellation = AudioExportCancellation()
        let token = cancellation
        running = true; finished = false; error = ""; progress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try OfflineAudioExport.run(project: project,song: song,plan: plan,mediaDirectory: media,outputDirectory: output,sampleRate: rate,encoding: encoding,secondaryEncoding: secondaryEncoding,cancellation: token) { update in
                    Task { @MainActor in self.progress = update }
                }
                Task { @MainActor in self.running = false; self.finished = true }
            } catch {
                let message = error is CancellationError ? JarasLocalization.string("Render cancelled.") : error.localizedDescription
                Task { @MainActor in self.running = false; self.error = message }
            }
        }
    }
}
struct AudioExportView: View {
    let project: Project
    let song: Song?
    let mediaDirectory: URL?
    @ObservedObject private var area = TimelineAreaSelection.shared
    @StateObject private var session = AudioExportSession()
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jaras.export.source") private var source = AudioExportSource.master
    @AppStorage("jaras.export.bounds") private var bounds = AudioExportBounds.project
    @State private var tracks: Set<UUID> = []
    @State private var clips: Set<UUID> = []
    @State private var regions: Set<UUID> = []
    @State private var choosingDirectory = false
    @State private var renderScreen = false
    @State private var renderedPlan: AudioExportPlan?
    @AppStorage("jaras.export.sampleRate") private var rate = 48000.0
    @AppStorage("jaras.export.format") private var format = AudioExportFormat.wav
    @AppStorage("jaras.export.bits") private var bits = 24
    @AppStorage("jaras.export.channels") private var channels = 2
    @AppStorage("jaras.export.bitrate") private var bitrate = 320
    @AppStorage("jaras.export.outputTab") private var outputTab = 0
    @AppStorage("jaras.export.secondaryEnabled") private var secondaryEnabled = false
    @AppStorage("jaras.export.secondaryFormat") private var secondaryFormat = AudioExportFormat.mp3
    @AppStorage("jaras.export.secondaryBits") private var secondaryBits = 24
    @AppStorage("jaras.export.secondaryBitrate") private var secondaryBitrate = 320
    @AppStorage("jaras.export.directory") private var directory = ""
    @AppStorage("jaras.export.fileName") private var fileName = "%project"
    private var plan: AudioExportPlan {
        guard let song else { return AudioExportPlan(jobs: []) }
        let range = area.range.flatMap { $0.song == song.id ? $0.start...$0.end : nil }
        let primary = AudioExportPlan(project: project,song: song,source: source,bounds: bounds,template: fileName,
                                      tracks: tracks,clips: clips,regions: regions,area: range,format: format)
        guard secondaryEnabled else { return primary }
        let secondary = AudioExportPlan(project: project,song: song,source: source,bounds: bounds,template: fileName,
                                        tracks: tracks,clips: clips,regions: regions,area: range,format: secondaryFormat)
        return AudioExportPlan.combining(primary: primary,secondary: secondary)

    }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack {
                Text(renderScreen ? "Rendering" : "Export").font(.headline)
                Spacer()
                Text("\(renderedPlan?.jobs.count ?? plan.jobs.count) files").font(.caption).foregroundStyle(JarasTheme.secondary)
                if !session.running {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28,height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Close").keyboardShortcut(.cancelAction)
                }
            }
            if renderScreen { rendering }
            else { configuration }
        }.padding(20).frame(width: 860).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .interactiveDismissDisabled(session.running)
            .onAppear {
                guard let song else { return }
                tracks = AudioExportSelection.shared.tracks(song.id)
                clips = AudioExportSelection.shared.clips(song.id)
                regions = AudioExportSelection.shared.regions(song.id)
                if UserDefaults.standard.object(forKey: "jaras.export.sampleRate") == nil {
                    rate = [44100.0,48000.0].contains(AudioDeviceSettings.shared.sampleRate) ? AudioDeviceSettings.shared.sampleRate : 48000
                }
                if directory.isEmpty { directory = FileManager.default.urls(for: .desktopDirectory,in: .userDomainMask).first?.path ?? "" }
                if fileName == "$region" { fileName = "%region" }
            }
            .fileImporter(isPresented: $choosingDirectory,allowedContentTypes: [.folder]) { if case .success(let url) = $0 { directory = url.path } }
    }
    private var configuration: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack(spacing: 18) {
                Picker("Source",selection: $source) { ForEach(AudioExportSource.allCases,id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Bounds",selection: $bounds) { ForEach(AudioExportBounds.allCases,id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }.disabled(source == .stems)
            }.pickerStyle(.menu)
            if source != .master || bounds == .regions { selectionList }
            GroupBox("Output") {
                Grid(alignment: .leading,horizontalSpacing: 10,verticalSpacing: 10) {
                    GridRow {
                        Text("Directory:")
                        HStack {
                            TextField("Directory",text: $directory)
                            Button { choosingDirectory = true } label: { Image(systemName: "folder").frame(width: 24,height: 20) }.accessibilityLabel("Choose folder")
                        }
                    }
                    GridRow { Text("File name:"); TextField("%project",text: $fileName) }
                }.textFieldStyle(.roundedBorder).padding(10)
            }
            HStack(spacing: 8) {
                ForEach(["%track","%region","%stem","%project"],id: \.self) { token in
                    Button { fileName += token } label: { Text(verbatim: token).font(.system(size: 11,design: .monospaced)) }
                        .buttonStyle(.bordered).help(token)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading,spacing: 4) {
                    ForEach(plan.jobs) { job in
                        HStack {
                            Text(verbatim: job.fileName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(verbatim: String(format:"%.2f s",job.duration)).foregroundStyle(JarasTheme.secondary)
                        }.font(.system(size: 12)).padding(.vertical,3)
                    }
                }.padding(8)
            }.scrollIndicators(.hidden).frame(height: 155).background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
            if plan.jobs.isEmpty { Text("Select files to render.").font(.caption).foregroundStyle(JarasTheme.yellow) }
            formatOptions
            HStack {
                Text("Sample rate").font(.caption)
                Picker("Sample rate",selection: $rate) { Text(verbatim: "44.1 kHz").tag(44100.0); Text(verbatim: "48 kHz").tag(48000.0) }.labelsHidden().frame(width: 105)

                Picker("Channels",selection: $channels) { Text("Stereo").tag(2); Text("Mono").tag(1) }.frame(width: 135)
                Spacer()
                Button("Render") {
                    guard let song, let mediaDirectory else { return }
                    guard AudioDestinationSpace.confirm(at: URL(fileURLWithPath: directory)) else { return }
                    let snapshot = plan
                    renderedPlan = snapshot
                    renderScreen = true
                    session.start(project: project,song: song,plan: snapshot,media: mediaDirectory,output: URL(fileURLWithPath: directory),rate: rate,encoding: AudioExportEncoding(format: format,bitDepth: bits,channels: channels,bitrate: bitrate,sampleRate: rate),secondaryEncoding: secondaryEnabled ? AudioExportEncoding(format: secondaryFormat,bitDepth: secondaryBits,channels: channels,bitrate: secondaryBitrate,sampleRate: rate) : nil)
                }.buttonStyle(.borderedProminent).tint(JarasTheme.green).keyboardShortcut(.defaultAction).disabled(plan.jobs.isEmpty || directory.isEmpty || mediaDirectory == nil)
            }
        }
    }
    private var formatOptions: some View {
        let chosenFormat = outputTab == 0 ? $format : $secondaryFormat
        let chosenBits = outputTab == 0 ? $bits : $secondaryBits
        let chosenBitrate = outputTab == 0 ? $bitrate : $secondaryBitrate
        return VStack(alignment: .leading,spacing: 10) {
            Picker("Output format",selection: $outputTab) {
                Text("Primary output format").tag(0); Text("Secondary output format").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if outputTab == 1 { Toggle("Enable secondary output",isOn: $secondaryEnabled) }
            HStack {
                Picker("Format",selection: chosenFormat) { ForEach(AudioExportFormat.allCases,id: \.self) { Text(verbatim: $0.rawValue).tag($0) } }
                if chosenFormat.wrappedValue == .mp3 {
                    Picker("Bitrate",selection: chosenBitrate) { ForEach([128,160,192,224,256,320],id: \.self) { Text(verbatim: "\($0) kbps").tag($0) } }
                } else {
                    Picker("Bit depth",selection: chosenBits) { Text(verbatim: "16 bit PCM").tag(16); Text(verbatim: "24 bit PCM").tag(24); Text(verbatim: "32 bit PCM").tag(32) }
                }
            }.disabled(outputTab == 1 && !secondaryEnabled)
        }.padding(10).background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
    }
    private var selectionList: some View {
        VStack(alignment: .leading,spacing: 4) {
            if source == .stems {
                selectionHeader("Items",all: Set(song?.tracks.flatMap(\.clips).filter { $0.audioFile != nil }.map(\.id) ?? []),value: $clips)
                ScrollView { LazyVStack(alignment: .leading) {
                    ForEach(song?.tracks.filter { $0.kind == .standard } ?? []) { track in
                        ForEach(track.clips.filter { $0.audioFile != nil }) { clip in
                            Toggle(isOn: selected(clip.id,in: $clips)) { Text(verbatim: track.name + " · " + clip.name).lineLimit(1) }
                        }
                    }
                } }.scrollIndicators(.hidden).frame(height: 90)
            } else {
                HStack(alignment: .top, spacing: 20) {
                if source != .master {
                    VStack(alignment: .leading, spacing: 4) {
                    selectionHeader("Tracks",all: Set(song?.tracks.filter { $0.kind == .standard }.map(\.id) ?? []),value: $tracks)
                    ScrollView { LazyVStack(alignment: .leading) {
                        ForEach(song?.tracks.filter { $0.kind == .standard } ?? []) { track in
                            Toggle(isOn: selected(track.id,in: $tracks)) { Text(verbatim: track.name).lineLimit(1) }
                        }
                    } }.scrollIndicators(.hidden).frame(height: 115)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if bounds == .regions {
                    VStack(alignment: .leading, spacing: 4) {
                    selectionHeader("Regions",all: Set(song?.parts.map(\.id) ?? []),value: $regions)
                    ScrollView { LazyVStack(alignment: .leading) {
                        ForEach(exportRegions) { region in
                            Toggle(isOn: selected(region.id,in: $regions)) {
                                Text(verbatim: region.displayName).lineLimit(1)
                            }.padding(.leading, region.parentRegionID == nil ? 0 : 16)
                        }
                    } }.scrollIndicators(.hidden).frame(height: 115)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                }
            }
        }.font(.caption)
    }
    private var exportRegions: [Part] {
        guard let song else { return [] }
        return song.parts.filter { $0.parentRegionID == nil }.flatMap { parent in
            [parent] + song.parts.filter { $0.parentRegionID == parent.id }.sorted { $0.startTime < $1.startTime }
        }
    }
    private func selected(_ id: UUID,in value: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue.contains(id) },set: { if $0 { value.wrappedValue.insert(id) } else { value.wrappedValue.remove(id) } })
    }
    private func selectionHeader(_ title: String,all: Set<UUID>,value: Binding<Set<UUID>>) -> some View {
        HStack { Text(LocalizedStringKey(title)).fontWeight(.semibold); Spacer(); Button("All") { value.wrappedValue = all }; Button("Clear") { value.wrappedValue = [] } }
    }
    private var rendering: some View {
        VStack(alignment: .leading,spacing: 14) {
            if let progress = session.progress {
                Text(verbatim: progress.fileName).font(.system(size: 12,weight: .semibold)).lineLimit(1)
                Canvas { context,size in
                    let width = size.width/CGFloat(max(1,progress.waveform.count))
                    let finished = Int(progress.fraction * Double(progress.waveform.count))
                    for index in 0..<min(finished+1,progress.waveform.count) {
                        let amplitude = CGFloat(min(1,progress.waveform[index])) * (size.height/2-3)
                        var line = Path(); let x = CGFloat(index)*width
                        line.move(to: CGPoint(x:x,y:size.height/2-amplitude)); line.addLine(to: CGPoint(x:x,y:size.height/2+amplitude))
                        context.stroke(line,with: .color(progress.clipped[index] ? .red : JarasTheme.green),lineWidth: max(1,width))
                    }
                }.frame(height: 180).background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
                ProgressView(value: progress.fraction).tint(JarasTheme.green)
                HStack {
                    Text("\(progress.completed) / \(progress.total) files")
                    Spacer()
                    Text(verbatim: progress.peak > 0 ? String(format: "Peak %+.2f dBFS",20*log10(progress.peak)) : "Peak −∞ dBFS")
                        .foregroundStyle(progress.clipped.contains(true) ? Color.red : JarasTheme.secondary)
                }.font(.caption)
            } else { ProgressView().frame(height: 180).frame(maxWidth: .infinity) }
            if !session.error.isEmpty { Text(verbatim: session.error).font(.caption).foregroundStyle(.red) }
            HStack {
                if session.running { Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction) }
                else if session.finished { Text("Render complete.").foregroundStyle(JarasTheme.green) }
                else { Button("Back") { renderScreen = false; renderedPlan = nil } }
                Spacer()
                if !session.running { Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
    }
}

struct ItemAudioExportRequest: Identifiable {
    let id = UUID()
    let project: Project
    let song: Song
    let items: Set<UUID>
    let mediaDirectory: URL?
}

struct ItemAudioExportView: View {
    let request: ItemAudioExportRequest
    @StateObject private var session = AudioExportSession()
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jaras.export.format") private var format = AudioExportFormat.wav
    @AppStorage("jaras.export.bits") private var bits = 24
    @AppStorage("jaras.export.bitrate") private var bitrate = 320
    @AppStorage("jaras.export.sampleRate") private var rate = 48000.0
    @AppStorage("jaras.export.itemChannels") private var channels = 0
    @AppStorage("jaras.export.directory") private var directory = ""
    @State private var choosingDirectory = false
    private var plan: AudioExportPlan {
        AudioExportPlan(project: request.project, song: request.song, source: .stems, bounds: .project,
                        template: "%stem", tracks: [], clips: request.items, regions: [], format: format)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Export audio items").font(.headline)
                Spacer()
                Text("\(plan.jobs.count) files").font(.caption).foregroundStyle(JarasTheme.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Format", selection: $format) {
                        ForEach(AudioExportFormat.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                    }
                    if format == .mp3 {
                        Picker("Bitrate", selection: $bitrate) {
                            ForEach([128, 160, 192, 224, 256, 320], id: \.self) { Text(verbatim: "\($0) kbps").tag($0) }
                        }
                    } else {
                        Picker("Bit depth", selection: $bits) {
                            ForEach([16, 24, 32], id: \.self) { Text(verbatim: "\($0) bit PCM").tag($0) }
                        }
                    }
                }
                HStack {
                    Picker("Sample rate", selection: $rate) {
                        Text(verbatim: "44.1 kHz").tag(44100.0); Text(verbatim: "48 kHz").tag(48000.0)
                    }
                    Picker("Channels", selection: $channels) { Text("Original").tag(0); Text("Stereo").tag(2); Text("Mono").tag(1) }
                }
                HStack {
                    TextField("Directory", text: $directory).textFieldStyle(.roundedBorder)
                    Button { choosingDirectory = true } label: { Image(systemName: "folder") }
                        .accessibilityLabel("Choose folder").help("Choose folder")
                }
            }.disabled(session.running || session.finished)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.jobs) { job in Text(verbatim: job.fileName).lineLimit(1).truncationMode(.middle) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(height: min(110, CGFloat(max(1, plan.jobs.count)) * 22 + 16))
                .background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
            if session.running {
                ProgressView(value: session.progress.map { (Double($0.completed) + $0.fraction) / Double(max(1, $0.total)) } ?? 0)
            }
            if !session.error.isEmpty { Text(verbatim: session.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if session.finished { Text("Render complete.").foregroundStyle(JarasTheme.green) }
            HStack {
                Button(session.running ? "Cancel" : "Close") {
                    if session.running { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if !session.finished {
                    Button("Export") { start() }.buttonStyle(.borderedProminent).tint(JarasTheme.green)
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.running || plan.jobs.isEmpty || directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.mediaDirectory == nil)
                }
            }
        }.padding(20).frame(width: 520).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .interactiveDismissDisabled(session.running)
            .onAppear {
                if directory.isEmpty { directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "" }
            }
            .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) {
                switch $0 {
                case .success(let url): directory = url.path
                case .failure(let error): session.error = error.localizedDescription
                }
            }
    }
    private func start() {
        guard let media = request.mediaDirectory else { return }
        let output = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        guard AudioDestinationSpace.confirm(at: output) else { return }
        session.start(project: request.project, song: request.song, plan: plan, media: media, output: output, rate: rate,
                      encoding: AudioExportEncoding(format: format, bitDepth: bits, channels: channels, bitrate: bitrate, sampleRate: rate), secondaryEncoding: nil)
    }
}

// MARK: - Destination disk reserve
/// Consult the destination volume, including a not-yet-created export directory.
/// This preflight never runs from an audio callback and never writes a probe file.
enum AudioDestinationSpace {
    static let reserveBytes: Int64 = 5_000_000_000
    static func needsWarning(availableBytes: Int64) -> Bool {
        availableBytes >= 0 && availableBytes < reserveBytes
    }
    static func existingAncestor(of destination: URL) -> URL {
        var directory = destination.standardizedFileURL
        while !FileManager.default.fileExists(atPath: directory.path) {
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return directory.resolvingSymlinksInPath()
    }
    static func availableBytes(at destination: URL) -> Int64? {
        let directory = existingAncestor(of: destination)
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacity { return Int64(bytes) }
        return (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }
    @MainActor static func confirm(at destination: URL) -> Bool {
        guard let available = availableBytes(at: destination), needsWarning(availableBytes: available) else { return true }
        #if os(macOS)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pouco espaço no disco de destino"
        alert.informativeText = String(format: "Restam %.2f GB livres no disco onde o áudio será salvo. A margem recomendada é de 5 GB. Libere espaço antes de gravar, re-renderizar ou exportar stems.\n\nDestino: %@", Double(available) / 1_000_000_000, destination.path)
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Continuar mesmo assim")
        return alert.runModal() == .alertSecondButtonReturn
        #else
        return true
        #endif
    }
}
