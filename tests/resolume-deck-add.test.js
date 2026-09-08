const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
const signatureSource = source.slice(
  source.indexOf('function hookMarkerResolumeCompositionSignature('),
  source.indexOf('async function waitForHookMarkerResolumeStable('));
const helperSource = source.slice(
  source.indexOf('async function addHookMarkerResolumeDeck('),
  source.indexOf('async function selectHookMarkerResolumeDeck('));

function initialComposition() {
  return {
    decks: [1, 2, 3].map((id) => ({
      id, name: { value: 'empty' }, selected: { value: id === 1 }
    })),
    columns: [{ id: 1 }],
    layers: []
  };
}

async function run({ staleList, timeout }) {
  const initial = initialComposition();
  const createdDeck = {
    id: 900, name: { value: 'empty' }, selected: { value: false }
  };
  let postCount = 0;
  const context = vm.createContext({
    Date,
    setTimeout: (callback) => callback(),
    hookMarkerResolumeApiRequest: async (_settings, endpoint) => {
      if (endpoint === '/composition/decks/add') {
        postCount += 1;
        if (timeout) {
          const error = new Error('tempo esgotado');
          error.code = 'RESOLUME_REQUEST_TIMEOUT';
          throw error;
        }
        return null;
      }
      if (endpoint.startsWith('/composition?')) {
        return staleList ? initial : {
          ...initial, decks: [...initial.decks, createdDeck]
        };
      }
      if (endpoint.startsWith('/composition/decks/4?')) {
        if (postCount > 0) return createdDeck;
        const error = new Error('deck não existe');
        error.status = 404;
        throw error;
      }
      throw new Error(`endpoint inesperado: ${endpoint}`);
    }
  });
  vm.runInContext(`${signatureSource}\n${helperSource}`, context);
  const result = await context.addHookMarkerResolumeDeck(
    {}, initial, 'Não confirmou.');
  assert.equal(postCount, 1);
  assert.equal(result.decks.length, 4);
  assert.equal(result.decks[3].id, 900);
}

async function runAfterCompositionSwitch() {
  const staleComposition = {
    decks: Array.from({ length: 32 }, (_, index) => ({
      id: 1000 + index,
      name: { value: `Deck antigo ${index + 1}` },
      selected: { value: index === 0 }
    })),
    columns: [{ id: 1000 }],
    layers: []
  };
  const freshComposition = initialComposition();
  freshComposition.decks.forEach((deck) => {
    deck.selected.value = false;
  });
  const createdDeck = {
    id: 900, name: { value: 'empty' }, selected: { value: false }
  };
  const compositionAfterPost = {
    ...freshComposition,
    decks: [...freshComposition.decks, createdDeck]
  };
  let postCount = 0;
  let directDeckReadAfterPostCount = 0;
  let now = 0;
  const FakeDate = class extends Date {
    static now() {
      now += 1000;
      return now;
    }
  };
  const context = vm.createContext({
    Date: FakeDate,
    setTimeout: (callback) => callback(),
    hookMarkerResolumeApiRequest: async (_settings, endpoint) => {
      if (endpoint === '/composition/decks/add') {
        postCount += 1;
        return null;
      }
      if (endpoint.startsWith('/composition?')) {
        // Reproduz o Arena ao vivo: o GET usado antes do POST ainda pertencia
        // à composição antiga, mas o primeiro GET posterior já traz a nova
        // composição visível com o quarto deck recém-criado.
        return compositionAfterPost;
      }
      if (endpoint.startsWith('/composition/decks/')) {
        if (postCount > 0) directDeckReadAfterPostCount += 1;
        const error = new Error('deck não existe');
        error.status = 404;
        throw error;
      }
      throw new Error(`endpoint inesperado: ${endpoint}`);
    }
  });
  vm.runInContext(`${signatureSource}\n${helperSource}`, context);
  const result = await context.addHookMarkerResolumeDeck(
    {}, staleComposition, 'Não confirmou.',
    { acceptRefreshedComposition: true });
  assert.equal(postCount, 1,
    'a ressincronização nunca pode repetir o POST e criar outro deck');
  assert.equal(result.decks.length, 4,
    'deve aceitar a nova geração mesmo que 4 seja menor que 32 + 1');
  assert.equal(result.decks[3].id, 900);
  assert.equal(directDeckReadAfterPostCount, 0,
    'não deve procurar o impossível deck 33 depois que a geração mudou');
}

