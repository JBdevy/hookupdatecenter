import SwiftUI
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

struct CatSynthEditor: View {
    @Binding var bank: CatSynthBank
    @Binding var enabled: Bool
    let audio: StemAudioPlayback
    var track: UUID?
    let effect: String

    private static let names = ["Violet Lead", "Sub Orbit", "Nebula Pad", "Laser Pluck",
                                "Glass Keys", "Deep Motion", "Air Choir", "Pulse Engine"]
    private static let factory = (0..<CatSynthBank.count).map { JarasCatSynth.factoryPatch(UInt($0)).map(\.floatValue) }
    private let accent = Color(hex: 0xb58aff)
    private let waves = ["Sine", "Triangle", "Saw", "Square", "Pulse"]
    @State private var sounding = Set<Int>()
    @State private var pressed: Int?
    @GestureState private var keyboardInteraction = false
    @State private var octave = 0
    @State private var presetToRename: Int?
    @State private var presetNameDraft = ""
    @State private var hoveredPreset: Int?
    @State private var openSelector: Int?
    @FocusState private var nameFocused: Bool
    #if os(macOS)
    private static let presetStripSpace = "catsynth-preset-strip"
    #else
    private static let presetDragType = UTType(exportedAs: "app.catlive.catsynth-preset")
    #endif

    private let refresh = Timer.publish(every: 1.0 / 24, on: .main, in: .common).autoconnect()

    private var selected: Int { max(0, min(CatSynthBank.count - 1, bank.selected)) }
    private var patch: [Float] {
        patch(for: selected)
    }

    private func patch(for index: Int) -> [Float] {
        if bank.slots.indices.contains(index), let values = bank.slots[index],
           values.count == CatSynthBank.parameterCount { return values }
        return Self.factory[index]
    }

    private func presetName(_ index: Int) -> String {
        if let names = bank.names, names.indices.contains(index), let name = names[index], !name.isEmpty { return name }
        return Self.names[index]
    }

