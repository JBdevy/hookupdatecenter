import SwiftUI

struct MultiLoopsEditor: View {
    @ObservedObject var show: ShowController
    let regionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var stage = 0
    @State private var name = ""
    @State private var invalid = false
    @State private var shake = 0.0
    @State private var first: UUID?
    @State private var second: UUID?
    @State private var draft: MultiLoop?
    @FocusState private var nameFocused: Bool
    private var region: Part? { show.current?.parts.first { $0.id == regionID } }
    private var loops: [MultiLoop] { region?.multiLoops ?? [] }
    private var availableTracks: [Track] { (show.current?.tracks ?? []).filter { $0.kind == .standard } }
    private var markers: [TimelineMarker] { guard let song = show.current, let region else { return [] }; return song.multiLoopMarkers(in: region) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Multiloop Manager").font(.title2.bold())
            Text(region?.displayName ?? "").foregroundStyle(.secondary)
            if stage == 0 { loopList }
            else if stage == 1 { nameForm }
            else if stage == 2 { markerForm }
            else if let draft { trackForm(draft) }
            Divider()
            HStack {
                Button(stage == 0 ? "Close" : "Cancel") {
                    if stage == 0 { dismiss() } else { stage = 0; draft = nil }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if stage == 1 { Button("Next", action: acceptName).keyboardShortcut(.defaultAction) }
                if stage == 2 { Button("OK", action: acceptMarkers).keyboardShortcut(.defaultAction).disabled(!validPair) }
                if stage == 3 { Button("Save") { if let draft { commit(draft) } }.keyboardShortcut(.defaultAction) }
            }
        }.padding(20).frame(width: 660, height: 490)
    }
    private var loopList: some View {
        VStack {
            HStack {
                Button { name = ""; invalid = false; first = nil; second = nil; stage = 1; nameFocused = true } label: { Image(systemName: "plus") }
                    .help("Create multiloop")
                Spacer()
            }
            ScrollView {
                LazyVStack {
                    ForEach(loops) { loop in
                        HStack {
                            Text(loop.name).lineLimit(1)
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
            Text(name).font(.headline)
            if markers.isEmpty { Text("No markers found").foregroundStyle(.secondary); Spacer() }
            else {
                HStack(alignment: .top, spacing: 18) {
                    markerColumn("Marker 1", selection: $first)
                    markerColumn("Marker 2", selection: $second)
                }
                Text("Choose two different markers in chronological order").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func markerColumn(_ title: String, selection: Binding<UUID?>) -> some View {
        VStack(alignment: .leading) {
            Text(LocalizedStringKey(title)).bold()
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(markers) { marker in
                        Button { selection.wrappedValue = marker.id } label: {
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
    private func acceptMarkers() {
        guard validPair, let first, let second else { return }
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
        draft = next; stage = 3
    }
    private func commit(_ loop: MultiLoop) {
        var next = loops
        if let index = next.firstIndex(where: { $0.id == loop.id }) { next[index] = loop } else { next.append(loop) }
        if show.setMultiLoops(next, region: regionID) { stage = 0; draft = nil }
    }
    private func trackForm(_ loop: MultiLoop) -> some View {
        VStack(alignment: .leading) {
            Text(loop.name).font(.headline)
            HStack {
                Text("Auto Fader")
                Button("−") { draft?.fadeSeconds = max(1, loop.fadeSeconds - 1) }.disabled(loop.fadeSeconds <= 1)
                Text("\(Int(loop.fadeSeconds))s").monospacedDigit().frame(width: 32)
                Button("+") { draft?.fadeSeconds = min(5, loop.fadeSeconds + 1) }.disabled(loop.fadeSeconds >= 5)
            }
            ScrollView {
                LazyVStack {
                    trackRow(id: MultiLoopTrack.masterID, name: "Master", ceiling: show.snapshot.project.masterVolume ?? 1)
                    ForEach(availableTracks) { track in trackRow(id: track.id, name: track.name, ceiling: track.volume) }
                }
            }
        }
    }
    private func trackRow(id: UUID, name: String, ceiling: Double) -> some View {
        let rule = draft?.tracks.first { $0.id == id } ?? MultiLoopTrack(id: id, gain: ceiling)
        return HStack {
            Text(name).lineLimit(1).frame(width: 155, alignment: .leading)
            Slider(value: Binding(get: { min(ceiling, rule.gain) }, set: { value in change(id) { $0.gain = min(ceiling, value) } }), in: 0...max(0.000001, ceiling)).disabled(ceiling <= 0)
            Text(rule.gain <= 0 ? "−∞" : String(format: "%.1f dB", 20 * log10(max(0.000001,min(ceiling,rule.gain))))).monospacedDigit().font(.caption).frame(width: 62)
            flag("Auto Fader", active: rule.autoFader, color: .green) { change(id) { $0.autoFader.toggle() } }
            flag("M", active: rule.mute, color: .red) { change(id) { $0.mute.toggle() } }
            flag("S", active: rule.solo, color: .yellow) { change(id) { $0.solo.toggle() } }
        }.padding(.vertical, 5)
    }
    private func flag(_ label: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.caption.bold()).padding(5).background(active ? color : Color.white.opacity(0.1)).foregroundStyle(active ? .black : .white).cornerRadius(3) }.buttonStyle(.plain)
    }
    private func change(_ id: UUID, edit: (inout MultiLoopTrack) -> Void) {
        guard var next = draft, let i = next.tracks.firstIndex(where: { $0.id == id }) else { return }
        edit(&next.tracks[i]); draft = next
    }
}
