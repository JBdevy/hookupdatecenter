const assert = require('assert');
const {
  buildCreateProjectRpp,
  calculatePeakNormalizationGain,
  classifyCreateProjectTrack,
  createProjectTrackGroups,
  resolveCreateProjectTrackGroup
} = require('../src/create-project');
const {
  auditAddProjectRpp,
  buildAddProjectRpp,
  inspectRppProject
} = require('../src/add-project');

function makeTrack(name, fileCount = 1) {
  const classification = classifyCreateProjectTrack(`${name}.wav`);
  const group = resolveCreateProjectTrackGroup(classification.name);
  return {
    name: classification.name,
    key: classification.key,
    groupKey: group.key,
    groupName: group.name,
    fileCount,
    songCount: 1,
    songNames: ['Teste'],
    unknownFileCount: classification.recognized ? 0 : fileCount
  };
}

function makeFile(name, duration = 2, takeVolume = 1) {
  const classification = classifyCreateProjectTrack(`${name}.wav`);
  return {
    filePath: `C:\\origem\\${name}.wav`,
    projectFilePath: `Media\\${name}.wav`,
    fileName: `${name}.wav`,
    extension: '.wav',
    duration,
    trackName: classification.name,
    trackKey: classification.key,
    recognized: classification.recognized,
    takeVolume
  };
}

function makeAudit(songName, files) {
  const trackNames = [...new Set(files.map((file) => file.trackName))];
  const tracks = trackNames.map((name) => makeTrack(name, files.filter((file) => file.trackName === name).length));
  return {
    ok: true,
    validSongCount: 1,
    totalAudioFiles: files.length,
    totalIncludedFiles: files.length,
    totalDuration: Math.max(...files.map((file) => file.duration)),
    tracks,
    groups: createProjectTrackGroups(tracks),
    songs: [{
      name: songName,
      sourceFolderName: songName,
      nameWasAdjusted: false,
      start: 0,
      duration: Math.max(...files.map((file) => file.duration)),
      end: Math.max(...files.map((file) => file.duration)),
      files
    }],
    emptyFolders: [],
    skippedFiles: []
  };
}

function countTrackName(rpp, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return (rpp.match(new RegExp(`^    NAME "?${escaped}"?$`, 'gm')) || []).length;
}

