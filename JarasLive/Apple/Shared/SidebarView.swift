import SwiftUI
struct SidebarView: View {
    @ObservedObject var show: ShowController
    static let entries = [("Projetos","square.stack.3d.up"),("Repertórios","list.bullet.rectangle"),("Músicas","music.note.list"),("Live","waveform"),("Configurações","gearshape")]
    var body: some View {
        HStack(spacing: 8) {
            Image("JarasLogo").resizable().scaledToFit()
                .frame(width: 106, height: 54).accessibilityLabel("Jaras Live")
            ForEach(Self.entries, id: \.0) { item in
                Button { show.section = item.0 } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.1).font(.system(size: 16))
                        Text(LocalizedStringKey(item.0)).font(.system(size: 10, weight: .medium))
                    }
                    .frame(width: 94, height: 48)
                    .background(show.section == item.0 ? JarasTheme.accent.opacity(0.12) : .clear)
                    .foregroundStyle(show.section == item.0 ? JarasTheme.accent : JarasTheme.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text("1.0.0").font(.system(size: 10, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 8).background(Color(hex: 0x101419))
    }
}
struct SidebarPreview: PreviewProvider { static var previews: some View { SidebarView(show: try! AppContainer(preview: true).show).frame(width: 1100) } }
