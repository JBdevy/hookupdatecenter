import SwiftUI

struct DAWActionsList: View {
    @ObservedObject var show: ShowController
    @ObservedObject private var mappings = ControlMappings.shared
    @State private var inputKind = "keyboard"
    @State private var category = DAWActionCategory.transport
    @State private var searchText = ""
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var categories: [DAWActionCategory] { DAWActionCategory.allCases }
    private var categoryActions: [DAWAction] {
        let actions = query.isEmpty ? category.actions : DAWAction.visible
        #if os(iOS)
        // Native iPad has a Track Mixer and teleprompter panel, but no separate
        // Hoz-Mixer/video windows or local project tabs to control.
        return actions.filter { ![.toggleBarMixer, .toggleVideo, .previousProjectTab, .nextProjectTab].contains($0) }
        #else
        return actions
        #endif
    }
    private var filteredActions: [DAWAction] {
        categoryActions.filter { action in
            (inputKind == "midi" ? action.supportsMIDI : !action.continuous) &&
            (query.isEmpty || JarasLocalization.string(action.title).localizedStandardContains(query) ||
             action.title.localizedStandardContains(query))
        }
    }
    private struct ResetRequest { let action: DAWAction; let kind: String }
    @State private var resetRequest: ResetRequest?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(JarasTheme.secondary)
                TextField("Search actions", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Clear search")
                }
            }.padding(8).background(JarasTheme.display).cornerRadius(6)
            categoryTabs
            Picker("Input", selection: $inputKind) {
                Text("Keyboard").tag("keyboard")
                Text("MIDI").tag("midi")
            }.pickerStyle(.segmented)
            Text("Actions are saved for all projects.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            if !mappings.error.isEmpty { Text(mappings.error).font(.jarasCaption).foregroundStyle(.red) }
            if filteredActions.isEmpty { Text("No actions found").font(.jarasCaption).foregroundStyle(JarasTheme.secondary) }
            ForEach(filteredActions, id: \.self) { action in
                let binding = mappings.actions.binding(action)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(LocalizedStringKey(action.title)).font(.jarasHeadline)
                        Spacer()
                        Button("Reset") { resetRequest = ResetRequest(action: action, kind: inputKind) }.font(.jarasCaption)
                    }
                    if action.needsTrack {
                        HStack {
                            Text("Track").font(.jarasCaption)
                            TextField("Selected track", text: Binding(get: { binding.trackNumber.map(String.init) ?? "" }, set: { text in
                                if text.isEmpty { mappings.setActionTrack(action, number: nil) }
                                else if let number = Int(text) { mappings.setActionTrack(action, number: number) }
                            })).frame(width: 90).textFieldStyle(.roundedBorder)
                            Text(targetName(binding.trackNumber)).font(.jarasCaption).foregroundStyle(JarasTheme.secondary).lineLimit(1)
                        }
                    }
                    HStack(spacing: 10) {
                        if inputKind == "keyboard" && action.fixedKeyboard {
                            Label(binding.keyboard?.label ?? "", systemImage: "lock.fill").font(.jarasCaption).frame(width: 140, alignment: .leading)
                        } else {
                            inputButton(action, kind: inputKind, input: inputKind == "keyboard" ? binding.keyboard : binding.midi)
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(JarasTheme.panel).cornerRadius(6)
            }
        }
        .onChange(of: category) { value in
            searchText = ""
            if value == .volume { inputKind = "midi" }
            if value == .shortcuts { inputKind = "keyboard" }
        }
        .alert("Restore this mapping?", isPresented: Binding(get: { resetRequest != nil }, set: { if !$0 { resetRequest = nil } }), presenting: resetRequest) { request in
            Button("Cancel", role: .cancel) { resetRequest = nil }
            Button("Restore") { mappings.resetAction(request.action, kind: request.kind); resetRequest = nil }
        } message: { request in
            Text(LocalizedStringKey(request.action.title))
        }
    }
    @ViewBuilder private var categoryTabs: some View {
        #if os(macOS)
        // A native segmented control keeps the intrinsic width of all six
        // labels. Let tabs wrap instead of widening the entire scroll content.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(categories) { item in
                Button { category = item } label: {
                    Text(LocalizedStringKey(item.rawValue))
                        .font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(query.isEmpty && category == item ? JarasTheme.accent.opacity(0.18) : JarasTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(query.isEmpty && category == item ? JarasTheme.accent : JarasTheme.text)
                    .accessibilityAddTraits(query.isEmpty && category == item ? .isSelected : [])
            }
        }
        #else
        Picker("Category", selection: $category) {
            ForEach(categories) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }.pickerStyle(.segmented)
        #endif
    }
    private func targetName(_ number: Int?) -> String {
        guard let number else { return JarasLocalization.string("Selected track") }
        return show.actionTrack(number: number)?.name ?? JarasLocalization.string("Track unavailable")
    }
    private func inputButton(_ action: DAWAction, kind: String, input: ControlInput?) -> some View {
        HStack(spacing: 4) {
            Button { mappings.beginAction(action, kind: kind) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(kind == "keyboard" ? "Keyboard" : "MIDI")).font(.jarasCaption2).foregroundStyle(JarasTheme.secondary)
                    Text(input?.label ?? JarasLocalization.string("Map control")).font(.jarasCaption).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6).contentShape(Rectangle())
            }.buttonStyle(.plain).background(JarasTheme.display).cornerRadius(4)
            if input != nil {
                Button { mappings.removeActionInput(action, kind: kind) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Remove mapping")
            }
        }.frame(maxWidth: .infinity)
    }
}
