const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  CREATE_PROJECT_DESTINATION_EXISTS_MESSAGE,
  CREATE_PROJECT_INTERNAL_PEAK_DB,
  CREATE_PROJECT_REGION_GAP_SECONDS,
  auditCreateProjectFolders,
  buildCreateProjectRpp,
  calculatePeakNormalizationGain,
  classifyCreateProjectTrack,
  inferSongNameFromFolder,
  prepareCreateProjectMedia,
  readMp3AudioDuration,
  readPcmAudioDuration,
  resolveCreateProjectTrackGroup,
  writeCreateProjectFileExclusive
} = require('../src/create-project');

function createSilentWav(durationSeconds, sampleRate = 8000) {
  const channels = 1;
  const bitsPerSample = 16;
  const frameCount = Math.round(durationSeconds * sampleRate);
  const dataSize = frameCount * channels * (bitsPerSample / 8);
  const buffer = Buffer.alloc(44 + dataSize);
  buffer.write('RIFF', 0);
  buffer.writeUInt32LE(36 + dataSize, 4);
  buffer.write('WAVE', 8);
  buffer.write('fmt ', 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(channels, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * channels * (bitsPerSample / 8), 28);
  buffer.writeUInt16LE(channels * (bitsPerSample / 8), 32);
  buffer.writeUInt16LE(bitsPerSample, 34);
  buffer.write('data', 36);
  buffer.writeUInt32LE(dataSize, 40);
  return buffer;
}

function createSyntheticMp3(frameCount = 100) {
  const frameLength = Math.floor((144 * 128000) / 44100);
  const buffer = Buffer.alloc(frameLength * frameCount);
  for (let index = 0; index < frameCount; index += 1) {
    buffer.writeUInt32BE(0xfffb9064, index * frameLength);
  }
  return buffer;
}

async function main() {
  assert.strictEqual(inferSongNameFromFolder('Sabor do Teu Beijo - VS Professional').name, 'Sabor do Teu Beijo');
  assert.strictEqual(inferSongNameFromFolder('Clube do VS - Evidências').name, 'Evidências');
  assert.strictEqual(inferSongNameFromFolder('Boate Azul (VS Premium)').name, 'Boate Azul');
  assert.strictEqual(inferSongNameFromFolder('Clube de VS - Ainda Ontem Chorei de Saudade').name, 'Ainda Ontem Chorei de Saudade');
  assert.strictEqual(inferSongNameFromFolder('VS Sertanejo - Página de Amigos').name, 'Página de Amigos');
  assert.strictEqual(inferSongNameFromFolder('Deus de Promessas - VS Gospel').name, 'Deus de Promessas');
  assert.strictEqual(inferSongNameFromFolder('MultiTracks.com.br - Bondade de Deus').name, 'Bondade de Deus');
  assert.strictEqual(inferSongNameFromFolder('MultiTracksForWorship.com - Way Maker').name, 'Way Maker');
  assert.strictEqual(inferSongNameFromFolder('Loop Community - Gratidão').name, 'Gratidão');
  assert.strictEqual(inferSongNameFromFolder('Santo Pra Sempre (PraiseCharts)').name, 'Santo Pra Sempre');
  assert.strictEqual(inferSongNameFromFolder('Worship Backing Band - Amazing Grace').name, 'Amazing Grace');
  assert.strictEqual(inferSongNameFromFolder('Playback Studio - Porque Ele Vive').name, 'Porque Ele Vive');
  assert.strictEqual(inferSongNameFromFolder('PlaybackStudio.com.br - Raridade').name, 'Raridade');
  assert.strictEqual(inferSongNameFromFolder('Bohemian Rhapsody - Karaoke-Version.com').name, 'Bohemian Rhapsody');
  assert.strictEqual(inferSongNameFromFolder('SongGalaxy.com - Africa').name, 'Africa');
  assert.strictEqual(inferSongNameFromFolder('Jamzone - Hotel California').name, 'Hotel California');
  assert.strictEqual(inferSongNameFromFolder('Loop de Amor').name, 'Loop de Amor');
  assert.strictEqual(inferSongNameFromFolder('Primeiro Amor').name, 'Primeiro Amor');
  assert.strictEqual(inferSongNameFromFolder('Worship You').name, 'Worship You');
  assert.strictEqual(inferSongNameFromFolder('Studio 54').name, 'Studio 54');
  assert.strictEqual(classifyCreateProjectTrack('Click Base.wav', 'Música').name, 'Click');
  assert.strictEqual(classifyCreateProjectTrack('Metrônomo.wav', 'Música').name, 'Click');
  assert.strictEqual(classifyCreateProjectTrack('01 Maestro.wav', 'Música').name, 'Regência');
  assert.strictEqual(classifyCreateProjectTrack('GPS.wav', 'Música').name, 'Regência');
  assert.strictEqual(classifyCreateProjectTrack('Contagem.wav', 'Música').name, 'Regência');
  assert.strictEqual(classifyCreateProjectTrack('Voz Guia.wav', 'Música').name, 'Guia');
  assert.strictEqual(classifyCreateProjectTrack('Guia Voz.wav', 'Música').name, 'Guia');
  assert.strictEqual(classifyCreateProjectTrack('VZ.wav', 'Música').name, 'Guia');
  assert.strictEqual(classifyCreateProjectTrack('Voz.wav', 'Música').name, 'Guia');
  assert.strictEqual(classifyCreateProjectTrack('Back Voz.wav', 'Música').name, 'Backing Vocal');
  assert.strictEqual(classifyCreateProjectTrack('Sanfona L.wav', 'Música').name, 'Sanfona L');
  assert.strictEqual(classifyCreateProjectTrack('Ukelele L.wav', 'Música').name, 'Ukulele L');
  assert.strictEqual(classifyCreateProjectTrack('Ukulele.wav', 'Música').name, 'Ukulele');
  assert.strictEqual(classifyCreateProjectTrack('Cavaco.wav', 'Música').name, 'Cavaquinho');
  assert.strictEqual(classifyCreateProjectTrack('Banjo.wav', 'Música').name, 'Banjo');
  assert.strictEqual(classifyCreateProjectTrack('Violão R.wav', 'Música').name, 'Violão R');
  assert.strictEqual(classifyCreateProjectTrack('GTR Base.wav', 'Música').name, 'Guitarra Base');
  assert.strictEqual(classifyCreateProjectTrack('Lead.wav', 'Música').name, 'Lead');
  assert.strictEqual(classifyCreateProjectTrack('Rhodes.wav', 'Música').name, 'Rhodes');
  assert.strictEqual(classifyCreateProjectTrack('Clavinet.wav', 'Música').name, 'Clavi');
  assert.strictEqual(classifyCreateProjectTrack('Bells.wav', 'Música').name, 'Bells');
  assert.strictEqual(classifyCreateProjectTrack('Conga.wav', 'Música').name, 'Conga');
  assert.strictEqual(classifyCreateProjectTrack('Meia Lua.wav', 'Música').name, 'Meia Lua');
  assert.strictEqual(classifyCreateProjectTrack('Half-Moon Tambourine.wav', 'Música').name, 'Meia Lua');
  assert.strictEqual(classifyCreateProjectTrack('Ganzá.wav', 'Música').name, 'Ganzá');
  assert.strictEqual(classifyCreateProjectTrack('Cuíca.wav', 'Música').name, 'Cuíca');
  assert.strictEqual(classifyCreateProjectTrack('Marimba.wav', 'Música').name, 'Marimba');
  assert.strictEqual(classifyCreateProjectTrack('Xylophone.wav', 'Música').name, 'Xilofone');
  assert.strictEqual(classifyCreateProjectTrack('Kalimba.wav', 'Música').name, 'Kalimba');
  assert.strictEqual(classifyCreateProjectTrack('Back Vocais.wav', 'Música').name, 'Backing Vocal');
  assert.strictEqual(classifyCreateProjectTrack('Back.wav', 'Música').name, 'Backing Vocal');
  assert.strictEqual(classifyCreateProjectTrack('BK 2.wav', 'Música').name, 'Backing Vocal 2');
  assert.strictEqual(classifyCreateProjectTrack('Backing Vocals 3.wav', 'Música').name, 'Backing Vocal 3');
  assert.strictEqual(classifyCreateProjectTrack('Backing.wav', 'Música').name, 'Backing Vocal');
  assert.strictEqual(classifyCreateProjectTrack('ORCHHIT.wav', 'Música').name, 'Hit');
  assert.strictEqual(classifyCreateProjectTrack('OrchHit2.wav', 'Música').name, 'Hit 2');
  assert.strictEqual(classifyCreateProjectTrack('Impact.wav', 'Música').name, 'Hit');
  assert.strictEqual(classifyCreateProjectTrack('DX.wav', 'Música').name, 'DX');
  assert.strictEqual(classifyCreateProjectTrack('DX7.wav', 'Música').name, 'DX');
  assert.strictEqual(classifyCreateProjectTrack('Nipe.wav', 'Música').name, 'Metais');
  assert.strictEqual(classifyCreateProjectTrack('Brass Section.wav', 'Música').name, 'Metais');
  assert.strictEqual(classifyCreateProjectTrack('Tp&Tb Section.wav', 'Música').name, 'Metais');
  assert.strictEqual(classifyCreateProjectTrack('BrssSect.wav', 'Música').name, 'Metais');
  assert.strictEqual(classifyCreateProjectTrack('Horns.wav', 'Música').name, 'Metais');
  assert.strictEqual(classifyCreateProjectTrack('Cornet.wav', 'Música').name, 'Corneta');
  assert.strictEqual(classifyCreateProjectTrack('Euphonium.wav', 'Música').name, 'Bombardino');
  assert.strictEqual(classifyCreateProjectTrack('French Horn.wav', 'Música').name, 'Trompa');
  assert.strictEqual(classifyCreateProjectTrack('Baritone Horn.wav', 'Música').name, 'Barítono de Metal');
  assert.strictEqual(classifyCreateProjectTrack('Shofar.wav', 'Música').name, 'Shofar');
  assert.strictEqual(classifyCreateProjectTrack('JamBlock.wav', 'Música').name, 'Jamblock');
  assert.strictEqual(classifyCreateProjectTrack('drums.wav', 'Música').name, 'Bateria');
  assert.strictEqual(classifyCreateProjectTrack('batera.wav', 'Música').name, 'Bateria');
  assert.strictEqual(classifyCreateProjectTrack('CX.wav', 'Música').name, 'Caixa');
  assert.strictEqual(classifyCreateProjectTrack('SD.wav', 'Música').name, 'Surdo');
  assert.strictEqual(classifyCreateProjectTrack('CG.wav', 'Música').name, 'Conga');
  assert.strictEqual(classifyCreateProjectTrack('BG.wav', 'Música').name, 'Bongo');
  assert.strictEqual(classifyCreateProjectTrack('Hihat.wav', 'Música').name, 'Hi-Hat');
  assert.strictEqual(classifyCreateProjectTrack('Ximbal.wav', 'Música').name, 'Hi-Hat');
  assert.strictEqual(classifyCreateProjectTrack('Tom1.wav', 'Música').name, 'Tom 1');
  assert.strictEqual(classifyCreateProjectTrack('Tom Tom 2.wav', 'Música').name, 'Tom 2');
  assert.strictEqual(classifyCreateProjectTrack('Tonton3.wav', 'Música').name, 'Tom 3');
  assert.strictEqual(classifyCreateProjectTrack('Ronton 4.wav', 'Música').name, 'Tom 4');
  assert.strictEqual(classifyCreateProjectTrack('Over L.wav', 'Música').name, 'Over L');
  assert.strictEqual(classifyCreateProjectTrack('Over R.wav', 'Música').name, 'Over R');
  assert.strictEqual(classifyCreateProjectTrack('Ride Cymbal.wav', 'Música').name, 'Ride');
  assert.strictEqual(classifyCreateProjectTrack('Crash Cymbal.wav', 'Música').name, 'Crash');
  assert.strictEqual(classifyCreateProjectTrack('Korg M1.wav', 'Música').name, 'M1');
  assert.strictEqual(classifyCreateProjectTrack('M1 Piano.wav', 'Música').name, 'Piano');
  assert.strictEqual(classifyCreateProjectTrack('M1 Piano 2.wav', 'Música').name, 'Piano 2');
  assert.strictEqual(classifyCreateProjectTrack('Korg Universe.wav', 'Música').name, 'Universe');
  assert.strictEqual(classifyCreateProjectTrack('Triton Studio.wav', 'Música').name, 'Triton');
  assert.strictEqual(classifyCreateProjectTrack('Kronos.wav', 'Música').name, 'Kronos');
  assert.strictEqual(classifyCreateProjectTrack('Kross2.wav', 'Música').name, 'Kross');
  assert.strictEqual(classifyCreateProjectTrack('Pa5X.wav', 'Música').name, 'Korg PA');
  assert.strictEqual(classifyCreateProjectTrack('D50.wav', 'Música').name, 'D-50');
  assert.strictEqual(classifyCreateProjectTrack('D-50 Fantasia.wav', 'Música').name, 'Fantasia');
  assert.strictEqual(classifyCreateProjectTrack('D50 Stac Heaven.wav', 'Música').name, 'Staccato Heaven');
  assert.strictEqual(classifyCreateProjectTrack('D50 Brass.wav', 'Música').name, 'Synth Brass');
  assert.strictEqual(classifyCreateProjectTrack('JV1080.wav', 'Música').name, 'JV-1080');
  assert.strictEqual(classifyCreateProjectTrack('XV-5080.wav', 'Música').name, 'XV-5080');
  assert.strictEqual(classifyCreateProjectTrack('Juno Strings.wav', 'Música').name, 'Synth Strings');
  assert.strictEqual(classifyCreateProjectTrack('JP-8000 Brass.wav', 'Música').name, 'Synth Brass');
  assert.strictEqual(classifyCreateProjectTrack('D-50 Voices.wav', 'Música').name, 'Vox Synth');
  assert.strictEqual(classifyCreateProjectTrack('D-50 Heaven.wav', 'Música').name, 'Pad');
  assert.strictEqual(classifyCreateProjectTrack('JP8BrtPd.wav', 'Música').name, 'Pad');
  assert.strictEqual(classifyCreateProjectTrack('Synth PolyKey.wav', 'Música').name, 'Synth');
  assert.strictEqual(classifyCreateProjectTrack('Fantom-06.wav', 'Música').name, 'Fantom');
  assert.strictEqual(classifyCreateProjectTrack('Integra-7.wav', 'Música').name, 'Integra-7');
  assert.strictEqual(classifyCreateProjectTrack('Trance Stab.wav', 'Música').name, 'Hit');
  assert.strictEqual(classifyCreateProjectTrack('Sequencer.wav', 'Música').name, 'Sequencer');
  assert.strictEqual(classifyCreateProjectTrack('arquivo desconhecido.wav', 'Música').name, 'Out');
  assert.strictEqual(resolveCreateProjectTrackGroup('Click').name, 'Interno');
  assert.strictEqual(resolveCreateProjectTrackGroup('Guia').name, 'Interno');
  assert.strictEqual(resolveCreateProjectTrackGroup('Guitarra Drive L').name, 'Guitarras');
  assert.strictEqual(resolveCreateProjectTrackGroup('Ukulele L').name, 'Violões');
  assert.strictEqual(resolveCreateProjectTrackGroup('Cavaquinho').name, 'Violões');
  assert.strictEqual(resolveCreateProjectTrackGroup('Banjo').name, 'Violões');
  assert.strictEqual(resolveCreateProjectTrackGroup('Violão R').name, 'Violões');
  assert.strictEqual(resolveCreateProjectTrackGroup('Sanfona R').name, 'Sanfonas');
  assert.strictEqual(resolveCreateProjectTrackGroup('Piano').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Rhodes').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Clavi').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Bells').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Lead').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Hit 2').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('DX').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('M1').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Universe').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('D-50').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Fantom').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Vox Synth').name, 'Teclados');
  assert.strictEqual(resolveCreateProjectTrackGroup('Trompete 2').name, 'Metais');
  assert.strictEqual(resolveCreateProjectTrackGroup('Sax').name, 'Metais');
  assert.strictEqual(resolveCreateProjectTrackGroup('Corneta').name, 'Metais');
  assert.strictEqual(resolveCreateProjectTrackGroup('Bombardino').name, 'Metais');
  assert.strictEqual(resolveCreateProjectTrackGroup('Shofar').name, 'Metais');
  assert.strictEqual(resolveCreateProjectTrackGroup('Bateria').name, 'Percussivo');
  assert.strictEqual(resolveCreateProjectTrackGroup('Conga').name, 'Percussivo');
  assert.strictEqual(resolveCreateProjectTrackGroup('Meia Lua').name, 'Percussivo');
  assert.strictEqual(resolveCreateProjectTrackGroup('Ganzá').name, 'Percussivo');
  assert.strictEqual(resolveCreateProjectTrackGroup('Cuíca').name, 'Percussivo');
  assert.strictEqual(resolveCreateProjectTrackGroup('Jamblock').name, 'Percussivo');
  assert.strictEqual(resolveCreateProjectTrackGroup('Marimba').name, 'Outros');
  assert.strictEqual(resolveCreateProjectTrackGroup('Xilofone').name, 'Outros');
  assert.strictEqual(resolveCreateProjectTrackGroup('Kalimba').name, 'Outros');
  assert.strictEqual(resolveCreateProjectTrackGroup('Backing Vocal 2').name, 'Back Vocais');
  assert.strictEqual(resolveCreateProjectTrackGroup('Baixo').name, 'Outros');
  assert.strictEqual(resolveCreateProjectTrackGroup('Sequencer').name, 'Outros');
  assert.strictEqual(CREATE_PROJECT_INTERNAL_PEAK_DB, -1);
  assert(Math.abs(calculatePeakNormalizationGain(-7) - 1.9952623149688795) < 1e-12);
  assert.strictEqual(calculatePeakNormalizationGain(-Infinity), 1);

  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'hook-create-project-'));
  try {
    const songA = path.join(root, 'Sabor do Teu Beijo - VS Professional');
    const songB = path.join(root, 'Clube do VS - Evidências');
    const empty = path.join(root, 'Pasta sem áudio');
    await Promise.all([songA, songB, empty].map((folder) => fs.promises.mkdir(folder)));
    const files = [
      [songA, 'Click.wav', 2],
      [songA, 'Maestro.wav', 3],
      [songA, 'Sanfona L.wav', 2.5],
      [songA, 'mistério.wav', 1],
      [songB, 'CLICK.WAV', 4],
      [songB, 'GPS.wav', 3],
      [songB, 'Sanfona R.wav', 2]
    ];
    for (const [folder, fileName, duration] of files) {
      await fs.promises.writeFile(path.join(folder, fileName), createSilentWav(duration));
    }
    await fs.promises.writeFile(path.join(songB, 'ignorar.flac'), Buffer.from('x'));

    const measured = await readPcmAudioDuration(path.join(songA, 'Maestro.wav'));
    assert(Math.abs(measured - 3) < 0.001);
    const mp3Fixture = path.join(root, 'duration-test.mp3');
    await fs.promises.writeFile(mp3Fixture, createSyntheticMp3(100));
    const measuredMp3 = await readMp3AudioDuration(mp3Fixture);
    assert(Math.abs(measuredMp3 - (100 * 1152 / 44100)) < 0.02);

    const measuredPeaks = [];
    const audit = await auditCreateProjectFolders({
      folderPaths: [songA, songB, empty],
      durationResolver: readPcmAudioDuration,
      peakResolver: async (filePath) => {
        measuredPeaks.push(path.basename(filePath));
        return /click/i.test(path.basename(filePath)) ? -7 : -3;
      }
    });
    assert.strictEqual(audit.validSongCount, 2);
    assert.strictEqual(audit.totalIncludedFiles, 7);
    assert.strictEqual(audit.songs[0].name, 'Sabor do Teu Beijo');
    assert.strictEqual(audit.songs[0].duration, 3);
    assert.strictEqual(audit.songs[1].name, 'Evidências');
    assert.strictEqual(CREATE_PROJECT_REGION_GAP_SECONDS, 60);
    assert.strictEqual(audit.songs[1].start, 63);
    assert.strictEqual(audit.songs[1].duration, 4);
    assert.strictEqual(audit.totalDuration, 67);
    assert.strictEqual(audit.emptyFolders.length, 1);
    assert.strictEqual(measuredPeaks.length, 4);
    assert(audit.songs.flatMap((song) => song.files)
      .filter((file) => ['Click', 'Regência'].includes(file.trackName))
      .every((file) => file.normalizePeakDb === -1 && file.takeVolume > 1));
    assert(audit.songs.flatMap((song) => song.files)
      .filter((file) => !['Click', 'Regência'].includes(file.trackName))
      .every((file) => file.normalizePeakDb === null && file.takeVolume === 1));
    assert(audit.tracks.some((track) => track.name === 'Regência' && track.fileCount === 2));
    assert(audit.tracks.some((track) => track.name === 'Click' && track.fileCount === 2));
    assert(audit.tracks.some((track) => track.name === 'Out' && track.fileCount === 1));
    assert.deepStrictEqual(audit.groups.map((group) => group.name), ['Interno', 'Sanfonas', 'Outros']);
    assert.deepStrictEqual(audit.groups.find((group) => group.name === 'Interno').tracks.map((track) => track.name), ['Click', 'Regência']);
    assert.strictEqual(new Set(audit.groups.map((group) => group.color)).size, audit.groups.length);

    const destinationPath = path.join(root, 'Projeto criado.rpp');
    const copyProgress = [];
    const preparedMedia = await prepareCreateProjectMedia(audit, destinationPath, {
      onProgress: (progress) => copyProgress.push(progress)
    });
    assert.strictEqual(preparedMedia.copiedCount, 7);
    assert.strictEqual(preparedMedia.reusedCount, 0);
    assert.strictEqual(copyProgress.length, 7);
    assert.strictEqual((await fs.promises.readdir(path.join(root, 'Media'))).length, 7);
    assert(preparedMedia.audit.songs.every((song) => song.files.every((file) => file.projectFilePath.startsWith(`Media${path.sep}`))));

    const reusedMedia = await prepareCreateProjectMedia(audit, destinationPath);
    assert.strictEqual(reusedMedia.copiedCount, 0);
    assert.strictEqual(reusedMedia.reusedCount, 7);

    const rpp = buildCreateProjectRpp(preparedMedia.audit, { platform: 'win32' });
    assert(rpp.startsWith('<REAPER_PROJECT'));
    assert(rpp.includes('RECORD_PATH "Media" ""'));
    assert.strictEqual((rpp.match(/\n  <TRACK /g) || []).length, audit.tracks.length + audit.groups.length);
    assert.strictEqual((rpp.match(/\n    <ITEM/g) || []).length, 7);
    assert(rpp.includes('NAME "Regência"'));
    assert(rpp.includes('NAME "Out"'));
    assert(rpp.includes('VOLPAN 1.995262315 0 1 -1'));
    assert(rpp.includes('VOLPAN 1.258925412 0 1 -1'));
    for (const group of audit.groups) {
      assert(rpp.includes(`NAME "${group.name}"\n    PEAKCOL ${group.color}`));
      assert(rpp.includes(`NAME "${group.tracks[0].name}"\n    PEAKCOL ${group.color}`));
    }
    assert.strictEqual((rpp.match(/\n    ISBUS 1 1/g) || []).length, audit.groups.length);
    assert.strictEqual((rpp.match(/\n    ISBUS 2 -1/g) || []).length, audit.groups.length);
    assert(!/\n      GROUP \d+/.test(rpp));
    assert(rpp.includes('MARKER 1 0 "Sabor do Teu Beijo"'));
    assert(rpp.includes('MARKER 2 63 "Evidências"'));
    assert(!rpp.includes('ignorar.flac'));
    assert(!rpp.includes(songA));
    assert(rpp.includes('FILE "Media\\001 - Sabor do Teu Beijo - Click.wav"'));
    await writeCreateProjectFileExclusive(destinationPath, rpp);
    await assert.rejects(
      () => writeCreateProjectFileExclusive(destinationPath, 'não pode sobrescrever'),
      (error) => error?.code === 'CREATE_PROJECT_DESTINATION_EXISTS' &&
        error.message === CREATE_PROJECT_DESTINATION_EXISTS_MESSAGE
    );
    assert.strictEqual(await fs.promises.readFile(destinationPath, 'utf8'), rpp);

    const brandedFolder = path.join(root, 'VS Professional - Temporal Edição 2026');
    await fs.promises.mkdir(brandedFolder);
    await fs.promises.writeFile(path.join(brandedFolder, 'Click - Temporal.wav'), createSilentWav(2));
    await fs.promises.writeFile(path.join(brandedFolder, 'GPS - Temporal.wav'), createSilentWav(2));
    const brandedAudit = await auditCreateProjectFolders({
      folderPaths: [brandedFolder],
      durationResolver: readPcmAudioDuration
    });
    assert.strictEqual(brandedAudit.songs[0].name, 'Temporal');
    assert.strictEqual(brandedAudit.songs[0].nameSource, 'audio-files');

    const recurringA = path.join(root, 'Música Um');
    const recurringB = path.join(root, 'Música Dois');
    await Promise.all([recurringA, recurringB].map((folder) => fs.promises.mkdir(folder)));
    await fs.promises.writeFile(path.join(recurringA, 'Textura Especial.wav'), createSilentWav(1));
    await fs.promises.writeFile(path.join(recurringB, 'Textura Especial.wav'), createSilentWav(1));
    const recurringAudit = await auditCreateProjectFolders({
      folderPaths: [recurringA, recurringB],
      durationResolver: readPcmAudioDuration
    });
    assert(recurringAudit.tracks.some((track) => track.name === 'Textura Especial' && track.fileCount === 2));
    assert.strictEqual(recurringAudit.unknownFileCount, 0);
    assert.strictEqual(resolveCreateProjectTrackGroup('Textura Especial').name, 'Outros');

    const collisionFolder = path.join(root, 'Teste sem sobreposição');
    await fs.promises.mkdir(collisionFolder);
    await fs.promises.writeFile(path.join(collisionFolder, 'GTR Base.wav'), createSilentWav(1));
    await fs.promises.writeFile(path.join(collisionFolder, 'Guitarra Base.wav'), createSilentWav(1));
    await fs.promises.writeFile(path.join(collisionFolder, 'Guitarra Base 2.wav'), createSilentWav(1));
    const collisionAudit = await auditCreateProjectFolders({
      folderPaths: [collisionFolder],
      durationResolver: readPcmAudioDuration
    });
    assert.strictEqual(new Set(collisionAudit.songs[0].files.map((file) => file.trackKey)).size, 3);
    assert.deepStrictEqual(
      collisionAudit.tracks.map((track) => track.name),
      ['Guitarra Base', 'Guitarra Base 2', 'Guitarra Base 3']
    );

    const taxonomyFolder = path.join(root, 'Teste da taxonomia');
    await fs.promises.mkdir(taxonomyFolder);
    await fs.promises.writeFile(path.join(taxonomyFolder, 'HIT.wav'), createSilentWav(1));
    await fs.promises.writeFile(path.join(taxonomyFolder, 'ORCHHIT.wav'), createSilentWav(1));
    await fs.promises.writeFile(path.join(taxonomyFolder, 'JamBlock.wav'), createSilentWav(1));
    const taxonomyAudit = await auditCreateProjectFolders({
      folderPaths: [taxonomyFolder],
      durationResolver: readPcmAudioDuration
    });
    const taxonomyFiles = taxonomyAudit.songs[0].files;
    assert.strictEqual(new Set(taxonomyFiles.map((file) => file.trackKey)).size, taxonomyFiles.length);
    assert(taxonomyFiles.every((file) => file.recognized && file.trackName !== 'Out'));
    assert.deepStrictEqual(
      taxonomyFiles.filter((file) => /hit/i.test(file.fileName)).map((file) => file.trackName).sort(),
      ['Hit', 'Hit 2']
    );
    assert(taxonomyAudit.tracks.some((track) => track.name === 'Jamblock'));
  } finally {
    await fs.promises.rm(root, { recursive: true, force: true });
  }
  process.stdout.write('Create Project: testes concluídos com sucesso.\n');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
