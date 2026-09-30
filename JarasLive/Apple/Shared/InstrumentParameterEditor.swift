import SwiftUI

struct InstrumentParameterEditor: View {
    let name: String
    let category: InstrumentCategory?
    private var drums: Bool { category == .drum }
    @State private var page = "Envelope"
    @Binding var parameters: InstrumentParameters
    private func envelope(_ key: WritableKeyPath<InstrumentParameters, Double>) -> Binding<Double> {
        Binding(get: { parameters[keyPath: key] }, set: { parameters[keyPath: key] = $0 })
    }
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Image(systemName: "pianokeys").foregroundStyle(JarasTheme.green)
                Text(name).font(.title2.weight(.semibold))
                Spacer()
                Picker("Parameters", selection: $page) {
                    Text("Envelope").tag("Envelope")
                    Text("Velocity").tag("Velocity")
                    Text("Cutoff").tag("Cutoff")
                    Text("Controller").tag("Controller")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 380)
            }
            if page == "Envelope" {
            Canvas { context, size in
                let inset = 16.0, height = size.height - inset * 2, width = size.width - inset * 2
                let total = parameters.attack + parameters.hold + parameters.decay + parameters.release + 1
                let attackX = inset + width * parameters.attack / total
                let holdX = attackX + width * parameters.hold / total
                let decayX = holdX + width * parameters.decay / total
                let releaseX = decayX + width / total
                let sustainY = inset + height * (1 - parameters.sustain)
                var curve = Path()
                curve.move(to: CGPoint(x: inset, y: inset + height))
                curve.addLine(to: CGPoint(x: attackX, y: inset))
                curve.addLine(to: CGPoint(x: holdX, y: inset))
                curve.addLine(to: CGPoint(x: decayX, y: sustainY))
                curve.addLine(to: CGPoint(x: releaseX, y: sustainY))
                curve.addLine(to: CGPoint(x: inset + width, y: inset + height))
                var area = curve; area.closeSubpath()
                let color = JarasTheme.green
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(curve, with: .color(color), lineWidth: 2)
            }.frame(minHeight: 130, maxHeight: 220).background(JarasTheme.display).cornerRadius(8)
            HStack(spacing: 8) {
                FXKnob("Attack", value: envelope(\.attack), range: 0...10, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0, parameter: .instrumentAttack)
                FXKnob("Hold", value: envelope(\.hold), range: 0...10, unit: "ms", multiplier: 1000, logarithmic: true, reset: 10, parameter: .instrumentHold)
                FXKnob("Decay", value: envelope(\.decay), range: 0.001...10, unit: "ms", multiplier: 1000, logarithmic: true, reset: 10, parameter: .instrumentDecay)
                FXKnob("Sustain", value: envelope(\.sustain), range: 0...1, unit: "%", multiplier: 100, reset: 1, parameter: .instrumentSustain)
                FXKnob("Release", value: envelope(\.release), range: 0.001...20, unit: "ms", multiplier: 1000, logarithmic: true, reset: drums ? 20 : 0.3, parameter: .instrumentRelease)
                FXKnob("Gain", value: $parameters.gain, range: -24...12, unit: "dB", reset: 0, parameter: .instrumentGain)
            }.padding(18).background(JarasTheme.display).cornerRadius(10)
            } else if page == "Velocity" { velocityPage } else if page == "Cutoff" { cutoffPage } else { controllerPage }
        }
    }
    private var velocity: InstrumentVelocityParameters { parameters.velocity ?? InstrumentVelocityParameters() }
    private var cutoff: InstrumentCutoffParameters { parameters.cutoff ?? InstrumentCutoffParameters() }
    private func filter(_ key: WritableKeyPath<InstrumentCutoffParameters, Double>) -> Binding<Double> {
        Binding(get: { cutoff[keyPath: key] }, set: { var value = cutoff; value[keyPath: key] = $0; parameters.cutoff = value })
    }
    private var velocityPage: some View {
        VStack(spacing: 20) {
            Picker("Curve", selection: Binding(get: { velocity.curve }, set: { var value = velocity; value.curve = $0; parameters.velocity = value })) {
                Text("Soft").tag(InstrumentVelocityCurve.soft)
                Text("Medium").tag(InstrumentVelocityCurve.medium)
                Text("Hard").tag(InstrumentVelocityCurve.hard)
            }.pickerStyle(.segmented).mapFXMIDI(.velocityCurve, name: "Curve", range: 0...2)
            Canvas { context, size in
                let rect = CGRect(x: 18, y: 18, width: size.width - 36, height: size.height - 36)
                var grid = Path()
                for step in 0...4 {
                    let fraction = CGFloat(step) / 4
                    grid.move(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.minY)); grid.addLine(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.maxY))
                    grid.move(to: CGPoint(x: rect.minX, y: rect.minY + fraction * rect.height)); grid.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fraction * rect.height))
                }
                context.stroke(grid, with: .color(JarasTheme.line), lineWidth: 1)
                var curve = Path()
                for step in 0...100 {
                    let x = Double(step) / 100
                    let point = CGPoint(x: rect.minX + x * rect.width, y: rect.maxY - velocity.curve.value(x) * rect.height)
                    if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(JarasTheme.green), lineWidth: 2)
            }.frame(minHeight: 150, maxHeight: 240).background(JarasTheme.display).cornerRadius(8)
            HStack(spacing: 24) {
                FXKnob("Cutoff", value: Binding(get: { velocity.cutoffMinimum }, set: { var value = velocity; value.cutoffMinimum = $0; parameters.velocity = value }), range: 20...20000, unit: "Hz", logarithmic: true, reset: 20000, parameter: .velocityCutoff)
                Text("Minimum cutoff for soft notes. Stronger notes open their own filter.").font(.callout).foregroundStyle(JarasTheme.secondary)
            }.padding(18).background(JarasTheme.display).cornerRadius(10)
        }
    }
    private var cutoffPage: some View {
        VStack(spacing: 22) {
            HStack(spacing: 24) {
                FXKnob("Cutoff", value: filter(\.frequency), range: 20...20000, unit: "Hz", logarithmic: true, reset: 20000, parameter: .cutoffFrequency)
                FXKnob("Depth", value: filter(\.depth), range: 0...10, unit: "oct", reset: 0, parameter: .cutoffDepth)
                Text("Cutoff envelope").font(.title3.weight(.semibold))
                Spacer()
            }.padding(18).background(JarasTheme.display).cornerRadius(10)
            HStack(spacing: 8) {
                FXKnob("Attack", value: filter(\.attack), range: 0...10, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0, parameter: .cutoffAttack)
                FXKnob("Hold", value: filter(\.hold), range: 0...10, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0, parameter: .cutoffHold)
                FXKnob("Decay", value: filter(\.decay), range: 0.001...10, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.3, parameter: .cutoffDecay)
                FXKnob("Sustain", value: filter(\.sustain), range: 0...1, unit: "%", multiplier: 100, reset: 1, parameter: .cutoffSustain)
                FXKnob("Release", value: filter(\.release), range: 0.001...20, unit: "ms", multiplier: 1000, logarithmic: true, reset: 0.3, parameter: .cutoffRelease)
            }.padding(18).background(JarasTheme.display).cornerRadius(10)
        }
    }

    private func controller(_ key: WritableKeyPath<InstrumentControllerParameters, Bool>) -> Binding<Bool> {
        Binding(get: { (parameters.controllers ?? InstrumentLibrary.controllers(category))[keyPath: key] }, set: { var value = parameters.controllers ?? InstrumentLibrary.controllers(category); value[keyPath: key] = $0; parameters.controllers = value })
    }
    private var controllerPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            FXKnob("Volume", value: Binding(get: { parameters.controllers?.volume ?? 0 }, set: { volume in
                var value = parameters.controllers ?? InstrumentLibrary.controllers(category)
                value.volume = min(0, max(-96, volume)); parameters.controllers = value
            }), range: -96...0, unit: "dB", reset: 0, parameter: .instrumentVolume)

            Picker("Voice mode", selection: Binding(get: {
                parameters.controllers?.monophonic ?? (category == .lead)
            }, set: { mono in
                var value = parameters.controllers ?? InstrumentLibrary.controllers(category)
                value.monophonic = mono; parameters.controllers = value
            })) {
                Text("Monophonic").tag(true)
                Text("Polyphonic").tag(false)
            }.pickerStyle(.segmented)
            Divider()
            Toggle("Modulation", isOn: controller(\.modulation)).mapFXMIDI(.modulation, name: "Modulation", range: 0...1)
            Text("Modulation wheel controls the cutoff.").foregroundStyle(JarasTheme.secondary)
            Divider()
            Toggle("Pitch Bend", isOn: controller(\.pitchBend)).mapFXMIDI(.pitchBend, name: "Pitch Bend", range: 0...1)
            Text("Pitch Bend controls vibrato depth at 6.85 Hz.").foregroundStyle(JarasTheme.secondary)
            Spacer(minLength: 20)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(JarasTheme.display).cornerRadius(10)
    }

}
