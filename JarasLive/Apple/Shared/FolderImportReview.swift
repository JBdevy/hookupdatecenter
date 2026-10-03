import SwiftUI

struct FolderImportReview: View {
    @State private var selection: FolderImportSelection
    @State private var query = ""
    let appending: Bool
    let cancel: () -> Void
    let confirm: ([URL]) -> Void

    init(folders: [URL], selectedFolders: [URL] = [], appending: Bool = false,
         cancel: @escaping () -> Void, confirm: @escaping ([URL]) -> Void) {
        var selection = FolderImportSelection(folders)
        for folder in selectedFolders where selection.position(of: folder) == nil { selection.toggle(folder) }
        _selection = State(initialValue: selection)
        self.appending = appending
        self.cancel = cancel; self.confirm = confirm
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose folders").font(.title3.bold())
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(JarasTheme.secondary)
                    TextField("Search folders", text: $query).textFieldStyle(.plain)
                }.padding(9).frame(maxWidth: 310).background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 6))
                Spacer(minLength: 0)
            }
            HStack {
                Button(selection.allSelected ? "Deselect all" : "Select all") { selection.toggleAll() }
                Spacer()
                Text("\(selection.selected.count) / \(selection.folders.count)").font(.caption.monospacedDigit()).foregroundStyle(JarasTheme.secondary)
            }
            Text(LocalizedStringKey(appending
                ? "Songs will be added in this order after the last song in the open project."
                : "Folders will be placed on the grid in the order you check them."))
                .font(.caption).foregroundStyle(JarasTheme.secondary)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Folders").font(.caption.bold()).foregroundStyle(JarasTheme.secondary)
                    ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(selection.matching(query), id: \.self) { folder in
                        let order = selection.position(of: folder)
                        Button { selection.toggle(folder) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: order == nil ? "square" : "checkmark.square.fill")
                                    .foregroundStyle(order == nil ? JarasTheme.secondary : JarasTheme.green)
                                    .font(.system(size: 16)).frame(width: 20)
                                Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if let order { Text(String(format: "%02d", order)).font(.caption.monospacedDigit().bold()).foregroundStyle(JarasTheme.green) }
                            }.padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34)
                                .background(order == nil ? JarasTheme.panel : JarasTheme.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(folder.lastPathComponent)
                            .accessibilityValue(order.map { String($0) } ?? "Not selected")
                            .jarasHelp(folder.path)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(JarasTheme.line).frame(width: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text("All regions preview").font(.caption.bold()).foregroundStyle(JarasTheme.secondary)
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(selection.selected.enumerated()), id: \.element) { entry in
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 2).fill(JarasTheme.green).frame(width: 3)
                                    Text(String(format: "%02d", entry.offset + 1))
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                                        .frame(minWidth: 20, alignment: .leading)
                                    Text(entry.element.lastPathComponent).font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.horizontal, 8).padding(.vertical, 7).frame(height: 34)
                                    .background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 5))
                                    .jarasHelp(entry.element.path)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { confirm(selection.selected) }
                    .buttonStyle(StageButtonStyle(color: JarasTheme.green))
                    .keyboardShortcut(.defaultAction).disabled(selection.selected.isEmpty)
            }
        }
    }
}
