const fs = require('fs');
const path = require('path');
const { containsCreateProjectTrackName, isCreateProjectSourceLabel, isCreateProjectTrackLabel } = require('./create-project');

const key = (value) => value.normalize('NFC').toLowerCase();
const inside = (parent, child) => {
  const relative = path.relative(parent, child);
  return relative === '' || (relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
};

function splitRemovalTexts(value) {
  return [...new Set(String(value || '').split(',').map((text) => text.trim()).filter(Boolean))];
}

function foldRemovalValue(value) {
  let text = '';
  const map = [];
  let offset = 0;
  for (const character of String(value || '')) {
    const start = offset;
    offset += character.length;
    const folded = character.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
    if (!folded) {
      if (map.length) map[map.length - 1].end = offset;
      continue;
    }
    for (const foldedCharacter of folded) {
      const separator = /[\s._\-–—]/u.test(foldedCharacter);
      if (separator && text.endsWith(' ')) {
        map[map.length - 1].end = offset;
        continue;
      }
      text += separator ? ' ' : foldedCharacter;
      map.push({ start, end: offset });
    }
  }
  return { text, map };
}

function removalName(name, text, directory) {
  // Literal text, without sensitivity to case, accents or common separators.
  // File extensions stay intact.
  const extension = directory ? '' : path.extname(name);
  const stem = extension ? name.slice(0, -extension.length) : name;
  const texts = Array.isArray(text) ? text : splitRemovalTexts(text);
  const foldedStem = foldRemovalValue(stem);
  const foldedTexts = [...new Set(texts.map((item) => foldRemovalValue(item).text.trim()).filter(Boolean))]
    .sort((a, b) => b.length - a.length);
  if (!foldedTexts.length) return null;

  // Uma única leitura do nome original, priorizando os termos mais longos.
  // Assim, remover um termo não cria por acidente uma nova correspondência.
  const ranges = [];
  for (let index = 0; index < foldedStem.text.length;) {
    const match = foldedTexts.find((item) => foldedStem.text.startsWith(item, index));
    if (!match) {
      index += 1;
      continue;
    }
    const first = foldedStem.map[index];
    const last = foldedStem.map[index + match.length - 1];
    if (first && last) ranges.push({ start: first.start, end: last.end });
    index += match.length;
  }
  if (!ranges.length) return null;

  let cursor = 0;
  let nextStem = '';
  for (const range of ranges) {
    nextStem += stem.slice(cursor, range.start);
    cursor = range.end;
  }
  nextStem = `${nextStem}${stem.slice(cursor)}`
    .replace(/^[\s._\-–—]+|[\s._\-–—]+$/gu, '')
    .replace(/\s{2,}/g, ' ')
    .trim();
  const nextName = nextStem + extension;
  if (!nextStem || nextStem === '.' || nextStem === '..' ||
      /[<>:"/\\|?*\u0000-\u001f]/.test(nextName) || /[. ]$/.test(nextName) ||
      /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(nextName)) {
    return { invalid: true, name: nextName };
  }
  return nextName === name ? null : { name: nextName };
}

async function auditRemoval(payload = {}) {
  const text = typeof payload.removeText === 'string' ? payload.removeText : '';
  const texts = splitRemovalTexts(text);
  if (!texts.length) throw new Error('Digite a palavra ou frase que deseja remover.');
  if (!payload.removeFolders && !payload.removeFiles) {
    throw new Error('Marque remover do nome da pasta, do arquivo, ou ambos.');
  }
  const selected = [...new Set((payload.folderPaths || []).map((item) => path.resolve(item)))];
  if (!selected.length) throw new Error('Escolha uma ou mais pastas primeiro.');
  const originals = [];
  for (const selectedPath of selected) {
    const stat = await fs.promises.lstat(selectedPath);
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      throw new Error(`Selecione uma pasta real, não um atalho: ${selectedPath}`);
    }
    const real = await fs.promises.realpath(selectedPath);
    if (real === path.parse(real).root) {
      throw new Error('Escolha pastas específicas, não a raiz do disco.');
    }
    if (!originals.includes(real)) originals.push(real);
  }
  // Selecting a folder and one of its children must not process either twice.
  const roots = originals.filter((candidate) =>
    !originals.some((parent) => parent !== candidate && inside(parent, candidate)));
  const operations = [];
  const skipped = [];
  const planned = new Set();
  const siblings = new Map();
  let totalScanned = 0;

  async function inspect(sourcePath, rootFolderPath) {
    let stat;
    try {
      stat = await fs.promises.lstat(sourcePath);
    } catch (error) {
      skipped.push({ sourcePath, reason: 'unreadable', message: error.message });
      return;
    }
    // Never follow symlinks/junctions into another folder tree.
    if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) return;
    const directory = stat.isDirectory();
    totalScanned += 1;
    if (directory) {
      let entries;
      try {
        entries = await fs.promises.readdir(sourcePath);
      } catch (error) {
        skipped.push({ sourcePath, reason: 'unreadable', message: error.message });
        return;
      }
      // Children before parents: parent renames cannot break pending paths.
      entries.sort();
      for (const entry of entries) await inspect(path.join(sourcePath, entry), rootFolderPath);
    }
    if (directory ? !payload.removeFolders : !payload.removeFiles) return;
    const fromName = path.basename(sourcePath);
    const candidate = removalName(fromName, texts, directory);
    if (!candidate) return; // No match: leave untouched, not a warning/error.
    if (candidate.invalid) {
      skipped.push({ sourcePath, reason: 'invalid_name' });
      return;
    }
    const parent = path.dirname(sourcePath);
    const targetPath = path.join(parent, candidate.name);
    if (!siblings.has(parent)) siblings.set(parent, await fs.promises.readdir(parent));
    // Conservative on case-insensitive Windows/macOS volumes, including two
    // source names that would collapse to the same destination in this batch.
    if (siblings.get(parent).some((entry) => key(entry) === key(candidate.name)) ||
        planned.has(key(targetPath))) {
      skipped.push({ sourcePath, targetPath, reason: 'target_exists' });
      return;
    }
    planned.add(key(targetPath));
    operations.push({ sourcePath, targetPath, rootFolderPath, fromName,
      toName: candidate.name, directory,
      relativeFolder: path.relative(path.dirname(rootFolderPath), parent) || '.',
      identity: { dev: stat.dev, ino: stat.ino, birthtimeMs: stat.birthtimeMs } });
  }
  for (const root of roots) await inspect(root, root);
  return { ok: true, mode: 'remove', folderPaths: originals,
    totalFolders: roots.length, totalScanned, totalOperations: operations.length,
    totalSkipped: skipped.length, operations, skipped };
}

