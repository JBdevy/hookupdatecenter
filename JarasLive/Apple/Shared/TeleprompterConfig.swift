import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class TeleprompterPreferences: ObservableObject {
    static let shared = TeleprompterPreferences()
    static let second = TeleprompterPreferences(key: "jaras.teleprompter2.settings")
    @Published private(set) var settings: TeleprompterSettings
    @Published private(set) var selected: TeleprompterPreset
    private let store: TeleprompterSettingsStore
    init(defaults: UserDefaults = .standard, key: String = TeleprompterSettingsStore.preferenceKey) {
        store = TeleprompterSettingsStore(defaults: defaults, key: key)
        settings = store.current; selected = store.selected
    }
    func select(_ preset: TeleprompterPreset) {
        guard store.select(preset) else { return }
        selected = preset; settings = store.current
    }
    func reload() { store.reload(); selected = store.selected; settings = store.current }
    func set<Value>(_ path: WritableKeyPath<TeleprompterSettings, Value>, _ value: Value) {
        var next = settings; next[keyPath: path] = value
        guard store.update(next) else { return }
        settings = store.current
    }
}
private struct TPOption { let value: String; let label: String }
private enum TPSettingField: Identifiable {
    case color(String, String, WritableKeyPath<TeleprompterSettings, UInt32>)
    case range(String, String, WritableKeyPath<TeleprompterSettings, Double>, ClosedRange<Double>)
    case choice(String, String, WritableKeyPath<TeleprompterSettings, String>, [TPOption])
    case toggle(String, String, WritableKeyPath<TeleprompterSettings, Bool>)
    var id: String {
        switch self {
        case .color(let id,_,_), .range(let id,_,_,_), .choice(let id,_,_,_), .toggle(let id,_,_): return id
        }
    }
    var label: String {
        switch self {
        case .color(_,let label,_), .range(_,let label,_,_), .choice(_,let label,_,_), .toggle(_,let label,_): return label
        }
    }
    var group: String {
        switch self { case .color: return "Colors"; case .range: return "Scales"; case .choice: return "Fonts and positions"; case .toggle: return "Display" }
    }
    static let all: [Self] = [
        .color("textColor", "Lyrics color", \.textColor),
        .color("textBoxColor", "Lyrics border color", \.textBoxColor),
        .color("clockColor", "Timer color", \.clockColor),
        .color("clockExpiredColor", "Expired countdown color", \.clockExpiredColor),
        .color("clockBorderColor", "Timer border color", \.clockBorderColor),
        .color("localClockColor", "Local clock color", \.localClockColor),
        .color("localClockBorderColor", "Local clock border color", \.localClockBorderColor),
        .color("borderColor", "Window border color", \.borderColor),
        .color("songNameColor", "Song name color", \.songNameColor),
        .color("queueNameColor", "Queued song color", \.queueNameColor),
        .color("progressColor", "Progress color", \.progressColor),
        .color("chordColor", "Chords color", \.chordColor),
        .range("textScale", "Lyrics scale", \.textScale, 35...100),
        .range("clockScale", "Timer scale", \.clockScale, 35...150),
        .range("songNameScale", "Song name scale", \.songNameScale, 35...200),
        .range("queueNameScale", "Queued song scale", \.queueNameScale, 35...200),
        .toggle("mediaStretch", "Stretch", \.stretchesMedia),
        .range("mediaScale", "Media scale", \.mediaScale, 25...150),
        .range("previewScale", "Preview depth", \.previewScale, 35...300),
        .range("localClockScale", "Local clock scale", \.localClockScale, 50...200),
        .range("chordScale", "Chords scale", \.chordScale, 10...100),
        .choice("textCase", "Text case", \.textCase, [TPOption(value: "original", label: "Original text"), TPOption(value: "uppercase", label: "UPPERCASE"), TPOption(value: "lowercase", label: "lowercase")]),
        .choice("fontFamily", "Lyrics font", \.fontFamily, [TPOption(value: "system", label: "Default"), TPOption(value: "arial", label: "ARIAL"), TPOption(value: "segoe", label: "SEGOE UI"), TPOption(value: "bahnschrift", label: "BAHNSCHRIFT"), TPOption(value: "verdana", label: "VERDANA"), TPOption(value: "tahoma", label: "TAHOMA"), TPOption(value: "georgia", label: "GEORGIA"), TPOption(value: "trebuchet", label: "TREBUCHET"), TPOption(value: "impact", label: "IMPACT"), TPOption(value: "mono", label: "MONO")]),
        .choice("previewFontFamily", "Preview font", \.previewFontFamily, [TPOption(value: "system", label: "Default"), TPOption(value: "arial", label: "ARIAL"), TPOption(value: "segoe", label: "SEGOE UI"), TPOption(value: "bahnschrift", label: "BAHNSCHRIFT"), TPOption(value: "verdana", label: "VERDANA"), TPOption(value: "tahoma", label: "TAHOMA"), TPOption(value: "georgia", label: "GEORGIA"), TPOption(value: "trebuchet", label: "TREBUCHET"), TPOption(value: "impact", label: "IMPACT"), TPOption(value: "mono", label: "MONO")]),
        .choice("songNameFontFamily", "Song name font", \.songNameFontFamily, [TPOption(value: "system", label: "Default"), TPOption(value: "arial", label: "ARIAL"), TPOption(value: "segoe", label: "SEGOE UI"), TPOption(value: "bahnschrift", label: "BAHNSCHRIFT"), TPOption(value: "verdana", label: "VERDANA"), TPOption(value: "tahoma", label: "TAHOMA"), TPOption(value: "georgia", label: "GEORGIA"), TPOption(value: "trebuchet", label: "TREBUCHET"), TPOption(value: "impact", label: "IMPACT"), TPOption(value: "mono", label: "MONO")]),
        .choice("queueNameFontFamily", "Queued song font", \.queueNameFontFamily, [TPOption(value: "system", label: "Default"), TPOption(value: "arial", label: "ARIAL"), TPOption(value: "segoe", label: "SEGOE UI"), TPOption(value: "bahnschrift", label: "BAHNSCHRIFT"), TPOption(value: "verdana", label: "VERDANA"), TPOption(value: "tahoma", label: "TAHOMA"), TPOption(value: "georgia", label: "GEORGIA"), TPOption(value: "trebuchet", label: "TREBUCHET"), TPOption(value: "impact", label: "IMPACT"), TPOption(value: "mono", label: "MONO")]),
        .choice("chordFontFamily", "Chords font", \.chordFontFamily, [TPOption(value: "system", label: "Default"), TPOption(value: "arial", label: "ARIAL"), TPOption(value: "segoe", label: "SEGOE UI"), TPOption(value: "bahnschrift", label: "BAHNSCHRIFT"), TPOption(value: "verdana", label: "VERDANA"), TPOption(value: "tahoma", label: "TAHOMA"), TPOption(value: "georgia", label: "GEORGIA"), TPOption(value: "trebuchet", label: "TREBUCHET"), TPOption(value: "impact", label: "IMPACT"), TPOption(value: "mono", label: "MONO")]),
        .choice("textAlignment", "Lyrics alignment", \.textAlignment, [TPOption(value: "left", label: "Left"), TPOption(value: "center", label: "Center"), TPOption(value: "right", label: "Right")]),
        .choice("clockPosition", "Timer position", \.clockPosition, [TPOption(value: "left-top", label: "Top left"), TPOption(value: "left-bottom", label: "Bottom left"), TPOption(value: "right-top", label: "Top right"), TPOption(value: "right-bottom", label: "Bottom right"), TPOption(value: "center-top", label: "Top center"), TPOption(value: "center-bottom", label: "Bottom center")]),
        .choice("localClockPosition", "Local clock position", \.localClockPosition, [TPOption(value: "left", label: "Left"), TPOption(value: "right", label: "Right")]),
        .choice("songNamePosition", "Song name position", \.songNamePosition, [TPOption(value: "top", label: "Top"), TPOption(value: "bottom", label: "Bottom")]),
        .choice("queueNamePosition", "Queued song position", \.queueNamePosition, [TPOption(value: "top", label: "Top"), TPOption(value: "bottom", label: "Bottom")]),
        .choice("progressPosition", "Progress position", \.progressPosition, [TPOption(value: "top", label: "Top"), TPOption(value: "bottom", label: "Bottom")]),
        .choice("progressMode", "Progress mode", \.progressMode, [TPOption(value: "lyrics", label: "Lyrics"), TPOption(value: "chords", label: "Chords")]),
        .choice("chordPosition", "Chords position", \.chordPosition, [TPOption(value: "top", label: "Top"), TPOption(value: "bottom", label: "Bottom")]),
        .toggle("windowBorderEnabled", "Show window border", \.windowBorderEnabled),
        .toggle("rgbWindowBorderEnabled", "RGB window border", \.rgbWindowBorderEnabled),
        .toggle("rgbClockBorderEnabled", "RGB timer and local clock borders", \.rgbClockBorderEnabled),
        .toggle("rgbTextBoxBorderEnabled", "RGB lyrics border", \.rgbTextBoxBorderEnabled),
        .toggle("rgbChordBorderEnabled", "RGB chords border", \.rgbChordBorderEnabled),
        .toggle("clockBorderEnabled", "Show timer border", \.clockBorderEnabled),
        .toggle("localClockBorderEnabled", "Show local clock border", \.localClockBorderEnabled),
        .toggle("textBoxEnabled", "Show lyrics border", \.textBoxEnabled),
        .toggle("clockEnabled", "Show timer", \.clockEnabled),
        .toggle("localClockEnabled", "Show local clock", \.localClockEnabled),
        .toggle("songNameEnabled", "Show song name", \.songNameEnabled),
        .toggle("queueNameEnabled", "Show queued song", \.queueNameEnabled),
        .toggle("chordsEnabled", "Show chords", \.chordsEnabled),
        .toggle("previewSongDurationEnabled", "Show song durations in preview", \.previewSongDurationEnabled),
        .toggle("previewBlockDurationEnabled", "Show block durations in preview", \.previewBlockDurationEnabled),
        .toggle("previewUnderlineEnabled", "Underline preview names", \.previewUnderlineEnabled),
        .toggle("progressEnabled", "Show progress bar", \.progressEnabled),
        .toggle("clearMode", "Clear mode (media only)", \.isClear),
    ]
}

