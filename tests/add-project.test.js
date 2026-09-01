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
  assert(updatedRpp.includes('VOLPAN 1.995262315 0 1 -1'));

  const model = inspectRppProject(updatedRpp);
  const internalFolder = model.groupFolders.get('interno');
  const internalChildren = internalFolder.directChildren.map((index) => model.tracks[index].name);
  assert.deepStrictEqual(internalChildren, ['Click', 'Guia']);
  const guitarsFolder = model.groupFolders.get('guitarras');
  assert.deepStrictEqual(guitarsFolder.directChildren.map((index) => model.tracks[index].name), ['Guitarra Drive L']);

  const secondAudit = auditAddProjectRpp(updatedRpp, incomingAudit);
  assert.strictEqual(secondAudit.reusedTrackCount, 3);
  assert.strictEqual(secondAudit.newTrackCount, 0);

  const guideOnlyRpp = buildCreateProjectRpp(makeAudit('Guia existente', [makeFile('Guia', 2)]), { platform: 'win32' });
  const internalIncoming = auditAddProjectRpp(guideOnlyRpp, makeAudit('Internos novos', [makeFile('Click', 2), makeFile('Regência', 2)]));
  const orderedInternalRpp = buildAddProjectRpp(guideOnlyRpp, internalIncoming);
  const orderedModel = inspectRppProject(orderedInternalRpp);
  const orderedFolder = orderedModel.groupFolders.get('interno');
  assert.deepStrictEqual(
    orderedFolder.directChildren.map((index) => orderedModel.tracks[index].name),
    ['Click', 'Regência', 'Guia']
  );
  process.stdout.write('Add Project: testes concluídos com sucesso.\n');
}

try {
  main();
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}
