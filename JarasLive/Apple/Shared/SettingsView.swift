import SwiftUI
struct SettingsView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var show: ShowController
    let backend: MockBackendClient
    @AppStorage("jaras.language") private var language = "en"
    @State private var offline = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Idioma", selection: $language) { Text("English").tag("en"); Text("Português").tag("pt-BR") }.pickerStyle(.segmented)
                Text("Conta e dispositivos").font(.title2.bold())
                Text(auth.loginResult?.account.email ?? "Preview").foregroundStyle(JarasTheme.secondary)
                HStack { Text("\(auth.devices.filter { $0.status == .active }.count) / \(auth.loginResult?.entitlement.maxDevices ?? 2) dispositivos"); Spacer(); Text(auth.phase == .offlineAuthorized ? "OFFLINE AUTORIZADO" : "AUTORIZADO").foregroundStyle(JarasTheme.green) }.font(.system(size: 12, weight: .semibold, design: .monospaced))
                ForEach(auth.devices) { device in
                    HStack { Image(systemName: device.platform == "macOS" ? "desktopcomputer" : "ipad.landscape"); VStack(alignment: .leading) { Text(device.deviceName); Text(device.platform).font(.caption).foregroundStyle(JarasTheme.secondary) }; Spacer(); Text(LocalizedStringKey(device.status.rawValue)).font(.caption).foregroundStyle(device.status == .active ? JarasTheme.green : JarasTheme.secondary) }.padding(12).background(JarasTheme.panel).cornerRadius(6)
                }
                Divider()
                Text("TESTES DO BACKEND MOCK").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(JarasTheme.accent)
                Toggle("Simular ausência de internet", isOn: $offline).onChange(of: offline) { value in Task { await backend.setOffline(value); await auth.revalidate() } }
                HStack {
                    Button("Validar agora") { Task { await auth.revalidate() } }
                    Button("Revogar este dispositivo") { Task { do { try await backend.revoke(auth.installation.id); await auth.revalidate() } catch { show.message = error.localizedDescription } } }
                }.buttonStyle(StageButtonStyle())
                Button("Simular outro dispositivo ocupando as vagas") { Task {
                    do {
                        let maximum = auth.loginResult?.entitlement.maxDevices ?? 2
                        for index in 0..<maximum {
                            var device = auth.installation; device.installationId = UUID(); device.deviceName = "Dispositivo simulado \(index + 1)"; device.platform = "iPadOS"
                            _ = try await backend.login(email: "demo@jaras.live", password: "jaras123", device: device)
                        }
                        await auth.revalidate()
                    } catch { show.message = error.localizedDescription }
                } }.buttonStyle(StageButtonStyle()).disabled(auth.loginResult?.account.email != "demo@jaras.live")
                Text("Se houver reprodução, a revogação será aplicada somente quando as agulhas terminarem ou você parar. O mock não envia e-mail nem se conecta a um servidor real.").font(.caption).foregroundStyle(JarasTheme.secondary)
                Button("Sair e liberar dispositivo") { Task { await auth.logout() } }.buttonStyle(StageButtonStyle(color: .red)).disabled(show.isPlaying || auth.busy)
                if !auth.message.isEmpty { Text(LocalizedStringKey(auth.message)).font(.caption).foregroundStyle(JarasTheme.yellow) }
            }.padding(24).frame(maxWidth: 760, alignment: .leading)
        }
    }
}
