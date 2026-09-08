const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
const resetSource = source.slice(
  source.indexOf('async function resetHookMarkerResolumeComposition('),
  source.indexOf('function hookMarkerResolumeDeckDefinition('));

async function run(initialCount, { staleInitialCount = 0 } = {}) {
  const decks = Array.from({ length: initialCount }, (_, index) => ({
    id: index + 1,
    original: true,
    name: { value: index === 1 ? 'empty 2' : 'empty' },
    selected: { value: index === 0 }
  }));
  let columns = Array.from({ length: 9 }, (_, index) => ({ id: index + 1 }));
  let activeId = decks[0].id;
  let idGeneration = 10;
  const calls = [];
  const snapshot = () => ({
    decks,
    columns,
    layers: [{ clips: columns.map(() => ({
      audio: null, video: null, connected: { value: 'Empty' }
    })) }]
  });
  const context = vm.createContext({
    Set,
    String,
    Array,
    encodeURIComponent,
    waitForHookMarkerResolumeStable: async () => {
      if (!staleInitialCount || calls.some((call) =>
        call.endpoint === '/composition/decks/add')) return snapshot();
      return {
        decks: Array.from({ length: staleInitialCount }, (_, index) => ({
          id: 5000 + index,
          name: { value: `Deck antigo ${index + 1}` },
          selected: { value: index === 0 }
        })),
        columns: [{ id: 5000 }],
        layers: [{ clips: [{
          audio: { volume: 1 }, video: null,
          connected: { value: 'Disconnected' }
        }] }]
      };
    },
    addHookMarkerResolumeDeck: async () => {
      calls.push({ endpoint: '/composition/decks/add', method: 'POST' });
      idGeneration += 1;
      decks.forEach((deck, index) => { deck.id = idGeneration * 100 + index; });
      decks.push({ id: idGeneration * 100 + decks.length,
        original: false, name: { value: 'empty' },
        selected: { value: false } });
      return snapshot();
    },
    selectHookMarkerResolumeDeck: async (_settings, id) => {
      activeId = id;
      decks.forEach((deck) => {
        deck.selected.value = String(deck.id) === String(id);
      });
      return snapshot();
    },
    mutateHookMarkerResolumeComposition: async (
      _settings, endpoint, options, predicate) => {
      calls.push({ endpoint, method: options.method });
      if (/^\/composition\/decks\/\d+$/.test(endpoint) &&
          options.method === 'PUT') {
        const index = Number(endpoint.split('/').at(-1)) - 1;
        decks[index].name.value = options.json.name.value;
      } else if (endpoint === '/composition/decks/1' &&
          options.method === 'DELETE') {
        assert.notEqual(decks[0].id, activeId,
          'nunca pode remover a primeira música');
        decks.splice(0, 1);
        idGeneration += 1;
        decks.forEach((deck, index) => {
          const wasActive = deck.id === activeId;
          deck.id = idGeneration * 100 + index;
          if (wasActive) activeId = deck.id;
        });
      } else if (endpoint.startsWith('/composition/columns/')) {
        columns = columns.slice(0, -1);
      } else {
        assert.fail(`operação inesperada: ${options.method} ${endpoint}`);
      }
      const state = snapshot();
      assert(predicate(state), `estado não confirmou ${endpoint}`);
      return state;
    }
  });
  vm.runInContext(resetSource, context);
  const result = await context.resetHookMarkerResolumeComposition(
    {}, 'Abertura');
  assert.equal(result.decks.length, 1);
  assert.equal(result.decks[0].original, false);
  assert.equal(result.decks[0].name.value, 'Abertura');
  assert.equal(result.columns.length, 1);
  assert.equal(calls.filter((call) =>
    call.endpoint === '/composition/decks/add').length, 1);
  assert.equal(calls.filter((call) =>
    call.method === 'DELETE' &&
    call.endpoint === '/composition/decks/1').length,
  initialCount);
}

(async () => {
  await run(1);
  await run(3);
  await run(4);
  await run(3, { staleInitialCount: 32 });
  console.log('RESOLUME_RESET_OK: ressincroniza no mesmo clique e remove somente os decks vazios da composição nova');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
