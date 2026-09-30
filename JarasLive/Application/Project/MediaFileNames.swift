import Foundation

/// Allocate once per import batch, including names retained for Undo.
struct MediaFileNames {
    private var used: Set<String> = []
    init(directory: URL) {
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                used.insert(url.lastPathComponent.lowercased())
            }
        }
    }
    mutating func allocate(_ name: String, forceSuffix: Bool = false) -> String {
        let clean = name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        let ext = (clean as NSString).pathExtension
        var stem = (clean as NSString).deletingPathExtension
        while stem.utf8.count > 220 { stem.removeLast() }
        let tail = ext.isEmpty ? "" : "." + ext
        var index = forceSuffix ? 1 : 0
        while true {
            let candidate = stem + (index == 0 ? "" : String(format: "-%02d", index)) + tail
            if used.insert(candidate.lowercased()).inserted { return candidate }
            index += 1
        }
    }
}
