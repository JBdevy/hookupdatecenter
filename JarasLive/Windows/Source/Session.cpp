#include "Session.h"
#include "Appearance.h"
#include "TrackTree.h"
#include "MediaCleanup.h"
namespace catlive {
namespace {
jaras::Song emptySong(const String &name) {
    jaras::Song s;
    s.id = uuid();
    s.name = utf8(name);
    s.duration = 120;
    s.bpm = 120;
    return s;
}
std::vector<double> waveform(AudioFormatReader &reader) {
    const auto samples = reader.lengthInSamples;
    const int bins = (int)std::min<int64>(4096, std::max<int64>(1, samples / 128));
    std::vector<double> peaks((size_t)bins, 0);
    AudioBuffer<float> buffer((int)std::min(2u, reader.numChannels), 32768);
    for (int64 pos = 0; pos < samples; pos += buffer.getNumSamples()) {
        int count = (int)std::min<int64>(buffer.getNumSamples(), samples - pos);
        buffer.clear();
        if (!reader.read(&buffer, 0, count, pos, true, true))
            throw std::runtime_error("Could not analyse audio.");
        for (int n = 0; n < count; ++n) {
            auto bin = (size_t)std::min<int64>(bins - 1, (pos + n) * bins / samples);
            for (int ch = 0; ch < buffer.getNumChannels(); ++ch)
                peaks[bin] = std::max(peaks[bin], (double)std::abs(buffer.getSample(ch, n)));
        }
    }
    return peaks;
}
} // namespace
Session::Session() {
    newProject();
    startTimerHz(8);
}
Session::~Session() {
    stopTimer();
    exportCancelled = true;
    alive.reset();
    worker.removeAllJobs(true, 30000);
}
void Session::notify() {
    ++revision;
    if (changed)
        changed();
}
void Session::newProject(String name) {
    if (busy)
        return;
    if (audio.isRecording())
        throw std::runtime_error("Pare a gravação antes de criar outro projeto.");
    core.execute({jaras::CommandKind::stopAll});
    jaras::Project p;
    p.id = uuid();
    p.name = utf8(name.trim().isEmpty() ? "Untitled" : name.trim());
    p.createdAt = p.updatedAt = utf8(Time::getCurrentTime().toISO8601(true));
    p.songs.push_back(emptySong("Timeline"));
    p.setlists.push_back({uuid(), p.name, {p.songs.front().id}});
    core.loadProject(std::move(p));
    original = var();
    observedMedia.clear();
    document = File();
    mediaDirectory = File::getSpecialLocation(File::userApplicationDataDirectory)
                         .getChildFile("Hook Developer/CatLive/Unsaved/" + text(project().id));
    mediaDirectory.createDirectory();
    undoHistory.clear();
    redoHistory.clear();
    recordArms.clear();
    recordSelection.clear();
    dirty = false;
    message.clear();
    prepare();
    notify();
}
void Session::prepare() {
    if (auto *current = song()) {
        audio.prepareSong(*current, mediaDirectory,
                          project().masterFXJSON ? JSON::parse(text(*project().masterFXJSON))
                                                 : var(),
                          &project());
        audio.setMixer(project(), *current);
        updateRecordArms();
        preparedSong = current->id;
        publishTransport();
        if (!audio.missingFiles.isEmpty())
            message = String::fromUTF8("Mídias ausentes: ") + String(audio.missingFiles.size()) +
                      ". Religue a pasta original antes do show.";
        else if (!audio.unsupported.isEmpty())
            message =
                String::fromUTF8(
                    "Este projeto contém processamento Apple que ainda precisa ser convertido: ") +
                audio.unsupported.joinIntoString(", ");
    }
}
void Session::load(const File &file) {
    if (busy || audio.isRecording() || transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare a reprodução antes de abrir outro projeto.");
    auto raw = ProjectCodec::read(file);
    auto p = ProjectCodec::decode(raw);
    auto previous = snapshot();
    auto previousFile = document, previousMedia = mediaDirectory;
    try {
        core.loadProject(p);
        if (p.savedCursor && std::any_of(p.songs.begin(), p.songs.end(), [&](const auto &song) {
                return song.id == p.savedCursor->songID;
            })) {
            core.execute({jaras::CommandKind::select, p.savedCursor->songID});
            core.execute({jaras::CommandKind::seek, {}, p.savedCursor->position});
            core.execute({jaras::CommandKind::editSeek, {}, p.savedCursor->position});
        }
        document = file;
        mediaDirectory = file.getParentDirectory();
        original = raw;
        prepare();
    } catch (...) {
        document = previousFile;
        mediaDirectory = previousMedia;
        restoreSnapshot(previous);
        throw;
    }
    undoHistory.clear();
    redoHistory.clear();
    observedMedia = mediaCleanup::references(project());
    dirty = false;
    notify();
}
var Session::snapshot() const { return ProjectCodec::encode(project(), original); }
void Session::save(const File &file) {
    if (audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de salvar o projeto.");
    if (busy)
        throw std::runtime_error("Aguarde a importação terminar.");
    auto target = file.withFileExtension("jl");
    auto targetDir = target.getParentDirectory();
    if (targetDir.createDirectory().failed())
        throw std::runtime_error("Não foi possível criar a pasta do projeto.");
    for (const auto &other : targetDir.findChildFiles(File::findFiles, false, "*.jl"))
        if (other != target)
            throw std::runtime_error("Escolha uma pasta separada para cada projeto CatLive.");
    auto p = project();
    if (transport().songId)
        p.savedCursor = jaras::SavedProjectCursor{*transport().songId, transport().editPosition};
    // The same media set as the Mac Project.mediaPaths policy, including legacy
    // track-level sources and custom Click samples. A Save As carries all of it.
    std::set<std::string> paths;
    for (const auto &song : p.songs)
        for (const auto &track : song.tracks) {
            if (track.audioFile)
                paths.insert(track.audioFile->path);
            if (track.clickSound)
                paths.insert(track.clickSound->path);
            for (const auto &clip : track.clips)
                if (clip.audioFile)
                    paths.insert(clip.audioFile->path);
        }
    for (const auto &id : instrumentAssets::identities(p)) {
        auto source = instrumentAssets::resolve(id, mediaDirectory),
             dest = targetDir.getChildFile("Instruments/" + id + ".sf2");
        if (!source.existsAsFile())
            throw std::runtime_error(
                utf8(String::fromUTF8("Instrumento ausente: ") + instrumentAssets::name(id)));
        if (source != dest) {
            dest.getParentDirectory().createDirectory();
            if (dest.existsAsFile()) {
                FileInputStream a(source), b(dest);
                if (SHA256(a) != SHA256(b))
                    throw std::runtime_error(
                        "A different instrument bank already exists in the destination.");
            } else if (!source.copyFileTo(dest))
                throw std::runtime_error("Could not copy the instrument bank.");
        }
    }
    if (targetDir != mediaDirectory)
        for (const auto &relative : paths) {
            auto source = ProjectCodec::resolveMedia(mediaDirectory, relative);
            auto dest = ProjectCodec::resolveMedia(targetDir, relative);
            if (!source.existsAsFile())
                throw std::runtime_error(
                    utf8(String::fromUTF8("Mídia ausente: ") + source.getFileName()));
            if (dest.existsAsFile() && dest != source) {
                FileInputStream a(source), b(dest);
                if (SHA256(a) != SHA256(b))
                    throw std::runtime_error("Já existe uma mídia diferente na pasta de destino.");
            } else if (dest != source) {
                dest.getParentDirectory().createDirectory();
                if (!source.copyFileTo(dest))
                    throw std::runtime_error("Não foi possível copiar as mídias.");
            }
        }
    p.updatedAt = utf8(Time::getCurrentTime().toISO8601(true));
    auto raw = ProjectCodec::encode(p, original);
    const auto remembered = targetDir == mediaDirectory ? observedMedia : mediaCleanup::Paths{};
    mediaCleanup::remember(p, target, remembered);
    ProjectCodec::write(target, raw);
    core.applyProjectEdit(p);
    original = raw;
    document = target;
    mediaDirectory = targetDir;
    observedMedia = mediaCleanup::references(p);
    dirty = false;
    message =
        String::fromUTF8("Projeto salvo · ") + Time::getCurrentTime().formatted("%d/%m/%Y %H:%M");
    notify();
}
void Session::cleanTimelineMedia(std::function<void(String)> completed) {
    if (busy || audio.isRecording() || transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare a reprodução ou gravação antes de limpar as mídias.");
    if (!document.existsAsFile())
        throw std::runtime_error("Salve o projeto antes de limpar as mídias.");
    save(document);
    const auto projectCopy = project();
    const auto raw = snapshot();
    const auto file = document;
    const auto known = observedMedia;
    busy = true;
    importProgress = 0;
    undoHistory.clear();
    redoHistory.clear();
    message = String::fromUTF8("Limpando mídias excluídas da timeline…");
    notify();
    const auto weak = std::weak_ptr<int>(alive);
    worker.addJob([this, weak, projectCopy, raw, file, known, completed] {
        String failure;
        int removed = 0;
        try {
            removed = mediaCleanup::removeDeleted(
                projectCopy, raw, file, known, [this, weak](double progress) {
                    MessageManager::callAsync([this, weak, progress] {
                        if (!weak.expired()) {
                            importProgress = progress;
                            notify();
                        }
                    });
                });
        } catch (const std::exception &e) {
            failure = String::fromUTF8(e.what());
        }
        MessageManager::callAsync([this, weak, removed, failure, completed] {
            if (weak.expired())
                return;
            busy = false;
            importProgress = 0;
            message = failure.isEmpty()
                          ? String(removed) +
                                String::fromUTF8(" arquivo(s) removido(s). Backups preservados.")
                          : failure;
            notify();
            if (completed)
                completed(failure);
        });
    });
}
void Session::syncClock() {
    auto elapsed = audio.takeElapsed();
    if (elapsed <= 0)
        return;
    auto old = transport().songId;
    const auto oldJump = transport().sectionJumpSerial;
    const auto oldPromotion = transport().subPlayPromotion;
    core.advance(elapsed);
    if (old != transport().songId && song())
        prepare();
    else {
        auto actual = audio.state();
        const auto &expected = transport();
        auto *device = audio.devices.getCurrentAudioDevice();
        double tolerance =
            device
                ? std::max(.003, device->getCurrentBufferSizeSamples() / audio.sampleRate() * 1.5)
                : .003;
        if (expected.playing != actual.playing || expected.subPlay.playing != actual.subPlaying ||
            oldJump != expected.sectionJumpSerial || oldPromotion != expected.subPlayPromotion ||
            std::abs(expected.position - actual.position) > tolerance)
            publishTransport();
    }
}
void Session::publishTransport() {
    const auto &t = transport();
    AudioEngine::State state;
    state.position = t.position;
    state.timecodePreferred = audio.timecodePreferred(t.regionId);
    state.playing = t.playing;
    state.subPosition = t.subPlay.position;
    state.subPlaying = t.subPlay.playing;
    if (song()) {
        state.scope[0] = jaras::playbackScope(*song(), t);
        state.scope[1] = jaras::playbackScope(*song(), t, true);
    }
    state.end = t.ignoreNextEnd.value_or(std::numeric_limits<double>::infinity());
    state.loop = t.loop.enabled;
    state.loopStart = t.loop.start.value_or(0);
    state.loopEnd = t.loop.end.value_or(song() ? song()->duration : 0);
    if (t.regionId && state.loop && song())
        for (const auto &p : song()->parts)
            if (p.id == *t.regionId && !t.loop.start && !t.loop.end) {
                state.loopStart = p.startTime;
                state.loopEnd = p.endTime;
            }
    audio.transport(state);
}
void Session::command(jaras::CommandKind kind, const ID &target, double value) {
    if (busy)
        return;
    if (audio.isRecording() &&
        (kind == jaras::CommandKind::stopAll || kind == jaras::CommandKind::stop ||
         kind == jaras::CommandKind::pause)) {
        toggleRecording();
        return;
    }
    if (audio.isRecording() && kind != jaras::CommandKind::play &&
        kind != jaras::CommandKind::volume && kind != jaras::CommandKind::pan &&
        kind != jaras::CommandKind::mute && kind != jaras::CommandKind::solo &&
        kind != jaras::CommandKind::phase && kind != jaras::CommandKind::masterMono)
        throw std::runtime_error("Conclua a gravação antes de mudar a posição ou a música.");
    syncClock();
    const bool start = kind == jaras::CommandKind::play || kind == jaras::CommandKind::subPlay;
    if (start && canPlay && !canPlay()) {
        message = String::fromUTF8("Faça login ou ative o trial para reproduzir.");
        notify();
        return;
    }
    if (start && !audio.missingFiles.isEmpty())
        throw std::runtime_error("Há mídias ausentes. Corrija-as antes de reproduzir.");
    if (start && !audio.unsupported.isEmpty())
        throw std::runtime_error(
            "Este projeto contém FX Apple ainda não convertidos. Renderize esses "
            "efeitos no Mac antes de reproduzir no Windows.");
    auto old = transport().songId;
    core.execute({kind, target, value});
    if (old != transport().songId)
        prepare();
    const bool mixer = kind == jaras::CommandKind::volume || kind == jaras::CommandKind::pan ||
                       kind == jaras::CommandKind::mute || kind == jaras::CommandKind::solo ||
                       kind == jaras::CommandKind::phase || kind == jaras::CommandKind::masterMono;
    if (mixer) {
        dirty = true;
        if (song())
            audio.setMixer(project(), *song());
    } else
        publishTransport();
    startTimerHz(transport().playing || transport().subPlay.playing ? 60 : 8);
    notify();
}
void Session::updateRecordArms() {
    if (const auto *current = song())
        for (const auto &track : current->tracks)
            audio.armTrack(track.id, recordingArmed(track.id));
}
void Session::setRecordingSelection(const ID &id) {
    if (audio.isRecording())
        return;
    if (recordSelection == id)
        return;
    recordSelection = id;
    updateRecordArms();
}
void Session::cycleRecordArm(const ID &id) {
    if (audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de alterar as pistas armadas.");
    if (const auto *current = song())
        for (const auto &track : current->tracks)
            if (track.id == id && jaras::fixedTrackName(track.role).empty()) {
                recordArms[id] = (recordArm(id) + 1) % 3;
                updateRecordArms();
                notify();
                return;
            }
}
void Session::toggleRecording() {
    if (audio.isRecording()) {
        auto takes = audio.stopTrackRecording();
        core.execute({jaras::CommandKind::stopAll});
        publishTransport();
        std::vector<std::pair<ID, jaras::AudioClip>> clips;
        for (auto &take : takes)
            if (take.duration > 0) {
                jaras::AudioClip clip;
                clip.id = uuid();
                clip.startTime = recordingStart;
                clip.duration = take.duration;
                clip.name = utf8(take.file == File() ? String("MIDI take")
                                                     : take.file.getFileNameWithoutExtension());
                if (take.midi)
                    clip.midi = std::move(take.midi);
                else {
                    clip.audioFile =
                        jaras::AudioFile{utf8(take.file.getRelativePathFrom(mediaDirectory)
                                                  .replaceCharacter('\\', '/')),
                                         {}};
                    if (auto reader = std::unique_ptr<AudioFormatReader>(
                            audio.formats.createReaderFor(take.file)))
                        clip.waveform = waveform(*reader);
                }
                clips.emplace_back(take.track, std::move(clip));
            }
        edit([&](jaras::Project &p) {
            for (auto &s : p.songs)
                if (s.id == recordingSong)
                    for (auto &t : s.tracks)
                        for (const auto &[id, clip] : clips)
                            if (t.id == id) {
                                t.clips.push_back(clip);
                                s.duration = std::max(s.duration, clip.startTime + clip.duration);
                            }
        });
        message =
            audio.recordingOverflows()
                ? String::fromUTF8(
                      "Gravação concluída com perda de blocos. Verifique os takes antes de usar.")
                : String::fromUTF8("Gravação adicionada às pistas armadas.");
        notify();
        return;
    }
    if (busy)
        return;
    if (canPlay && !canPlay())
        throw std::runtime_error("Valide sua licença para gravar.");
    if (!song())
        return;
    if (transport().loop.enabled)
        throw std::runtime_error("Desative o loop antes de gravar.");
    if (transport().subPlay.playing)
        throw std::runtime_error("Pare o Sub Play antes de gravar.");
    syncClock();
    recordingStart = transport().playing ? transport().position : transport().editPosition;
    recordingSong = song()->id;
    Appearance settings;
    const bool aiff = settings.value("jaras.media.record.format", "WAV").toString() == "AIFF";
    const int bits = (int)settings.value("jaras.media.record.bits", 24);
    std::vector<TrackCapture::Target> targets;
    for (const auto &track : song()->tracks)
        if (recordingArmed(track.id) && jaras::fixedTrackName(track.role).empty()) {
            TrackCapture::Target target;
            target.track = track.id;
            target.midi = track.recordingChannels == 0;
            target.channels = track.recordingChannels.value_or(2);
            if (target.midi)
                target.channels = 2;
            target.bus = track.fxJSON &&
                         !instrumentAssets::settings(JSON::parse(text(*track.fxJSON))).empty();
            target.input = track.inputPatch ? track.inputPatch->firstChannel : 1;
            if (!target.midi && !target.bus && !track.inputPatch)
                throw std::runtime_error(
                    utf8("Escolha a entrada no Patch da pista " + text(track.name) + "."));
            if (track.recordingFormat == "mp3")
                throw std::runtime_error("Selecione WAV ou WAV 32 para a gravação desta pista. MP3 "
                                         "está disponível em Exportar.");
            if (!target.midi)
                target.file = mediaDirectory.getChildFile("Stems/Recordings")
                                  .getNonexistentChildFile(
                                      File::createLegalFileName(text(track.name)) + "-" +
                                          Time::getCurrentTime().formatted("%Y%m%d-%H%M%S") + "-" +
                                          text(uuid()).substring(0, 8),
                                      aiff && !track.recordingFormat ? ".aiff" : ".wav");
            target.bits = track.recordingFormat == "wav32" ? 32
                          : track.recordingFormat == "wav" ? 24
                                                           : bits;
            targets.push_back(std::move(target));
        }
    if (targets.empty())
        throw std::runtime_error("Arme pelo menos uma pista no botão REC antes de gravar.");
    if (!audio.missingFiles.isEmpty() || !audio.unsupported.isEmpty())
        throw std::runtime_error("Resolva as mídias ou efeitos ausentes antes de gravar.");
    audio.startTrackRecording(targets, bits, song()->bpm);
    if (!transport().playing)
        command(jaras::CommandKind::play);
    message = String::fromUTF8("Gravando áudio · clique em REC ou Stop para concluir");
    notify();
}
void Session::configureSetlist(jaras::RegionSetlist state) {
    if (busy)
        return;
    syncClock();
    auto before = snapshot();
    core.configureRegionSetlist(std::move(state));
    undoHistory.push_back(std::move(before));
    if (undoHistory.size() > 40)
        undoHistory.erase(undoHistory.begin());
    redoHistory.clear();
    dirty = true;
    publishTransport();
    notify();
}
void Session::edit(const std::function<void(jaras::Project &)> &change, bool rebuild) {
    if (busy)
        return;
    if (rebuild && audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de alterar a estrutura do projeto.");
    syncClock();
    if (rebuild && (transport().playing || transport().subPlay.playing))
        throw std::runtime_error("Pare a reprodução antes de alterar a estrutura do projeto.");
    auto before = snapshot();
    auto p = project();
    change(p);
    jaras::validate(p);
    const auto beforeMedia = mediaCleanup::references(project()),
               afterMedia = mediaCleanup::references(p);
    observedMedia.insert(beforeMedia.begin(), beforeMedia.end());
    observedMedia.insert(afterMedia.begin(), afterMedia.end());
    core.applyProjectEdit(std::move(p));
    undoHistory.push_back(before);
    if (undoHistory.size() > 40)
        undoHistory.erase(undoHistory.begin());
    redoHistory.clear();
    dirty = true;
    if (rebuild)
        prepare();
    else if (song())
        audio.setMixer(project(), *song());
    notify();
}
void Session::configureEffects(const ID &id, const var &settings) {
    if (busy)
        return;
    syncClock();
    auto before = snapshot();
    auto p = project();
    const auto json = utf8(JSON::toString(settings, true));
    bool found = id.empty();
    if (id.empty())
        p.masterFXJSON = json;
    else
        for (auto &song : p.songs)
            for (auto &track : song.tracks)
                if (track.id == id) {
                    track.fxJSON = json;
                    found = true;
                }
    if (!found)
        throw std::runtime_error("A faixa deste efeito não existe mais.");
    jaras::validate(p);
    audio.setEffects(id, settings);
    core.applyProjectEdit(std::move(p));
    undoHistory.push_back(before);
    if (undoHistory.size() > 40)
        undoHistory.erase(undoHistory.begin());
    redoHistory.clear();
    dirty = true;
    notify();
}
void Session::configureTiming(double bpm, int beats, int unit,
                              jaras::ProjectTimeSettings settings) {
    if (busy || audio.isRecording() || transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare a reprodução antes de alterar o tempo do projeto.");
    auto before = snapshot();
    core.setProjectTiming(bpm, beats, unit, settings);
    undoHistory.push_back(std::move(before));
    if (undoHistory.size() > 40)
        undoHistory.erase(undoHistory.begin());
    redoHistory.clear();
    dirty = true;
    prepare();
    notify();
}
void Session::restoreSnapshot(const var &raw) {
    auto p = ProjectCodec::decode(raw);
    core.execute({jaras::CommandKind::stopAll});
    core.loadProject(p);
    original = raw;
    prepare();
    dirty = true;
    notify();
}
void Session::undo() {
    if (!canUndo() || busy)
        return;
    if (transport().playing)
        throw std::runtime_error("Pare para desfazer alterações.");
    auto value = undoHistory.back();
    redoHistory.push_back(snapshot());
    undoHistory.pop_back();
    restoreSnapshot(value);
}
void Session::redo() {
    if (!canRedo() || busy)
        return;
    if (transport().playing)
        throw std::runtime_error("Pare para refazer alterações.");
    auto value = redoHistory.back();
    undoHistory.push_back(snapshot());
    redoHistory.pop_back();
    restoreSnapshot(value);
}
void Session::importAudio(const Array<File> &files, double at) {
    if (busy || files.isEmpty())
        return;
    if (transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare antes de importar áudio.");
    auto base = snapshot();
    auto songID = song() ? song()->id : ID{};
    auto directory = mediaDirectory;
    busy = true;
    importProgress = 0;
    message = String::fromUTF8("Importando áudio…");
    notify();
    auto weak = std::weak_ptr<int>(alive);
    worker.addJob([this, weak, files, at, songID, directory, base] {
        std::vector<jaras::Track> tracks;
        String error;
        try {
            AudioFormatManager formats;
            formats.registerBasicFormats();
            jaras::TrackTaxonomy taxonomy;
            for (int i = 0; i < files.size(); ++i) {
                const auto &file = files.getReference(i);
                std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
                if (!reader || reader->sampleRate <= 0 || reader->lengthInSamples <= 0)
                    throw std::runtime_error(
                        utf8(String::fromUTF8("Formato de áudio inválido: ") + file.getFileName()));
                jaras::Track t;
                t.id = uuid();
                t.name = utf8(file.getFileNameWithoutExtension());
                t.role = taxonomy.classify(t.name);
                t.color = theme::role(t.role.id).getARGB() & 0xffffff;
                jaras::AudioClip c;
                c.id = uuid();
                c.name = t.name;
                c.startTime = std::max(0.0, at);
                c.duration = (double)reader->lengthInSamples / reader->sampleRate;
                auto relative = "Stems/" + text(c.id) + file.getFileExtension().toLowerCase();
                auto dest = directory.getChildFile(relative);
                dest.getParentDirectory().createDirectory();
                if (!file.copyFileTo(dest))
                    throw std::runtime_error("Não foi possível copiar o áudio para o projeto.");
                c.audioFile = jaras::AudioFile{utf8(relative), {}};
                c.waveform = waveform(*reader);
                t.clips.push_back(std::move(c));
                tracks.push_back(std::move(t));
                MessageManager::callAsync([this, weak, i, total = files.size()] {
                    if (!weak.expired()) {
                        importProgress = (double)(i + 1) / total;
                        if (changed)
                            changed();
                    }
                });
            }
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
        }
        MessageManager::callAsync(
            [this, weak, songID, base, tracks = std::move(tracks), error]() mutable {
                if (weak.expired())
                    return;
                busy = false;
                if (error.isNotEmpty()) {
                    message = error;
                    notify();
                    return;
                }
                try {
                    edit([&](jaras::Project &p) {
                        for (auto &s : p.songs)
                            if (s.id == songID) {
                                bool hadClips = false;
                                for (auto &t : s.tracks)
                                    hadClips |= !t.clips.empty();
                                if (!hadClips)
                                    s.duration = 1;
                                for (auto &t : tracks) {
                                    for (auto &c : t.clips)
                                        s.duration = std::max(s.duration, c.startTime + c.duration);
                                    s.tracks.push_back(std::move(t));
                                }
                            }
                    });
                    message =
                        String::fromUTF8("Áudio importado · ") + String(tracks.size()) + " pistas";
                    notify();
                } catch (const std::exception &e) {
                    message = String::fromUTF8(e.what());
                    notify();
                }
            });
    });
}
void Session::addTrack(String name, String role) {
    auto id = song() ? song()->id : ID{};
    edit([&](jaras::Project &p) {
        for (auto &s : p.songs)
            if (s.id == id) {
                if (s.tracks.size() >= 512)
                    throw std::runtime_error("Track limit reached.");
                jaras::Track t;
                t.id = uuid();
                t.name = utf8(name);
                t.role.id = utf8(role);
                s.tracks.push_back(t);
            }
    });
}
void Session::importVideo(const File &source, double duration) {
    if (busy)
        return;
    if (transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Stop before importing video.");
    if (!source.existsAsFile() || !std::isfinite(duration) || duration <= 0)
        throw std::runtime_error("Invalid video.");
    auto songID = song() ? song()->id : ID{};
    auto at = transport().position;
    auto clipID = uuid();
    auto relative = "Videos/" + text(clipID) + source.getFileExtension();
    auto dest = mediaDirectory.getChildFile(relative);
    auto weak = std::weak_ptr<int>(alive);
    busy = true;
    message = "Importing video...";
    notify();
    worker.addJob([this, weak, source, dest, relative, duration, at, songID, clipID] {
        String error;
        dest.getParentDirectory().createDirectory();
        if (!source.copyFileTo(dest))
            error = "Unable to copy video.";
        MessageManager::callAsync([this, weak, source, relative, duration, at, songID, clipID,
                                   error] {
            if (weak.expired())
                return;
            busy = false;
            if (error.isNotEmpty()) {
                message = error;
                notify();
                return;
            }
            try {
                edit([&](jaras::Project &p) {
                    for (auto &s : p.songs)
                        if (s.id == songID) {
                            auto found = std::find_if(s.tracks.begin(), s.tracks.end(),
                                                      [](auto &t) { return t.role.id == "video"; });
                            if (found == s.tracks.end()) {
                                jaras::Track t;
                                t.id = uuid();
                                t.name = "Video";
                                t.role.id = "video";
                                s.tracks.push_back(t);
                                found = std::prev(s.tracks.end());
                            }
                            double start = at;
                            for (auto &item : found->clips)
                                if (start < item.startTime + item.duration &&
                                    start + duration > item.startTime)
                                    start = item.startTime + item.duration;
                            jaras::AudioClip clip;
                            clip.id = clipID;
                            clip.name = utf8(source.getFileNameWithoutExtension());
                            clip.startTime = start;
                            clip.duration = duration;
                            clip.audioFile = jaras::AudioFile{utf8(relative), {}};
                            found->clips.push_back(clip);
                            s.duration = std::max(s.duration, start + duration);
                        }
                });
                message = "Video imported.";
            } catch (const std::exception &e) {
                message = String::fromUTF8(e.what());
            }
            notify();
        });
    });
}
void Session::exportMix(const File &destination, int bits) {
    if (!song())
        return;
    ExportRequest request;
    request.directory = destination.getParentDirectory();
    request.encodings[0].bits = bits;
    ExportJob job;
    job.name = destination.getFileName();
    job.end = song()->duration;
    request.jobs = {job};
    exportAudio(std::move(request));
}
void Session::exportAudio(ExportRequest request) {
    if (busy || !song())
        return;
    if (transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare a reprodução antes de exportar.");
    if (canPlay && !canPlay())
        throw std::runtime_error("Valide sua licença para exportar áudio.");
    const auto projectCopy = project();
    const auto songCopy = *song();
    const auto directory = mediaDirectory;
    exportCancelled = false;
    busy = true;
    importProgress = 0;
    message = String::fromUTF8("Renderizando áudio…");
    notify();
    auto weak = std::weak_ptr<int>(alive);
    worker.addJob([this, weak, projectCopy, songCopy, directory, request = std::move(request)] {
        String error;
        try {
            audioExport::render(projectCopy, songCopy, directory, request, exportCancelled,
                                [this, weak](double progress) {
                                    MessageManager::callAsync([this, weak, progress] {
                                        if (!weak.expired()) {
                                            importProgress = progress;
                                            if (changed)
                                                changed();
                                        }
                                    });
                                });
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
        }
        MessageManager::callAsync([this, weak, error, count = (int)request.jobs.size()] {
            if (weak.expired())
                return;
            busy = false;
            message = error.isEmpty()
                          ? String::fromUTF8("Exportação concluída: ") + String(count) + " arquivos"
                          : error;
            notify();
        });
    });
}
void Session::addSong(String name) {
    edit([&](jaras::Project &p) {
        auto s = emptySong(name);
        if (!p.setlists.empty())
            p.setlists.front().songIds.push_back(s.id);
        p.songs.push_back(s);
    });
}
void Session::renameTrack(ID id, String name) {
    edit(
        [&](jaras::Project &p) {
            for (auto &s : p.songs)
                for (auto &t : s.tracks)
                    if (t.id == id)
                        t.name = utf8(name);
        },
        false);
}
void Session::removeTrack(ID id) {
    edit([&](jaras::Project &p) {
        for (auto &s : p.songs)
            trackTree::remove(s, id);
    });
}
void Session::removeClip(ID id) {
    edit([&](jaras::Project &p) {
        for (auto &s : p.songs)
            for (auto &t : s.tracks)
                t.clips.erase(std::remove_if(t.clips.begin(), t.clips.end(),
                                             [&](auto &c) { return c.id == id; }),
                              t.clips.end());
    });
}
void Session::addMarker(String name, double position, bool section) {
    auto id = song() ? song()->id : ID{};
    edit([&](jaras::Project &p) {
        for (auto &s : p.songs)
            if (s.id == id) {
                if (!s.markers)
                    s.markers.emplace();
                jaras::TimelineMarker m;
                m.id = uuid();
                m.name = utf8(name);
                m.position = jlimit(0.0, s.duration, position);
                m.color = 0xffdc52;
                m.section = section;
                s.markers->push_back(m);
            }
    });
}
void Session::addRegion(String name, double start, double end) {
    auto id = song() ? song()->id : ID{};
    edit([&](jaras::Project &p) {
        for (auto &s : p.songs)
            if (s.id == id) {
                jaras::Part part;
                part.id = uuid();
                part.name = utf8(name);
                part.startTime = std::max(0.0, start);
                part.endTime = std::min(s.duration, end);
                part.color = 0x66556a;
                s.parts.push_back(part);
            }
    });
}
void Session::reorderTrack(ID id, ID before) {
    edit([&](jaras::Project &p) {
        for (auto &s : p.songs)
            trackTree::move(s, id, before);
    });
}
void Session::reorderSong(ID id, int direction) {
    edit([&](jaras::Project &p) {
        auto it = std::find_if(p.songs.begin(), p.songs.end(), [&](auto &s) { return s.id == id; });
        if (it == p.songs.end())
            return;
        auto i = (int)std::distance(p.songs.begin(), it), next = i + direction;
        if (next < 0 || next >= (int)p.songs.size())
            return;
        std::iter_swap(it, p.songs.begin() + next);
        if (!p.setlists.empty()) {
            p.setlists[0].songIds.clear();
            for (auto &s : p.songs)
                p.setlists[0].songIds.push_back(s.id);
        }
    });
}
void Session::timerCallback() {
    try {
        if (audio.isRecording() && audio.recordedSamples() > 0 && !audio.state().playing) {
            toggleRecording();
            return;
        }
        syncClock();
        if (playbackUpdate)
            playbackUpdate(transport());
        if (tick)
            tick();
    } catch (const std::exception &e) {
        message = String::fromUTF8(e.what());
        core.execute({jaras::CommandKind::stopAll});
        publishTransport();
        notify();
    }
}
void Session::makeInspectionProject(bool withAudioFixture) {
    // Explicit visual fixture only; the regular launch always opens a real empty project.
    inspection = true;
    newProject(String::fromUTF8("CatLive · Visual inspection"));
    if (withAudioFixture) {
        auto file = mediaDirectory.getChildFile("Stems/Inspection.wav");
        file.getParentDirectory().createDirectory();
        auto stream = file.createOutputStream();
        if (!stream)
            throw std::runtime_error("Could not create inspection audio.");
        WavAudioFormat wav;
        std::unique_ptr<AudioFormatWriter> writer(
            wav.createWriterFor(stream.get(), 48000, 1, 24, {}, 0));
        if (!writer)
            throw std::runtime_error("Could not create inspection WAV writer.");
        stream.release();
        AudioBuffer<float> tone(1, 96000);
        for (int i = 0; i < tone.getNumSamples(); ++i)
            tone.setSample(0, i,
                           .5f * (float)std::sin(i * MathConstants<double>::twoPi * 997 / 48000.));
        if (!writer->writeFromAudioSampleBuffer(tone, 0, tone.getNumSamples()))
            throw std::runtime_error("Could not write inspection audio.");
    }
    edit([withAudioFixture](jaras::Project &p) {
        auto &song = p.songs.front();
        song.name = "SHOW AO VIVO";
        song.duration = 240;
        song.bpm = 124;
        for (int i = 0; i < 32; ++i) {
            const StringArray names{
                "Click",   "Guia",     "Drums",         String::fromUTF8("Percussão"),
                "Bass",    "Guitar L", "Guitar R",      "Keys",
                "Strings", "Sanfona",  "Backing Vocal", "FX"};
            const StringArray roles{"click", "guide",     "drums",        "drums",
                                    "bass",  "guitar",    "guitar",       "keys",
                                    "keys",  "accordion", "backingVocal", "fx"};
            jaras::Track t;
            t.id = uuid();
            t.name = utf8(names[i % 12] + (i >= 12 ? " " + String(i / 12 + 1) : String()));
            t.role.id = utf8(roles[i % 12]);
            for (int section = 0; section < 4; ++section) {
                jaras::AudioClip c;
                c.id = uuid();
                c.name = t.name;
                c.startTime = section * 60.;
                c.duration = 58;
                if (withAudioFixture && i == 0 && section == 0)
                    c.audioFile = jaras::AudioFile{"Stems/Inspection.wav", {}};
                for (int j = 0; j < 512; ++j)
                    c.waveform.push_back(.08 + .65 * std::abs(std::sin(j * .63 + i)) *
                                                   std::abs(std::sin(j * .027 + section)));
                t.clips.push_back(c);
            }
            song.tracks.push_back(t);
        }
        for (int i = 0; i < 4; ++i)
            song.parts.push_back(
                {uuid(),
                 utf8(StringArray{"INTRO", "VERSO", String::fromUTF8("REFRÃO"), "FINAL"}[i]),
                 i * 60., (i + 1) * 60., (unsigned)(i % 2 ? 0x77515b : 0x605061)});
        for (int i = 0; i < 24; ++i) {
            song.parts.push_back(
                {uuid(), utf8(String::fromUTF8("Música ") + String(i + 1).paddedLeft('0', 2)),
                 240.0 + i * 60, 300.0 + i * 60, (unsigned)(0x7799aa + i * 111)});
        }
        song.duration = 1680;
        song.markers.emplace();
        for (int part = 0; part < 4; ++part)
            for (int section = 0; section < 2; ++section) {
                jaras::TimelineMarker marker;
                marker.id = uuid();
                marker.name = section == 0 ? "VERSO" : "REFRÃO";
                marker.position = part * 60. + (section + 1) * 20.;
                marker.section = true;
                song.markers->push_back(marker);
            }
        for (int i = 0; i < 24; ++i) {
            auto extra = emptySong(String::fromUTF8("Música ") + String(i + 1).paddedLeft('0', 2));
            p.setlists[0].songIds.push_back(extra.id);
            p.songs.push_back(extra);
        }
    });
    dirty = false;
    message = String::fromUTF8("VISUAL TEST · NO AUDIO");
    notify();
}
} // namespace catlive