async function runWithOldSnapshotAfterPost() {
  const currentComposition = initialComposition();
  const staleComposition = {
    decks: Array.from({ length: 32 }, (_, index) => ({
      id: 1000 + index,
      name: { value: `Deck antigo ${index + 1}` },
      selected: { value: index === 0 }
    })),
    columns: [{ id: 1000 }],
    layers: []
  };
  const createdDeck = {
    id: 900, name: { value: 'empty' }, selected: { value: false }
  };
  const freshComposition = {
    ...currentComposition,
    decks: [...currentComposition.decks, createdDeck]
  };
  let compositionReads = 0;
  let postCount = 0;
  const context = vm.createContext({
    Date,
    setTimeout: (callback) => callback(),
    hookMarkerResolumeApiRequest: async (_settings, endpoint) => {
      if (endpoint === '/composition/decks/add') {
        postCount += 1;
        return null;
      }
      if (endpoint.startsWith('/composition?')) {
        compositionReads += 1;
        return compositionReads === 1 ? staleComposition : freshComposition;
      }
      if (endpoint.startsWith('/composition/decks/4?')) {
        if (postCount > 0) return createdDeck;
        const error = new Error('deck não existe');
        error.status = 404;
        throw error;
      }
      throw new Error(`endpoint inesperado: ${endpoint}`);
    }
  });
  vm.runInContext(`${signatureSource}\n${helperSource}`, context);
  const result = await context.addHookMarkerResolumeDeck(
    {}, currentComposition, 'Não confirmou.');
  assert.equal(postCount, 1);
  assert.equal(result.decks.length, 4,
    'um snapshot antigo maior não pode confirmar a inclusão atual');
  assert.deepEqual(Array.from(result.decks, (deck) => deck.id),
    [1, 2, 3, 900],
    'o fallback direto não pode misturar decks da composição antiga');
}

async function runWithSameCountOldSnapshotAfterPost() {
  const currentComposition = initialComposition();
  const staleComposition = {
    decks: Array.from({ length: 4 }, (_, index) => ({
      id: 1000 + index,
      name: { value: `Deck antigo ${index + 1}` },
      selected: { value: index === 0 }
    })),
    columns: [{ id: 1000 }],
    layers: []
  };
  const createdDeck = {
    id: 900, name: { value: 'empty' }, selected: { value: false }
  };
  const freshComposition = {
    ...currentComposition,
    decks: [...currentComposition.decks, createdDeck]
  };
  let compositionReads = 0;
  let postCount = 0;
  const context = vm.createContext({
    Date,
    setTimeout: (callback) => callback(),
    hookMarkerResolumeApiRequest: async (_settings, endpoint) => {
      if (endpoint === '/composition/decks/add') {
        postCount += 1;
        return null;
      }
      if (endpoint.startsWith('/composition?')) {
        compositionReads += 1;
        return compositionReads === 1 ? staleComposition : freshComposition;
      }
      if (endpoint.startsWith('/composition/decks/4?')) {
        const error = new Error('leitura direta ainda atrasada');
        error.status = 404;
        throw error;
      }
      throw new Error(`endpoint inesperado: ${endpoint}`);
    }
  });
  vm.runInContext(`${signatureSource}\n${helperSource}`, context);
  const result = await context.addHookMarkerResolumeDeck(
    {}, currentComposition, 'Não confirmou.');
  assert.equal(postCount, 1);
  assert.equal(compositionReads, 2,
    'a mesma contagem com prefixo antigo não pode encerrar a confirmação');
  assert.deepEqual(Array.from(result.decks, (deck) => deck.id),
    [1, 2, 3, 900]);
}

async function runWithPreviouslyCreatedTargetDeck() {
  const currentComposition = initialComposition();
  const existingDeck = {
    id: 900, name: { value: 'empty' }, selected: { value: false }
  };
  const actualComposition = {
    ...currentComposition,
    decks: [...currentComposition.decks, existingDeck]
  };
  let postCount = 0;
  const context = vm.createContext({
    Date,
    setTimeout: (callback) => callback(),
    hookMarkerResolumeApiRequest: async (_settings, endpoint) => {
      if (endpoint.startsWith('/composition/decks/4?')) return existingDeck;
      if (endpoint === '/composition/decks/add') {
        postCount += 1;
        actualComposition.decks.push({
          id: 901, name: { value: 'empty' }, selected: { value: false }
        });
        return null;
      }
      if (endpoint.startsWith('/composition?')) return actualComposition;
      throw new Error(`endpoint inesperado: ${endpoint}`);
    }
  });
  vm.runInContext(`${signatureSource}\n${helperSource}`, context);
  const result = await context.addHookMarkerResolumeDeck(
    {}, currentComposition, 'Não confirmou.');
  assert.equal(postCount, 0,
    'um deck-alvo já criado por tentativa anterior não pode gerar outro POST');
  assert.deepEqual(Array.from(result.decks, (deck) => deck.id),
    [1, 2, 3, 900]);
}

(async () => {
  await run({ staleList: false, timeout: false });
  await run({ staleList: true, timeout: true });
  await runAfterCompositionSwitch();
  await runWithOldSnapshotAfterPost();
  await runWithSameCountOldSnapshotAfterPost();
  await runWithPreviouslyCreatedTargetDeck();
  console.log('RESOLUME_DECK_ADD_OK: continua após POST pendurado, lista atrasada e troca de composição');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
