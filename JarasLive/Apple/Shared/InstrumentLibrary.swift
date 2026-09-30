import SwiftUI
import AVFoundation

enum InstrumentCategory: String, CaseIterable, Identifiable {
    case pianos = "Grand Piano", upright = "Upright", electric = "Electric", keyboard = "Keyboard"
    case organ = "Organ", strings = "Strings", guitar = "Guitar", bass = "Bass"
    case synth = "Synth", synthPad = "Synth Pad", lead = "Lead", acordeon = "Acordeon"
    case brass = "Brass", mallets = "Mallets", drum = "Drum"
    var id: String { rawValue }
    var folder: String {
        switch self {
        case .pianos: return "01-Grand Piano"
        case .upright: return "02-Upright"
        case .electric: return "03-Eletric"
        case .keyboard: return "04-Keyboard"
        case .organ: return "05-Organ"
        case .strings: return "06-Strings"
        case .guitar: return "07-Guitar"
        case .bass: return "08-Bass"
        case .synth: return "09-Synth"
        case .synthPad: return "10-Synth Pad"
        case .lead: return "11-Lead"
        case .acordeon: return "12-Acordeon"
        case .brass: return "13-Brass"
        case .mallets: return "14-Mallets"
        case .drum: return "16-Drum"
        }
    }
}
struct LibraryInstrument: Identifiable {
    let id: String
    let name: String
    let category: InstrumentCategory
    var percussion: Bool { category == .drum }
    var url: URL { URL(string: "https://pub-1b271ca25cc347ce82f835a8125d6d93.r2.dev/")!.appendingPathComponent(category.folder).appendingPathComponent(name + ".sf2") }
}
@MainActor final class InstrumentLibrary: ObservableObject {
    static let shared = InstrumentLibrary()
    static let catalog = [
        LibraryInstrument(id: "astoria-grand", name: "Astoria Grand", category: .pianos),
        LibraryInstrument(id: "bright-grand", name: "Bright Grand", category: .pianos),
        LibraryInstrument(id: "c7-grand", name: "C7 Grand", category: .pianos),
        LibraryInstrument(id: "cfx-premium", name: "CFX Premium", category: .pianos),
        LibraryInstrument(id: "full-grand", name: "Full Grand", category: .pianos),
        LibraryInstrument(id: "grand-imperial", name: "Grand Imperial", category: .pianos),
        LibraryInstrument(id: "grand-lady-d", name: "Grand Lady D", category: .pianos),
        LibraryInstrument(id: "italian-grand", name: "Italian Grand", category: .pianos),
        LibraryInstrument(id: "royal-grand-3d", name: "Royal Grand 3D", category: .pianos),
        LibraryInstrument(id: "s6-grand", name: "S6 Grand", category: .pianos),
        LibraryInstrument(id: "s700-intimate", name: "S700 Intimate", category: .pianos),
        LibraryInstrument(id: "s700-natural", name: "S700 Natural", category: .pianos),
        LibraryInstrument(id: "salsa-grand-1", name: "Salsa Grand 1", category: .pianos),
        LibraryInstrument(id: "salsa-grand-2", name: "Salsa Grand 2", category: .pianos),
        LibraryInstrument(id: "silver-grand", name: "Silver Grand", category: .pianos),
        LibraryInstrument(id: "soft-grand", name: "Soft Grand", category: .pianos),
        LibraryInstrument(id: "studio-grand", name: "Studio Grand", category: .pianos),
        LibraryInstrument(id: "velvet-grand", name: "Velvet Grand", category: .pianos),
        LibraryInstrument(id: "vintage-grand-1", name: "Vintage Grand 1", category: .pianos),
        LibraryInstrument(id: "vintage-grand-2", name: "Vintage Grand 2", category: .pianos),
        LibraryInstrument(id: "vintage-grand-3", name: "Vintage Grand 3", category: .pianos),
        LibraryInstrument(id: "white-grand", name: "White Grand", category: .pianos),
        LibraryInstrument(id: "baby-upright", name: "Baby Upright", category: .upright),
        LibraryInstrument(id: "black-upright", name: "Black Upright", category: .upright),
        LibraryInstrument(id: "felt-upright", name: "Felt Upright", category: .upright),
        LibraryInstrument(id: "grand-upright", name: "Grand Upright", category: .upright),
        LibraryInstrument(id: "honkytonk-upright", name: "HonkyTonk Upright", category: .upright),
        LibraryInstrument(id: "mellow-upright", name: "Mellow Upright", category: .upright),
        LibraryInstrument(id: "pearl-upright", name: "Pearl Upright", category: .upright),
        LibraryInstrument(id: "romantic-upright", name: "Romantic Upright", category: .upright),
        LibraryInstrument(id: "80s-layer", name: "80s Layer", category: .electric),
        LibraryInstrument(id: "ballad-ep-1", name: "Ballad EP 1", category: .electric),
        LibraryInstrument(id: "ballad-ep-2", name: "Ballad EP 2", category: .electric),
        LibraryInstrument(id: "ballad-key", name: "Ballad Key", category: .electric),
        LibraryInstrument(id: "chorusdyno", name: "ChorusDyno", category: .electric),
        LibraryInstrument(id: "crystal-ep", name: "Crystal EP", category: .electric),
        LibraryInstrument(id: "dx-crisp", name: "Dx Crisp", category: .electric),
        LibraryInstrument(id: "dx-legend", name: "DX Legend", category: .electric),
        LibraryInstrument(id: "e-piano-2", name: "E. Piano 2", category: .electric),
        LibraryInstrument(id: "ep1-ep2", name: "Ep1 + Ep2", category: .electric),
        LibraryInstrument(id: "fm-dyno", name: "FM Dyno", category: .electric),
        LibraryInstrument(id: "full-tines", name: "Full Tines", category: .electric),
        LibraryInstrument(id: "galaxy-dx", name: "Galaxy DX", category: .electric),
        LibraryInstrument(id: "hybrid-ep-1", name: "Hybrid EP 1", category: .electric),
        LibraryInstrument(id: "mks-ep", name: "MKS Ep", category: .electric),
        LibraryInstrument(id: "r-b-soft", name: "R&B Soft", category: .electric),
        LibraryInstrument(id: "rd-bright-tines", name: "RD Bright Tines", category: .electric),
        LibraryInstrument(id: "rd-close-ideal", name: "RD Close Ideal", category: .electric),
        LibraryInstrument(id: "rd-low-deep", name: "RD low Deep", category: .electric),
        LibraryInstrument(id: "rd-nefertiti", name: "RD Nefertiti", category: .electric),
        LibraryInstrument(id: "rd-shallow-close", name: "RD Shallow Close", category: .electric),
        LibraryInstrument(id: "rd-stockholm", name: "RD Stockholm", category: .electric),
        LibraryInstrument(id: "rd-tines-amped", name: "RD Tines Amped", category: .electric),
        LibraryInstrument(id: "rhodes-4", name: "Rhodes 4", category: .electric),
        LibraryInstrument(id: "tx-ep1", name: "Tx EP1", category: .electric),
        LibraryInstrument(id: "tx-ep2", name: "Tx EP2", category: .electric),
        LibraryInstrument(id: "vintage-ep-1", name: "Vintage Ep 1", category: .electric),
        LibraryInstrument(id: "vintage-ep-2", name: "Vintage Ep 2", category: .electric),
        LibraryInstrument(id: "wurlitzer-amped", name: "Wurlitzer Amped", category: .electric),
        LibraryInstrument(id: "yama-eps", name: "Yama EPs", category: .electric),
        LibraryInstrument(id: "clavinet-wah", name: "Clavinet Wah", category: .keyboard),
        LibraryInstrument(id: "clavinet", name: "Clavinet", category: .keyboard),
        LibraryInstrument(id: "cp-80-1", name: "CP 80 1", category: .keyboard),
        LibraryInstrument(id: "cp-80-2", name: "CP 80 2", category: .keyboard),
        LibraryInstrument(id: "la-midi", name: "La Midi", category: .keyboard),
        LibraryInstrument(id: "midi-grand", name: "Midi Grand", category: .keyboard),
        LibraryInstrument(id: "catedral", name: "Catedral", category: .organ),
        LibraryInstrument(id: "fast-organ-full", name: "Fast Organ Full", category: .organ),
        LibraryInstrument(id: "fast-organ-one", name: "Fast Organ One", category: .organ),
        LibraryInstrument(id: "fast-rotary", name: "Fast Rotary", category: .organ),
        LibraryInstrument(id: "organ-arp", name: "Organ Arp", category: .organ),
        LibraryInstrument(id: "slow-organ-full", name: "Slow Organ Full", category: .organ),
        LibraryInstrument(id: "slow-organ-one", name: "Slow Organ One", category: .organ),
        LibraryInstrument(id: "slow-rotary", name: "Slow Rotary", category: .organ),
        LibraryInstrument(id: "cello", name: "Cello", category: .strings),
        LibraryInstrument(id: "cinematic-strings", name: "Cinematic Strings", category: .strings),
        LibraryInstrument(id: "film-strings", name: "Film Strings", category: .strings),
        LibraryInstrument(id: "full-strings", name: "Full Strings", category: .strings),
        LibraryInstrument(id: "horns-orch", name: "Horns Orch", category: .strings),
        LibraryInstrument(id: "romantic-strings", name: "Romantic Strings", category: .strings),
        LibraryInstrument(id: "staccato-w", name: "Staccato W", category: .strings),
        LibraryInstrument(id: "staccato-x", name: "Staccato X", category: .strings),
        LibraryInstrument(id: "violin-one", name: "Violin One", category: .strings),
        LibraryInstrument(id: "violin-s", name: "Violin S", category: .strings),
        LibraryInstrument(id: "violin", name: "Violin", category: .strings),
        LibraryInstrument(id: "banjo-1", name: "Banjo 1", category: .guitar),
        LibraryInstrument(id: "guitar-ambience", name: "Guitar Ambience", category: .guitar),
        LibraryInstrument(id: "guitar-boiler", name: "Guitar Boiler", category: .guitar),
        LibraryInstrument(id: "guitar-cappuccino", name: "Guitar Cappuccino", category: .guitar),
        LibraryInstrument(id: "guitar-ch", name: "Guitar CH", category: .guitar),
        LibraryInstrument(id: "guitar-comp", name: "Guitar Comp", category: .guitar),
        LibraryInstrument(id: "guitar-drive-1", name: "Guitar Drive 1", category: .guitar),
        LibraryInstrument(id: "guitar-drive-2", name: "Guitar Drive 2", category: .guitar),
        LibraryInstrument(id: "guitar-drive-3", name: "Guitar Drive 3", category: .guitar),
        LibraryInstrument(id: "guitar-jazz-cat", name: "Guitar Jazz Cat", category: .guitar),
        LibraryInstrument(id: "guitar-jazzernaut", name: "Guitar Jazzernaut", category: .guitar),
        LibraryInstrument(id: "guitar-overdrive", name: "Guitar OverDrive", category: .guitar),
        LibraryInstrument(id: "guitar-pgd", name: "Guitar PGD", category: .guitar),
        LibraryInstrument(id: "guitar-warm", name: "Guitar Warm", category: .guitar),
        LibraryInstrument(id: "nylon-guitar-1", name: "Nylon Guitar 1", category: .guitar),
        LibraryInstrument(id: "steel-guitar-1", name: "Steel Guitar 1", category: .guitar),
        LibraryInstrument(id: "steel-guitar-2", name: "Steel Guitar 2", category: .guitar),
        LibraryInstrument(id: "stratocaster", name: "Stratocaster", category: .guitar),
        LibraryInstrument(id: "acoustic-bass", name: "Acoustic Bass", category: .bass),
        LibraryInstrument(id: "bass-moog", name: "Bass Moog", category: .bass),
        LibraryInstrument(id: "bassdeepsaw", name: "BassDeepSaw", category: .bass),
        LibraryInstrument(id: "bassdeepsq", name: "BassDeepSQ", category: .bass),
        LibraryInstrument(id: "bassgoodrange", name: "BassGoodRange", category: .bass),
        LibraryInstrument(id: "fr-bass", name: "FR Bass", category: .bass),
        LibraryInstrument(id: "jazz-bass", name: "Jazz Bass", category: .bass),
        LibraryInstrument(id: "pick-bass-2", name: "Pick Bass 2", category: .bass),
        LibraryInstrument(id: "pick-bass", name: "Pick Bass", category: .bass),
        LibraryInstrument(id: "precision-bass-1", name: "Precision Bass 1", category: .bass),
        LibraryInstrument(id: "precision-bass-2", name: "Precision Bass 2", category: .bass),
        LibraryInstrument(id: "precision-drive", name: "Precision Drive", category: .bass),
        LibraryInstrument(id: "precision-vintage", name: "Precision Vintage", category: .bass),
        LibraryInstrument(id: "synth-bass-2", name: "Synth Bass 2", category: .bass),
        LibraryInstrument(id: "synth-bass-3", name: "Synth Bass 3", category: .bass),
        LibraryInstrument(id: "synth-bass-square", name: "Synth Bass Square", category: .bass),
        LibraryInstrument(id: "synth-bass", name: "Synth Bass", category: .bass),
        LibraryInstrument(id: "upright-bass-ride", name: "Upright Bass Ride", category: .bass),
        LibraryInstrument(id: "upright-bass", name: "Upright Bass", category: .bass),
        LibraryInstrument(id: "vintage-jb", name: "Vintage JB", category: .bass),
        LibraryInstrument(id: "yama-trb", name: "Yama TRB", category: .bass),
        LibraryInstrument(id: "70s-bounce", name: "70s Bounce", category: .synth),
        LibraryInstrument(id: "bells-brightness-2", name: "Bells Brightness 2", category: .synth),
        LibraryInstrument(id: "bells-brightness", name: "Bells Brightness", category: .synth),
        LibraryInstrument(id: "bells-fairy", name: "Bells Fairy", category: .synth),
        LibraryInstrument(id: "bells-laser", name: "Bells Laser", category: .synth),
        LibraryInstrument(id: "ds-bells", name: "Ds Bells", category: .synth),
        LibraryInstrument(id: "fantasy-ks", name: "Fantasy Ks", category: .synth),
        LibraryInstrument(id: "fr-bells", name: "FR Bells", category: .synth),
        LibraryInstrument(id: "horizon", name: "Horizon", category: .synth),
        LibraryInstrument(id: "hs-sine", name: "Hs Sine", category: .synth),
        LibraryInstrument(id: "noise-slice", name: "Noise Slice", category: .synth),
        LibraryInstrument(id: "oneverb", name: "Oneverb", category: .synth),
        LibraryInstrument(id: "pad-pluck", name: "Pad Pluck", category: .synth),
        LibraryInstrument(id: "pluck-essenc", name: "Pluck Essenc", category: .synth),
        LibraryInstrument(id: "pluck-life", name: "Pluck Life", category: .synth),
        LibraryInstrument(id: "pluck-rhodes", name: "Pluck Rhodes", category: .synth),
        LibraryInstrument(id: "pluck-state", name: "Pluck State", category: .synth),
        LibraryInstrument(id: "pluck-white", name: "Pluck White", category: .synth),
        LibraryInstrument(id: "pluckverb", name: "Pluckverb", category: .synth),
        LibraryInstrument(id: "pure-feather", name: "Pure Feather", category: .synth),
        LibraryInstrument(id: "purple-lullaby", name: "Purple Lullaby", category: .synth),
        LibraryInstrument(id: "quantum-pad", name: "Quantum Pad", category: .synth),
        LibraryInstrument(id: "sine-pluck-1", name: "Sine Pluck 1", category: .synth),
        LibraryInstrument(id: "sine-pluck-2", name: "Sine Pluck 2", category: .synth),
        LibraryInstrument(id: "synth-basic", name: "Synth Basic", category: .synth),
        LibraryInstrument(id: "synth-bells", name: "Synth Bells", category: .synth),
        LibraryInstrument(id: "synth-brass-1", name: "Synth Brass 1", category: .synth),
        LibraryInstrument(id: "synth-brass-2", name: "Synth Brass 2", category: .synth),
        LibraryInstrument(id: "synth-hour", name: "Synth Hour", category: .synth),
        LibraryInstrument(id: "synth-pluck-1", name: "Synth Pluck 1", category: .synth),
        LibraryInstrument(id: "synth-pluck-2", name: "Synth Pluck 2", category: .synth),
        LibraryInstrument(id: "synth-pluck-3", name: "Synth Pluck 3", category: .synth),
        LibraryInstrument(id: "synth-pluck-4", name: "Synth Pluck 4", category: .synth),
        LibraryInstrument(id: "synth-tesla", name: "Synth Tesla", category: .synth),
        LibraryInstrument(id: "vocal-cuts-1", name: "Vocal Cuts 1", category: .synth),
        LibraryInstrument(id: "vocal-cuts-2", name: "Vocal Cuts 2", category: .synth),
        LibraryInstrument(id: "vocal-cuts-3", name: "Vocal Cuts 3", category: .synth),
        LibraryInstrument(id: "affect-saw", name: "Affect Saw", category: .synthPad),
        LibraryInstrument(id: "africa-pad", name: "Africa Pad", category: .synthPad),
        LibraryInstrument(id: "ambient-pad", name: "Ambient Pad", category: .synthPad),
        LibraryInstrument(id: "analog-pad", name: "Analog Pad", category: .synthPad),
        LibraryInstrument(id: "angel-pad", name: "Angel Pad", category: .synthPad),
        LibraryInstrument(id: "angelic-pad", name: "Angelic Pad", category: .synthPad),
        LibraryInstrument(id: "bealty-pad", name: "Bealty Pad", category: .synthPad),
        LibraryInstrument(id: "bell-pad", name: "Bell Pad", category: .synthPad),
        LibraryInstrument(id: "breath-pad", name: "Breath Pad", category: .synthPad),
        LibraryInstrument(id: "cruncher-pad", name: "Cruncher Pad", category: .synthPad),
        LibraryInstrument(id: "drut-pad", name: "Drut Pad", category: .synthPad),
        LibraryInstrument(id: "dystopian-pad", name: "Dystopian Pad", category: .synthPad),
        LibraryInstrument(id: "force-pad", name: "Force Pad", category: .synthPad),
        LibraryInstrument(id: "gemani-pad", name: "Gemani Pad", category: .synthPad),
        LibraryInstrument(id: "glass-pad", name: "Glass Pad", category: .synthPad),
        LibraryInstrument(id: "happy-pad", name: "Happy Pad", category: .synthPad),
        LibraryInstrument(id: "jab-pad", name: "Jab Pad", category: .synthPad),
        LibraryInstrument(id: "organic-pad", name: "Organic Pad", category: .synthPad),
        LibraryInstrument(id: "shimmer-pad", name: "Shimmer Pad", category: .synthPad),
        LibraryInstrument(id: "shinng-pad", name: "Shinng Pad", category: .synthPad),
        LibraryInstrument(id: "space-pad", name: "Space Pad", category: .synthPad),
        LibraryInstrument(id: "sublime-pad", name: "Sublime Pad", category: .synthPad),
        LibraryInstrument(id: "sun-pad", name: "Sun Pad", category: .synthPad),
        LibraryInstrument(id: "sweep-pad", name: "Sweep Pad", category: .synthPad),
        LibraryInstrument(id: "synth-atmosphere", name: "Synth Atmosphere", category: .synthPad),
        LibraryInstrument(id: "synth-saw-env", name: "Synth Saw Env", category: .synthPad),
        LibraryInstrument(id: "synth-saw-x", name: "Synth Saw X", category: .synthPad),
        LibraryInstrument(id: "synth-saw", name: "Synth Saw", category: .synthPad),
        LibraryInstrument(id: "synth-trance", name: "Synth Trance", category: .synthPad),
        LibraryInstrument(id: "warm-pad-nx", name: "Warm Pad NX", category: .synthPad),
        LibraryInstrument(id: "glide-moog", name: "Glide Moog", category: .lead),
        LibraryInstrument(id: "lead-chariot", name: "Lead Chariot", category: .lead),
        LibraryInstrument(id: "lead-electricity", name: "Lead Electricity", category: .lead),
        LibraryInstrument(id: "lead-energy", name: "Lead Energy", category: .lead),
        LibraryInstrument(id: "lead-march", name: "Lead March", category: .lead),
        LibraryInstrument(id: "lead-moss", name: "Lead Moss", category: .lead),
        LibraryInstrument(id: "lead-smooth", name: "Lead Smooth", category: .lead),
        LibraryInstrument(id: "saw-moog-1", name: "saw Moog 1", category: .lead),
        LibraryInstrument(id: "saw-moog-2", name: "saw Moog 2", category: .lead),
        LibraryInstrument(id: "saw-moog-3", name: "saw Moog 3", category: .lead),
        LibraryInstrument(id: "sine-bell", name: "Sine Bell", category: .lead),
        LibraryInstrument(id: "sine-moog", name: "Sine Moog", category: .lead),
        LibraryInstrument(id: "sine-saw", name: "Sine Saw", category: .lead),
        LibraryInstrument(id: "mussette", name: "Mussette", category: .acordeon),
        LibraryInstrument(id: "scandalli-accordeon", name: "Scandalli Accordeon", category: .acordeon),
        LibraryInstrument(id: "scandalli-armonium", name: "Scandalli Armonium", category: .acordeon),
        LibraryInstrument(id: "scandalli-bandoneon", name: "Scandalli Bandoneon", category: .acordeon),
        LibraryInstrument(id: "scandalli-basson", name: "Scandalli Basson", category: .acordeon),
        LibraryInstrument(id: "scandalli-clarinet", name: "Scandalli Clarinet", category: .acordeon),
        LibraryInstrument(id: "scandalli-flute", name: "Scandalli Flute", category: .acordeon),
        LibraryInstrument(id: "scandalli-master", name: "Scandalli Master", category: .acordeon),
        LibraryInstrument(id: "scandalli-mussette", name: "Scandalli Mussette", category: .acordeon),
        LibraryInstrument(id: "scandalli-oboe", name: "Scandalli Oboe", category: .acordeon),
        LibraryInstrument(id: "scandalli-organ", name: "Scandalli Organ", category: .acordeon),
        LibraryInstrument(id: "scandalli-piccolo", name: "Scandalli Piccolo", category: .acordeon),
        LibraryInstrument(id: "scandalli-saxophone", name: "Scandalli Saxophone", category: .acordeon),
        LibraryInstrument(id: "scandalli-violin", name: "Scandalli Violin", category: .acordeon),
        LibraryInstrument(id: "artic-fall", name: "Artic Fall", category: .brass),
        LibraryInstrument(id: "brass-fr-2", name: "Brass FR 2", category: .brass),
        LibraryInstrument(id: "brass-fr-3", name: "Brass FR 3", category: .brass),
        LibraryInstrument(id: "epic-horns", name: "Epic Horns", category: .brass),
        LibraryInstrument(id: "fr-brass", name: "FR Brass", category: .brass),
        LibraryInstrument(id: "pop-brass", name: "Pop Brass", category: .brass),
        LibraryInstrument(id: "pop-doit", name: "Pop Doit", category: .brass),
        LibraryInstrument(id: "pop-fall", name: "Pop Fall", category: .brass),
        LibraryInstrument(id: "pop-shake", name: "Pop Shake", category: .brass),
        LibraryInstrument(id: "sax-alto", name: "Sax Alto", category: .brass),
        LibraryInstrument(id: "sax-soprano", name: "Sax Soprano", category: .brass),
        LibraryInstrument(id: "sax-tenor", name: "Sax Tenor", category: .brass),
        LibraryInstrument(id: "section-brass", name: "Section Brass", category: .brass),
        LibraryInstrument(id: "sp-horns", name: "SP Horns", category: .brass),
        LibraryInstrument(id: "sup-brass", name: "Sup Brass", category: .brass),
        LibraryInstrument(id: "bowed-glass", name: "Bowed Glass", category: .mallets),
        LibraryInstrument(id: "celeste-2", name: "Celeste 2", category: .mallets),
        LibraryInstrument(id: "celeste", name: "Celeste", category: .mallets),
        LibraryInstrument(id: "choir-ahh", name: "Choir Ahh", category: .mallets),
        LibraryInstrument(id: "choir-ohh", name: "Choir Ohh", category: .mallets),
        LibraryInstrument(id: "clarinet-1", name: "Clarinet 1", category: .mallets),
        LibraryInstrument(id: "clarinet-2", name: "Clarinet 2", category: .mallets),
        LibraryInstrument(id: "fantasia", name: "Fantasia", category: .mallets),
        LibraryInstrument(id: "fantasy", name: "Fantasy", category: .mallets),
        LibraryInstrument(id: "flute-oboe", name: "Flute Oboe", category: .mallets),
        LibraryInstrument(id: "flute", name: "Flute", category: .mallets),
        LibraryInstrument(id: "glass", name: "Glass", category: .mallets),
        LibraryInstrument(id: "heaven", name: "Heaven", category: .mallets),
        LibraryInstrument(id: "j-pop", name: "J-Pop", category: .mallets),
        LibraryInstrument(id: "kalimba", name: "Kalimba", category: .mallets),
        LibraryInstrument(id: "kristal", name: "Kristal", category: .mallets),
        LibraryInstrument(id: "latin-flute", name: "Latin Flute", category: .mallets),
        LibraryInstrument(id: "marimba", name: "Marimba", category: .mallets),
        LibraryInstrument(id: "marimbell", name: "Marimbell", category: .mallets),
        LibraryInstrument(id: "orch-hit-1", name: "Orch Hit 1", category: .mallets),
        LibraryInstrument(id: "sin-bell", name: "Sin Bell", category: .mallets),
        LibraryInstrument(id: "steel-drum", name: "Steel Drum", category: .mallets),
        LibraryInstrument(id: "vibes", name: "Vibes", category: .mallets),
        LibraryInstrument(id: "wood-bell", name: "Wood Bell", category: .mallets),
        LibraryInstrument(id: "woodwind", name: "WoodWind", category: .mallets),
        LibraryInstrument(id: "drum-kit-1", name: "Drum Kit 1", category: .drum),
        LibraryInstrument(id: "drum-kit-2", name: "Drum Kit 2", category: .drum),
        LibraryInstrument(id: "drum-kit-3", name: "Drum Kit 3", category: .drum)
    ]
    static func category(_ id: String?) -> InstrumentCategory? { catalog.first { $0.id == id }?.category }
    static func controllers(_ category: InstrumentCategory?) -> InstrumentControllerParameters {
        InstrumentControllerParameters(modulation: category == .synthPad || category == .strings, pitchBend: category == .bass || category == .lead, monophonic: category == .lead)
    }
    static func parameters(_ id: String?) -> InstrumentParameters {
        var value = InstrumentParameters(drums: category(id) == .drum)
        value.controllers = controllers(category(id)); return value
    }
    static func displayName(_ id: String?) -> String { catalog.first { $0.id == id }?.name ?? "Instrument" }
    let directory: URL
    @Published private(set) var downloaded: Set<String> = []
    @Published private(set) var progress: [String:Double] = [:]
    @Published private(set) var sources: [String:URL] = [:]
    @Published var error = ""
    private var jobs: [String:Task<Void,Never>] = [:]
    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("JarasLive/Instruments",isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        refresh()
    }
    func file(_ id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("sf2") }
    func refresh() {
        downloaded = Set(Self.catalog.filter { FileManager.default.fileExists(atPath: file($0.id).path) }.map(\.id))
        sources = Dictionary(uniqueKeysWithValues: Self.catalog.map { ($0.id, $0.url) })
    }

