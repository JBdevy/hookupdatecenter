import SwiftUI

/// Stable identifiers stored in the project, independent of language and font availability.
enum TrackInstrumentIcon: String, CaseIterable, Identifiable {
    case keyboard, piano, synthesizer, electricGuitar, acousticGuitar, cello
    case microphone, backingVocals, bass, drums, conga, bongo, surdo, accordion, organ, cowbell, jamblock
    case saxophone, trombone, trumpet, flute, clarinet, violin
    case tambourine, triangle, maracas, shaker, agogo, cajon, guiro, timbales
    case fx, click, guide, voice, backs, vocal
    var lettering: String? {
        switch self {
        case .fx: return "FX"
        case .click: return "CLICK"
        case .guide: return "GUIA"
        case .voice: return "VOZ"
        case .backs: return "BACKS"
        case .vocal: return "VOCAL"
        default: return nil
        }
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyboard: return "Teclado"
        case .piano: return "Piano"
        case .synthesizer: return "Synth"
        case .electricGuitar: return "Guitarra"
        case .acousticGuitar: return "Violão"
        case .cello: return "Cello"
        case .microphone: return "Microfone"
        case .backingVocals: return "3 vozes"
        case .bass: return "Baixo"
        case .drums: return "Bateria"
        case .conga: return "Conga"
        case .bongo: return "Bongô"
        case .surdo: return "Surdo"
        case .accordion: return "Acordeon"
        case .organ: return "Órgão"
        case .cowbell: return "Cowbell"
        case .jamblock: return "Jamblock"
        case .saxophone: return "Saxofone"
        case .trombone: return "Trombone"
        case .trumpet: return "Trompete"
        case .flute: return "Flauta"
        case .clarinet: return "Clarinete"
        case .violin: return "Violino"
        case .tambourine: return "Pandeiro"
        case .triangle: return "Triângulo"
        case .maracas: return "Maracas"
        case .shaker: return "Shaker"
        case .agogo: return "Agogô"
        case .cajon: return "Cajón"
        case .guiro: return "Güiro"
        case .timbales: return "Timbales"
        case .fx, .click, .guide, .voice, .backs, .vocal: return lettering ?? rawValue
        }
    }
}