function main() {
  const baseAudit = makeAudit('Música existente', [makeFile('Click', 2)]);
  const baseRpp = buildCreateProjectRpp(baseAudit, { platform: 'win32' });
  const incomingAudit = makeAudit('Música nova', [
    makeFile('Click', 3, calculatePeakNormalizationGain(-7)),
    makeFile('Guia Voz', 3),
    makeFile('Guitarra Drive L', 3)
  ]);

  const audit = auditAddProjectRpp(baseRpp, incomingAudit, { projectPath: 'C:\\Projetos\\Show.rpp' });
  assert.strictEqual(audit.appendStart, 62);
  assert.strictEqual(audit.songs[0].start, 62);
  assert.strictEqual(audit.songs[0].end, 65);
  assert.strictEqual(audit.reusedTrackCount, 1);
  assert.strictEqual(audit.newTrackCount, 2);
  assert.strictEqual(audit.tracks.find((track) => track.name === 'Click').action, 'reuse');
  assert.strictEqual(audit.tracks.find((track) => track.name === 'Guia').action, 'create');

  const updatedRpp = buildAddProjectRpp(baseRpp, audit);
  assert(updatedRpp.startsWith('<REAPER_PROJECT'));
  assert.strictEqual((updatedRpp.match(/\n    <ITEM/g) || []).length, 4);
  assert.strictEqual(countTrackName(updatedRpp, 'Interno'), 1);
  assert.strictEqual(countTrackName(updatedRpp, 'Click'), 1);
  assert.strictEqual(countTrackName(updatedRpp, 'Guia'), 1);
  assert.strictEqual(countTrackName(updatedRpp, 'Guitarras'), 1);
  assert.strictEqual(countTrackName(updatedRpp, 'Guitarra Drive L'), 1);
  assert(updatedRpp.includes('MARKER 2 62 "Música nova"'));
  assert(updatedRpp.includes('MARKER 2 65 "" 1'));
  assert(!/\n      GROUP \d+/.test(updatedRpp));
  assert(updatedRpp.includes('RECORD_PATH "Media" ""'));
  assert(updatedRpp.includes('VOLPAN 1 0 1.995262315 -1'));
  assert(!/^      VOLPAN (?!1 0 )/gm.test(updatedRpp));

  const emptyRpp = '<REAPER_PROJECT 0.1 "7.0/x64" 1700000000\n>\n';
  const emptyAudit = auditAddProjectRpp(emptyRpp, makeAudit('Primeira música', [makeFile('Click', 2)]));
  assert.strictEqual(emptyAudit.songs[0].start, 60);

  const model = inspectRppProject(updatedRpp);
  const internalFolder = model.groupFolders.get('interno');
  const internalChildren = internalFolder.directChildren.map((index) => model.tracks[index].name);
  assert.deepStrictEqual(internalChildren, ['Click', 'Guia']);
  const guitarsFolder = model.groupFolders.get('guitarras');
  assert.deepStrictEqual(guitarsFolder.directChildren.map((index) => model.tracks[index].name), ['Guitarra Drive L']);

  const secondAudit = auditAddProjectRpp(updatedRpp, incomingAudit);
  assert.strictEqual(secondAudit.reusedTrackCount, 3);
  assert.strictEqual(secondAudit.newTrackCount, 0);

  const namedTrackRpp = buildCreateProjectRpp(makeAudit('Base', [
    makeFile('Vocal', 2), makeFile('Pandeirola', 2)
  ]), { platform: 'win32' });
  const namedTrackIncoming = auditAddProjectRpp(namedTrackRpp, makeAudit('Música nova', [
    makeFile('Vocal - Silva Santos', 2), makeFile('Pandeirola - Silva Santos', 2)
  ]));
  assert.strictEqual(namedTrackIncoming.reusedTrackCount, 2);
  assert.strictEqual(namedTrackIncoming.newTrackCount, 0);

  let drumsRpp = buildCreateProjectRpp(makeAudit('Base', [makeFile('Bateria')]), { platform: 'win32' });
  const drumsHierarchy = inspectRppProject(drumsRpp).tracks.map(t => [t.name, t.parentIndex, t.folderDelta]);
  for (const alias of ['drum', 'DRUMM', 'Drumms']) {
    const drumsAudit = auditAddProjectRpp(drumsRpp, makeAudit(alias, [makeFile(alias)]));
    assert.strictEqual(drumsAudit.reusedTrackCount, 1, alias);
    assert.strictEqual(drumsAudit.newTrackCount, 0, alias);
    drumsRpp = buildAddProjectRpp(drumsRpp, drumsAudit);
    assert.deepStrictEqual(inspectRppProject(drumsRpp).tracks.map(t => [t.name, t.parentIndex, t.folderDelta]), drumsHierarchy);
  }
  assert.strictEqual((drumsRpp.match(/\n    <ITEM/g) || []).length, 4);

  const guideOnlyRpp = buildCreateProjectRpp(makeAudit('Guia existente', [makeFile('Guia', 2)]), { platform: 'win32' });
  const internalIncoming = auditAddProjectRpp(guideOnlyRpp, makeAudit('Internos novos', [makeFile('Click', 2), makeFile('Regência', 2)]));
  const orderedInternalRpp = buildAddProjectRpp(guideOnlyRpp, internalIncoming);
  const orderedModel = inspectRppProject(orderedInternalRpp);
  const orderedFolder = orderedModel.groupFolders.get('interno');
  assert.deepStrictEqual(
    orderedFolder.directChildren.map((index) => orderedModel.tracks[index].name),
    ['Click', 'Regência', 'Guia']
  );
  // Reuse means media only: do not move the user's track or create a
  // category folder merely because its current parent has a different name.
  const customHierarchy = buildCreateProjectRpp(makeAudit('Base', [makeFile('Guitarra', 2), makeFile('Sanfona', 2)]), { platform: 'win32' })
    .replace('NAME "Guitarras"', 'NAME "Minha pasta"').replace('NAME "Sanfonas"', 'NAME "Outra pasta"');
  const hierarchyBefore = inspectRppProject(customHierarchy);
  const reuseAudit = auditAddProjectRpp(customHierarchy, makeAudit('Nova', [makeFile('Guitarra', 3), makeFile('Sanfona', 3)]));
  assert.strictEqual(reuseAudit.newTrackCount, 0);
  const preserved = inspectRppProject(buildAddProjectRpp(customHierarchy, reuseAudit));
  assert.deepStrictEqual(preserved.tracks.map(t => [t.name, t.parentIndex, t.folderDelta]), hierarchyBefore.tracks.map(t => [t.name, t.parentIndex, t.folderDelta]));
  assert(!preserved.groupFolders.has('guitarras') && !preserved.groupFolders.has('sanfonas'));

  // Decorative # and singular category names still identify existing folders
  // when a genuinely new child has to be inserted.
  const decorated = buildCreateProjectRpp(makeAudit('Base', [makeFile('Guitarra', 2), makeFile('Sanfona', 2)]), { platform: 'win32' })
    .replace('NAME "Guitarras"', 'NAME "#GUITARRAS"').replace('NAME "Sanfonas"', 'NAME "#SANFONA"');
  const decoratedAudit = auditAddProjectRpp(decorated, makeAudit('Nova', [makeFile('Guitarra Solo', 3), makeFile('Sanfona Solo', 3)]));
  const decoratedResult = inspectRppProject(buildAddProjectRpp(decorated, decoratedAudit));
  assert.strictEqual(decoratedResult.tracks.filter(t => t.isFolder).length, 2);
  assert.strictEqual(decoratedResult.groupFolders.get('guitarras').name, '#GUITARRAS');
  assert.strictEqual(decoratedResult.groupFolders.get('sanfonas').name, '#SANFONA');
  assert.strictEqual(decoratedResult.groupFolders.get('guitarras').directChildren.length, 2);
  assert.strictEqual(decoratedResult.groupFolders.get('sanfonas').directChildren.length, 2);
  // Metals already live in a mixed folder: new instruments belong there too.
  // Two incoming categories target the same folder; close it only once.
  const mixed = '<REAPER_PROJECT 0.1 "7.0/x64" 1700000000\n' + [
    ['#OUTROS', 1, 1], ['METAIS', 0, 0], ['BASS', 2, -1],
    ['Minha pasta', 1, 1], ['Guitarra Solo', 2, -1], ['Last', 0, 0]
  ].map(([name, type, delta]) => `  <TRACK\n    NAME "${name}"\n    ISBUS ${type} ${delta}\n  >`).join('\n') + '\n>\n';
  const mixedIncoming = makeAudit('Nova', ['Sax', 'FX 1', 'FX 2', 'Baixo', 'Guitarra'].map(name => makeFile(name)));
  const mixedResult = inspectRppProject(buildAddProjectRpp(mixed, auditAddProjectRpp(mixed, mixedIncoming)));
  const parentName = (model, name) => model.tracks[model.tracks.find(t => t.name === name).parentIndex]?.name;
  assert.deepStrictEqual(mixedResult.tracks.filter(t => t.isFolder).map(t => t.name), ['#OUTROS', 'Minha pasta']);
  for (const name of ['METAIS', 'BASS', 'Sax', 'FX 1', 'FX 2']) assert.strictEqual(parentName(mixedResult, name), '#OUTROS');
  assert.strictEqual(parentName(mixedResult, 'Guitarra'), 'Minha pasta');
  assert.strictEqual(parentName(mixedResult, 'Last'), undefined);
  const mixedBefore = inspectRppProject(mixed);
  assert.deepStrictEqual(mixedResult.tracks.filter(t => mixedBefore.tracks.some(old => old.name === t.name)).map(t => t.name), mixedBefore.tracks.map(t => t.name));
  const repeatedMixed = inspectRppProject(buildAddProjectRpp(mixedResult.text, auditAddProjectRpp(mixedResult.text, mixedIncoming)));
  assert.deepStrictEqual(repeatedMixed.tracks.map(t => [t.name, t.parentIndex]), mixedResult.tracks.map(t => [t.name, t.parentIndex]));

  // An outer folder closes on its last nested child. Appending a direct child
  // must retain the inner closing delta and the following root track.
  const nested = '<REAPER_PROJECT 0.1 "7.0/x64" 1700000000\n' + [
    ['#OUTROS', 1, 1], ['Baixo', 0, 0], ['Subgrupo', 1, 1], ['Piano', 2, -2], ['Last', 0, 0]
  ].map(([name, type, delta]) => `  <TRACK\n    NAME "${name}"\n    ISBUS ${type} ${delta}\n  >`).join('\n') + '\n>\n';
  const nestedIncoming = makeAudit('Nova', [makeFile('FX 1')]);
  const nestedResult = inspectRppProject(buildAddProjectRpp(nested, auditAddProjectRpp(nested, nestedIncoming)));
  assert.strictEqual(parentName(nestedResult, 'Piano'), 'Subgrupo');
  assert.strictEqual(parentName(nestedResult, 'FX 1'), '#OUTROS');
  assert.strictEqual(parentName(nestedResult, 'Last'), undefined);
  const bothLevelsIncoming = makeAudit('Nova', [makeFile('FX 1'), makeFile('Synth')]);
  const bothLevels = inspectRppProject(buildAddProjectRpp(nested, auditAddProjectRpp(nested, bothLevelsIncoming)));
  assert.strictEqual(parentName(bothLevels, 'Piano'), 'Subgrupo');
  assert.strictEqual(parentName(bothLevels, 'Synth'), 'Subgrupo');
  assert.strictEqual(parentName(bothLevels, 'FX 1'), '#OUTROS');
  assert.strictEqual(parentName(bothLevels, 'Last'), undefined);
  const standalone = '<REAPER_PROJECT 0.1 "7.0/x64" 1700000000\n  <TRACK\n    NAME "METAIS"\n    ISBUS 0 0\n  >\n  <TRACK\n    NAME "Last"\n    ISBUS 0 0\n  >\n>\n';
  const standaloneIncoming = makeAudit('Nova', [makeFile('Sax')]);
  const standaloneResult = inspectRppProject(buildAddProjectRpp(standalone, auditAddProjectRpp(standalone, standaloneIncoming)));
  assert.deepStrictEqual(standaloneResult.tracks.map(t => t.name), ['METAIS', 'Sax', 'Last']);
  assert(standaloneResult.tracks.every(t => !t.isFolder && t.parentIndex == null));
  process.stdout.write('Add Project: testes concluídos com sucesso.\n');
}

try {
  main();
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}