async function executeRemoval(plan, onProgress = () => {}) {
  let renamedFiles = 0;
  let renamedFolders = 0;
  const errors = [];
  const folderPaths = [...plan.folderPaths];
  const total = plan.operations.length;
  const progress = (phase, current) => onProgress({ phase, current, total,
    percent: total ? Math.round(current / total * 100) : 100,
    renamed: renamedFiles + renamedFolders, renamedFiles, renamedFolders, failed: errors.length });
  progress('start', 0);
  for (const [index, operation] of plan.operations.entries()) {
    try {
      // The preview is immutable. Changed/deleted/replaced sources require a
      // fresh audit, and links introduced after the audit are never followed.
      let ancestor = path.dirname(operation.sourcePath);
      while (true) {
        const stat = await fs.promises.lstat(ancestor);
        if (stat.isSymbolicLink()) throw new Error('O caminho mudou desde a auditoria. Gere outra prévia.');
        if (ancestor === path.parse(ancestor).root) break;
        ancestor = path.dirname(ancestor);
      }
      const stat = await fs.promises.lstat(operation.sourcePath);
      if (stat.isSymbolicLink() || stat.isDirectory() !== operation.directory ||
          stat.dev !== operation.identity.dev || stat.ino !== operation.identity.ino ||
          stat.birthtimeMs !== operation.identity.birthtimeMs) {
        throw new Error('O item mudou desde a auditoria. Gere outra prévia.');
      }
      const entries = await fs.promises.readdir(path.dirname(operation.targetPath));
      if (entries.some((entry) => key(entry) === key(operation.toName))) {
        throw new Error('Já existe um item com o nome de destino. Nada foi sobrescrito.');
      }
      await fs.promises.rename(operation.sourcePath, operation.targetPath);
      if (operation.directory) {
        renamedFolders += 1;
        for (let i = 0; i < folderPaths.length; i += 1) {
          if (inside(operation.sourcePath, folderPaths[i])) {
            folderPaths[i] = path.join(operation.targetPath, path.relative(operation.sourcePath, folderPaths[i]));
          }
        }
      } else renamedFiles += 1;
    } catch (error) {
      errors.push({ fromName: operation.fromName, toName: operation.toName,
        message: error.message });
    }
    // Avoid saturating Electron IPC for very large folder trees.
    if (index % 20 === 0 || index === total - 1) progress('running', index + 1);
  }
  progress('done', total);
  return { ok: errors.length === 0, mode: 'remove', renamedFiles, renamedFolders,
    renamed: renamedFiles + renamedFolders, failed: errors.length, folderPaths,
    totalScanned: plan.totalScanned, totalOperations: total,
    totalSkipped: plan.totalSkipped, errors: errors.slice(0, 20) };
}

