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
    @Published var confirmingReplacement = false
    private(set) var replacementFiles: [String] = []
    private var pendingExport: (() -> Void)?
    func cancelReplacement() { pendingExport = nil; replacementFiles = []; confirmingReplacement = false }
    func confirmReplacement() { let action = pendingExport; cancelReplacement(); action?() }
    func cancel() { cancellation.cancel(); cancelReplacement() }
    func start(project: Project, song: Song, plan: AudioExportPlan, media: URL, output: URL, rate: Double, encoding: AudioExportEncoding, secondaryEncoding: AudioExportEncoding?, includeHardwareOutputs: Bool = false, printTrackPolarity: Bool = false, replacingFiles: Set<String> = []) {
        guard !running else { return }
        let collisions = plan.jobs.map(\.fileName).filter {
            FileManager.default.fileExists(atPath: output.appendingPathComponent($0).path) && !replacingFiles.contains($0)
        }
        if !collisions.isEmpty {
            replacementFiles = collisions
            let approved = replacingFiles.union(collisions)
            pendingExport = { [weak self] in self?.start(project: project, song: song, plan: plan, media: media, output: output,
                rate: rate, encoding: encoding, secondaryEncoding: secondaryEncoding,
                includeHardwareOutputs: includeHardwareOutputs, printTrackPolarity: printTrackPolarity, replacingFiles: approved) }
            confirmingReplacement = true
            return
        }
        cancellation = AudioExportCancellation()
        let token = cancellation
        let instruments = Dictionary(uniqueKeysWithValues: song.tracks.filter { $0.clips.contains { $0.midi != nil } }
            .map { ($0.id, ItemReRender.midiInstruments(for: $0, projectDirectory: media)) })
        running = true; finished = false; error = ""; progress = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try OfflineAudioExport.run(project: project,song: song,plan: plan,mediaDirectory: media,outputDirectory: output,sampleRate: rate,encoding: encoding,secondaryEncoding: secondaryEncoding,cancellation: token,
                    includeHardwareOutputs: includeHardwareOutputs, printTrackPolarity: printTrackPolarity, midiInstrumentsByTrack: instruments, replacingFiles: replacingFiles) { update in
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
    var regionSelection: Set<UUID>? = nil
    @ObservedObject private var mixerSelection = AudioExportSelection.shared
    @ObservedObject private var area = TimelineAreaSelection.shared
    @StateObject private var session = AudioExportSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceEditorDismiss) private var closeEditor
    @AppStorage("jaras.export.source") private var source = AudioExportSource.master
    @AppStorage("jaras.export.bounds") private var bounds = AudioExportBounds.project
    @State private var tracks: Set<UUID> = []
    @State private var clips: Set<UUID> = []
    @State private var regions: Set<UUID> = []
    @State private var choosingDirectory = false
    #if os(iOS)
    @State private var scopedDirectory: URL?
    @AppStorage("jaras.export.directoryBookmark") private var directoryBookmark = Data()
    #endif
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
    @State private var regionFileName = "%region"
    private var selectedMixerTracks: Set<UUID> {
        guard let song else { return [] }
        return mixerSelection.tracks(song.id).intersection(song.tracks.filter { $0.kind == .standard }.map(\.id))
    }
    private func synchronizeMixerTracks() {
        guard !regionMode, !renderScreen, !session.running else { return }
        tracks = selectedMixerTracks
    }
    private var regionMode: Bool { regionSelection != nil }
    private var effectiveSource: AudioExportSource { regionMode ? .master : source }
    private var effectiveBounds: AudioExportBounds { regionMode ? .regions : bounds }
    private var outputName: Binding<String> { regionMode ? $regionFileName : $fileName }
    private var plan: AudioExportPlan {
        guard let song else { return AudioExportPlan(jobs: []) }
        let range = area.range.flatMap { $0.song == song.id ? $0.start...$0.end : nil }
        let primary = AudioExportPlan(project: project,song: song,source: effectiveSource,bounds: effectiveBounds,template: outputName.wrappedValue,
                                      tracks: tracks,clips: clips,regions: regions,area: range,format: format)
        guard secondaryEnabled else { return primary }
        let secondary = AudioExportPlan(project: project,song: song,source: effectiveSource,bounds: effectiveBounds,template: outputName.wrappedValue,
                                        tracks: tracks,clips: clips,regions: regions,area: range,format: secondaryFormat)
        return AudioExportPlan.combining(primary: primary,secondary: secondary)

    }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack {
                Text(renderScreen ? "Rendering" : regionMode ? "Export region audio" : "Export").font(.jarasHeadline)
                Spacer()
                Text("\(renderedPlan?.jobs.count ?? plan.jobs.count) files").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                if !session.running {
                    Button { (closeEditor ?? { dismiss() })() } label: { Image(systemName: "xmark").frame(width: 28,height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Close").keyboardShortcut(.cancelAction)
                }
            }
            if renderScreen { rendering }
            else { configuration }
        }.padding(20)
            #if os(macOS)
            .frame(width: 860)
            #else
            .frame(maxWidth: 860)
            #endif
            .background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .interactiveDismissDisabled(session.running)
            .alert("Replace existing files?", isPresented: $session.confirmingReplacement) {
                Button("Cancel", role: .cancel) { session.cancelReplacement(); renderScreen = false; renderedPlan = nil }
                Button("Replace", role: .destructive) { session.confirmReplacement() }
            } message: { Text(verbatim: session.replacementFiles.joined(separator: "\n")) }

            .onChange(of: selectedMixerTracks) { _ in synchronizeMixerTracks() }
            .onChange(of: renderScreen) { rendering in if !rendering { synchronizeMixerTracks() } }
            .onAppear {
                guard let song else { return }
                tracks = selectedMixerTracks
                clips = AudioExportSelection.shared.clips(song.id)
                regions = regionSelection ?? AudioExportSelection.shared.regions(song.id)
                if UserDefaults.standard.object(forKey: "jaras.export.sampleRate") == nil {
                    rate = [44100.0,48000.0].contains(AudioDeviceSettings.shared.sampleRate) ? AudioDeviceSettings.shared.sampleRate : 48000
                }
                #if os(iOS)
                restoreExportDirectory()
                #else
                if directory.isEmpty { directory = FileManager.default.urls(for: .desktopDirectory,in: .userDomainMask).first?.path ?? "" }
                #endif
                if fileName == "$region" { fileName = "%region" }
            }
            .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                #if os(iOS)
                selectExportDirectory(url)
                #else
                directory = url.path
                #endif
            }
            #if os(iOS)
            .onDisappear {
                scopedDirectory?.stopAccessingSecurityScopedResource()
                scopedDirectory = nil
            }
            #endif
    }
    #if os(iOS)
    private func selectExportDirectory(_ url: URL) {
        let acquired = url.startAccessingSecurityScopedResource()
        scopedDirectory?.stopAccessingSecurityScopedResource()
        scopedDirectory = acquired ? url : nil
        directory = url.path
        directoryBookmark = (try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
    }
    private func restoreExportDirectory() {
        var stale = false
        if !directoryBookmark.isEmpty, let url = try? URL(resolvingBookmarkData: directoryBookmark, options: [],
                relativeTo: nil, bookmarkDataIsStale: &stale) {
            selectExportDirectory(url)
        } else {
            directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        }
    }
    #endif
    private var configuration: some View {
        VStack(alignment: .leading,spacing: 12) {
            if regionMode {
                Text("Render each selected region through the Master, including tracks routed to hardware outputs.")
                    .font(.jarasCaption).foregroundStyle(JarasTheme.secondary).fixedSize(horizontal: false, vertical: true)
            } else { HStack(spacing: 18) {
                Picker("Source",selection: $source) { ForEach(AudioExportSource.allCases,id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                Picker("Bounds",selection: $bounds) { ForEach(AudioExportBounds.allCases,id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }.disabled(source == .stems)
            }.pickerStyle(.menu) }
            if effectiveSource != .master || effectiveBounds == .regions { selectionList }
            GroupBox("Output") {
                LazyVGrid(columns: [GridItem(.flexible(minimum: 80, maximum: 120), spacing: 10, alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                    Text("Directory:")
                    HStack {
                        TextField("Directory",text: $directory)
                        Button { choosingDirectory = true } label: { Image(systemName: "folder").frame(width: 24,height: 20) }.accessibilityLabel("Choose folder")
                    }
                    Text("File name:")
                    TextField(regionMode ? "%region" : "%project",text: outputName)
                }.textFieldStyle(.roundedBorder).padding(10)
            }
            HStack(spacing: 8) {
                ForEach(["%track","%region","%stem","%project"],id: \.self) { token in
                    Button { outputName.wrappedValue += token } label: { Text(verbatim: token).font(.jarasSystem(size: 11,design: .monospaced)) }
                        .buttonStyle(.bordered).jarasHelp(token)
                }
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading,spacing: 4) {
                    ForEach(plan.jobs) { job in
                        HStack {
                            Text(verbatim: job.fileName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(verbatim: String(format:"%.2f s",job.duration)).foregroundStyle(JarasTheme.secondary)
                        }.font(.jarasSystem(size: 12)).padding(.vertical,3)
                    }
                }.padding(8)
            }.frame(height: 155).background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
            if plan.jobs.isEmpty { Text("Select files to render.").font(.jarasCaption).foregroundStyle(JarasTheme.yellow) }
            formatOptions
            HStack {
                Text("Sample rate").font(.jarasCaption)
                Picker("Sample rate",selection: $rate) { Text(verbatim: "44.1 kHz").tag(44100.0); Text(verbatim: "48 kHz").tag(48000.0) }.labelsHidden().frame(width: 105)

                Picker("Channels",selection: $channels) { Text("Stereo").tag(2); Text("Mono").tag(1) }.frame(width: 135)
                Spacer()
                Button("Render") {
                    guard let song, let mediaDirectory else { return }
                    guard AudioDestinationSpace.confirm(at: URL(fileURLWithPath: directory)) else { return }
                    let snapshot = plan
                    renderedPlan = snapshot
                    renderScreen = true
                    session.start(project: project,song: song,plan: snapshot,media: mediaDirectory,output: URL(fileURLWithPath: directory),rate: rate,encoding: AudioExportEncoding(format: format,bitDepth: bits,channels: channels,bitrate: bitrate,sampleRate: rate),secondaryEncoding: secondaryEnabled ? AudioExportEncoding(format: secondaryFormat,bitDepth: secondaryBits,channels: channels,bitrate: secondaryBitrate,sampleRate: rate) : nil,
                        includeHardwareOutputs: regionMode)
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
            if effectiveSource == .stems {
                selectionHeader("Items",all: Set(song?.tracks.flatMap(\.clips).filter { $0.audioFile != nil }.map(\.id) ?? []),value: $clips)
                ScrollView(showsIndicators: false) { LazyVStack(alignment: .leading) {
                    ForEach(song?.tracks.filter { $0.kind == .standard } ?? []) { track in
                        ForEach(track.clips.filter { $0.audioFile != nil }) { clip in
                            Toggle(isOn: selected(clip.id,in: $clips)) { Text(verbatim: track.name + " · " + clip.name).lineLimit(1) }
                        }
                    }
                } }.frame(height: 90).padding(10)
                    .background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(alignment: .top, spacing: 20) {
                if effectiveSource != .master {
                    VStack(alignment: .leading, spacing: 4) {
                    selectionHeader("Tracks",all: Set(song?.tracks.filter { $0.kind == .standard }.map(\.id) ?? []),value: $tracks)
                    ScrollView(showsIndicators: false) { LazyVStack(alignment: .leading) {
                        ForEach(song?.tracks.filter { $0.kind == .standard } ?? []) { track in
                            Toggle(isOn: selected(track.id,in: $tracks)) { Text(verbatim: track.name).lineLimit(1) }
                        }
                    } }.frame(height: 115)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if effectiveBounds == .regions {
                    VStack(alignment: .leading, spacing: 4) {
                    selectionHeader("Regions",all: Set(song?.parts.map(\.id) ?? []),value: $regions)
                    ScrollView(showsIndicators: false) { LazyVStack(alignment: .leading) {
                        ForEach(exportRegions) { region in
                            Toggle(isOn: selected(region.id,in: $regions)) {
                                Text(verbatim: region.displayName).lineLimit(1)
                            }.padding(.leading, region.parentRegionID == nil ? 0 : 16)
                        }
                    } }.frame(height: 115)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                }
            }
        }.font(.jarasCaption)
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
                Text(verbatim: progress.fileName).font(.jarasSystem(size: 12,weight: .semibold)).lineLimit(1)
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
                ProgressView(value: progress.fraction).progressViewStyle(JarasProgressBarStyle()).tint(JarasTheme.green)
                HStack {
                    Text("\(progress.completed) / \(progress.total) files")
                    Spacer()
                    Text(verbatim: progress.peak > 0 ? String(format: "Peak %+.2f dBFS",20*log10(progress.peak)) : "Peak −∞ dBFS")
                        .foregroundStyle(progress.clipped.contains(true) ? Color.red : JarasTheme.secondary)
                }.font(.jarasCaption)
            } else { ProgressView().frame(height: 180).frame(maxWidth: .infinity) }
            if !session.error.isEmpty { Text(verbatim: session.error).font(.jarasCaption).foregroundStyle(.red) }
            HStack {
                if session.running { Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction) }
                else if session.finished { Text("Render complete.").foregroundStyle(JarasTheme.green) }
                else { Button("Back") { renderScreen = false; renderedPlan = nil } }
                Spacer()
                if !session.running { Button("Close") { (closeEditor ?? { dismiss() })() }.keyboardShortcut(.defaultAction) }
            }
        }
    }
}

struct RegionAudioExportRequest: Identifiable {
    let id = UUID()
    let project: Project
    let song: Song
    let regions: Set<UUID>
    let mediaDirectory: URL?
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
    @Environment(\.workspaceEditorDismiss) private var closeEditor
    @AppStorage("jaras.export.format") private var format = AudioExportFormat.wav
    @AppStorage("jaras.export.bits") private var bits = 24
    @AppStorage("jaras.export.bitrate") private var bitrate = 320
    @AppStorage("jaras.export.sampleRate") private var rate = 48000.0
    @AppStorage("jaras.export.itemChannels") private var channels = 0
    @AppStorage("jaras.export.directory") private var directory = ""
    @State private var choosingDirectory = false
    @State private var processing: AudioItemExportProcessing?
    private var plan: AudioExportPlan {
        AudioExportPlan(project: request.project, song: request.song, source: .stems, bounds: .project,
                        template: "%stem", tracks: [], clips: request.items, regions: [], format: format)
    }
    var body: some View {
        Group {
            if processing == nil {
                VStack(spacing: 14) {
                    Text("Export audio items").font(.jarasHeadline)
                    Button { processing = .pre } label: { Text(verbatim: AudioItemExportProcessing.pre.rawValue).frame(maxWidth: .infinity) }
                    Button { processing = .post } label: { Text(verbatim: AudioItemExportProcessing.post.rawValue).frame(maxWidth: .infinity) }
                    Button("Cancel") { (closeEditor ?? { dismiss() })() }.keyboardShortcut(.cancelAction)
                }.buttonStyle(.bordered).controlSize(.large)
                    .padding(24).frame(width: 420).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            } else { exportForm }
        }
    }
    private var exportForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Export audio items").font(.jarasHeadline)
                Spacer()
                Text("\(plan.jobs.count) files").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
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
                        .accessibilityLabel("Choose folder")
                }
            }.disabled(session.running || session.finished)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.jobs) { job in Text(verbatim: job.fileName).lineLimit(1).truncationMode(.middle) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(height: min(110, CGFloat(max(1, plan.jobs.count)) * 22 + 16))
                .background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 6))
            if session.running {
                ProgressView(value: session.progress.map { (Double($0.completed) + $0.fraction) / Double(max(1, $0.total)) } ?? 0).progressViewStyle(JarasProgressBarStyle())
            }
            if !session.error.isEmpty { Text(verbatim: session.error).font(.jarasCaption).foregroundStyle(.red).textSelection(.disabled) }
            if session.finished { Text("Render complete.").foregroundStyle(JarasTheme.green) }
            HStack {
                Button(LocalizedStringKey(session.running ? "Cancel" : "Close")) {
                    if session.running { session.cancel() } else { (closeEditor ?? { dismiss() })() }
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
            .alert("Replace existing files?", isPresented: $session.confirmingReplacement) {
                Button("Cancel", role: .cancel) { session.cancelReplacement();  }
                Button("Replace", role: .destructive) { session.confirmReplacement() }
            } message: { Text(verbatim: session.replacementFiles.joined(separator: "\n")) }

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
        session.start(project: request.project, song: (processing ?? .post).song(request.song), plan: plan, media: media, output: output, rate: rate,
                      encoding: AudioExportEncoding(format: format, bitDepth: bits, channels: channels, bitrate: bitrate, sampleRate: rate), secondaryEncoding: nil, printTrackPolarity: true)
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
        confirm(at: destination, availableBytes: availableBytes(at: destination))
    }
    @MainActor static func confirm(at destination: URL, availableBytes: Int64?) -> Bool {
        guard let available = availableBytes, needsWarning(availableBytes: available) else { return true }
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

struct MultitrackExportProject: Identifiable, Sendable {
    var id: UUID { tab }
    let tab: UUID
    let project: Project
    let song: Song
    let mediaDirectory: URL
    var selection: Set<UUID>
    var destination: URL?
    var ignoreMutedTracks = false
    var ignoreMutedItems = false

    let regions: [Part]

    init(tab: UUID, project: Project, song: Song, mediaDirectory: URL, selection: Set<UUID>) {
        self.tab = tab
        self.project = project
        self.song = song
        self.mediaDirectory = mediaDirectory
        regions = song.parts.filter { $0.parentRegionID == nil }
            .sorted { $0.startTime < $1.startTime }
        self.selection = selection.intersection(regions.map(\.id))
    }
}

struct MultitrackExportRequest: Identifiable {
    let id = UUID()
    let projects: [MultitrackExportProject]
    let active: UUID
}

@MainActor final class MultitrackPresentation: ObservableObject {
    @Published var request: MultitrackExportRequest?
    var exporting = false
}

struct MultitrackSheet: ViewModifier {
    let presentation: MultitrackPresentation
    func body(content: Content) -> some View {
        content.background { MultitrackPresentationAnchor(presentation: presentation) }
    }
}

private struct MultitrackPresentationAnchor: View {
    @ObservedObject var presentation: MultitrackPresentation
    var body: some View {
        #if os(macOS)
        Color.clear
            .workspaceEditor("Export Multitrack", item: $presentation.request, scrolls: false,
                size: CGSize(width: 560, height: 460), canClose: { !presentation.exporting }) { request in
                MultitrackExportView(request, onRunningChanged: { presentation.exporting = $0 })
            }
            .frame(width: 0, height: 0)
        #else
        Color.clear.sheet(item: $presentation.request) { MultitrackExportView($0) }
            .frame(width: 0, height: 0)
        #endif
    }
}

@MainActor private final class MultitrackExportSession: ObservableObject {
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var error = ""
    private var cancellation = AudioExportCancellation()

    func cancel() { cancellation.cancel() }
    func start(_ projects: [MultitrackExportProject], onCompleted: @escaping () -> Void) {
        guard !running else { return }
        cancellation = AudioExportCancellation()
        let token = cancellation
        running = true; progress = 0; error = ""; status = ""
        Task {
            defer { if running { running = false } }
            do {
                try await Task.detached(priority: .utility) { [weak self] in
                    try MultitrackRenderer.run(projects, cancellation: token) { fraction, status in
                        Task { @MainActor [weak self] in
                            self?.progress = fraction
                            self?.status = status
                        }
                    }
                }.value
                running = false
                onCompleted()
            } catch is CancellationError { status = JarasLocalization.string("Export canceled.") }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct MultitrackExportView: View {
    @State private var projects: [MultitrackExportProject]
    @State private var selected: UUID
    @State private var choosing = false
    @StateObject private var session = MultitrackExportSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceEditorDismiss) private var dismissEditor
    private let onRunningChanged: (Bool) -> Void

    init(_ request: MultitrackExportRequest, onRunningChanged: @escaping (Bool) -> Void = { _ in }) {
        _projects = State(initialValue: request.projects)
        _selected = State(initialValue: request.active)
        self.onRunningChanged = onRunningChanged
    }
    private var activeProjects: [MultitrackExportProject] { projects.filter { !$0.selection.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Multitrack").font(.jarasHeadline)
            if projects.count > 1 {
                MultitrackProjectTabs(projects: projects, selection: $selected)
            }
            if let index = projects.firstIndex(where: { $0.id == selected }) {
                configuration(index)
                    .disabled(session.running)
            }
            if session.running {
                ProgressView(value: session.progress).progressViewStyle(JarasProgressBarStyle())
                Text(verbatim: session.status).font(.jarasCaption)
            }
            if !session.error.isEmpty { Text(verbatim: session.error).foregroundStyle(.red) }
            HStack {
                Button(session.running ? "Cancel" : "Close") {
                    if session.running { session.cancel() }
                    else { close() }
                }
                Spacer()
                Button("Export") {
                    session.start(activeProjects) {
                        onRunningChanged(false)
                        close()
                    }
                }
                    .buttonStyle(.borderedProminent).tint(JarasTheme.green)
                    .disabled(session.running || activeProjects.isEmpty || activeProjects.contains { $0.destination == nil })
            }
        }
        .padding(20).frame(idealWidth: 560)
        .background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
        .interactiveDismissDisabled(session.running)
        .onChange(of: session.running, perform: onRunningChanged)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard let index = projects.firstIndex(where: { $0.id == selected }) else { return }
            switch result {
            case .success(let directory): projects[index].destination = directory
            case .failure(let error): session.error = error.localizedDescription
            }
        }
    }

    private func close() {
        if let dismissEditor { dismissEditor() }
        else { dismiss() }
    }

    private func configuration(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                TextField("Destination", text: Binding(
                    get: { projects[index].destination?.path ?? "" },
                    set: { value in projects[index].destination = value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true) : nil }
                ))
                .textFieldStyle(.roundedBorder)
                Button("Browse…") { choosing = true }
            }
            Toggle("Ignore muted tracks", isOn: $projects[index].ignoreMutedTracks)
            Toggle("Ignore muted items", isOn: $projects[index].ignoreMutedItems)
            HStack {
                Text("Region folders").font(.jarasCaption)
                Spacer()
                Button("Check all") { projects[index].selection = Set(projects[index].regions.map(\.id)) }
                    .disabled(projects[index].selection.count == projects[index].regions.count)
                Button("Uncheck all") { projects[index].selection.removeAll() }
                    .disabled(projects[index].selection.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(projects[index].regions) { part in
                        Toggle(isOn: Binding(
                            get: { projects[index].selection.contains(part.id) },
                            set: { value in
                                if value { projects[index].selection.insert(part.id) }
                                else { projects[index].selection.remove(part.id) }
                            }
                        )) {
                            Text(verbatim: MultitrackRenderer.safeName(part.displayName))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minHeight: 100, idealHeight: 175, maxHeight: 230)
        }
    }
}

private struct MultitrackProjectTabs: View {
    let projects: [MultitrackExportProject]
    @Binding var selection: UUID
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let scrolls = projects.count > 4
            let gap: CGFloat = 4
            let visible = CGFloat(min(4, projects.count))
            let buttonWidth = max(1, (geometry.size.width - gap * (visible - 1)) / visible)
            let total = CGFloat(projects.count) * (buttonWidth + gap) - gap
            ScrollViewReader { proxy in
                VStack(spacing: 5) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: gap) {
                            ForEach(projects) { project in
                                Button { selection = project.id } label: {
                                    Text(verbatim: project.project.name).lineLimit(1).truncationMode(.tail)
                                        .frame(width: buttonWidth, height: 26)
                                        .foregroundStyle(selection == project.id ? Color.black : JarasTheme.text)
                                        .background(selection == project.id ? JarasTheme.green : JarasTheme.line)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).id(project.id)
                            }
                        }.background(GeometryReader { tabs in
                            Color.clear.preference(key: MultitrackTabOffset.self,
                                value: -tabs.frame(in: .named("multitrack-tabs")).minX)
                        })
                    }.coordinateSpace(name: "multitrack-tabs")
                        .onPreferenceChange(MultitrackTabOffset.self) { offset = $0 }
                    if scrolls {
                        let fraction = min(1, max(0, offset / max(1, total - geometry.size.width)))
                        let thumb = geometry.size.width * geometry.size.width / total
                        ZStack(alignment: .leading) {
                            Capsule().fill(JarasTheme.line)
                            Capsule().fill(JarasTheme.green).frame(width: thumb)
                                .offset(x: fraction * (geometry.size.width - thumb))
                        }.frame(height: 4)
                            .padding(.vertical, 3).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                let progress = min(1, max(0, (value.location.x - thumb / 2) / max(1, geometry.size.width - thumb)))
                                let index = Int((progress * CGFloat(projects.count - 4)).rounded())
                                proxy.scrollTo(projects[index].id, anchor: .leading)
                            })
                    }
                }.onAppear { if scrolls { proxy.scrollTo(selection) } }
            }
        }.frame(height: projects.count > 4 ? 41 : 26)
    }
}

private struct MultitrackTabOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private enum MultitrackRenderer {
    static func safeName(_ raw: String) -> String {
        var name = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters))
            .joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while name.utf8.count > 165 { name.removeLast() }
        if ["CON","PRN","AUX","NUL","COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
            "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9"].contains(name.components(separatedBy: ".")[0].uppercased()) {
            name += "_"
        }
        return name.isEmpty ? "Export" : name
    }
    private static func createFolder(_ name: String, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let name = safeName(name)
        var version = 1
        while true {
            let path = directory.appendingPathComponent(version == 1 ? name : "\(name) - \(version)", isDirectory: true)
            do {
                try fm.createDirectory(at: path, withIntermediateDirectories: false)
                return path
            } catch {
                guard (error as NSError).code == NSFileWriteFileExistsError || fm.fileExists(atPath: path.path) else { throw error }
                version += 1
            }
        }
    }
    static func run(_ projects: [MultitrackExportProject], cancellation: AudioExportCancellation,
                    progress: (Double, String) -> Void) throws {
        let fm = FileManager.default
        let count = projects.reduce(0) { total, config in
            let children = Dictionary(grouping: config.song.parts.compactMap { $0.parentRegionID }, by: { $0 })
            return total + config.regions.filter { config.selection.contains($0.id) }.reduce(0) {
                $0 + max(1, children[$1.id]?.count ?? 0)
            }
        }
        var completed = 0
        var created: [URL] = []
        let grants = Set(projects.flatMap { [$0.mediaDirectory, $0.destination].compactMap { $0 } })
            .filter { $0.startAccessingSecurityScopedResource() }
        var success = false
        defer {
            if !success { for path in created.reversed() { try? fm.removeItem(at: path) } }
            grants.forEach { $0.stopAccessingSecurityScopedResource() }
        }
        for config in projects {
            guard let destination = config.destination else { continue }
            var song = config.song
            for index in song.tracks.indices {
                song.tracks[index].solo = false
                if !config.ignoreMutedTracks { song.tracks[index].mute = false }
                if !config.ignoreMutedItems {
                    for item in song.tracks[index].clips.indices where song.tracks[index].clips[item].muted == true {
                        song.tracks[index].clips[item].muted = false
                    }
                }
            }
            var project = config.project
            project.masterMute = false; project.masterSolo = false
            var audio = song
            for index in audio.parts.indices { audio.parts[index].pitchSemitones = nil }
            for row in audio.tracks.indices {
                let track = audio.tracks[row]
                audio.tracks[row].clips = track.clips.filter { AudioSeparation.accepts($0, on: track) }
                if audio.tracks[row].clips.isEmpty { audio.tracks[row].audioFile = nil }
            }
            let childrenByParent = Dictionary(grouping: song.parts.filter { $0.parentRegionID != nil }) { $0.parentRegionID! }
            for root in config.regions where config.selection.contains(root.id) {
                if cancellation.cancelled { throw CancellationError() }
                let rootFolder = try createFolder(root.displayName, in: destination)
                created.append(rootFolder)
                let children = (childrenByParent[root.id] ?? []).sorted { song.playbackRegionStart($0) < song.playbackRegionStart($1) }
                let fullItems = !children.isEmpty
                var owners: [UUID: UUID] = [:]
                if fullItems {
                    for clip in song.tracks.flatMap(\.clips) {
                        owners[clip.id] = song.dominantUnifiedOwner(at: clip.startTime, end: clip.startTime + clip.duration,
                            group: root.id, preferred: clip.regionOwnerID)
                    }
                }
                var entries: [MultitrackDrawerData.Entry] = []
                for part in fullItems ? children : [root] {
                    if cancellation.cancelled { throw CancellationError() }
                    let folder = fullItems ? try createFolder(part.displayName, in: rootFolder) : rootFolder
                    let message = "\(completed + 1)/\(count) • \(config.project.name) • \(part.displayName)"
                    progress(Double(completed) / Double(max(1, count)), message)
                    var names = MediaFileNames(directory: folder)
                    var jobs: [AudioExportFormat: [AudioExportJob]] = [:]
                    var sourceItems: [AudioExportFormat: Set<UUID>] = [:]
                    var mixedTracks = Set<UUID>()
                    var printedRateChange = false
                    var renderedStems: [MultitrackRegionData.RenderedStem] = []
                    var lyricsFiles: [String] = []
                    var savedTracks: [UUID: Track] = [:]
                    var copiedAssets: [URL: String] = [:]
                    for (index, track) in song.tracks.enumerated() where !track.mute {
                        let clips = track.clips.filter { clip in
                            guard clip.muted != true else { return false }
                            let end = clip.startTime + clip.duration
                            return fullItems
                                ? owners[clip.id] == part.id
                                : clip.startTime < part.endTime && end > part.startTime
                        }
                        var stored = config.song.tracks[index]
                        let originals = Dictionary(uniqueKeysWithValues: stored.clips.map { ($0.id, $0) })
                        stored.clips = []
                        let audioItems = clips.filter { AudioSeparation.accepts($0, on: track) }
                        if track.kind == .standard, !audioItems.isEmpty {
                            let items = audioItems.sorted { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime }
                            func format(for clip: AudioClip) -> AudioExportFormat {
                                let path = clip.audioFile?.path ?? track.audioFile?.path ?? ""
                                switch (path as NSString).pathExtension.lowercased() {
                                case "wav", "wave": return .wav
                                case "aif", "aiff", "aifc": return .aiff
                                default: return .mp3
                                }
                            }
                            func stemItem(_ clip: AudioClip) -> MultitrackRegionData.RenderedStem.Item {
                                let segments = song.tempoAudioSegments(clip)
                                if abs(clip.audioRate - 1) > 1e-7 || segments.contains(where: { abs($0.audioRate - 1) > 1e-7 }) {
                                    printedRateChange = true
                                }
                                return .init(offset: clip.startTime - part.startTime, duration: clip.duration,
                                    rate: segments.first?.audioRate ?? clip.audioRate)
                            }
                            let label = safeName(track.name + " – " + part.displayName)
                            if fullItems {
                                for (index, clip) in items.enumerated() {
                                    let encoding = format(for: clip)
                                    let filename = names.allocate(label + String(format: " %03d.", index + 1) + encoding.fileExtension)
                                    jobs[encoding, default: []].append(AudioExportJob(id: clip.id.uuidString, fileName: filename,
                                        start: clip.startTime, end: clip.startTime + clip.duration, track: track.id, clip: clip.id))
                                    renderedStems.append(.init(file: filename, track: track.id, items: [stemItem(clip)]))
                                }
                            } else {
                                let grouped = Dictionary(grouping: items, by: format(for:))
                                if grouped.count > 1 { mixedTracks.insert(track.id) }
                                for encoding in AudioExportFormat.allCases {
                                    guard let matching = grouped[encoding] else { continue }
                                    sourceItems[encoding, default: []].formUnion(matching.map(\.id))
                                    let filename = names.allocate(label + "." + encoding.fileExtension)
                                    jobs[encoding, default: []].append(AudioExportJob(id: track.id.uuidString, fileName: filename,
                                        start: part.startTime, end: part.endTime, track: track.id, clip: nil))
                                    renderedStems.append(.init(file: filename, track: track.id, items: matching.map(stemItem)))
                                }
                            }
                        }
                        for clip in clips where clip.isProjectionMedia {
                            if cancellation.cancelled { throw CancellationError() }
                            guard let path = clip.audioFile?.path else { continue }
                            let source = path.hasPrefix("/") ? URL(fileURLWithPath: path) : config.mediaDirectory.projectMedia(path)
                            let filename: String
                            if let copied = copiedAssets[source] { filename = copied }
                            else {
                                filename = names.allocate(safeName(source.deletingPathExtension().lastPathComponent) + "." + source.pathExtension)
                                try fm.copyItem(at: source, to: folder.appendingPathComponent(filename))
                                copiedAssets[source] = filename
                            }
                            var item = originals[clip.id] ?? clip
                            item.audioFile = AudioFile(path: "Videos/" + filename)
                            item.waveform = []; item.waveformChannels = nil
                            stored.clips.append(item)
                        }
                        if track.kind.isTeleprompter {
                            let number = track.kind == .teleprompt ? 1 : 2
                            let textClips = clips.filter { $0.text != nil && !$0.isProjectionMedia }
                            stored.clips += textClips.map { originals[$0.id] ?? $0 }
                            let lyrics = JLLyricsDocument(teleprompter: number, clips: textClips, origin: part.startTime)
                            if !lyrics.items.isEmpty {
                                let filename = names.allocate(safeName(part.displayName) + ".jllyrics")
                                try JSONEncoder().encode(lyrics).write(to: folder.appendingPathComponent(filename), options: .atomic)
                                lyricsFiles.append(filename)
                            }
                        }
                        let hasProgramChanges = track.programChanges?.contains {
                            $0.position >= part.startTime && $0.position < part.endTime
                        } == true
                        if !stored.clips.isEmpty || hasProgramChanges || (track.kind == .standard && !audioItems.isEmpty) {
                            savedTracks[track.id] = stored
                        }
                    }
                    let ordered = config.song.tracks.compactMap { savedTracks[$0.id] }
                    let manifest = try MultitrackRegionData.snapshot(song: config.song, region: part, tracks: ordered,
                        renderedStems: renderedStems, lyricsFiles: lyricsFiles, fullItems: fullItems, tunerUnbaked: true, printedRateChange: printedRateChange)
                    if fullItems {
                        let flag = song.markers?.first { $0.sourceRegionID == part.id && $0.unifiedRegionID == root.id }
                        entries.append(.init(folder: folder.lastPathComponent, offset: part.startTime - root.startTime,
                            cue: song.playbackRegionStart(part) - root.startTime, data: manifest,
                            cueID: flag?.id, cueName: flag?.name, cueColor: flag?.color))
                    } else {
                        let manifestURL = folder.appendingPathComponent(MultitrackRegionData.prefix + safeName(part.name))
                        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
                    }
                    var finishedJobs = 0
                    let jobCount = jobs.values.reduce(0) { $0 + $1.count }
                    for format in AudioExportFormat.allCases {
                        guard let batch = jobs[format] else { continue }
                        var renderingSong = audio
                        let regionItems = sourceItems[format] ?? []
                        let splitTracks = Set(batch.compactMap(\.track)).intersection(mixedTracks)
                        for row in renderingSong.tracks.indices {
                            if splitTracks.contains(renderingSong.tracks[row].id) {
                                renderingSong.tracks[row].clips.removeAll { !regionItems.contains($0.id) }
                                if renderingSong.tracks[row].clips.isEmpty { renderingSong.tracks[row].audioFile = nil }
                            }
                        }
                        try OfflineAudioExport.run(project: project, song: renderingSong, plan: AudioExportPlan(jobs: batch),
                            mediaDirectory: config.mediaDirectory, outputDirectory: folder, sampleRate: 48000,
                            encoding: AudioExportEncoding(format: format, bitrate: 320), cancellation: cancellation) {
                            let rendered = (Double(finishedJobs) + $0.fraction * Double(batch.count)) / Double(jobCount)
                            progress((Double(completed) + rendered) / Double(max(1, count)), message)
                        }
                        finishedJobs += batch.count
                    }
                    completed += 1
                }
                if fullItems {
                    let drawer = MultitrackDrawerData(version: 2, name: root.name, duration: root.endTime - root.startTime,
                        color: root.color, uppercaseName: root.uppercaseName, entries: entries, pitchSemitones: root.pitchSemitones)
                    try drawer.validate()
                    let manifestURL = rootFolder.appendingPathComponent(MultitrackRegionData.prefix + safeName(root.name))
                    try JSONEncoder().encode(drawer).write(to: manifestURL, options: .atomic)
                }
            }
        }
        if cancellation.cancelled { throw CancellationError() }
        success = true
        progress(1, "")
    }
}
