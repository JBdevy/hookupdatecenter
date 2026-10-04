import SwiftUI
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AuthService
    let backend: any BackendClient
    @State private var email = ""
    @State private var cpf = ""
    @State private var deviceName = ""
    @State private var login = false
    @State private var managingDevices = false
    var offersTrial = true
    var onAuthorized: () -> Void = {}
    @FocusState private var field: Int?
    var body: some View {
        VStack(spacing: 22) {
            Image("CatLiveSplash").resizable().scaledToFit().frame(width: 160, height: 160)
            if auth.requiresDeviceName {
                Text("Nome deste dispositivo").font(.title2.bold())
                Text("Escolha um nome para identificar este PC na sua conta e na lista de conexão do iPad ou celular.")
                    .font(.callout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                TextField("Ex.: PC do palco", text: $deviceName)
                    .textFieldStyle(.roundedBorder).focused($field, equals: 3).onSubmit { finishNaming() }
                Text(deviceName.isEmpty || DeviceDisplayName.validated(deviceName) != nil
                     ? "O nome é obrigatório. Use um nome curto e fácil de reconhecer."
                     : "Use um nome mais curto, com letras ou números, sem quebras de linha.")
                    .font(.caption).foregroundStyle(JarasTheme.secondary)
                HStack(spacing: 12) {
                    Button("Voltar") { auth.cancelDeviceNaming(); cpf = ""; field = 2 }
                        .buttonStyle(StageButtonStyle())
                    Button(auth.busy ? "Aguarde…" : "Salvar e continuar") { finishNaming() }
                        .buttonStyle(StageButtonStyle(color: JarasTheme.accent, active: true))
                        .disabled(DeviceDisplayName.validated(deviceName) == nil)
                }.disabled(auth.busy)
            } else {
            Text("Bem-vindo ao CatLive").font(.title2.bold())
            HStack(spacing: 12) {
                Button("Login") { login = true; field = 1 }
                    .buttonStyle(StageButtonStyle(color: JarasTheme.accent, active: login))
                if offersTrial { Button("Trial teste · 7 dias") {
                    Task { if await auth.startTrial(hardwareID: hardwareID) { onAuthorized() } }
                }.buttonStyle(StageButtonStyle(color: JarasTheme.accent, active: false)) }
                if !offersTrial { Button("Fechar") { dismiss() }.buttonStyle(StageButtonStyle()) }
            }.disabled(auth.busy)
            if login || !offersTrial {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("E-mail cadastrado", text: $email).textContentType(.username).focused($field, equals: 1).onSubmit { field = 2 }
                    SecureField("CPF", text: $cpf).focused($field, equals: 2).onSubmit { submit() }
                    Button(auth.busy ? "Aguarde…" : "Entrar") { submit() }
                        .buttonStyle(StageButtonStyle(color: JarasTheme.accent, active: true)).disabled(auth.busy || email.isEmpty || cpf.isEmpty)
                    Button("Gerenciar dispositivos") { managingDevices = true }
                        .disabled(auth.busy || email.isEmpty || cpf.isEmpty)
                }.textFieldStyle(.roundedBorder)
            }
            }
            if auth.busy { ProgressView().controlSize(.small) }
            if !auth.message.isEmpty { Text(auth.message).font(.footnote).foregroundStyle(JarasTheme.yellow).fixedSize(horizontal: false, vertical: true) }
            if !auth.requiresDeviceName { Text(offersTrial ? "Use o e-mail e o CPF da sua compra.\nO trial começa no primeiro acesso neste dispositivo." : "Use o e-mail e o CPF da sua compra.")
                .font(.caption).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center) }
        }.padding(30).frame(width: 440).background(JarasTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16)).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(JarasTheme.background)
            .onChange(of: auth.requiresDeviceName) { naming in
                if naming { cpf = ""; field = 3 }
            }
            .onDisappear { auth.cancelDeviceNaming() }
            .interactiveDismissDisabled(auth.busy || auth.requiresDeviceName)
            .sheet(isPresented: $managingDevices) {
                CredentialDevicesView(auth: auth, backend: backend, email: email, cpf: cpf)
            }
    }
    private func finishNaming() {
        Task { if await auth.completeDeviceNaming(deviceName) { deviceName = ""; onAuthorized() } }
    }
    private var hardwareID: String { DeviceAuthorizationService.hardwareID(fallback: auth.installation.id) }
    private func submit() {
        Task {
            if await auth.beginLogin(email: email, password: cpf) { cpf = ""; onAuthorized() }
        }
    }
}
struct CredentialDevicesView: View {
    @ObservedObject var auth: AuthService
    let backend: any BackendClient
    let email: String
    let cpf: String
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [AuthorizedDevice] = []
    @State private var pending: AuthorizedDevice?
    @State private var busy = false
    @State private var loaded = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Dispositivos conectados").font(.title2.bold()); Spacer(); Button("Fechar") { dismiss() }.disabled(busy) }
            Text(email).foregroundStyle(JarasTheme.secondary)
            Text("Remova um computador para liberar sua licença e entrar em outro.").font(.callout)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(devices) { device in
                        DeviceAccountRow(device: device, current: device.id == auth.installation.id) { pending = device }.disabled(busy)
                    }
                    if loaded && devices.isEmpty { Text("Nenhum dispositivo conectado.").foregroundStyle(JarasTheme.secondary) }
                }
            }.frame(minHeight: 160, maxHeight: 300)
            if busy { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(JarasTheme.yellow) }
            Button("Atualizar lista") { Task { await load() } }.disabled(busy)
        }.padding(24).frame(width: 520).background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .task { await load() }
            .alert("Remover dispositivo?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { device in
                Button("Cancelar", role: .cancel) { pending = nil }
                Button("Remover", role: .destructive) { Task { await remove(device) } }
            } message: { device in
                Text(device.id == auth.installation.id ? "Você sairá da conta neste computador e a licença ficará disponível." : "A licença de \(device.deviceName) ficará disponível. Ele precisará entrar novamente para usar a conta.")
            }
    }
    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { devices = try await backend.credentialDevices(email: email, cpf: cpf); loaded = true; message = "" }
        catch { message = error.localizedDescription }
    }
    private func remove(_ device: AuthorizedDevice) async {
        guard !busy else { return }; busy = true; defer { busy = false }; pending = nil
        do {
            try await backend.revokeDevice(email: email, cpf: cpf, installationId: device.id)
            devices.removeAll { $0.id == device.id }; auth.removedAtLogin(device, email: email)
            message = "Dispositivo removido. A licença está disponível."
        } catch { message = error.localizedDescription }
    }
}
struct DeviceAccountRow: View {
    let device: AuthorizedDevice
    let current: Bool
    var remove: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.platform == "macOS" ? "desktopcomputer" : "laptopcomputer").font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.deviceName).font(.headline)
                Text(device.platform + (current ? " · Este computador" : "")).font(.caption).foregroundStyle(JarasTheme.secondary)
                Text("Último acesso: " + device.lastSeenAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(JarasTheme.secondary)
            }
            Spacer()
            Button("Remover", role: .destructive, action: remove)
        }.padding(12).background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