struct TrackInstrumentIconView: View {
    let icon: TrackInstrumentIcon
    var body: some View {
        Group {
        if let text = icon.lettering {
            Text(verbatim: text).font(.system(size: text.count <= 3 ? 22 : 12, weight: .heavy, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
        } else {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 64
            context.translateBy(x: (size.width - 64 * scale) / 2, y: (size.height - 64 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.stroke(Self.drawing(icon), with: .foreground,
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        }
        }.accessibilityLabel(icon.title)
    }
    /// Vector artwork stays sharp at every interface scale, including short mixer rows.
    static func drawing(_ icon: TrackInstrumentIcon) -> Path {
        var p = Path()
        func line(_ points: [(Double, Double)]) {
            guard let first = points.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { p.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: 2, height: 2)) }
        func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { p.addEllipse(in: CGRect(x: x, y: y, width: w, height: h)) }
        func keys(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
            box(x, y, width, height)
            for k in 1..<8 { let xx = x + width * Double(k) / 8; line([(xx,y),(xx,y+height)]) }
            for k in [1,2,4,5,6] { let xx = x + width * Double(k) / 8; box(xx-1.5,y,3,height*0.52) }
        }
        func mic(_ x: Double, _ y: Double, _ h: Double) {
            box(x-3,y,6,12); line([(x,y+12),(x,y+h),(x-7,y+h+4)])
            line([(x,y+h),(x+7,y+h+4)])
            line([(x-5,y+7),(x-5,y+12),(x,y+15),(x+5,y+12),(x+5,y+7)])
        }
        switch icon {
        case .keyboard:
            box(6,17,52,29); keys(9,27,46,16)
            for x in [12.0,19,26] { oval(x,21,2,2) }
            line([(19,46),(45,57)]); line([(45,46),(19,57)])
        case .synthesizer:
            box(5,12,54,39); keys(8,33,48,15)
            for x in [10.0,19,28] { oval(x,18,5,5) }
            box(39,18,13,8); line([(11,28),(31,28)])
        case .piano:
            p.move(to: CGPoint(x: 12,y: 41)); p.addLine(to: CGPoint(x: 12,y: 12))
            p.addCurve(to: CGPoint(x: 49,y: 17), control1: CGPoint(x: 19,y: 1), control2: CGPoint(x: 37,y: 7))
            p.addCurve(to: CGPoint(x: 52,y: 41), control1: CGPoint(x: 59,y: 23), control2: CGPoint(x: 39,y: 30)); p.closeSubpath()
            keys(10,41,44,10); line([(14,51),(14,59)]); line([(50,51),(50,59)])
        case .organ:
            for (i,h) in [18.0,25,32,38,32,25,18].enumerated() {
                let x=10+Double(i)*6; box(x,42-h,4,h)
            }
            keys(8,42,48,8); keys(8,52,48,8)
        case .electricGuitar, .bass, .acousticGuitar:
            // Instrument is drawn upright: neck, headstock, body and bridge.
            box(29,10,6,27); box(28,3,8,8)
            for y in [5.0,9] { line([(25,y),(28,y)]); line([(36,y),(39,y)]) }
            if icon == .acousticGuitar {
                p.move(to: CGPoint(x: 26,y: 28))
                p.addCurve(to: CGPoint(x: 19,y: 43), control1: CGPoint(x: 12,y: 27), control2: CGPoint(x: 27,y: 37))
                p.addCurve(to: CGPoint(x: 45,y: 43), control1: CGPoint(x: 1,y: 64), control2: CGPoint(x: 63,y: 64))
                p.addCurve(to: CGPoint(x: 38,y: 28), control1: CGPoint(x: 37,y: 37), control2: CGPoint(x: 52,y: 27))
                oval(27,38,10,10)
            } else if icon == .bass {
                p.move(to: CGPoint(x: 27,y: 31))
                p.addCurve(to: CGPoint(x: 19,y: 27), control1: CGPoint(x: 21,y: 43), control2: CGPoint(x: 21,y: 25))
                p.addCurve(to: CGPoint(x: 15,y: 51), control1: CGPoint(x: 15,y: 28), control2: CGPoint(x: 11,y: 43))
                p.addCurve(to: CGPoint(x: 44,y: 55), control1: CGPoint(x: 16,y: 62), control2: CGPoint(x: 37,y: 63))
                p.addCurve(to: CGPoint(x: 43,y: 32), control1: CGPoint(x: 53,y: 46), control2: CGPoint(x: 46,y: 34))
                p.addQuadCurve(to: CGPoint(x: 37,y: 37), control: CGPoint(x: 39,y: 43))
                line([(26,43),(38,43)])
            } else {
                line([(26,25),(20,34),(20,29),(13,38),(16,53),(25,59),(39,57),(48,47),(47,34),(41,28),(40,36),(37,32)])
                line([(25,44),(39,44)]); line([(25,48),(39,48)])
            }
            line([(26,53),(38,53)]); line([(32,11),(32,53)])
            if icon == .bass { line([(29,20),(35,20)]); line([(29,25),(35,25)]); oval(41,49,3,3) }
        case .cello:
            box(29,4,6,29)
            p.move(to: CGPoint(x: 26,y: 21))
            p.addCurve(to: CGPoint(x: 25,y: 38), control1: CGPoint(x: 10,y: 20), control2: CGPoint(x: 12,y: 33))
            p.addCurve(to: CGPoint(x: 14,y: 49), control1: CGPoint(x: 25,y: 43), control2: CGPoint(x: 13,y: 42))
            p.addCurve(to: CGPoint(x: 50,y: 49), control1: CGPoint(x: 10,y: 62), control2: CGPoint(x: 54,y: 62))
            p.addCurve(to: CGPoint(x: 39,y: 38), control1: CGPoint(x: 51,y: 42), control2: CGPoint(x: 39,y: 43))
            p.addCurve(to: CGPoint(x: 38,y: 21), control1: CGPoint(x: 52,y: 33), control2: CGPoint(x: 54,y: 20))
            line([(32,6),(32,62)]); line([(25,48),(39,48)])
            line([(23,37),(21,43)]); line([(43,37),(41,43)])
        case .microphone: mic(32,7,45)
        case .backingVocals: mic(12,17,34); mic(32,7,44); mic(52,17,34)
        case .drums:
            oval(20,30,26,26); oval(24,34,18,18)
            box(13,22,14,10); box(36,20,14,10)
            oval(3,11,19,4); oval(43,9,18,4)
            line([(12,15),(12,52),(6,57)]); line([(12,52),(18,57)])
            line([(52,13),(52,51),(46,57)]); line([(52,51),(58,57)])
            line([(26,56),(23,60)]); line([(41,55),(44,60)])
        case .conga:
            oval(19,8,26,8)
            p.move(to: CGPoint(x: 19,y: 12)); p.addCurve(to: CGPoint(x: 24,y: 56),control1: CGPoint(x: 14,y: 30),control2: CGPoint(x: 22,y: 48))
            p.addQuadCurve(to: CGPoint(x: 40,y: 56),control: CGPoint(x: 32,y: 60))
            p.addCurve(to: CGPoint(x: 45,y: 12),control1: CGPoint(x: 42,y: 48),control2: CGPoint(x: 50,y: 30))
            line([(23,19),(25,31)]); line([(41,19),(39,31)])
        case .bongo:
            oval(5,20,25,8); oval(34,25,25,8)
            line([(6,25),(9,46),(25,46),(29,25)])
            line([(35,30),(38,50),(54,50),(58,30)])
            line([(30,32),(34,32)]); line([(13,29),(14,38)]); line([(47,35),(47,44)])
        case .surdo:
            oval(12,12,40,11); oval(12,48,40,10)
            line([(12,17),(12,53)]); line([(52,17),(52,53)])
            for x in [19.0,32,45] { line([(x,24),(x,47)]) }
            line([(22,5),(39,13)])
        case .cowbell:
            // Tapered metal bell, open flared mouth and mounting eye.
            box(26,5,12,9)
            line([(24,15),(40,15),(52,50),(12,50),(24,15)])
            p.move(to: CGPoint(x: 12,y: 50))
            p.addQuadCurve(to: CGPoint(x: 52,y: 50), control: CGPoint(x: 32,y: 64))
            line([(26,20),(20,43)])
            line([(16,51),(48,51)])
        case .jamblock:
            // Hollow rectangular percussion block with slit and mounting bracket.
            box(27,5,10,11); oval(30,8,4,4)
            line([(8,24),(20,17),(57,17),(57,43),(45,51),(8,51),(8,24),(45,24),(57,17)])
            line([(45,24),(45,51)])
            box(12,33,29,7)
            line([(49,30),(53,27),(53,38),(49,41),(49,30)])
        case .saxophone:
            line([(14,7),(23,6),(30,12)])
            p.move(to: CGPoint(x: 30,y: 12))
            p.addCurve(to: CGPoint(x: 24,y: 43), control1: CGPoint(x: 30,y: 23), control2: CGPoint(x: 20,y: 33))
            p.addCurve(to: CGPoint(x: 44,y: 38), control1: CGPoint(x: 27,y: 58), control2: CGPoint(x: 49,y: 53))
            line([(44,38),(40,29),(55,26),(53,42)])
            p.move(to: CGPoint(x: 53,y: 42))
            p.addCurve(to: CGPoint(x: 17,y: 45), control1: CGPoint(x: 57,y: 64), control2: CGPoint(x: 16,y: 65))
            p.addCurve(to: CGPoint(x: 23,y: 14), control1: CGPoint(x: 12,y: 35), control2: CGPoint(x: 27,y: 22))
            line([(23,14),(20,11),(14,11)]); oval(39,24,17,6)
            for y in [20.0,27,34] { oval(25-(y-20)*0.3,y,3,3) }
        case .trumpet:
            line([(5,27),(38,27),(47,22),(57,15),(57,43),(47,36),(38,31),(5,31),(5,27)])
            p.move(to: CGPoint(x: 11,y: 31)); p.addLine(to: CGPoint(x: 11,y: 42))
            p.addQuadCurve(to: CGPoint(x: 38,y: 42),control: CGPoint(x: 25,y: 53))
            p.addLine(to: CGPoint(x: 38,y: 32))
            for x in [18.0,26,34] { line([(x,21),(x,40)]); line([(x-2,19),(x+2,19)]) }
            line([(3,24),(3,34)])
        case .trombone:
            line([(5,18),(24,18),(42,13),(51,7),(51,28),(42,22),(25,22),(5,22)])
            p.move(to: CGPoint(x: 16,y: 22)); p.addLine(to: CGPoint(x: 16,y: 49))
            p.addCurve(to: CGPoint(x: 32,y: 49),control1: CGPoint(x: 16,y: 62),control2: CGPoint(x: 32,y: 62))
            p.addLine(to: CGPoint(x: 32,y: 25))
            line([(20,23),(20,49)]); line([(28,26),(28,49)])
            line([(16,34),(32,34)]); line([(3,15),(3,25)])
        case .flute:
            // Side-blown tube, lip plate and open keys.
            box(5,27,54,8); oval(9,25,9,12)
            for x in [25.0,32,39,46,53] { oval(x,26,3,10) }
            line([(57,25),(57,37)])
        case .clarinet:
            line([(30,4),(34,4),(35,12),(36,45),(43,57),(21,57),(28,45),(29,12),(30,4)])
            line([(28,16),(36,16)]); line([(27,44),(37,44)])
            for y in [21.0,28,35] { oval(30,y,4,4) }
            line([(38,23),(39,40)])
        case .violin:
            box(29,5,6,23)
            p.move(to: CGPoint(x: 26,y: 22))
            p.addCurve(to: CGPoint(x: 24,y: 36), control1: CGPoint(x: 12,y: 19), control2: CGPoint(x: 14,y: 34))
            p.addCurve(to: CGPoint(x: 18,y: 43), control1: CGPoint(x: 25,y: 41), control2: CGPoint(x: 18,y: 37))
            p.addCurve(to: CGPoint(x: 46,y: 43), control1: CGPoint(x: 7,y: 63), control2: CGPoint(x: 57,y: 63))
            p.addCurve(to: CGPoint(x: 40,y: 36), control1: CGPoint(x: 46,y: 37), control2: CGPoint(x: 39,y: 41))
            p.addCurve(to: CGPoint(x: 38,y: 22), control1: CGPoint(x: 50,y: 34), control2: CGPoint(x: 52,y: 19))
            line([(32,11),(32,53)]); line([(26,46),(38,46)])
            line([(9,54),(52,10)]); line([(11,56),(54,12)])
        case .tambourine:
            oval(8,12,48,41); oval(13,17,38,31)
            for (x,y) in [(10.0,24.0),(45,24),(26,12),(26,45)] { oval(x,y,10,4); oval(x,y+4,10,4) }
        case .triangle:
            line([(34,8),(8,53),(56,53),(39,19)])
            line([(32,8),(30,3),(36,3),(34,8)])
            line([(27,43),(57,21)])
        case .maracas:
            oval(7,9,19,26); oval(38,9,19,26)
            line([(14,35),(14,57),(19,57),(19,35)])
            line([(45,35),(45,57),(50,57),(50,35)])
            line([(8,21),(25,21)]); line([(39,21),(56,21)])
        case .shaker:
            oval(9,13,18,9); oval(9,48,18,9)
            line([(9,17),(9,52)]); line([(27,17),(27,52)])
            line([(38,20),(44,16),(40,27),(47,24)])
            line([(38,36),(44,32),(40,43),(47,40)])
        case .agogo:
            line([(16,24),(25,24),(31,50),(9,50),(16,24)])
            line([(40,13),(48,13),(55,37),(33,37),(40,13)])
            oval(9,47,22,6); oval(33,34,22,6)
            p.move(to: CGPoint(x: 20,y: 24)); p.addCurve(to: CGPoint(x: 44,y: 13),control1: CGPoint(x: 17,y: 1),control2: CGPoint(x: 35,y: 2))
        case .cajon:
            line([(12,17),(41,17),(53,9),(24,9),(12,17),(12,56),(41,56),(53,47),(53,9)])
            line([(41,17),(41,56)]); oval(44,25,6,12)
            for (x,y) in [(16.0,21.0),(36,21),(16,51),(36,51)] { oval(x,y,1,1) }
        case .guiro:
            p.addRoundedRect(in: CGRect(x: 16,y: 8,width: 22,height: 49),cornerSize: CGSize(width: 11,height: 11))
            for y in stride(from: 20.0,through: 46.0,by: 4) { line([(19,y),(35,y)]) }
            oval(24,12,6,4); line([(44,50),(53,14)])
        case .timbales:
            oval(4,17,26,8); oval(34,17,26,8)
            line([(4,21),(4,38),(30,38),(30,21)])
            line([(34,21),(34,38),(60,38),(60,21)])
            line([(30,30),(34,30)]); line([(32,30),(32,53),(22,60)])
            line([(32,53),(42,60)]); line([(13,7),(29,14)]); line([(51,7),(35,14)])
        case .fx, .click, .guide, .voice, .backs, .vocal: break
        case .accordion:
            box(6,17,14,36); box(44,17,14,36)
            for x in stride(from: 22.0,through: 42.0,by: 4) { line([(x,18),(x+2,14),(x+2,55),(x,51)]) }
            for y in stride(from: 22.0,through: 47.0,by: 5) { line([(7,y),(17,y)]) }
            for x in [48.0,53] { for y in [23.0,31,39,47] { oval(x,y,1,1) } }
            line([(9,17),(15,8),(49,8),(55,17)])
        }
        return p
    }
}

struct TrackInstrumentPickerModal: View {
    let show: ShowController
    let request: TrackDetailsEditRequest
    let close: () -> Void
    @State private var icon: String?
    init(show: ShowController, request: TrackDetailsEditRequest, close: @escaping () -> Void) {
        self.show = show; self.request = request; self.close = close
        _icon = State(initialValue: request.instrumentIcon)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ícone da pista").font(.jarasTitle2.bold())
            Text(verbatim: request.tracks.count == 1 ? request.name : "\(request.tracks.count) pistas selecionadas")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary).lineLimit(1)
            #if os(macOS)
            choices.frame(height: 350)
            #else
            choices.frame(maxHeight: .infinity)
            #endif
            HStack {
                Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar") {
                    show.editTrackDetails(request.tracks, name: nil, color: nil,
                                          instrumentIcon: icon, project: request.project)
                    close()
                }.keyboardShortcut(.defaultAction)
            }.buttonStyle(StageButtonStyle(color: JarasTheme.accent))
        }.padding(22).frame(maxWidth: 530).foregroundStyle(.white).background(JarasTheme.panel)
        #if os(macOS)
        .frame(width: 530)
        #endif
    }
    private var choices: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 8) {
                choice(nil, title: "Sem ícone")
                ForEach(TrackInstrumentIcon.allCases) { choice($0, title: $0.title) }
            }.padding(2)
        }
    }
    private func choice(_ value: TrackInstrumentIcon?, title: String) -> some View {
        Button { icon = value?.rawValue } label: {
            VStack(spacing: 5) {
                Group {
                    if let value { TrackInstrumentIconView(icon: value) }
                    else { RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).padding(7) }
                }.frame(height: 38)
                Text(verbatim: title).font(.jarasSystem(size: 10)).lineLimit(1).minimumScaleFactor(0.7)
            }.foregroundStyle(.white).padding(6).frame(maxWidth: .infinity)
                .background(icon == value?.rawValue ? JarasTheme.green.opacity(0.25) : Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(icon == value?.rawValue ? JarasTheme.green : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityAddTraits(icon == value?.rawValue ? .isSelected : [])
    }
}
