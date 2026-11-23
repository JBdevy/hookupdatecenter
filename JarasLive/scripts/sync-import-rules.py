#!/usr/bin/env python3
"""Embed Hook Center's current pure classification and rename rules for JavaScriptCore."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
source = (root.parent / 'src/create-project.js').read_text()
rename = (root.parent / 'src/hook-rename-removal.js').read_text()
addition = (root.parent / 'src/add-project.js').read_text()
shim = r'''
const path = {
 basename(value, extension = '') { const name = String(value).split('/').pop(); return extension && name.endsWith(extension) ? name.slice(0, -extension.length) : name; },
 extname(value) { const name = this.basename(value); const dot = name.lastIndexOf('.'); return dot > 0 ? name.slice(dot) : ''; },
 resolve(value) { return value; }, join(...values) { return values.join('/'); }
};
const crypto = { randomInt(max) { return Math.floor(Math.random() * max); } };
'''
pure = source[source.index('const SUPPORTED_AUDIO_EXTENSIONS'):source.index('async function mapWithConcurrency')]
pure += rename[rename.index('function splitRemovalTexts'):rename.index('async function auditRemoval')]
pure += rename[rename.index('function suggestRepeatedNames'):rename.index('async function auditSuggestions')]
pure += source[source.index('function calculatePeakNormalizationGain'):source.index('function createGuid')]
pure = pure.replace('const CREATE_PROJECT_REGION_GAP_SECONDS = 60;', 'const CREATE_PROJECT_REGION_GAP_SECONDS = 30;').replace('Reserva o primeiro minuto do grid e mantém um minuto inteiro entre o fim', 'Reserva trinta segundos do grid e mantém trinta segundos entre o fim')
pure = pure.replace('async function auditCreateProjectFolders', 'function auditCreateProjectFolders').replace('await mapWithConcurrency(discovered.audioFiles, 4, async (filePath) => {', 'discovered.audioFiles.map((filePath) => {').replace('await ', '')
pure += addition[addition.index('function canonicalExistingTrackKey'):addition.index('function parseTopLevelTrackRanges')]
# Canonical taxonomy labels can differ from their alias regex (e.g. Clarim, XP).
# Keep these labels and folder names out of cleanup candidates too.
pure = pure.replace('if (!normalized || isCreateProjectSourceLabel(normalized)) return false;', 'if (!normalized || isCreateProjectSourceLabel(normalized)) return false;\n  if (CREATE_PROJECT_TRACK_RULES.some(rule => normalizeWords(rule.name) === normalized) || CREATE_PROJECT_TRACK_GROUPS.some(group => normalizeWords(group.name) === normalized)) return true;')
# Keep guitar wah distinct from the generic guitar label in CatLive.
pure = pure.replace(r"  if (has(/\b(drive|dist|distorcao|distortion)\b/)) variants.push('Drive');", r"  if (has(/\b(drive|dist|distorcao|distortion)\b/)) variants.push('Drive');" + '\n' + r"  if (rule.name === 'Guitarra' && has(/\bwah(?: wah)?\b/)) variants.push('Wah');")
# CatLive Add Project can resolve real destination names before taxonomy.
# Keep Hook Center's standalone project creation unchanged.
pure = pure.replace('peakResolver, onProgress } = {})', 'peakResolver, onProgress, classifyTrack = classifyCreateProjectTrack, resolveTrackKey = key => key } = {})')
pure = pure.replace('classifyCreateProjectTrack(filePath, discovered.inferredSongName.name)', 'classifyTrack(filePath, discovered.inferredSongName.name)')
pure = pure.replace('recognized: classification.recognized,', 'recognized: classification.recognized,\n          matchedExistingName: classification.matchedExistingName === true,')
pure = pure.replace('const usedKeys = new Set();\n    for (const file of song.files)', 'const usedKeys = new Set();\n    for (const file of [...song.files].sort((a, b) => Number(b.matchedExistingName) - Number(a.matchedExistingName)))')
pure = pure.replace('index += 1;\n      } while (reservedKeys.has(duplicateKey)', 'index += 1;\n        duplicateKey = resolveTrackKey(duplicateKey);\n      } while (reservedKeys.has(duplicateKey)')
wrapper = r'''
// Use the exact artwork IDs bundled by CatLive on every platform. The track
// taxonomy has already removed song names and resolved numbered variants.
const catLiveStemIcons = new Map(Object.entries({
 'Other/metronome': ['Click', 'Metronome'],
 'Other/dynamic-mic': ['Guia', 'Regência'],
 'Other/vocals': ['Vocal', 'Vox', 'Coro', 'Backing Vocal', 'Back Vocais'],
 'Keyboards/accordion': ['Sanfona', 'Sanfonas'],
 'Guitar/double-cut-electric': ['Guitarra', 'Guitarras'],
 'Guitar/classical-guitar': ['Violão Nylon'],
 'Guitar/steel-string-acoustic': ['Violão', 'Violões'],
 'Guitar/banjo': ['Banjo'],
 'Guitar/ukulele': ['Ukulele'],
 'Strings/mandolin': ['Bandolim'],
 'Bass/precision-bass': ['Baixo'],
 'Drums/acoustic-drum-kit': ['Bateria', 'Over', 'Percussivo'],
 'Drums/kick-drum': ['Bumbo'],
 'Drums/snare-drum': ['Caixa', 'Rimshot', 'Tarol'],
 'Drums/hi-hat': ['Hi-Hat'],
 'Drums/floor-tom': ['Surdo'],
 'Drums/rack-toms': ['Tom'],
 'Drums/ride-cymbal': ['Ride'],
 'Drums/crash-cymbal': ['Crash', 'Pratos', 'Reverse Cymbal'],
 'Percussion/congas': ['Conga'],
 'Percussion/bongos': ['Bongo'],
 'Percussion/tambourine': ['Pandeiro', 'Pandeirola', 'Meia Lua'],
 'Percussion/shaker': ['Shaker', 'Ganzá'],
 'Percussion/cowbell': ['Cowbell'],
 'Percussion/claves': ['Clave'],
 'Percussion/triangle': ['Triângulo'],
 'Percussion/cajon': ['Cajón'],
 'Percussion/djembe': ['Djembe'],
 'Percussion/maracas': ['Maracas'],
 'Percussion/guiro': ['Reco-Reco'],
 'Percussion/wood-block': ['Woodblock', 'Bloco'],
 'Percussion/chime-tree': ['Bar Chimes'],
 'Percussion/vibraphone': ['Vibrafone'],
 'Other/kalimba': ['Kalimba'],
 'Keyboards/grand-piano': ['Piano'],
 'Keyboards/upright-piano': ['Honky Tonk'],
 'Keyboards/electric-piano': ['Rhodes', 'Wurlitzer', 'Electric Piano', 'CP80', 'Clavi'],
 'Keyboards/tonewheel-organ': ['Hammond', 'Órgão'],
 'Keyboards/synth-workstation': ['Teclado', 'Teclados', 'Triton', 'Trinity', 'Kronos', 'Nautilus', 'Krome', 'Kross', 'Fantom'],
 'Keyboards/digital-synth': ['DX', 'Vox Synth', 'Synth Brass', 'Synth Strings', 'M1', 'D-50', 'JD-800', 'JV-1080', 'XV-5080', 'XP', 'Opsix', 'Modwave', 'Wavestation', 'Wavestate'],
 'Keyboards/analog-synth': ['Synth', 'Saw', 'Square', 'Pulse', 'Pad', 'Lead', 'Pluck', 'Arp', 'Juno', 'Jupiter', 'MS-20', 'Polysix', 'Minilogue', 'SH-101', 'JX', 'System-8'],
 'Strings/string-ensemble': ['Cordas', 'Orquestra'],
 'Strings/violin': ['Violino'],
 'Strings/viola': ['Viola'],
 'Strings/cello': ['Cello'],
 'Strings/concert-harp': ['Harpa'],
 'Strings/sitar': ['Sitar'],
 'Strings/koto': ['Koto'],
 'Brass/trumpet': ['Metais', 'Trompete', 'Trompete Piccolo', 'Trompete Baixo', 'Clarim'],
 'Brass/trombone': ['Trombone', 'Trombone Alto', 'Trombone Tenor'],
 'Brass/bass-trombone': ['Trombone Baixo'],
 'Brass/cornet': ['Corneta'],
 'Brass/flugelhorn': ['Flugelhorn'],
 'Brass/tuba': ['Tuba'],
 'Brass/sousaphone': ['Sousafone'],
 'Brass/euphonium': ['Bombardino', 'Barítono de Metal'],
 'Brass/french-horn': ['Trompa', 'Trompa Alto', 'Mellophone'],
 'Wind/alto-saxophone': ['Sax', 'Sax Soprano', 'Sax Alto', 'Sax Tenor', 'Sax Barítono'],
 'Wind/flute': ['Flauta', 'Piccolo'],
 'Wind/clarinet': ['Clarinete'],
 'Wind/oboe': ['Oboé'],
 'Wind/bassoon': ['Fagote'],
 'Wind/harmonica': ['Harmônica'],
 'Sound Effects/impact': ['Hit']
}).flatMap(([icon, names]) => names.map(name => [name, 'png:' + icon])));

function catLiveStemIcon(trackName) {
 const name = String(trackName || '').trim().replace(/^#+\s*/, '');
 const base = getCreateProjectTrackBaseName(name);
 const canonical = base === 'Out' && !/^out(?:\s+\d+)?$/i.test(name)
   ? getCreateProjectTrackBaseName(classifyCreateProjectTrack(name + '.wav').name)
   : base;
 return catLiveStemIcons.get(name) || catLiveStemIcons.get(canonical) || 'png:Other/waveform';
}

function suggestImportRemovals(names, { limit = 12 } = {}) {
 const groups = new Set(CREATE_PROJECT_TRACK_GROUPS.map(group => normalizeTrackKey(group.name)));
 return suggestRepeatedNames(names, { limit: Math.max(64, limit) })
   .filter(item => !groups.has(normalizeTrackKey(item.text)))
   .slice(0, limit);
}
function existingImportClassifier(tracks) {
 const exact = new Map(), canonical = new Map();
 for (const track of tracks) {
   if (track.isFolder || !Number.isInteger(track.index)) continue;
   const name = normalizeTrackKey(track.name);
   if (name && !exact.has(name)) exact.set(name, track);
   const key = canonicalExistingTrackKey(track.name);
   if (key && !canonical.has(key)) canonical.set(key, track);
   if (key && !canonical.has('custom:' + key)) canonical.set('custom:' + key, track);
 }
 const resolveKey = key => canonical.has(key) ? 'existing:' + canonical.get(key).index : key;
 const classify = (filePath, folderName) => {
   const name = path.basename(filePath, path.extname(filePath));
   // Exact filename first, then the normal import cleanup (song/ordering prefix).
   const target = exact.get(normalizeTrackKey(name)) || exact.get(stripSongName(name, folderName));
   if (target) {
     const normalized = normalizeTrackKey(target.name);
     const internal = /^(click|regencia)( \d+)?$/.exec(normalized);
     const label = internal ? (internal[1] === 'click' ? 'Click' : 'Regência') + (internal[2] || '') : target.name;
     return { name: label, key: 'existing:' + target.index, recognized: true, matchedExistingName: true, sourceName: name };
   }
   const result = classifyCreateProjectTrack(filePath, folderName);
   const key = resolveKey(result.key);
   if (!result.recognized || key !== result.key) return { ...result, key };

   // Providers frequently append 1 to the first stem even when the
   // equivalent destination has no number. Prefer an explicit numbered
   // destination and keep 2 and later separate for simultaneous stems.
   const first = result.key.endsWith(' 1');
   if (first || !/ \d+$/.test(result.key)) {
     const alternate = first ? result.key.slice(0, -2) : result.key + ' 1';
     const target = canonical.get(alternate);
     if (target) {
       return { ...result, name: first ? result.name.slice(0, -2) : result.name, key: 'existing:' + target.index };
     }
   }
   return result;
 };
 return { classify, resolveKey };
}
function analyzeImport(folders, existingTracks = []) {
 const matching = existingImportClassifier(existingTracks);
 const entries = new Map(folders.map(folder => [folder.path, folder.files]));
 const durations = new Map(folders.flatMap(folder => folder.files.map(file => [folder.path + '/' + file.name, file.duration])));
 const peaks = new Map(folders.flatMap(folder => folder.files.map(file => [folder.path + '/' + file.name, file.peakDb])));
 globalThis.fs = { promises: { readdir(folder) { return entries.get(folder).map(file => ({ name: file.name, isFile() { return true; } })); } } };
 return auditCreateProjectFolders({ folderPaths: folders.map(folder => folder.path), durationResolver: file => durations.get(file), peakResolver: file => peaks.get(file), classifyTrack: matching.classify, resolveTrackKey: matching.resolveKey });
}
'''
(root / 'Application/Project/HookImportRules.swift').write_text('// Generated by scripts/sync-import-rules.py from Hook Center.\nimport Foundation\nenum HookImportRules {\nstatic let source = #"""\n' + shim + pure + wrapper + '\n"""#\n}\n')

(root / "Windows/Assets/HookImportRules.js").write_text(shim + pure + wrapper)