    func download(_ id: String) {
        guard jobs[id] == nil, let url = sources[id], Self.catalog.contains(where: { $0.id == id }) else { return }
        progress[id] = 0; error = ""
        jobs[id] = Task {
            defer { jobs[id] = nil; progress[id] = nil }
            do {
                let observer = DownloadProgress { [weak self] value in Task { @MainActor in guard let self, self.jobs[id] != nil else { return }; self.progress[id] = value } }
                let (temporary,response) = try await URLSession.shared.download(for: URLRequest(url: url),delegate: observer)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw ProjectError.invalid("Download failed") }
                let handle = try FileHandle(forReadingFrom: temporary)
                let header = try handle.read(upToCount: 12); try handle.close()
                guard let header, header.count == 12, String(data: header.prefix(4),encoding: .ascii) == "RIFF", String(data: header.suffix(4),encoding: .ascii) == "sfbk" else { throw ProjectError.invalid("The downloaded file is not an SF2 sound bank.") }
                let destination = file(id)
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary,to: destination) }
                downloaded.insert(id)
            } catch { self.error = error.localizedDescription }
        }
    }
}
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    private var last = -1.0
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession,downloadTask: URLSessionDownloadTask,didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession,downloadTask: URLSessionDownloadTask,didWriteData bytesWritten: Int64,totalBytesWritten: Int64,totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten)/Double(totalBytesExpectedToWrite)
        if fraction-last >= 0.01 { last = fraction; progress(fraction) }
    }
}
struct InstrumentBrowser: View {
    @Binding var selected: String?
    @ObservedObject private var library = InstrumentLibrary.shared
    @State private var category: InstrumentCategory = .pianos
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 5)], spacing: 5) {
                    ForEach(InstrumentCategory.allCases) { entry in
                        Button { category = entry } label: {
                            Text(LocalizedStringKey(entry.rawValue)).font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .background(category == entry ? JarasTheme.green.opacity(0.25) : JarasTheme.display)
                                .clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    if !InstrumentLibrary.catalog.contains(where: { $0.category == category }) {
                        Text("No instruments available yet").font(.callout).foregroundStyle(JarasTheme.secondary).padding(24)
                    }
                    ForEach(InstrumentLibrary.catalog.filter { $0.category == category }) { instrument in
                        HStack(spacing: 12) {
                            Button { selected = instrument.id } label: {
                                HStack { Image(systemName: "pianokeys"); Text(instrument.name); Spacer() }.frame(maxWidth: .infinity).frame(height: 32).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!library.downloaded.contains(instrument.id))
                            if let progress = library.progress[instrument.id] {
                                ProgressView(value: progress).frame(width: 90).tint(JarasTheme.green)
                                Text("\(Int(progress*100))%").font(.caption.monospacedDigit()).frame(width: 32)
                            } else if library.downloaded.contains(instrument.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(JarasTheme.green)
                            } else {
                                Button("Download") { library.download(instrument.id) }.disabled(library.sources[instrument.id] == nil)
                            }
                        }.padding(.horizontal,12).padding(.vertical,3)
                            .background(selected == instrument.id ? JarasTheme.green.opacity(0.2) : JarasTheme.display)
                            .cornerRadius(5)
                    }
                }
            }
            if !library.error.isEmpty { Text(LocalizedStringKey(library.error)).font(.caption).foregroundStyle(.red) }
        }.onAppear { library.refresh(); if let instrument = InstrumentLibrary.catalog.first(where: { $0.id == selected }) { category = instrument.category } }
    }
}