struct TeleprompterConfig: View {
    @State private var showingNotices = false
    @ObservedObject var preferences: TeleprompterPreferences
    let close: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Teleprompter settings").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 36,height: 36).contentShape(Rectangle()) }
                    .buttonStyle(.plain).jarasHelp("Close")
            }
            #if os(macOS)
            Picker("Settings", selection: $showingNotices) {
                Text("Teleprompter").tag(false)
                Text("Messages").tag(true)
            }.pickerStyle(.segmented)
            #endif
            if !showingNotices {
                Picker("Preset", selection: Binding(get: { preferences.selected },set: { preferences.select($0) })) {
                    Text("Night").tag(TeleprompterPreset.night); Text("Day").tag(TeleprompterPreset.day)
                }.pickerStyle(.segmented)
                GeometryReader { geometry in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(["Colors","Scales","Fonts and positions","Display"],id: \.self) { group in
                                VStack(alignment: .leading,spacing: 10) {
                                    Text(LocalizedStringKey(group)).font(.system(size: 12,weight: .bold)).foregroundStyle(JarasTheme.green)
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 8),count: geometry.size.width > 520 ? 2 : 1),spacing: 8) {
                                        ForEach(TPSettingField.all.filter { $0.group == group }) { field in
                                            fieldView(field).padding(9).frame(maxWidth: .infinity,minHeight: group == "Colors" || group == "Display" ? 48 : 70,alignment: .leading)
                                                .background(JarasTheme.display).cornerRadius(6)
                                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(JarasTheme.line))
                                        }
                                    }
                                }.padding(10).background(JarasTheme.background).cornerRadius(6)
                            }
                        }.padding(.trailing,2).padding(.bottom,10)
                    }
                }
            }
            #if os(macOS)
            if showingNotices {
                ScrollView { TPNoticeSettingsView().frame(maxWidth: .infinity, alignment: .leading) }
            }
            #endif
            HStack {
                Button("Timer settings") { TeleprompterTimerController.shared.showConfiguration() }
                Spacer(); Button("Close",action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(16).frame(minWidth: 500,idealWidth: 760,maxWidth: .infinity,minHeight: 520,idealHeight: 700,maxHeight: .infinity)
            .background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
    }
    @ViewBuilder private func fieldView(_ field: TPSettingField) -> some View {
        switch field {
        case .color(_,let label,let path):
            HStack {
                Text(LocalizedStringKey(label)).frame(maxWidth: .infinity,alignment: .leading)
                ColorPicker(LocalizedStringKey(label),selection: Binding(get: { Color(hex: preferences.settings[keyPath: path]) },set: { preferences.set(path,$0.teleprompterRGB) }),supportsOpacity: false).labelsHidden()
            }
        case .range(_,let label,let path,let limits):
            VStack(alignment: .leading,spacing: 5) {
                HStack { Text(LocalizedStringKey(label)); Spacer(); Text("\(Int(preferences.settings[keyPath: path]))%").monospacedDigit() }.lineLimit(1).minimumScaleFactor(0.8)
                Slider(value: Binding(get: { preferences.settings[keyPath: path] },set: { preferences.set(path,$0) }),in: limits,step: 5).tint(JarasTheme.green).accessibilityLabel(LocalizedStringKey(label))
            }
        case .choice(_,let label,let path,let options):
            VStack(alignment: .leading,spacing: 5) {
                Text(LocalizedStringKey(label))
                Picker(LocalizedStringKey(label),selection: Binding(get: { preferences.settings[keyPath: path] },set: { preferences.set(path,$0) })) {
                    ForEach(options,id: \.value) { option in Text(LocalizedStringKey(option.label)).tag(option.value) }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity,alignment: .leading)
            }
        case .toggle(_,let label,let path):
            Toggle(LocalizedStringKey(label),isOn: Binding(get: { preferences.settings[keyPath: path] },set: { preferences.set(path,$0) }))
        }
    }
}
private extension Color {
    var teleprompterRGB: UInt32 {
        #if os(macOS)
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return 0xffffff }
        let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red,green: &green,blue: &blue,alpha: &alpha)
        #endif
        func channel(_ value: CGFloat) -> UInt32 { UInt32(min(255,max(0,(value * 255).rounded()))) }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }
}
