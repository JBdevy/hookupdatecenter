private final class MigrationLayoutProbeView: NSView {
    var role = ""
    override var isFlipped: Bool { true }
}
private struct MigrationLayoutProbe: NSViewRepresentable {
    let role: String
    func makeNSView(context: Context) -> MigrationLayoutProbeView { MigrationLayoutProbeView() }
    func updateNSView(_ view: MigrationLayoutProbeView, context: Context) { view.role = role }
}
private func migrationDescendants<T: NSView>(_ type: T.Type, _ root: NSView) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { migrationDescendants(type, $0) }
}
@MainActor private func settleMigrationLayout(_ root: NSView) {
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    root.layoutSubtreeIfNeeded()
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ProjectMigrationNotice(notice: "", language: "en", dismiss: {}))
    if #available(macOS 13, *) { host.sizingOptions = [] }
    if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
    window.contentView = host
    for language in ["pt-BR", "en"] {
        let title = JarasLocalization.string("Project migration", language: language)
        precondition(title == (language == "pt-BR" ? "Migração de projeto" : "Project migration"))
        let summary = JarasLocalization.string("Project imported. Review these notes before playback.", language: language)
        precondition(summary == (language == "pt-BR" ? "Projeto importado. Confira estes avisos antes de reproduzir." : "Project imported. Review these notes before playback."))
        let name = "Pista \"principal\" 100% · VST: Compressor 50% %@"
        let format = JarasLocalization.string("%@: %@ was not imported; only VST3 effects are supported during REAPER migration.", language: language)
        let warning = String(format: format, "Synth", name)
        precondition(warning.contains(name))
        precondition(warning.contains(language == "pt-BR" ? "não foi importado" : "was not imported"))
        for count in [1, 200] {
            let notes = (0..<count).map { "\($0 + 1) · " + warning }.joined(separator: "\n\n")
            host.rootView = ProjectMigrationNotice(notice: notes, language: language, dismiss: {})
            for size in [CGSize(width: 520, height: count == 1 ? 220 : 360), CGSize(width: 440, height: 300), CGSize(width: 320, height: 240)] {
                window.setContentSize(size); settleMigrationLayout(host)
                let probes = Dictionary(uniqueKeysWithValues: migrationDescendants(MigrationLayoutProbeView.self, host).map { ($0.role, $0) })
                let header = probes["header"]!, details = probes["details"]!, ok = probes["ok"]!
                let headerRect = header.convert(header.bounds, to: host), detailsRect = details.convert(details.bounds, to: host), okRect = ok.convert(ok.bounds, to: host)
                precondition(host.bounds.insetBy(dx: -0.1, dy: -0.1).contains(headerRect), "Header stays visible: \(size)")
                precondition(host.bounds.insetBy(dx: -0.1, dy: -0.1).contains(okRect), "OK stays on screen: \(size), \(okRect)")
                precondition(okRect.width >= 64 && okRect.height >= 24)
                precondition(!detailsRect.intersects(okRect), "Details never overlap the dismiss action")
                let scroll = migrationDescendants(NSScrollView.self, host).first!
                precondition(!ok.isDescendant(of: scroll), "OK must be outside the scrolling text")
                if count > 1 {
                    let document = scroll.documentView!
                    precondition(document.bounds.height > scroll.contentView.bounds.height, "Large reports scroll instead of growing the dialog")
                    document.scroll(CGPoint(x: 0, y: document.bounds.height))
                    settleMigrationLayout(host)
                    precondition(ok.convert(ok.bounds, to: host) == okRect, "Scrolling details keeps OK fixed")
                }
                print("MIGRATION_NOTICE_LAYOUT_OK language=\(language) warnings=\(count) viewport=\(size)")
            }
        }
    }
    window.close()
}
