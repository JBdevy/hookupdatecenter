import Foundation

/// Maintains the order of checked folders independently of the search filter.
struct FolderImportSelection: Equatable {
    let folders: [URL]
    private(set) var selected: [URL] = []
    init(_ urls: [URL]) {
        var seen = Set<URL>()
        folders = urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }
    var allSelected: Bool { !folders.isEmpty && selected.count == folders.count }
    func position(of url: URL) -> Int? { selected.firstIndex(of: url).map { $0 + 1 } }
    mutating func toggle(_ url: URL) {
        guard folders.contains(url) else { return }
        if let index = selected.firstIndex(of: url) { selected.remove(at: index) }
        else { selected.append(url) }
    }
    mutating func toggleAll() {
        if allSelected { selected.removeAll() }
        else {
            let checked = Set(selected)
            selected.append(contentsOf: folders.filter { !checked.contains($0) })
        }
    }
    func matching(_ query: String) -> [URL] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? folders : folders.filter { $0.lastPathComponent.localizedStandardContains(query) }
    }
}
