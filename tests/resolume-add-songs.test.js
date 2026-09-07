const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
const songNames = ['abertura', '5 da manha', 'Nova música'];
const map = { cues: songNames.map((deckName, index) => ({
  deck: index + 1, column: 1, regionStart: true, deckName, sourceKey: `region:${index}`
})), assignments: { 'region:0': '0:0', 'region:1': '1:0', 'region:2': '2:0' } };

function scenario(title, names, minor = 22, savedMap = map) {
  const projectMap = structuredClone(savedMap);
  const persisted = {};
  let rppAssignments;
  const composition = {
    name: { value: title },
    decks: names.map((name, index) => ({
      id: index + 1, name: { value: name }, selected: { value: index === 0 }
    }))
  };
  const calls = [];
  const context = vm.createContext({
    requireHookMarkerProject: async () => ({ projectName: 'Projeto Desmonstração' }),
    saveHookMarkerSettings: x => x,
    resolveHookMarkerResolumeApiConnection: async settings => ({
      settings, product: { name: 'Arena', major: 7, minor }
    }),
    createHookMarkerResolumeMap: async () => {},
    buildPersistedHookMarkerResolumeMap: () => projectMap,
    hookMarkerResolumeProjectKey: () => 'project-id',
    store: { get: key => persisted[key], set: (key, value) => { persisted[key] = value; } },
    syncHookMarkerResolumeMapToExtension: async (project, settings, cueMap) => {
      rppAssignments = JSON.stringify(cueMap.assignments);
      return true;
    },
    waitForHookMarkerResolumeStable: async () => composition,
    mutateHookMarkerResolumeComposition: async (settings, endpoint, options, predicate) => {
      calls.push(endpoint);
      if (endpoint === '/composition/decks/add') {
        composition.decks.push({ id: 100 + composition.decks.length, name: { value: 'empty' } });
      } else if (endpoint === '/composition') {
        // O PUT da composição aplica arrays por posição, não pelo campo id.
        for (const [index, deck] of options.json.decks.entries()) {
          composition.decks[index].name = deck.name;
        }
      } else if (/^\/composition\/decks\/\d+$/.test(endpoint)) {
        composition.decks[Number(endpoint.split('/').at(-1)) - 1].name = options.json.name;
      } else {
        assert.fail(`Unexpected mutation: ${endpoint}`);
      }
      assert(predicate(composition));
      return composition;
    },
    configureHookMarkerResolumeDeck: async (settings, state, cueMap, id, number) => {
      calls.push(`configure:${number}`);
      return { composition: state, columnCount: 1 };
    },
    selectHookMarkerResolumeDeck: async () => composition,
    hookMarkerResolumeApiRequest: async (settings, endpoint) => { calls.push(endpoint); }
  });
  for (const [start, end] of [
    ['function parseHookMarkerResolumeAssignments(', 'function parseHookMarkerGrandMa2Assignments('],
    ['function hookMarkerResolumeDecksMatch(', 'async function getHookMarkerState('],
    ['function hookMarkerResolumeDeckDefinition(', 'async function configureHookMarkerResolumeDeck('],
    ['async function addHookMarkerResolumeSongs(', 'async function requireHookMarkerProject(']
  ]) {
    const from = source.indexOf(start);
    const to = source.indexOf(end, from);
    assert(from >= 0 && to > from);
    vm.runInContext(source.slice(from, to), context);
  }
  return { composition, calls, projectMap,
    readRpp: () => context.parseHookMarkerResolumeAssignments(rppAssignments),
    run: () => context.addHookMarkerResolumeSongs({}) };
}

