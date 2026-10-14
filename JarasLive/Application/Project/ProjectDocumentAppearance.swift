import Foundation
#if os(macOS)
import AppKit
#endif

/// Refresh a stale Finder preview when opening a document. Saves use the
/// registered document type icon and must not synchronously enter AppKit.
enum ProjectDocumentAppearance {
    static func apply(to url: URL) {
        #if os(macOS)
        guard ["jl", "bkjl"].contains(url.pathExtension.lowercased()),
              let iconURL = Bundle.main.url(forResource: "CatLiveIcon", withExtension: "icns") else { return }
        let apply = {
            guard let icon = NSImage(contentsOf: iconURL) else { return }
            _ = NSWorkspace.shared.setIcon(icon, forFile: url.path, options: [])
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.sync(execute: apply) }
        #endif
    }
}