struct LoginPreview: PreviewProvider {
    static var previews: some View { let container = try! AppContainer(preview: true); LoginView(auth: container.auth, backend: container.backend).frame(width: 1100, height: 720) }
}
/// One reusable notice, reopened every five seconds while access is restricted.
/// The audio gate is independent of this UI, including while the notice is closed.
struct LicenseNotice: View {
    @ObservedObject var auth: AuthService
    let backend: any BackendClient
    @State private var visible = true
    @State private var signingIn = false
    @State private var showingGrace = false
    @State private var graceSeconds = 5
    var body: some View {
        Group {
            if showingGrace && !auth.graceNotice.isEmpty && auth.restriction.isEmpty && !signingIn {
                VStack(spacing: 18) {
                    Image(systemName: "clock.badge.exclamationmark").font(.system(size: 25)).foregroundStyle(JarasTheme.yellow)
                    Text("Prazo de tolerância").font(.title2.bold())
                    Text(auth.graceNotice).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text("Este aviso fecha em \(graceSeconds)s").font(.caption).foregroundStyle(JarasTheme.secondary)
                }.padding(26).frame(width: 440).background(JarasTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(JarasTheme.yellow.opacity(0.5)))
                    .shadow(color: .black.opacity(0.5), radius: 22)
            }
            if visible && !auth.restriction.isEmpty && auth.workspaceAllowed && !signingIn {
                VStack(spacing: 18) {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 25)).foregroundStyle(JarasTheme.yellow)
                    Text("CatLive").font(.title2.bold())
                    Text(auth.restriction).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Fechar") { visible = false }
                        Button("Login") { signingIn = true }
                        Button("Verificar licença") { Task { await auth.revalidate() } }.disabled(auth.busy)
                    }.buttonStyle(.bordered)
                }.padding(26).frame(width: 420).background(JarasTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(JarasTheme.yellow.opacity(0.5)))
                    .shadow(color: .black.opacity(0.5), radius: 22)
            }
        }
        .sheet(isPresented: $signingIn) {
            LoginView(auth: auth, backend: backend, offersTrial: false, onAuthorized: { signingIn = false }).frame(width: 550, height: 620)
        }
        .task(id: auth.graceNotice) {
            showingGrace = !auth.graceNotice.isEmpty; graceSeconds = 5
            guard showingGrace else { return }
            for seconds in stride(from: 5, through: 1, by: -1) {
                graceSeconds = seconds
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            showingGrace = false
        }
        .task(id: auth.restriction) {
            visible = true
            guard !auth.restriction.isEmpty else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    visible = false
                    try await Task.sleep(nanoseconds: 80_000_000)
                    visible = true
                } catch { return }
            }
        }
    }
}
