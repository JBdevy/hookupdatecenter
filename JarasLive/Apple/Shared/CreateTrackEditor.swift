import SwiftUI

struct CreateTrackEditor: View {
    @ObservedObject var show: ShowController
    var afterTrack: UUID? = nil
    let close: () -> Void
    var created: ([UUID]) -> Void = { _ in }
    @State private var kind = TrackKind.standard
    @State private var name = ""
    @State private var countDraft = "1"
    @State private var sequential = false
    @State private var inputChannels = 0
    @State private var invalidCount = false
    @State private var countShake = 0.0
    @State private var failure = ""
    @FocusState private var nameFocused: Bool
    private var specialTrackExists: Bool {
        kind != .standard && show.snapshot.project.songs.contains { $0.tracks.contains { $0.kind == kind } }
    }
    private var unavailable: Bool { specialTrackExists }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Criar pista").font(.title2.bold())
            Picker("Type", selection: $kind) {
                ForEach(TrackKind.allCases.filter { $0 != .video }, id: \.self) { kind in Text(LocalizedStringKey(kind.title)).tag(kind) }
            }
            if kind == .standard {
                TextField("Nome da pista", text: $name).textFieldStyle(.roundedBorder)
                    .focused($nameFocused).onSubmit(create)
                HStack(spacing: 12) {
                    Toggle("Sequential", isOn: $sequential).disabled(inputChannels == 0)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                    Spacer()
                    Text("Count")
                    TextField("1", text: $countDraft).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).frame(width: 62).accessibilityLabel("Count")
                        .onSubmit(create)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalidCount ? Color.red : .clear, lineWidth: 1.5))
                        .modifier(InputValidationShake(animatableData: countShake))
                }
                if inputChannels == 0 {
                    Text("No audio inputs available.").font(.caption).foregroundStyle(JarasTheme.secondary)
                }
                if invalidCount {
                    Text("Enter a positive whole number.").font(.caption).foregroundStyle(.red)
                }
            } else { Text(LocalizedStringKey(kind.title)).foregroundStyle(JarasTheme.secondary) }
            if specialTrackExists {
                Text(String(format: JarasLocalization.string("A %@ track already exists."), JarasLocalization.string(kind.title)))
                    .font(.caption).foregroundStyle(.orange)
            }
            if !failure.isEmpty { Text(LocalizedStringKey(failure)).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Criar", action: create).keyboardShortcut(.defaultAction)
                    .disabled(unavailable || (kind == .standard && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.buttonStyle(StageButtonStyle(color: JarasTheme.accent))
        }.padding(28).frame(width: 370).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear {
                refreshInputs()
                if name.isEmpty { name = String(format: JarasLocalization.string("Track %lld"), (show.current?.tracks.count ?? 0) + 1) }
                nameFocused = true
            }
            .onChange(of: kind) { _ in failure = ""; nameFocused = kind == .standard }
            .onReceive(AudioDeviceSettings.shared.$devices.dropFirst()) { _ in refreshInputs() }
            .onReceive(AudioDeviceSettings.shared.$inputUID.dropFirst()) { _ in refreshInputs() }
    }
    private func refreshInputs() {
        inputChannels = TrackRecording.shared.inputChannels
        if inputChannels == 0 { sequential = false }
    }
    private func validateCount() -> Int? {
        guard let parsed = Int(countDraft.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
            invalidCount = true
            withAnimation(.linear(duration: 0.32)) { countShake += 1 }
            return nil
        }
        invalidCount = false
        return parsed
    }
    private func create() {
        guard !unavailable else { return }
        let count: Int
        if kind == .standard { guard let value = validateCount() else { return }; count = value }
        else { count = 1 }
        let inputs: [OutputPatch]
        if kind == .standard && sequential {
            inputs = ShowController.sequentialInputPatches(count: count, channels: inputChannels)
        } else if kind == .standard && inputChannels > 0 {
            inputs = Array(repeating: OutputPatch(firstChannel: 1, channelCount: min(2, inputChannels)), count: count)
        } else { inputs = [] }
        let ids = show.addTracks(name: kind == .standard ? name : kind.title, role: kind == .standard ? .other : TrackRole(rawValue: kind.rawValue), count: count, inputPatches: inputs, after: afterTrack)
        guard !ids.isEmpty else { failure = show.message; return }
        created(ids); close()
    }
}
