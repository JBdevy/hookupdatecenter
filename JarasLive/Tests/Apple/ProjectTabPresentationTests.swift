import AppKit
import SwiftUI
import Combine

extension Font { static var jarasBody: Font { .body } }
@MainActor final class ShowController {
    struct Snapshot { struct Project { var name = "Untitled" }; var project = Project() }
    var snapshot = Snapshot()
}
@MainActor final class ProjectDocuments: ObservableObject {
    @Published var ready = false
    @Published var opened = UUID()
    @Published var currentURL: URL?
    let show = ShowController()
}
@MainActor final class AppContainer {
    let documents = ProjectDocuments()
    var show: ShowController { documents.show }
    let auth = 0, backend = 0
    var desktopWorkspaceHost: NSHostingView<AnyView>?
    var desktopWorkspaceIdentity: UUID?
    var desktopWorkspaceEnvironment: String?
}
@MainActor final class DesktopProjectTabs: ObservableObject {
    static let shared = DesktopProjectTabs()
    @Published var projects: [AppContainer] = []
    @Published var selected = 0
}
@MainActor struct MainView: View {
    let show: ShowController
    let auth: Int, backend: Int
    @ObservedObject var documents: ProjectDocuments
    var body: some View { Text(show.snapshot.project.name) }
}
@MainActor struct TrackedTitle: NSViewRepresentable {
    static var rendered = ""
    let text: String
    init(_ text: String) { self.text = text }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { Self.rendered = text }
}

// INSERT_WORKSPACE
// INSERT_TITLE

@MainActor private struct DocumentRoot: View {
    let container: AppContainer
    @ObservedObject var documents: ProjectDocuments
    var body: some View {
        VStack {
            DesktopProjectTabName(documents: documents).frame(height: 20)
            ZStack {
                DesktopWorkspaceView(container: container)
                if !documents.ready { Text("Loading") }
            }
        }
    }
}
@MainActor private struct Root: View {
    @ObservedObject var tabs: DesktopProjectTabs
    var body: some View {
        let container = tabs.projects[tabs.selected]
        DocumentRoot(container: container, documents: container.documents)
    }
}
@MainActor private func settle() {
    let deadline = Date(timeIntervalSinceNow: 0.15)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
}
@main struct Runner {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let tabs = DesktopProjectTabs.shared
        let first = AppContainer(), second = AppContainer()
        first.documents.ready = true
        first.documents.currentURL = URL(fileURLWithPath: "/fixture/First.jl")
        tabs.projects = [first, second]
        let window = NSWindow(contentRect: .init(x: 10, y: 10, width: 300, height: 160), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Root(tabs: tabs)); window.orderBack(nil)
        settle()
        precondition(first.desktopWorkspaceHost != nil)
        let firstHost = first.desktopWorkspaceHost
        tabs.selected = 1; settle()
        precondition(second.desktopWorkspaceHost == nil)
        if !CommandLine.arguments.contains("legacy") {
            precondition(firstHost?.isHidden == true, "Loading a new tab must hide the previous document")
        }
        // Completion occurs later, with the same container and selected tab.
        second.show.snapshot.project.name = "Loaded project"
        second.documents.currentURL = URL(fileURLWithPath: "/fixture/Loaded project.jl")
        second.documents.ready = true; second.documents.opened = UUID(); settle()
        let mounted = second.desktopWorkspaceHost != nil && second.desktopWorkspaceIdentity == second.documents.opened
        if CommandLine.arguments.contains("legacy") {
            precondition(!mounted, "Negative control must reproduce the blank tab")
            print("LEGACY_ASYNC_TAB_COMPLETION_LEFT_PREVIOUS_HOST_MOUNTED_REPRODUCED")
            window.close(); return
        }
        precondition(mounted && second.desktopWorkspaceHost?.isHidden == false)
        precondition(TrackedTitle.rendered == "Loaded project", "The title must not remain Untitled until tab switching")
        let secondHost = second.desktopWorkspaceHost
        tabs.selected = 0; settle(); precondition(first.desktopWorkspaceHost === firstHost)
        tabs.selected = 1; settle(); precondition(second.desktopWorkspaceHost === secondHost)
        // Replacing the document inside this tab must replace only its host.
        second.documents.opened = UUID(); settle()
        precondition(second.desktopWorkspaceHost !== secondHost && first.desktopWorkspaceHost === firstHost)
        window.close()
        print("ASYNC_PROJECT_TAB_LOAD_MOUNTS_CORRECT_HOST_AND_TITLE_WITHOUT_TAB_SWITCH_OK")
    }
}
