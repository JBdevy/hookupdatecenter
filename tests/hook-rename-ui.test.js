const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../src/index.html'), 'utf8');
const source = fs.readFileSync(path.join(__dirname, '../src/renderer.js'), 'utf8');
class Element {
  constructor(tag = 'input') {
    this.tag = tag;
    this.value = '';
    this.checked = false;
    this.disabled = false;
    this.textContent = '';
    this.style = { setProperty(name, value) { this[name] = value; } };
    this.clientWidth = 80;
    this.scrollWidth = 200;
    this.dataset = {};
    this.children = [];
    this.listeners = {};
    this.attributes = {};
    this.classes = new Set();
    this.classList = {
      add: (name) => this.classes.add(name), remove: (name) => this.classes.delete(name),
      toggle: (name, enabled) => enabled ? this.classes.add(name) : this.classes.delete(name)
    };
  }
  set innerHTML(value) { this.html = value; this.children = []; }
  get innerHTML() { return this.html || ''; }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener(name, callback) { this.listeners[name] = callback; }
  appendChild(child) { this.children.push(child); }
}
const elements = new Map();
for (const match of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"[^>]*>/g)) {
  elements.set('#' + match[2], new Element(match[1]));
}
const modes = ['add', 'remove'].map((mode) => {
  const element = new Element('button');
  element.dataset.hookRenameMode = mode;
  return element;
});
const messages = [];
const confirmations = [];
let previewCalls = 0;
let runCalls = 0;
let suggestionCalls = 0;
let confirmationAccepted = true;
const context = vm.createContext({
  console,
  requestAnimationFrame: (callback) => callback(),
  document: {
    querySelectorAll: (selector) => selector === '[data-hook-rename-mode]' ? modes :
      [...elements].filter(([id, element]) => id.startsWith('#hookRename') && ['input', 'button'].includes(element.tag)).map(([, value]) => value).concat(modes),
    createElement: (tag) => new Element(tag)
  },
  $: (id) => elements.get(id),
  showModal: (message) => messages.push(message),
  confirmModal: async (message) => { confirmations.push(message); return confirmationAccepted; },
  friendlyError: (error) => error.message,
  escapeHtml: (value) => String(value).replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
  window: { hookUpdateCenter: {
    selectManyHookRenameFolders: async () => ({ ok: true, multiple: true, folderPaths: ['C:/Test/One', 'C:/Test/Two'], folderNames: ['One', 'Two'] }),
    suggestHookRename: async () => { suggestionCalls += 1; return { suggestions:
      ['Hook Audio', 'Clube do VS', 'VS Professional', 'Mario Sena', 'abacate', 'Fornecedor Novo', 'Mais Um']
        .map((text) => ({ text, count: 3 })) }; },
    previewHookRename: async (payload) => { previewCalls += 1; return { mode: payload.mode, totalOperations: 0, totalScanned: 3, totalSkipped: 0, operations: [], auditToken: 'test-token' }; },
    runHookRename: async (payload) => {
      runCalls += 1;
      assert.equal(payload.auditToken, 'test-token');
      assert.equal(payload.removeText, 'Hook Audio, Clube do VS');
      return { renamedFiles: 0, renamedFolders: 0, folderPaths: payload.folderPaths };
    }
  } }
});
const begin = source.indexOf('function getHookRenameFolderPaths()');
const end = source.indexOf('function formatCreateProjectDuration(', begin);
assert(begin > 0 && end > begin);
vm.runInContext(`let hookRenameFolder = null; let hookRenameLastPreview = null;
  let hookRenameMode = 'add'; let hookRenameBusy = false; let hookRenameSuggestionsKey = '';
  let hookRenameSuggestionResizeObserver = null;
  let hookRenameSuggestionCandidates = []; let hookRenameSuggestionUnreadable = 0;
  ${source.slice(begin, end)}`, context);
const run = (code) => vm.runInContext(code, context);

(async () => {
  run('setupHookRename()');
  assert.equal(elements.get('#hookRenameRemovalFields').classes.has('hidden'), true);
  await modes[1].listeners.click();
  assert.equal(elements.get('#hookRenameAdditionFields').classes.has('hidden'), true);
  assert.equal(elements.get('#hookRenameRunButton').textContent, 'Renomear');
  await run('selectManyHookRenameFolders()');
  assert.equal(suggestionCalls, 1);
  assert.equal(previewCalls, 0); // Suggestions do not rename or require a search string.
  const suggestion = elements.get('#hookRenameSuggestions').children[0];
  assert.equal(suggestion.classes.has('is-overflowing'), true);
  assert.equal(suggestion.children[0].children[0].style['--rename-marquee-distance'], '-120px');
  suggestion.children[0].clientWidth = 250;
  context.testMarquee = [{ button: suggestion, viewport: suggestion.children[0], text: suggestion.children[0].children[0] }];
  run('animateHookRenameSuggestions(testMarquee)');
  assert.equal(suggestion.classes.has('is-overflowing'), false);
  suggestion.listeners.click();
  assert.equal(elements.get('#hookRenameRemoveTextInput').value, 'Hook Audio');
  const area = elements.get('#hookRenameSuggestions');
  assert.equal(area.children.length, 5);
  assert.equal(area.children[0].children[0].children[0].textContent, 'Clube do VS');
  assert.equal(area.children.at(-1).children[0].children[0].textContent, 'Fornecedor Novo');
  area.children[0].listeners.click();
  assert.equal(elements.get('#hookRenameRemoveTextInput').value, 'Hook Audio, Clube do VS');
  suggestion.listeners.click();
  assert.equal(elements.get('#hookRenameRemoveTextInput').value, 'Hook Audio, Clube do VS');
  assert.equal(area.children.length, 5);
  assert.equal(area.children.at(-1).children[0].children[0].textContent, 'Mais Um');
  assert.equal(suggestionCalls, 1); // No new disk audit on each selection.
  elements.get('#hookRenameRemoveFilesCheck').checked = true;
  elements.get('#hookRenameRemoveFilesCheck').listeners.change();
  assert.equal(elements.get('#hookRenameRunButton').disabled, false);
  await run('runHookRename()');
  assert.equal(runCalls, 1);
  assert.equal(previewCalls, 1);
  assert.equal(confirmations[0].okText, 'Renomear');
  assert.equal(messages.at(-1).message, '0 arquivos e 0 pastas alteradas.');
  assert.equal(run('hookRenameBusy'), false);
  // Cancellation does not mutate anything, including with an empty audit.
  confirmationAccepted = false;
  await run('runHookRename()');
  assert.equal(runCalls, 1);
  assert.equal(run('hookRenameBusy'), false);
  run('hookRenameBusy = true');
  await modes[0].listeners.click();
  assert.equal(run('hookRenameMode'), 'remove');
  run('hookRenameBusy = false');
  await modes[0].listeners.click();
  assert.equal(elements.get('#hookRenameRunButton').textContent, 'Renomear arquivos');
  assert.equal(elements.get('#hookRenameAdditionFields').classes.has('hidden'), false);
  console.log('HOOK_RENAME_UI_OK: modes, automatic suggestions, overflow marquee, fill input, confirmation, zero-result message, cancel, busy controls');
})().catch((error) => { console.error(error); process.exitCode = 1; });
