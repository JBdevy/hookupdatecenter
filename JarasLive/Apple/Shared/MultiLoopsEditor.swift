import SwiftUI

struct MultiLoopsEditor: View {
    @ObservedObject var show: ShowController
    let regionID: UUID
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var stage = 0
    @State private var name = ""
    @State private var invalid = false
    @State private var shake = 0.0
    @State private var first: UUID?
    @State private var second: UUID?
    @State private var draft: MultiLoop?
    @State private var pairWarning = false
    @State private var markerWarning = false
    @State private var trackSelection = MultiLoopTrackSelection()
    @State private var gainDrag: MultiLoopGainDrag?
    @FocusState private var nameFocused: Bool
    private var region: Part? { show.current?.parts.first { $0.id == regionID } }
    private var totalLoop: Bool { region?.totalLoop == true }
    private var bypassed: Bool { guard let song = show.current, let region else { return false }; return song.multiLoopsBypassed(in: region) }
    private var loops: [MultiLoop] { region?.multiLoops ?? [] }
    private var availableTracks: [Track] { (show.current?.tracks ?? []).filter { $0.kind == .standard } }
    private var markers: [TimelineMarker] { guard let song = show.current, let region else { return [] }; return song.multiLoopMarkers(in: region) }
    private var hasEnoughMarkers: Bool { markers.count >= 2 }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Multiloop Manager").font(.jarasTitle2.bold())
            Text(region?.displayName ?? "").foregroundStyle(.secondary)
            if stage == 0 { loopList }
            else if stage == 1 { nameForm }
            else if stage == 2 { markerForm }
            else if let draft { trackForm(draft) }
            Divider()
            HStack {
                Button(stage == 0 ? "Close" : "Cancel") {
                    if stage == 0 { if let close { close() } else { dismiss() } } else { stage = 0; draft = nil }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if stage == 1 { Button("Next", action: acceptName).keyboardShortcut(.defaultAction) }
                if stage == 2 { Button("OK", action: acceptMarkers).keyboardShortcut(.defaultAction).disabled(!validPair) }
                if stage == 3 { Button("Save") { if let draft { commit(draft) } }.keyboardShortcut(.defaultAction) }
            }
        }.padding(20)
            #if os(macOS)
            .frame(width: 760, height: 540)
            #else
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            .alert("A multiloop cannot exist inside another multiloop.", isPresented: $pairWarning) {
                Button("OK", role: .cancel) { pairWarning = false }
            }
            .alert("Multiloop", isPresented: $markerWarning) {
                Button("OK", role: .cancel) { markerWarning = false }
            } message: {
                Text("Create at least 2 section markers enabled for looping in this song before creating a multiloop.")
            }
    }
    private var loopList: some View {
        VStack {
            HStack {
                Button {
                    guard hasEnoughMarkers else { markerWarning = true; return }
                    name = ""; invalid = false; first = nil; second = nil; stage = 1; nameFocused = true
                } label: { Image(systemName: "plus") }
                    .jarasHelp("Create multiloop")
                    .opacity(hasEnoughMarkers ? 1 : 0.4)
                    .disabled(bypassed && hasEnoughMarkers)
                Button { show.setTotalLoop(!totalLoop, region: regionID) } label: {
                    Text("Total Loop").font(.jarasCallout.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(totalLoop ? JarasTheme.green : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(totalLoop ? Color.black : Color.white)
                }.buttonStyle(.plain).accessibilityValue(totalLoop ? "On" : "Off")
                Spacer()
            }
            ScrollView {
                LazyVStack {
                    ForEach(loops) { loop in
                        HStack {
                            flag(loop.isEnabled ? "On" : "Off", active: loop.isEnabled, color: JarasTheme.green) {
                                var next = loop; next.enabled = !loop.isEnabled; commit(next)
                            }.jarasHelp("Enable multiloop").disabled(bypassed)
                            Text(loop.name).lineLimit(1).opacity(bypassed || !loop.isEnabled ? 0.45 : 1)
                            if bypassed { Text("Bypass").font(.jarasCaption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Markers") { draft = loop; name = loop.name; first = loop.marker1; second = loop.marker2; stage = 2 }
                            Button("Edit") { editTracks(loop) }
                            Button("Delete", role: .destructive) { _ = show.setMultiLoops(loops.filter { $0.id != loop.id }, region: regionID) }
                        }.padding(8).background(Color.white.opacity(0.05))
                    }
                }
            }
        }
    }
    private var nameForm: some View {
        VStack(alignment: .leading) {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                .onSubmit(acceptName)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalid ? .red : .clear))
                .modifier(InputValidationShake(animatableData: shake))
                .onChange(of: name) { _ in invalid = false }
            if invalid { Text("Choose a name").foregroundStyle(.red) }
            Spacer()
        }
    }
    private func acceptName() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalid = true; withAnimation(.linear(duration: 0.3)) { shake += 1 }; return
        }
        draft = nil; stage = 2
    }
    private var validPair: Bool {
        guard let a = markers.first(where: { $0.id == first }), let b = markers.first(where: { $0.id == second }) else { return false }
        return a.position < b.position
    }
    private var markerForm: some View {
        VStack(alignment: .leading) {
            Text(name).font(.jarasHeadline)
            if markers.isEmpty { Text("No markers found").foregroundStyle(.secondary); Spacer() }
            else {
                HStack(alignment: .top, spacing: 18) {
                    markerColumn("Marker 1", selection: $first, isFirst: true)
                    markerColumn("Marker 2", selection: $second, isFirst: false)
                }
                Text("Choose two different markers in chronological order").font(.jarasCaption).foregroundStyle(.secondary)
            }
        }
    }
    private func markerColumn(_ title: String, selection: Binding<UUID?>, isFirst: Bool) -> some View {
        VStack(alignment: .leading) {
            Text(LocalizedStringKey(title)).bold()
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(markers) { marker in
                        Button {
                            let a = isFirst ? marker.id : first, b = isFirst ? second : marker.id
                            if conflicts(first: a, second: b) { pairWarning = true }
                            else { selection.wrappedValue = marker.id }
                        } label: {
                            HStack {
                                Image(systemName: selection.wrappedValue == marker.id ? "largecircle.fill.circle" : "circle")
                                Text(marker.name).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.2fs", marker.position)).monospacedDigit()
                            }.padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.frame(maxWidth: .infinity)
    }
    private func conflicts(first: UUID?, second: UUID?) -> Bool {
        guard let first, let second else { return false }
        var candidate = draft ?? MultiLoop(name: name, marker1: first, marker2: second)
        candidate.marker1 = first; candidate.marker2 = second
        return show.current?.multiLoopConflicts(candidate) == true
    }
    private func acceptMarkers() {
        guard validPair, let first, let second, !bypassed else { return }
        if conflicts(first: first, second: second) { pairWarning = true; return }
        var next = draft ?? MultiLoop(name: name.trimmingCharacters(in: .whitespacesAndNewlines), marker1: first, marker2: second)
        next.marker1 = first; next.marker2 = second
        commit(next)
    }
    private func editTracks(_ loop: MultiLoop) {
        var next = loop
        let channels = [(MultiLoopTrack.masterID, show.snapshot.project.masterVolume ?? 1)] + availableTracks.map { ($0.id, $0.volume) }
        let availableIDs = Set(channels.map { $0.0 })
        next.tracks.removeAll { !availableIDs.contains($0.id) }
        for (id, volume) in channels where !next.tracks.contains(where: { $0.id == id }) { next.tracks.append(MultiLoopTrack(id: id, gain: volume)) }
        draft = next; trackSelection = MultiLoopTrackSelection(); gainDrag = nil; stage = 3
    }
    private func commit(_ loop: MultiLoop) {
        var next = loops
        if let index = next.firstIndex(where: { $0.id == loop.id }) { next[index] = loop } else { next.append(loop) }
        if show.setMultiLoops(next, region: regionID) { stage = 0; draft = nil }
    }
    private func trackForm(_ loop: MultiLoop) -> some View {
        let tracks = availableTracks
        let groups = Set(tracks.compactMap(\.parentTrackID))
        let depths = show.current?.trackGroupDepths ?? [:]
        return VStack(alignment: .leading) {
            Text(loop.name).font(.jarasHeadline)
            HStack {
                Text("Auto Fader")
                Button("−") { draft?.fadeSeconds = max(1, loop.fadeSeconds - 1) }.disabled(loop.fadeSeconds <= 1)
                Text("\(Int(loop.fadeSeconds))s").monospacedDigit().frame(width: 32)
                Button("+") { draft?.fadeSeconds = min(5, loop.fadeSeconds + 1) }.disabled(loop.fadeSeconds >= 5)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    trackRow(id: MultiLoopTrack.masterID, name: "Master", ceiling: show.snapshot.project.masterVolume ?? 1)
                    ForEach(tracks) { track in
                        trackRow(id: track.id, name: track.name, ceiling: track.volume,
                                 group: groups.contains(track.id), depth: depths[track.id] ?? 0)
                    }
                }
                // Overlay scrollers must never cover a row's Solo button.
                .padding(.trailing, 20)
            }
        }
    }
    private func trackRow(id: UUID, name: String, ceiling: Double, group: Bool = false, depth: Int = 0) -> some View {
        let rule = draft?.tracks.first { $0.id == id } ?? MultiLoopTrack(id: id, gain: ceiling)
        let master = id == MultiLoopTrack.masterID
        let selected = trackSelection.ids.contains(id)
        return HStack {
            Button { selectTrack(id, additive: true) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? JarasTheme.green : Color.secondary)
            }.buttonStyle(.plain).accessibilityLabel(name).accessibilityValue(selected ? "Selected" : "Not selected")
            HStack(spacing: 7) {
                Image(systemName: master ? "slider.horizontal.3" : group ? "folder.fill" : "waveform")
                    .foregroundStyle(group ? JarasTheme.green : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(group || master ? .jarasCallout.bold() : .jarasCallout).lineLimit(1)
                    if !master { Text(group ? "Track group" : "Track").font(.jarasCaption).foregroundStyle(.secondary) }
                }
            }
            .padding(.leading, CGFloat(min(depth, 4)) * 10)
            .frame(width: 166, alignment: .leading)
            .contentShape(Rectangle())
            #if os(macOS)
            .overlay(MultiLoopSelectionClick { shift, additive in selectTrack(id, extending: shift, additive: additive) })
            #else
            .onTapGesture { selectTrack(id, additive: true) }
            #endif
            .jarasHelp(name)
            Slider(value: Binding(get: { min(ceiling, rule.gain) }, set: { setGain($0, from: id) }),
                   in: 0...max(0.000001, ceiling), onEditingChanged: { editing in
                if editing { beginGainDrag(id) } else { gainDrag = nil }
            }).disabled(ceiling <= 0)
            Text(rule.gain <= 0 ? "−∞" : String(format: "%.1f dB", 20 * log10(max(0.000001,min(ceiling,rule.gain))))).monospacedDigit().font(.jarasCaption).frame(width: 62)
            flag("Auto Fader", active: rule.autoFader, color: .green) { change(id) { $0.autoFader = !rule.autoFader } }
            flag("M", active: rule.mute, color: .red) { change(id) { $0.mute = !rule.mute } }
            flag("S", active: rule.solo, color: .yellow) { change(id) { $0.solo = !rule.solo } }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(selected ? JarasTheme.green.opacity(0.16) : Color.white.opacity(group || master ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? JarasTheme.green.opacity(0.7) : .clear))
    }
    private func flag(_ label: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(LocalizedStringKey(label)).font(.jarasCaption.bold()).padding(5).background(active ? color : Color.white.opacity(0.1)).foregroundStyle(active ? .black : .white).cornerRadius(3) }.buttonStyle(.plain)
    }
    private func change(_ id: UUID, edit: (inout MultiLoopTrack) -> Void) {
        guard var next = draft else { return }
        gainDrag = nil
        let targets = trackSelection.targets(for: id)
        for i in next.tracks.indices where targets.contains(next.tracks[i].id) { edit(&next.tracks[i]) }
        draft = next
    }
    private func selectTrack(_ id: UUID, extending: Bool = false, additive: Bool = false) {
        gainDrag = nil
        trackSelection.select(id, ordered: [MultiLoopTrack.masterID] + availableTracks.map(\.id), extending: extending, additive: additive)
    }
    private func beginGainDrag(_ id: UUID) {
        guard let draft else { return }
        let targets = trackSelection.targets(for: id)
        var ceilings = Dictionary(uniqueKeysWithValues: availableTracks.map { ($0.id, $0.volume) })
        ceilings[MultiLoopTrack.masterID] = show.snapshot.project.masterVolume ?? 1
        gainDrag = MultiLoopGainDrag(source: id, targets: targets, rules: draft.tracks, ceilings: ceilings)
    }
    private func setGain(_ value: Double, from id: UUID) {
        if gainDrag?.source != id { beginGainDrag(id) }
        guard var next = draft, let gains = gainDrag?.gains(at: value) else { return }
        for i in next.tracks.indices { if let gain = gains[next.tracks[i].id] { next.tracks[i].gain = gain } }
        draft = next
    }
}

#if os(macOS)
private struct MultiLoopSelectionClick: NSViewRepresentable {
    let action: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> MultiLoopSelectionClickView { MultiLoopSelectionClickView() }
    func updateNSView(_ view: MultiLoopSelectionClickView, context: Context) { view.action = action }
}
private final class MultiLoopSelectionClickView: NSView {
    var action: ((Bool, Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        action?(event.modifierFlags.contains(.shift), !event.modifierFlags.intersection([.command, .control]).isEmpty)
    }
    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { mouseDown(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
#endif
