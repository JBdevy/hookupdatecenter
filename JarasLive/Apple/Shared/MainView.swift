import SwiftUI
import UniformTypeIdentifiers
struct MainView: View {
    @ObservedObject var show: ShowController
    @ObservedObject var auth: AuthService
    let backend: MockBackendClient
    @State private var repertoire = true
    @State private var importing = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                #if os(macOS)
                SidebarView(show: show)
                #endif
                #if os(iOS)
                HStack {
                    Text("JARAS LIVE").font(.system(size: 16, weight: .black, design: .rounded)).foregroundStyle(JarasTheme.accent)
                    Spacer()
                    ForEach([("Repertórios","waveform"),("Configurações","gearshape")], id: \.0) { item in Button { show.section = item.0 } label: { Image(systemName: item.1).frame(width: 44, height: 40) }.buttonStyle(.plain).foregroundStyle(show.section == item.0 ? JarasTheme.accent : .white).accessibilityLabel(item.0) }
                }.padding(.horizontal, 14).background(JarasTheme.panel)
                #endif
                TransportView(show: show)
                HStack {
                    Button { repertoire.toggle() } label: { Label("Repertório", systemImage: "sidebar.right") }.buttonStyle(.plain)
                    Text(show.snapshot.project.name).lineLimit(1).foregroundStyle(JarasTheme.secondary)
                    Spacer()
                    Text("DEMO · SEM ÁUDIO").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                    if auth.revokedPending { Text("Autorização pendente ao parar").foregroundStyle(JarasTheme.yellow) }
                    Button { Task { await show.save() } } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("Salvar projeto").buttonStyle(.plain)
                }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 14).frame(height: 34).background(Color(hex: 0x171d25))
                if show.section == "Configurações" { SettingsView(auth: auth, show: show, backend: backend) }
                
                else if show.section == "Projetos" {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Projetos").font(.title.bold())
                        Text(show.snapshot.project.name).font(.title2)
                        Text("\(show.snapshot.project.songs.count) músicas · formato .jaras 1").foregroundStyle(JarasTheme.secondary)
                        HStack { Button("Salvar projeto") { Task { await show.save() } }; Button("Abrir .jaras") { importing = true }.disabled(show.isPlaying); Button("Abrir grid") { show.section = "Repertórios" } }.buttonStyle(StageButtonStyle(color: JarasTheme.accent))
                        Spacer()
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    #if os(macOS)
                    HSplitView {
                        TimelineGridView(show: show)
                            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                        if repertoire {
                            SongListView(show: show)
                                .frame(minWidth: 180, idealWidth: 240, maxWidth: 486.5, maxHeight: .infinity)
                        }
                    }
                    #else
                    HStack(spacing: 1) {
                        TimelineGridView(show: show)
                        if repertoire { SongListView(show: show).frame(width: 220) }
                    }
                    #endif
                }
                HStack {
                    Circle().fill(show.isPlaying ? JarasTheme.green : JarasTheme.secondary).frame(width: 5, height: 5)
                    Text(LocalizedStringKey(show.isPlaying ? "REPRODUZINDO" : "PARADO"))
                    Text("•").foregroundStyle(JarasTheme.line)
                    Text("Próxima: \(show.next?.name ?? "Fim do repertório")")
                    Spacer()
                    if !show.message.isEmpty { Text(LocalizedStringKey(show.message)).lineLimit(1).foregroundStyle(JarasTheme.yellow); Button { show.message = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    Text("4/4").foregroundStyle(JarasTheme.secondary)
                }.font(.system(size: 9, weight: .medium, design: .monospaced)).padding(.horizontal, 14).frame(height: 27).background(JarasTheme.panel)
            }
        }.background(JarasTheme.background).foregroundStyle(.white).preferredColorScheme(.dark)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
                do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; try show.importProject(Data(contentsOf: url)); show.section = "Repertórios" } catch { show.message = error.localizedDescription }
            }
    }
}
struct MainPreview: PreviewProvider { static var previews: some View { let container = try! AppContainer(preview: true); MainView(show: container.show, auth: container.auth, backend: container.backend).frame(width: 1360, height: 800) } }