    var body: some View {
        VStack(spacing: 10) {
            presetStrip
            ScrollView {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0..<3) { index in oscillator(index) }
                        module("FILTER") {
                            selector("Mode", 15, ["Low Pass", "Band Pass", "High Pass"])
                            HStack(spacing: 2) {
                                dial("Cutoff", 13, 20...18000, "Hz", logarithmic: true)
                                dial("Res", 14, 0...0.98)
                                dial("Drive", 16, 0...1)
                                dial("Env", 17, -1...1)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        envelope("AMPLIFIER ENV", 18)
                        envelope("FILTER ENV", 22)
                        module("MODULATION") {
                            selector("LFO wave", 26, ["Sine", "Triangle", "Square"])
                            HStack(spacing: 2) {
                                dial("Rate", 27, 0.05...16, "Hz", logarithmic: true)
                                dial("Pitch", 28, 0...2, "st")
                                dial("Filter", 29, 0...1)
                            }
                        }
                        module("OUTPUT") {
                            selector("Voice mode", 33, ["Poly", "Mono"])
                            HStack(spacing: 2) {
                                dial("Volume", 32, 0...1)
                                dial("Spread", 31, 0...1)
                                dial("Glide", 30, 0...0.8, "s")
                                dial("Noise", 12, 0...1)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button { changeOctave(-1) } label: { Image(systemName: "minus") }.disabled(octave == -2)
                Text("Octave").font(.jarasCaption)
                Text(String(format: "%+d", octave)).monospacedDigit().foregroundStyle(accent)
                Button { changeOctave(1) } label: { Image(systemName: "plus") }.disabled(octave == 2)
                Spacer()
            }.buttonStyle(.bordered)
            keyboard.frame(height: 86)
        }.padding(12)
        .environment(\.fxDialAccent, accent)
        .environment(\.fxKnobDiameter, 31)
        .foregroundStyle(Color(hex: 0xf2eaff))
        .background {
            RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: 0x25143c), Color(hex: 0x100a21)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.42)) }
        }
        .onDisappear { press(nil) }
        .onChange(of: enabled) { if !$0 { press(nil) } }
        .onReceive(refresh) { _ in
            let voice = audio.effects(for: track)?.catSynthVoices[effect]
            let next = Set(notes.filter { voice?.keyIsActive(UInt($0)) == true })
            if next != sounding { sounding = next }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            press(nil)
            completePresetName()
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in press(nil) }
        .background(IpadTextKeyboardScope())
        #endif
    }

    private var presetStrip: some View {
        VStack(spacing: 7) {
            HStack {
                Group {
                    if presetToRename != nil {
                        TextField("Preset name", text: $presetNameDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onChange(of: presetNameDraft) { draft in
                                if draft.count > CatSynthBank.presetNameLimit {
                                    presetNameDraft = String(draft.prefix(CatSynthBank.presetNameLimit))
                                }
                            }
                            .onSubmit(completePresetName)
                            #if os(macOS)
                            .background(FieldOutsideClick(active: true, includesOtherWindows: true, dismiss: completePresetName))
                            #endif
                            .onChange(of: nameFocused) { focused in
                                if !focused { completePresetName() }
                            }
                    } else {
                        Text(verbatim: presetName(selected))
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                presetNameDraft = presetName(selected)
                                presetToRename = selected
                                nameFocused = true
                            }
                    }
                }.font(.jarasSystem(size: 17, weight: .bold))
                    .frame(height: 26, alignment: .leading)
                Spacer()
                Toggle("Enabled", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                    .tint(accent).accessibilityLabel("Enabled")
            }
            GeometryReader { geometry in
                let gap: CGFloat = 6
                let width = max(0, (geometry.size.width - gap * CGFloat(CatSynthBank.count - 1)) / CGFloat(CatSynthBank.count))
                HStack(spacing: gap) {
                    ForEach(0..<CatSynthBank.count, id: \.self) { index in
                        let button = Button {
                            completePresetName()
                            bank.selected = index
                        } label: {
                            Text(verbatim: String(format: "%02d", index + 1))
                                .font(.jarasSystem(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(selected == index ? Color(hex: 0x140522) : accent)
                                .frame(width: width, height: 29)
                                .background(selected == index ? accent : Color(hex: 0x211335), in: RoundedRectangle(cornerRadius: 5))
                                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(accent.opacity(hoveredPreset == index ? 1 : 0.35), lineWidth: hoveredPreset == index ? 2 : 1) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(Text(verbatim: presetName(index)))
                            .accessibilityAddTraits(selected == index ? .isSelected : [])
                        #if os(macOS)
                        button.simultaneousGesture(presetDrag(from: index, width: width, gap: gap))
                        #else
                        button.onDrag { dragPreset(index) }
                            .onDrop(of: [Self.presetDragType], isTargeted: Binding(
                                get: { hoveredPreset == index },
                                set: { active in
                                    if active { hoveredPreset = index }
                                    else if hoveredPreset == index { hoveredPreset = nil }
                                }
                            )) { providers in dropPreset(providers, on: index) }
                        #endif
                    }
                }
                #if os(macOS)
                .coordinateSpace(name: Self.presetStripSpace)
                #endif
            }.frame(height: 29)
        }.padding(9).background(Color(hex: 0x120a20), in: RoundedRectangle(cornerRadius: 8))
    }

    private func completePresetName() {
        guard let index = presetToRename else { return }
        presetToRename = nil
        nameFocused = false
        let name = String(presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CatSynthBank.presetNameLimit))
        var update = bank
        var names = update.names ?? Array(repeating: nil, count: CatSynthBank.count)
        names[index] = name.isEmpty || name == Self.names[index] ? nil : name
        update.names = names.contains(where: { $0 != nil }) ? names : nil
        if update.names != bank.names { bank = update }
    }

    private func copyPreset(_ values: [Float], name: String, to index: Int) {
        var update = bank
        update.slots[index] = values
        var names = update.names ?? Array(repeating: nil, count: CatSynthBank.count)
        names[index] = name == Self.names[index] ? nil : name
        update.names = names.contains(where: { $0 != nil }) ? names : nil
        bank = update
    }

    #if os(macOS)
    private func presetDrag(from source: Int, width: CGFloat, gap: CGFloat) -> some Gesture {
        func target(at point: CGPoint) -> Int? {
            guard point.x >= 0, point.y >= 0, point.y < 29 else { return nil }
            let index = Int(point.x / (width + gap))
            guard index < CatSynthBank.count, index != source,
                  point.x - CGFloat(index) * (width + gap) < width else { return nil }
            return index
        }
        return DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.presetStripSpace))
            .onChanged { hoveredPreset = target(at: $0.location) }
            .onEnded {
                hoveredPreset = nil
                guard let index = target(at: $0.location) else { return }
                completePresetName()
                copyPreset(patch(for: source), name: presetName(source), to: index)
            }
    }
    #else
    private struct PresetDrag: Codable {
        let effect: String
        let track: UUID?
        let source: Int
        let values: [Float]
        let name: String
    }

    private func dragPreset(_ index: Int) -> NSItemProvider {
        completePresetName()
        let provider = NSItemProvider()
        let preset = PresetDrag(effect: effect, track: track, source: index, values: patch(for: index), name: presetName(index))
        guard let data = try? JSONEncoder().encode(preset) else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: Self.presetDragType.identifier, visibility: .ownProcess) { complete in
            complete(data, nil)
            return nil
        }
        return provider
    }

    private func dropPreset(_ providers: [NSItemProvider], on index: Int) -> Bool {
        guard let item = providers.first else { return false }
        item.loadDataRepresentation(forTypeIdentifier: Self.presetDragType.identifier) { data, _ in
            guard let data, let preset = try? JSONDecoder().decode(PresetDrag.self, from: data),
                  preset.effect == effect, preset.track == track, preset.source != index,
                  preset.values.count == CatSynthBank.parameterCount, preset.values.allSatisfy(\.isFinite) else { return }
            DispatchQueue.main.async { self.copyPreset(preset.values, name: preset.name, to: index) }
        }
        return true
    }
    #endif

    private func oscillator(_ index: Int) -> some View {
        let first = index * 4
        return module("OSC \(index + 1)") {
            selector("Waveform", first, waves)
            HStack(spacing: 2) {
                dial("Level", first + 1, 0...1)
                dial("Tune", first + 2, -24...24, "st", integer: true)
                dial("Fine", first + 3, -100...100, "ct", integer: true)
            }
        }
    }

    private func envelope(_ name: String, _ first: Int) -> some View {
        module(name) {
            CatSynthEnvelopeShape(attack: Double(patch[first]), decay: Double(patch[first + 1]),
                          sustain: Double(patch[first + 2]), release: Double(patch[first + 3]), color: accent)
                .frame(height: 24)
            HStack(spacing: 2) {
                dial("Atk", first, 0.001...4, "s", logarithmic: true)
                dial("Dec", first + 1, 0.005...4, "s", logarithmic: true)
                dial("Sus", first + 2, 0...1)
                dial("Rel", first + 3, 0.006...8, "s", logarithmic: true)
            }
        }
    }

    private func module<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.jarasSystem(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.4).foregroundStyle(accent)
            content()
        }.padding(8).frame(maxWidth: .infinity)
            .background(Color(hex: 0x161020), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(accent.opacity(0.23)) }
    }

    private func selector(_ label: String, _ index: Int, _ labels: [String]) -> some View {
        let value = Int(patch[index])
        return Button {
            openSelector = index
        } label: {
            HStack {
                Text(verbatim: labels[labels.indices.contains(value) ? value : 0]).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.jarasSystem(size: 9, weight: .semibold))
            }.font(.jarasSystem(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color(hex: 0x2a1a3c), in: RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(accent.opacity(0.26)) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label))
            .popover(isPresented: Binding(get: { openSelector == index }, set: { if !$0, openSelector == index { openSelector = nil } }),
                     arrowEdge: .top) {
                VStack(spacing: 0) {
                    ForEach(labels.indices, id: \.self) { option in
                        Button {
                            set(index, Double(option))
                            openSelector = nil
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark").font(.jarasSystem(size: 9, weight: .bold))
                                    .opacity(option == value ? 1 : 0)
                                Text(verbatim: labels[option])
                                Spacer(minLength: 6)
                            }.padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(option == value ? Color(hex: 0x392650) : Color.clear)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.font(.jarasSystem(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0xf2eaff))
                    .padding(4).frame(minWidth: 134)
                    .background(Color(hex: 0x211335))
            }
    }
    private func dial(_ title: String, _ index: Int, _ range: ClosedRange<Double>, _ unit: String = "",
                      logarithmic: Bool = false, integer: Bool = false) -> some View {
        FXKnob(title, value: Binding(get: { Double(patch[index]) }, set: { set(index, integer ? $0.rounded() : $0) }),
               range: range, unit: unit, logarithmic: logarithmic, reset: Double(Self.factory[selected][index]))
    }

    private func set(_ index: Int, _ value: Double) {
        var values = patch
        values[index] = Float(value)
        if bank.slots.count != CatSynthBank.count { bank.slots = CatSynthBank().slots }
        bank.slots[selected] = values
    }

    private var notes: ClosedRange<Int> { (48 + octave * 12)...(84 + octave * 12) }
    private func isBlack(_ note: Int) -> Bool { [1, 3, 6, 8, 10].contains(note % 12) }
    private func key(_ note: Int, _ size: CGSize) -> CGRect {
        let width = size.width / 22
        let before = notes.prefix { $0 < note }.filter { !isBlack($0) }.count
        let black = isBlack(note)
        return CGRect(x: CGFloat(before) * width - (black ? width * 0.29 : 0), y: 0,
                      width: black ? width * 0.58 : width, height: black ? size.height * 0.62 : size.height)
    }

    private var keyboard: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for black in [false, true] {
                    for note in notes where isBlack(note) == black {
                        let rect = key(note, size).insetBy(dx: 0.5, dy: 0)
                        let on = sounding.contains(note) || note == pressed
                        let color = on ? accent : black ? Color(hex: 0x251731) : Color(hex: 0xece4fa)
                        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
                        if note % 12 == 0 {
                            context.draw(Text("C\(note / 12 - 1)").font(.jarasSystem(size: 8, weight: .medium)).foregroundColor(.black),
                                         at: CGPoint(x: rect.midX, y: rect.maxY - 12))
                        }
                    }
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($keyboardInteraction) { _, active, _ in active = true }
                    .onChanged { drag in
                    let point = drag.location, size = geometry.size
                    let hit = notes.first { isBlack($0) && key($0, size).contains(point) }
                        ?? notes.first { !isBlack($0) && key($0, size).contains(point) }
                    press(enabled ? hit : nil)
                }.onEnded { _ in press(nil) })
                .onChange(of: keyboardInteraction) { if !$0 { press(nil) } }
                .accessibilityLabel("37-key keyboard")
        }.background(Color(hex: 0x100917))
    }

    private func changeOctave(_ delta: Int) {
        press(nil)
        octave = max(-2, min(2, octave + delta))
    }
    private func press(_ note: Int?) {
        guard pressed != note else { return }
        if let pressed { audio.playCatSynthKey(track, effect: effect, key: pressed, velocity: 0) }
        pressed = nil
        if let note, audio.playCatSynthKey(track, effect: effect, key: note, velocity: 100) { pressed = note }
    }
}

private struct CatSynthEnvelopeShape: View {
    let attack, decay, sustain, release: Double
    let color: Color
    var body: some View {
        Canvas { context, size in
            let total = attack + decay + release + 0.4
            let peak = size.width * attack / total
            let fall = peak + size.width * decay / total
            let sustainEnd = fall + size.width * 0.4 / total
            let height = size.height - 2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: peak, y: 2))
            path.addLine(to: CGPoint(x: fall, y: height - sustain * (height - 2)))
            path.addLine(to: CGPoint(x: sustainEnd, y: height - sustain * (height - 2)))
            path.addLine(to: CGPoint(x: size.width, y: height))
            context.stroke(path, with: .color(color.opacity(0.82)), lineWidth: 1.4)
        }.accessibilityHidden(true)
    }
}
