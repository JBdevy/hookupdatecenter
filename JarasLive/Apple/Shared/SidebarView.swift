import SwiftUI
struct SidebarView: View {
    var close: () -> Void = {}
    var openProjects: () -> Void = {}
    var exit: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            navigation("Projetos", icon: "square.stack.3d.up", active: false, action: openProjects)
            navigation("Live Session", icon: "waveform", active: true, action: {})
            Spacer(minLength: 0)
            if let exit { navigation("Sair", icon: "rectangle.portrait.and.arrow.right", active: false, action: exit) }
        }.padding(.horizontal, 12).padding(.vertical, 12).background(JarasTheme.background)
    }
    private func navigation(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button { close(); action() } label: {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 38)
                .background(active ? JarasTheme.accent.opacity(0.12) : .clear)
                .foregroundStyle(active ? JarasTheme.accent : JarasTheme.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
struct SidebarPreview: PreviewProvider { static var previews: some View { SidebarView().frame(width: 1100) } }
