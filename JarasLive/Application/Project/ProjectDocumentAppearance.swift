import Foundation
#if os(macOS)
import AppKit
#endif

/// A file icon survives Finder's cached type previews. Atomic saves replace the
/// file inode, so attach it after every successful write as well as on open.
enum ProjectDocumentAppearance {
    static func apply(to url: URL) {
        #if os(macOS)
        guard ["jl", "bkjl"].contains(url.pathExtension.lowercased()),
              let iconURL = Bundle.main.url(forResource: "JarasLiveIcon", withExtension: "icns") else { return }
        let apply = {
            guard let icon = NSImage(contentsOf: iconURL) else { return }
            _ = NSWorkspace.shared.setIcon(icon, forFile: url.path, options: [])
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.sync(execute: apply) }
        #endif
    }
}