function suggestRepeatedNames(names, { limit = 5 } = {}) {
  const counts = new Map();
  const sourceLabels = new Map();
  const trackLabels = new Map();
  const cached = (cache, detector, value) => {
    if (!cache.has(value)) cache.set(value, detector(value));
    return cache.get(value);
  };
  for (const name of names) {
    const tokens = [...name.matchAll(/[^\s_\-()[\]{}.,]+/gu)];
    const supplierTokens = new Set();
    const trackTokens = new Set();
    const windows = [];
    for (let start = 0; start < tokens.length; start += 1) {
      for (let size = 1; size <= 6 && start + size <= tokens.length; size += 1) {
        const last = tokens[start + size - 1];
        const text = name.slice(tokens[start].index, last.index + last[0].length);
        windows.push({ start, size, text });
        if (cached(sourceLabels, isCreateProjectSourceLabel, text)) {
          for (let i = start; i < start + size; i += 1) supplierTokens.add(i);
        }
      }
    }
    for (const { start, size, text } of windows) {
      if (Array.from({ length: size }, (_, i) => start + i).some((i) => supplierTokens.has(i))) continue;
      if (cached(trackLabels, isCreateProjectTrackLabel, text)) {
        for (let i = start; i < start + size; i += 1) trackTokens.add(i);
      }
    }
    const perItem = new Set();
    for (const { start, size, text } of windows) {
      if (Array.from({ length: size }, (_, i) => start + i).some((i) => trackTokens.has(i))) continue;
      if (text.length < 2 || text.length > 120 || !/\p{L}/u.test(text)) continue;
      perItem.add(text);
    }
    for (const text of perItem) counts.set(text, (counts.get(text) || 0) + 1);
  }
  const candidates = [...counts]
    .filter(([text, count]) => count > 1 && !containsCreateProjectTrackName(text))
    .map(([text, count]) => [text, count, cached(sourceLabels, isCreateProjectSourceLabel, text)])
    // Prefer the complete provider tag over generic pieces such as "VS".
    // Never use the song-name cleanup here: it would erase the very brands
    // the user is trying to remove from their folders and files.
    .sort((a, b) => Number(b[2]) - Number(a[2]) || b[1] - a[1] ||
      b[0].length - a[0].length || a[0].localeCompare(b[0]));
  const suggestions = [];
  for (const [text, count] of candidates) {
    // Prefer the complete repeated phrase over five variations of its words.
    if (suggestions.some((item) => item.text.includes(text) || text.includes(item.text))) continue;
    suggestions.push({ text, count });
    if (suggestions.length >= limit) break;
  }
  return suggestions;
}

async function auditSuggestions(folderPaths = []) {
  const roots = [];
  for (const folder of folderPaths) {
    const resolved = path.resolve(folder);
    const stat = await fs.promises.lstat(resolved);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('Escolha pastas reais, não atalhos.');
    const real = await fs.promises.realpath(resolved);
    if (real === path.parse(real).root) throw new Error('Escolha pastas específicas, não a raiz do disco.');
    if (!roots.includes(real)) roots.push(real);
  }
  const names = [];
  let unreadable = 0;
  async function visit(sourcePath) {
    try {
      const stat = await fs.promises.lstat(sourcePath);
      if (stat.isSymbolicLink() || (!stat.isFile() && !stat.isDirectory())) return;
      const name = path.basename(sourcePath);
      names.push(stat.isDirectory() ? name : path.parse(name).name);
      if (stat.isDirectory()) {
        for (const entry of await fs.promises.readdir(sourcePath)) await visit(path.join(sourcePath, entry));
      }
    } catch (_) { unreadable += 1; }
  }
  for (const root of roots.filter((candidate) => !roots.some((parent) => parent !== candidate && inside(parent, candidate)))) {
    await visit(root);
  }
  // The UI shows five at a time and keeps the remaining candidates locally,
  // so choosing a tag can reveal the next one without scanning the disk again.
  return { suggestions: suggestRepeatedNames(names, { limit: Infinity }), totalScanned: names.length, unreadable };
}

module.exports = { auditRemoval, executeRemoval, removalName, auditSuggestions, suggestRepeatedNames, splitRemovalTexts };
