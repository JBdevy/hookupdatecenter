const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { auditRemoval, executeRemoval, removalName, auditSuggestions, suggestRepeatedNames, splitRemovalTexts } = require('../src/hook-rename-removal');
const { containsCreateProjectTrackName, isCreateProjectSourceLabel } = require('../src/create-project');

(async () => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'hook-rename-test-'));
  const file = async (relative, content = relative) => {
    const target = path.join(temporary, relative);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, content);
    return target;
  };
  try {
    assert.equal(removalName('song.wav', 'wav', false), null);
    assert.equal(removalName('song.wav', 'Song', false), null);
    assert.equal(removalName('TAG.wav', 'TAG', false).invalid, true);
    assert.equal(removalName('TAGcon.wav', 'TAG', false).invalid, true);
    assert.equal(removalName('Mix [Hook] [Hook].mp3', '[Hook]', false).name, 'Mix.mp3');
    assert.equal(removalName('Minha música.wav', 'música', false).name, 'Minha.wav');

    const root = path.join(temporary, 'TAG Album');
    await file('TAG Album/TAG Faixa/TAG Voz.wav', 'audio');
    await file('TAG Album/TAG Faixa/Sem marca.txt', 'text');
    await file('TAG Album/TAG Documento.pdf', 'pdf');
    const options = { folderPaths: [root, path.join(root, 'TAG Faixa'), root],
      removeText: 'TAG', removeFiles: true, removeFolders: true };
    const plan = await auditRemoval(options);
    assert.equal(plan.totalOperations, 4);
    assert.equal(plan.totalFolders, 1);
    assert.equal(plan.operations.at(-1).sourcePath, root);
    // Auditing is read-only, regardless of what will be renamed later.
    assert.equal(await fs.readFile(path.join(root, 'TAG Faixa/TAG Voz.wav'), 'utf8'), 'audio');
    const result = await executeRemoval(plan);
    assert.equal(result.failed, 0);
    assert.equal(result.renamedFiles, 2);
    assert.equal(result.renamedFolders, 2);
    assert.deepEqual(result.folderPaths, [path.join(temporary, 'Album'), path.join(temporary, 'Album/Faixa')]);
    assert.equal(await fs.readFile(path.join(temporary, 'Album/Faixa/Voz.wav'), 'utf8'), 'audio');
    assert.equal(await fs.readFile(path.join(temporary, 'Album/Faixa/Sem marca.txt'), 'utf8'), 'text');
    const empty = await executeRemoval(await auditRemoval({ ...options, folderPaths: result.folderPaths }));
    assert.equal(empty.renamedFiles, 0);
    assert.equal(empty.renamedFolders, 0);

    const collision = path.join(temporary, 'collision');
    await file('collision/TAGMusic.wav', 'keep-original');
    await file('collision/Music.wav', 'keep-destination');
    await file('collision/TAG.wav');
    await file('collision/aTAG.txt');
    await file('collision/TAGa.txt');
    const conflictPlan = await auditRemoval({ ...options, folderPaths: [collision] });
    assert.equal(conflictPlan.totalOperations, 1);
    assert.equal(conflictPlan.skipped.filter((item) => item.reason === 'target_exists').length, 2);
    assert.equal(conflictPlan.skipped.filter((item) => item.reason === 'invalid_name').length, 1);
    await executeRemoval(conflictPlan);
    assert.equal(await fs.readFile(path.join(collision, 'Music.wav'), 'utf8'), 'keep-destination');
    assert.equal(await fs.readFile(path.join(collision, 'TAGMusic.wav'), 'utf8'), 'keep-original');

    const late = path.join(temporary, 'late');
    await file('late/TAGSong.wav', 'source');
    const latePlan = await auditRemoval({ ...options, folderPaths: [late] });
    await file('late/Song.wav', 'created-after-preview');
    await file('late/TAGNew.wav', 'not-in-preview');
    const lateResult = await executeRemoval(latePlan);
    assert.equal(lateResult.failed, 1);
    assert.equal(lateResult.renamedFiles, 0);
    assert.equal(await fs.readFile(path.join(late, 'Song.wav'), 'utf8'), 'created-after-preview');
    assert.equal(await fs.readFile(path.join(late, 'TAGNew.wav'), 'utf8'), 'not-in-preview');

    const filesOnly = path.join(temporary, 'TAG filesOnly');
    await file('TAG filesOnly/TAG child/TAG Audio.aiff');
    const onlyFiles = await executeRemoval(await auditRemoval({ ...options,
      folderPaths: [filesOnly], removeFolders: false }));
    assert.equal(onlyFiles.renamedFolders, 0);
    assert.equal(onlyFiles.renamedFiles, 1);
    const onlyFolders = await executeRemoval(await auditRemoval({ ...options,
      folderPaths: [filesOnly], removeFiles: false }));
    assert.equal(onlyFolders.renamedFolders, 2);
    assert.equal(onlyFolders.renamedFiles, 0);

    const external = path.join(temporary, 'external');
    await file('external/TAG Outside.txt', 'outside');
    await fs.mkdir(path.join(temporary, 'links'));
    await fs.symlink(external, path.join(temporary, 'links/junction'), process.platform === 'win32' ? 'junction' : 'dir');
    const linkPlan = await auditRemoval({ ...options, folderPaths: [path.join(temporary, 'links')] });
    assert.equal(linkPlan.totalOperations, 0);
    assert.equal(await fs.readFile(path.join(external, 'TAG Outside.txt'), 'utf8'), 'outside');

    const suggestions = suggestRepeatedNames(['Hook Audio Voz', 'Hook Audio Bateria', 'Hook Audio Guitarra']);
    assert.equal(suggestions[0].text, 'Hook Audio');
    assert.equal(suggestions[0].count, 3);
    assert.equal(suggestions.length, 1);
    assert.deepEqual(suggestRepeatedNames(['TAG TAG TAG']), []);
    assert.equal(suggestRepeatedNames(['Aaa Bbb Ccc Ddd Eee Fff Ggg', 'Aaa', 'Bbb', 'Ccc', 'Ddd', 'Eee', 'Fff', 'Ggg']).length, 5);
    const suggestRoot = path.join(temporary, 'suggest');
    await file('suggest/Fornecedor Show/Fornecedor Voz.mp3');
    await file('suggest/Fornecedor Show/Fornecedor Bateria.wav');
    const audited = await auditSuggestions([suggestRoot, path.join(suggestRoot, 'Fornecedor Show')]);
    assert.deepEqual(audited.suggestions[0], { text: 'Fornecedor', count: 3 });
    assert.equal(audited.totalScanned, 4);
    for (const item of ['Click', 'GTR', 'Piano', 'Pno', 'Vocal', 'Vox', 'Electric Piano',
      'Hi-Hat', 'Backing Vocal', 'Violão']) {
      assert.equal(containsCreateProjectTrackName(item), true, item);
      assert.deepEqual(suggestRepeatedNames([item, item]), [], item);
    }
    for (const brand of ['Clube do VS', 'VS Professional', 'Loop Community',
      'Playback Professional', 'Worship Backing Tracks', 'Custom Backing Tracks']) {
      assert.equal(isCreateProjectSourceLabel(brand), true, brand);
      assert.equal(containsCreateProjectTrackName(brand), false, brand);
      assert.equal(suggestRepeatedNames([`${brand} - Click`, `${brand} - GTR`])[0].text, brand);
    }
    const providers = suggestRepeatedNames(['Clube do VS - Piano', 'Clube do VS - Piano',
      'VS Professional - Click', 'VS Professional - Click', 'Sem Fornecedor - GTR', 'Sem Fornecedor - GTR']);
    assert(providers.some((item) => item.text === 'Clube do VS'));
    assert(providers.some((item) => item.text === 'VS Professional'));
    assert(!providers.some((item) => /piano|click|gtr/i.test(item.text)));
    // Filtering affects suggestions only, not a deliberate manual removal.
    assert.equal(removalName('Piano Song.wav', 'Piano', false).name, 'Song.wav');
    assert.deepEqual(splitRemovalTexts('Clube do VS, VS Professional, , Mario Sena, Mario Sena'),
      ['Clube do VS', 'VS Professional', 'Mario Sena']);
    assert.equal(removalName('Clube do VS Song VS Professional Mario Sena.wav',
      'Clube do VS, VS Professional, Mario Sena', false).name, 'Song.wav');
    assert.equal(removalName('ABTAGCD.wav', 'TAG, ABCD', false).name, 'ABCD.wav');
    assert.equal(removalName('Clube do VS Song.wav', 'VS, Clube do VS', false).name, 'Song.wav');
    assert.equal(removalName('Piano.wav', ', ,', false), null);
    const multiRoot = path.join(temporary, 'multi');
    await file('multi/Clube do VS Song/VS Professional Mario Sena Voz.wav', 'multi-audio');
    await file('multi/Clube do VS Song/abacate Foto.png', 'multi-image');
    await file('multi/Clube do VS Song/Sem marca.txt', 'unchanged');
    const multiResult = await executeRemoval(await auditRemoval({
      folderPaths: [multiRoot], removeText: 'Clube do VS, VS Professional, Mario Sena, abacate',
      removeFiles: true, removeFolders: true
    }));
    assert.equal(multiResult.renamedFiles, 2);
    assert.equal(multiResult.renamedFolders, 1);
    assert.equal(multiResult.failed, 0);
    assert.equal(await fs.readFile(path.join(multiRoot, 'Song/Voz.wav'), 'utf8'), 'multi-audio');
    assert.equal(await fs.readFile(path.join(multiRoot, 'Song/Foto.png'), 'utf8'), 'multi-image');
    assert.equal(await fs.readFile(path.join(multiRoot, 'Song/Sem marca.txt'), 'utf8'), 'unchanged');
    await assert.rejects(auditRemoval({ ...options, removeText: '' }), /Digite/);
    await assert.rejects(auditRemoval({ ...options, removeFiles: false, removeFolders: false }), /Marque/);
    console.log('HOOK_RENAME_REMOVAL_OK: recursive, overlapping roots, conflicts, no match, options, extensions, symlinks, suggestions');
  } finally {
    // Only this freshly-created test directory, never selected user folders.
    if (path.dirname(temporary) !== path.resolve(os.tmpdir()) || !path.basename(temporary).startsWith('hook-rename-test-')) {
      throw new Error('Unexpected test cleanup path');
    }
    await fs.rm(temporary, { recursive: true, force: true });
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