(async () => {
  const batch = scenario('Outro nome', songNames.slice(0, 1));
  assert.equal((await batch.run()).addedMusicCount, 2);
  assert.deepEqual(batch.composition.decks.map(deck => deck.name.value), songNames);
  assert.deepEqual(batch.calls.filter(endpoint => /^\/composition\/decks\/\d+$/.test(endpoint)),
    ['/composition/decks/2', '/composition/decks/3']);
  for (const minor of [22, 27]) {
    for (const title of ['Projeto Desmonstracao', 'Meu show salvo com outro nome']) {
      const test = scenario(title, songNames.slice(0, 2), minor);
      const result = await test.run();
      assert.equal(result.addedMusicCount, 1);
      assert.deepEqual(test.composition.decks.map(deck => deck.name.value), songNames);
      assert.equal(test.composition.name.value, title);
      assert.deepEqual(test.calls, [
        '/composition/decks/add', '/composition/decks/3', 'configure:3', '/composition/save'
      ]);
    }
  }
  for (const names of [['Outro show'], ['5 da manha', 'abertura']]) {
    const test = scenario('Projeto Desmonstração', names);
    await assert.rejects(test.run(), /não correspondem ao mapa/);
    assert.equal(test.calls.length, 0, 'A composição incompatível deve permanecer intacta.');
  }
  const complete = scenario('Outro nome de arquivo', songNames);
  assert.equal((await complete.run()).addedMusicCount, 0);
  assert.equal(complete.calls.length, 0);
  assert.equal(complete.readRpp().__vshookDecks[0].sourceKey, 'region:0');

  // Simula outro computador: apenas os vínculos enviados ao RPP são usados.
  const renamedMap = structuredClone(map);
  renamedMap.assignments = complete.readRpp();
  renamedMap.cues[0].deckName = 'Abertura renomeada no REAPER';
  renamedMap.cues.push({ deck: 4, column: 1, regionStart: true,
    deckName: 'Música nova após renomear', sourceKey: 'region:99' });
  renamedMap.assignments['region:99'] = '3:0';
  const renamed = scenario('AVC sem acento', songNames, 27, renamedMap);
  assert.equal((await renamed.run()).addedMusicCount, 1);
  assert.equal(renamed.composition.decks[0].name.value, 'abertura');
  assert.equal(renamed.composition.decks[3].name.value, 'Música nova após renomear');
  assert.equal(renamed.readRpp().__vshookDecks[3].sourceKey, 'region:99');
  assert.deepEqual(renamed.calls, [
    '/composition/decks/add', '/composition/decks/4', 'configure:4', '/composition/save'
  ]);
  const replacedMap = structuredClone(renamedMap);
  replacedMap.cues[0].sourceKey = 'region:outra';
  const replaced = scenario('AVC sem acento', songNames, 22, replacedMap);
  await assert.rejects(replaced.run(), /não correspondem ao mapa/);
  assert.equal(replaced.calls.length, 0);
  const reordered = scenario('AVC sem acento', [songNames[1], songNames[0], songNames[2]], 22, renamedMap);
  await assert.rejects(reordered.run(), /não correspondem ao mapa/);
  assert.equal(reordered.calls.length, 0);
  // Nome vazio na coluna 2 não pode levar o nome do refrão (coluna 3) até ela.
  const columnsState = {
    decks: [{ id: 1, selected: { value: true } }],
    columns: [1, 2, 3].map(id => ({ id, name: { value: `Column ${id}` } }))
  };
  const columnCalls = [];
  const columnsContext = vm.createContext({
    selectHookMarkerResolumeDeck: async () => columnsState,
    mutateHookMarkerResolumeComposition: async (settings, endpoint, options, predicate) => {
      columnCalls.push(endpoint);
      assert.match(endpoint, /^\/composition\/columns\/\d+$/);
      const index = Number(endpoint.split('/').at(-1)) - 1;
      columnsState.columns[index].name = options.json.name;
      assert(predicate(columnsState));
      return columnsState;
    }
  });
  vm.runInContext(source.slice(source.indexOf('function hookMarkerResolumeDeckDefinition('),
    source.indexOf('async function waitForHookMarkerResolumeFile(')), columnsContext);
  await columnsContext.configureHookMarkerResolumeDeck({}, columnsState, { cues: [
    { deck: 1, column: 1, regionStart: true, deckName: 'Teste' },
    { deck: 1, column: 2, columnName: '' },
    { deck: 1, column: 3, columnName: 'Refrão' }
  ] }, 1, 1);
  assert.deepEqual(columnsState.columns.map(column => column.name.value),
    ['Início', 'Column 2', 'Refrão']);
  assert.deepEqual(columnCalls, ['/composition/columns/1', '/composition/columns/3']);
  console.log('RESOLUME_ADD_SONGS_OK: rename via persisted region ID, portable RPP, append only, mismatches rejected');
})().catch(error => { console.error(error); process.exitCode = 1; });
