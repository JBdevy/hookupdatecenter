import SwiftUI
struct LoginView: View {
    @ObservedObject var auth: AuthService
    let backend: MockBackendClient
    @State private var email = "demo@jaras.live"
    @State private var password = ""
    @State private var name = ""
    @State private var mode = "Entrar"
    @State private var licenses = 2
    @State private var scenario: MockScenario = .valid
    @FocusState private var field: Int?
    var body: some View {
        ZStack {
            JarasTheme.background.ignoresSafeArea()
            HStack(spacing: 65) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("JARAS").font(.system(size: 52, weight: .black, design: .rounded)).tracking(4)
                    Text("LIVE").font(.system(size: 23, weight: .bold, design: .monospaced)).tracking(12).foregroundStyle(JarasTheme.accent)
                    Rectangle().fill(JarasTheme.accent).frame(width: 64, height: 4)
                    Text("Seu show.\nNo seu controle.").font(.system(size: 25, weight: .medium))
                    Text("MULTITRACK · REPERTÓRIOS · SUB PLAY").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                }.frame(maxWidth: 340, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) {
                    Text(LocalizedStringKey(mode)).font(.title2.bold())
                    if mode == "Criar conta" { TextField("Nome", text: $name).focused($field, equals: 0) }
                    TextField("E-mail", text: $email).focused($field, equals: 1).textContentType(.username).onSubmit { field = 2 }
                    if mode != "Recuperar senha" { SecureField("Senha", text: $password).focused($field, equals: 2).textContentType(.password).onSubmit { submit() } }
                    if !auth.message.isEmpty { Text(LocalizedStringKey(auth.message)).font(.footnote).foregroundStyle(JarasTheme.yellow).fixedSize(horizontal: false, vertical: true) }
                    Button(action: submit) { HStack { Spacer(); Text(LocalizedStringKey(auth.busy ? "Aguarde…" : mode)); Spacer() } }.buttonStyle(StageButtonStyle(color: JarasTheme.accent, active: true)).disabled(auth.busy)
                    HStack { Button("Entrar") { mode = "Entrar" }; Spacer(); Button("Criar conta") { mode = "Criar conta" }; Spacer(); Button("Esqueci a senha") { mode = "Recuperar senha" } }.font(.caption).buttonStyle(.plain).foregroundStyle(JarasTheme.secondary)
                    Divider().overlay(JarasTheme.line)
                    Text("AMBIENTE DE DEMONSTRAÇÃO").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(JarasTheme.accent)
                    Text("demo@jaras.live · senha: jaras123").font(.caption).foregroundStyle(JarasTheme.secondary)
                    Picker("Licenças", selection: $licenses) { ForEach(1...3, id: \.self) { count in Group { if count == 1 { Text("1 dispositivo") } else { Text("\(count) dispositivos") } }.tag(count) } }.pickerStyle(.segmented)
                    Picker("Cenário", selection: $scenario) { Text("Normal").tag(MockScenario.valid); Text("Bloqueada").tag(MockScenario.blocked); Text("Expirada").tag(MockScenario.expired); Text("Revogada").tag(MockScenario.revoked) }
                }.textFieldStyle(.roundedBorder).padding(28).frame(width: 390).background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12))
            }.padding(32)
        }
    }
    private func submit() {
        Task {
            await backend.configure(maxDevices: licenses, scenario: scenario)
            if mode == "Criar conta" { await auth.signup(name: name, email: email, password: password) }
            else if mode == "Recuperar senha" { await auth.resetPassword(email: email) }
            else { await auth.login(email: email, password: password) }
            password = ""
        }
    }
}
struct LoginPreview: PreviewProvider {
    static var previews: some View { let container = try! AppContainer(preview: true); LoginView(auth: container.auth, backend: container.backend).frame(width: 1100, height: 720) }
}
