const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
const mutationSource = source.slice(
  source.indexOf('async function mutateHookMarkerResolumeComposition('),
  source.indexOf('async function selectHookMarkerResolumeDeck('));

function loadMutation(request, wait) {
  const context = vm.createContext({
    hookMarkerResolumeApiRequest: request,
    waitForHookMarkerResolumeComposition: wait,
    setTimeout: (callback) => callback()
  });
  vm.runInContext(mutationSource, context);
  return context.mutateHookMarkerResolumeComposition;
}

(async () => {
  {
    let requests = 0;
    let confirmations = 0;
    const mutate = loadMutation(async () => {
      requests += 1;
      if (requests === 1) {
        const error = new Error('Resolume respondeu 412: canceled');
        error.status = 412;
        throw error;
      }
      return null;
    }, async () => {
      confirmations += 1;
      if (confirmations === 1) throw new Error('ainda não mudou');
      return { decks: [{ id: 1 }] };
    });
    const result = await mutate({}, '/composition/decks/2',
      { method: 'DELETE' }, () => true, 'Não removeu.', 5000);
    assert.equal(requests, 2, 'deve repetir a ação cancelada quando o estado não mudou');
    assert.equal(result.decks.length, 1);
  }

  {
    let requests = 0;
    const mutate = loadMutation(async () => {
      requests += 1;
      const error = new Error('Resolume respondeu 412: canceled');
      error.status = 412;
      throw error;
    }, async () => ({ decks: [{ id: 1 }] }));
    await mutate({}, '/composition/decks/2', { method: 'DELETE' },
      () => true, 'Não removeu.', 5000);
    assert.equal(requests, 1,
      'não deve repetir quando o estado confirma a primeira ação');
  }

  {
    let confirmations = 0;
    const mutate = loadMutation(async () => {
      const error = new Error('Resolume respondeu 400');
      error.status = 400;
      throw error;
    }, async () => { confirmations += 1; });
    await assert.rejects(
      mutate({}, '/composition/decks/2', { method: 'DELETE' },
        () => true, 'Não removeu.', 5000),
      /Resolume respondeu 400/);
    assert.equal(confirmations, 0, 'erro definitivo não deve ser repetido');
  }

  console.log('RESOLUME_MUTATION_RETRY_OK: 412 conferido e repetido sem duplicação');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
