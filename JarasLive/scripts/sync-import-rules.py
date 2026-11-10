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
# CatLive Add Project can resolve real destination names before taxonomy.
# Keep Hook Center's standalone project creation unchanged.
pure = pure.replace('peakResolver, onProgress } = {})', 'peakResolver, onProgress, classifyTrack = classifyCreateProjectTrack, resolveTrackKey = key => key } = {})')
pure = pure.replace('classifyCreateProjectTrack(filePath, discovered.inferredSongName.name)', 'classifyTrack(filePath, discovered.inferredSongName.name)')
pure = pure.replace('recognized: classification.recognized,', 'recognized: classification.recognized,\n          matchedExistingName: classification.matchedExistingName === true,')
pure = pure.replace('const usedKeys = new Set();\n    for (const file of song.files)', 'const usedKeys = new Set();\n    for (const file of [...song.files].sort((a, b) => Number(b.matchedExistingName) - Number(a.matchedExistingName)))')
pure = pure.replace('index += 1;\n      } while (reservedKeys.has(duplicateKey)', 'index += 1;\n        duplicateKey = resolveTrackKey(duplicateKey);\n      } while (reservedKeys.has(duplicateKey)')
wrapper = r'''
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
   return { ...result, key: resolveKey(result.key) };
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
