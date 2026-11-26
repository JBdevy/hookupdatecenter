import SwiftUI
import UIKit
enum JarasTheme {
    static let green = Color.green, text = Color.white, secondary = Color.gray
}
enum RemoteSurface { static let panel = Color(white: 0.13) }
extension Font {
    static let jarasHeadline = Font.headline
    static func jarasSystem(size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}
extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
// PRODUCTION_KEYBOARD_CODE
@main struct KeyboardFixtureApp: App { var body: some Scene { WindowGroup { KeyboardFixture() } } }
struct KeyboardFixture: View {
    @State private var modal = false
    @State private var text = ""
    @State private var notes = ""
    @State private var secure = ""
    @State private var saved = ""
    @State private var uppercase = true
    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            VStack {
                Button("Editar") { modal = true }
                TextField("Pesquisa", text: $text).textFieldStyle(.roundedBorder).accessibilityIdentifier("search")
                SecureField("PIN", text: $secure).textFieldStyle(.roundedBorder).keyboardType(.numberPad).accessibilityIdentifier("pin")
                TextEditor(text: $notes).frame(height: 120).accessibilityIdentifier("notes")
                Text("Pesquisa: " + text).accessibilityIdentifier("search-result")
                Text("Texto: " + notes).accessibilityIdentifier("notes-result")
                Text("Salvo: " + saved).accessibilityIdentifier("saved")
                Spacer()
            }.padding(30)
            if modal {
                IpadCompactModal {
                    NameColorEditor(title: "Editar pista", initialName: "Guitarra", initialColor: 0x339944,
                                    save: { name, _ in saved = name }, close: { modal = false }, uppercaseName: $uppercase)
                }
            }
        }.preferredColorScheme(.dark).background(IpadTextKeyboardScope())
    }
}
