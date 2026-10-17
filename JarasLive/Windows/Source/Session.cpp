#include "Session.h"
#include "MediaSource.h"
#include "ItemRender.h"
#include "Appearance.h"
#include "TrackTree.h"
#include "MediaCleanup.h"
#include "ClickTempo.h"
#include "TempoEditing.h"
#include "RecordingProject.h"
#include "TrackEditing.h"
#include "TimelineMovementLock.h"
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
    p.masterColor = 0x414141;
    p.name = utf8(name.trim().isEmpty() ? "Untitled" : name.trim());
    p.createdAt = p.updatedAt = utf8(Time::getCurrentTime().toISO8601(true));
    p.songs.push_back(emptySong("Timeline"));
    p.setlists.push_back({uuid(), p.name, {p.songs.front().id}});
    subCursorPreviewUntil = 0;
    focusedRegion.reset(); ++setlistFocusRevision;
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
void Session::createRecordingProject(String name, int channels, const File &target) {
    if (busy || audio.isRecording() || transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare a reprodução e aguarde antes de criar um projeto.");
    if (target.existsAsFile())
        throw std::runtime_error("Já existe um projeto neste local. Escolha outro nome.");
    auto project = makeRecordingProject(name, channels);
    // Build and write before replacing the open session. Failure leaves it intact.
    const auto raw = ProjectCodec::encode(project);
    ProjectCodec::write(target, raw);
    load(target);
    for (const auto &track : song()->tracks)
        recordArms[track.id] = 1;
    updateRecordArms();
    notify();
}
void Session::prepare() {
    fadeoutRequested = false;
    fadeoutTracks.clear();
    audio.cancelTrackFadeout();
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
        subCursorPreviewUntil = 0;
    focusedRegion.reset(); ++setlistFocusRevision;
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
void Session::warnTransportFadeout(String warning) {
    if (transportFadeoutWarning) transportFadeoutWarning(warning);
    else message = warning;
}
void Session::toggleTransportFadeout(bool enabled, const std::set<ID> &tracks, double seconds) {
    if (fadeoutRequested) { cancelTransportFadeout(); return; }
    if (!enabled) { warnTransportFadeout("Ative Fadeout no clique direito do Play."); return; }
    if (transport().subPlay.playing) { warnTransportFadeout("Pare o Subplay antes de iniciar o Fadeout."); return; }
    if (!transport().playing) { warnTransportFadeout(String::fromUTF8("O Fadeout funciona com o transporte em reprodução.")); return; }
    if (busy || !song()) return;
    if (!std::isfinite(seconds) || seconds < 1 || seconds > 5) {
        warnTransportFadeout(String::fromUTF8("Escolha uma duração de 1 a 5 segundos.")); return;
    }
    if (!inspection && !audio.devices.getCurrentAudioDevice()) {
        warnTransportFadeout(String::fromUTF8("Selecione um dispositivo de áudio antes de iniciar o Fadeout.")); return;
    }
    std::set<ID> selected;
    for (const auto &track : song()->tracks) if (tracks.count(track.id) &&
        !jaras::isTeleprompterRole(track.role) && track.role.id != "video" &&
        track.role.id != "timecode" && track.role.id != "chords") selected.insert(track.id);
    if (selected.empty()) { warnTransportFadeout("Escolha pelo menos uma pista para o Fadeout."); return; }
    audio.startTrackFadeout(selected, seconds);
    fadeoutTracks = std::move(selected); fadeoutDuration = seconds; fadeoutRequested = true;
    if (tick) tick();
}
void Session::cancelTransportFadeout() {
    audio.cancelTrackFadeout(); fadeoutRequested = false; fadeoutTracks.clear();
    if (tick) tick();
}
bool Session::trackFaderLocked(const ID &id) const {
    if (!fadeoutRequested) return false;
    if (fadeoutTracks.count(id)) return true;
    if (const auto *current = song())
        for (const auto &track : current->tracks)
            if (track.id == id && track.stereoLinkPartner && fadeoutTracks.count(*track.stereoLinkPartner))
                return true;
    return false;
}
void Session::updateTransportFadeout() {
    if (!fadeoutRequested) return;
    if (!transport().playing || !audio.trackFadeoutActive()) { cancelTransportFadeout(); return; }
    if (!busy && audio.trackFadeoutComplete()) {
        // Keep zero in the audio path while stopped, including FX tails. The
        // visible/saved faders return immediately; the next Play releases it.
        const ScopedValueSetter<bool> completing(completingFadeout, true);
        command(jaras::CommandKind::stop);
        fadeoutRequested = false; fadeoutTracks.clear();
        if (tick) tick();
    }
}
std::optional<std::pair<double,double>> Session::selectedTimeRange() const {
    if (!timeSelection || timeSelection->project != project().id || !song() || timeSelection->song != song()->id) return {};
    return std::pair<double,double>{timeSelection->start,timeSelection->end};
}
void Session::clearTimeRange() { timeSelection.reset(); }
void Session::selectTimeRange(double from, double to) {
    if (busy || !song() || !std::isfinite(from) || !std::isfinite(to)) return;
    if (audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de alterar a área de loop.");
    const double start=std::max(0.,std::min(from,to)), end=std::max(0.,std::max(from,to));
    if (end<=start) { clearTimeRange(); return; }
    timeSelection=TimeSelection{project().id,song()->id,start,end};
    if (transport().loop.enabled && !transport().multiLoop) {
        syncClock();
        core.execute({jaras::CommandKind::loopStart,{},start});
        core.execute({jaras::CommandKind::loopEnd,{},end});
        publishTransport();
    }
}
void Session::command(jaras::CommandKind kind, const ID &target, double value) {
    if (fadeoutRequested && kind == jaras::CommandKind::subPlay) {
        warnTransportFadeout(String::fromUTF8("Subplay indisponível enquanto o Fadeout está acontecendo.")); return;
    }
    if (kind == jaras::CommandKind::volume && trackFaderLocked(target)) return;
    if (busy)
        return;
    if (audio.isRecording() &&
        (kind == jaras::CommandKind::stopAll || kind == jaras::CommandKind::stop ||
         kind == jaras::CommandKind::pause)) {
        toggleRecording();
        if (fadeoutRequested && !completingFadeout) cancelTransportFadeout();
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
    const bool wasPlaying = transport().playing;
    const bool cancellingTransport = transport().loop.enabled || transport().queuedSectionMarkerId ||
                                     transport().queuedRegionId || transport().queue.songId;
    if (kind == jaras::CommandKind::toggleLoop && !transport().loop.enabled)
        if (const auto range=selectedTimeRange()) {
            core.execute({jaras::CommandKind::loopStart,{},range->first});
            core.execute({jaras::CommandKind::loopEnd,{},range->second});
        }
    core.execute({kind, target, value});
    if (kind == jaras::CommandKind::escape && !cancellingTransport) clearTimeRange();
    if (old != transport().songId) clearTimeRange();
    if (start && (transport().playing || transport().subPlay.playing) &&
        !fadeoutRequested && audio.trackFadeoutComplete())
        audio.cancelTrackFadeout();
    if (kind == jaras::CommandKind::subSeek) subCursorPreviewUntil = Time::getMillisecondCounterHiRes() + 2000;
    if (old != transport().songId) subCursorPreviewUntil = 0;
    if (old != transport().songId)
        prepare();
    if (old != transport().songId) { focusedRegion.reset(); ++setlistFocusRevision; }
    if (kind == jaras::CommandKind::editSeek || (kind == jaras::CommandKind::queueSection && !transport().playing))
        focusTimelineRegion(transport().editPosition);
    else if (kind == jaras::CommandKind::seek || (kind == jaras::CommandKind::play && !wasPlaying))
        focusTimelineRegion(transport().position, true);
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
    if (fadeoutRequested && !completingFadeout && !transport().playing) cancelTransportFadeout();
    notify();
}
void Session::focusTimelineRegion(double position, bool force) {
    const auto *current = song();
    if (!current) return;
    const jaras::Part *root = nullptr;
    for (const auto &part : current->parts)
        if (!part.parentRegionID && position >= part.startTime && position < part.endTime &&
            (!root || part.endTime - part.startTime < root->endTime - root->startTime)) root = &part;
    std::optional<ID> next;
    if (root) {
        const jaras::Part *child = nullptr;
        for (const auto &part : current->parts)
            if (part.parentRegionID == root->id && position >= part.startTime && position < part.endTime &&
                (!child || part.startTime > child->startTime || (part.startTime == child->startTime && part.endTime > child->endTime))) child = &part;
        next = child ? child->id : root->id;
        auto state = project().regionSetlist.value_or(jaras::RegionSetlist{});
        for (const auto &playlist : state.playlists)
            if (state.selectedId == playlist.id && playlist.songId == current->id &&
                std::find(playlist.regionIds.begin(), playlist.regionIds.end(), root->id) == playlist.regionIds.end()) {
                state.selectedId.reset();
                auto before = snapshot();
                core.configureRegionSetlist(std::move(state));
                undoHistory.push_back(std::move(before));
                if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
                redoHistory.clear(); dirty = true; force = true;
                break;
            }
    }
    if (focusedRegion != next || force) { focusedRegion = next; ++setlistFocusRevision; }
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
        const auto directory = mediaDirectory;
        const auto projectID = project().id, songID = recordingSong;
        const auto start = recordingStart;
        const auto drops = audio.recordingOverflows();
        const std::weak_ptr<int> lifetime = alive;
        busy = true;
        message = String::fromUTF8("Finalizando gravação…");
        notify();
        worker.addJob([this, lifetime, directory, projectID, songID, start, drops,
                       takes = std::move(takes)]() mutable {
            std::vector<std::pair<ID, jaras::AudioClip>> clips;
            StringArray failures;
            AudioFormatManager formats;
            registerAudioFormats(formats);
            for (auto &take : takes) {
                if (take.duration <= 0) continue;
                if (take.encodedFile != File()) {
                    try { TrackCapture::finalizeEncoding(take); }
                    catch (const std::exception &failure) {
                        failures.add(String::fromUTF8("MP3 não concluído; take WAV preservado: ") +
                                     take.file.getFullPathName() + " (" + String::fromUTF8(failure.what()) + ")");
                        continue; // Preserve raw capture; never present failed MP3 as a successful WAV take.
                    }
                }
                jaras::AudioClip clip;
                clip.id = uuid();
                clip.startTime = start;
                clip.duration = take.duration;
                clip.name = utf8(take.file == File() ? String("MIDI take")
                                                     : take.file.getFileNameWithoutExtension());
                if (take.midi) clip.midi = std::move(take.midi);
                else {
                    clip.audioFile = jaras::AudioFile{
                        utf8(take.file.getRelativePathFrom(directory).replaceCharacter('\\', '/')), {}};
                    try {
                        if (auto reader = std::unique_ptr<AudioFormatReader>(formats.createReaderFor(take.file)))
                            clip.waveform = waveform(*reader);
                        else failures.add(String::fromUTF8("Não foi possível analisar o take: ") + take.file.getFileName());
                    } catch (const std::exception &failure) {
                        failures.add(String::fromUTF8(failure.what()));
                    }
                }
                clips.emplace_back(take.track, std::move(clip));
            }
            MessageManager::callAsync([this, lifetime, projectID, songID, drops,
                                       clips = std::move(clips), failures] {
                if (lifetime.expired()) return;
                busy = false;
                if (project().id != projectID) { notify(); return; }
                try {
                    if (!clips.empty()) edit([&](jaras::Project &project) {
                        for (auto &song : project.songs) if (song.id == songID)
                            for (auto &track : song.tracks)
                                for (const auto &[id, clip] : clips) if (track.id == id) {
                                    track.clips.push_back(clip);
                                    song.duration = std::max(song.duration, clip.startTime + clip.duration);
                                }
                    });
                    message = !failures.isEmpty()
                        ? String::fromUTF8("A gravação não foi concluída em todas as pistas.")
                        : drops ? String::fromUTF8("Gravação concluída com perda de blocos. Verifique os takes antes de usar.")
                                : String::fromUTF8("Gravação adicionada às pistas armadas.");
                    if (!failures.isEmpty()) message += " " + failures.joinIntoString(String::fromUTF8(" · "));
                } catch (const std::exception &failure) { message = String::fromUTF8(failure.what()); }
                notify();
            });
        });
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
    const auto advancedFormat = utf8(settings.value("jaras.media.record.format", "WAV").toString());
    const int bits = (int)settings.value("jaras.media.record.bits", 24);
    const int bitrate = (int)settings.value("jaras.media.record.bitrate", 320);
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
            const auto encoding = recordingEncoding::resolve(track.recordingFormat, advancedFormat, bits, bitrate);
            if (!target.midi)
                target.file = mediaDirectory.getChildFile("Stems/Recordings")
                                  .getNonexistentChildFile(
                                      File::createLegalFileName(text(track.name)) + "-" +
                                          Time::getCurrentTime().formatted("%Y%m%d-%H%M%S") + "-" +
                                          text(uuid()).substring(0, 8), text(encoding.extension));
            target.bits = encoding.bits;
            target.floatingPoint = encoding.floatingPoint;
            target.bitrate = encoding.bitrate;
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
void Session::detectRegionBPM(std::set<ID> ids) {
    if (busy || !song() || ids.empty()) return;
    if (audio.isRecording() || transport().playing || transport().subPlay.playing)
        throw std::runtime_error("Pare a reprodução antes de detectar o BPM.");
    const auto sourceSong = *song(); const auto projectID = project().id;
    const auto directory = mediaDirectory; const std::weak_ptr<int> lifetime = alive;
    exportCancelled = false; busy = true; message = String::fromUTF8("Detectando BPM…"); notify();
    worker.addJob([this, sourceSong, projectID, directory, ids, lifetime] {
        std::map<ID, std::vector<jaras::TimelineMarker>> detected;
        std::map<std::string, std::vector<clickTempo::Transient>> cached;
        StringArray failures;
        for (const auto &part : sourceSong.parts) if (ids.count(part.id)) {
            if (lifetime.expired() || exportCancelled.load()) return;
            try {
                auto values = clickTempo::markers(sourceSong, part, [&](const auto &file) {
                    auto found = cached.find(file.path);
                    if (found == cached.end()) found = cached.emplace(file.path, clickTempo::transients(ProjectCodec::resolveMedia(directory, file.path), &exportCancelled)).first;
                    return found->second;
                }, &exportCancelled);
                if (values.empty()) failures.add(text(part.name) + String::fromUTF8(": Nenhum andamento estável encontrado na pista Click."));
                else detected.emplace(part.id, std::move(values));
            } catch (const std::exception &e) { failures.add(text(part.name) + ": " + String::fromUTF8(e.what())); }
        }
        MessageManager::callAsync([this, lifetime, projectID, songID=sourceSong.id, detected=std::move(detected), failures] {
            if (lifetime.expired()) return;
            busy = false;
            if (project().id != projectID || !song() || song()->id != songID) { notify(); return; }
            try {
                if (!detected.empty()) edit([&](jaras::Project &project) {
                    for (auto &song : project.songs) if (song.id == songID)
                        for (const auto &part : song.parts) if (auto at=detected.find(part.id); at!=detected.end()) clickTempo::insert(song,part,at->second);
                });
                message = failures.joinIntoString(String::fromUTF8(" · "));
            } catch (const std::exception &e) { message = String::fromUTF8(e.what()); }
            notify();
        });
    });
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
std::vector<ID> Session::duplicateTracks(const std::set<ID> &targets) {
    if (busy || !song() || targets.empty()) return {};
    const auto result = trackEditing::duplicateDocument(snapshot(), song()->id, targets);
    if (result.trackIDs.empty()) return {};
    edit([&](jaras::Project &p) { p = ProjectCodec::decode(result.document); });
    original = result.document;
    notify();
    return result.trackIDs;
}
void Session::edit(const std::function<void(jaras::Project &)> &change, bool rebuild, bool allowTimingEdit) {
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
    if (!allowTimingEdit && timelineGrid::changesLockedGeometry(project(), p))
        throw std::runtime_error("Desbloqueie o cadeado para mover ou redimensionar itens, regiões e marcadores.");
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
    configureEffects(std::map<ID, var>{{id, settings}});
}
std::map<ID, var> Session::currentEffects(const std::map<ID, var> &targets) const {
    std::map<ID, var> result;
    for (const auto &[id, ignored] : targets) {
        if (id.empty()) result[id] = project().masterFXJSON ? JSON::parse(text(*project().masterFXJSON)) : var();
        else for (const auto &song : project().songs) for (const auto &track : song.tracks)
            if (track.id == id) result[id] = track.fxJSON ? JSON::parse(text(*track.fxJSON)) : var();
    }
    return result;
}
void Session::configureEffects(const std::map<ID, var> &changes) { applyEffects(changes, true); }
void Session::applyEffects(const std::map<ID, var> &changes, bool recordHistory) {
    if (busy || changes.empty())
        return;
    syncClock();
    auto before = currentEffects(changes);
    auto p = project();
    for (const auto &[id, settings] : changes) {
        const std::optional<std::string> json = settings.isVoid() ? std::nullopt : std::optional<std::string>(utf8(JSON::toString(settings, true)));
        bool found = id.empty();
        if (id.empty()) p.masterFXJSON = json;
        else for (auto &song : p.songs) for (auto &track : song.tracks) if (track.id == id) {
            track.fxJSON = json; found = true;
        }
        if (!found) throw std::runtime_error("A faixa deste efeito não existe mais.");
    }
    jaras::validate(p);
    for (const auto &[id, settings] : changes) audio.setEffects(id, settings);
    core.applyProjectEdit(std::move(p));
    if (recordHistory) {
        undoHistory.emplace_back(std::move(before));
        if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
        redoHistory.clear();
    }
    dirty = true;
    notify();
}
double Session::tempoBPM() const {
    return song() ? tempoEditing::bpm(*song(), tempoEditing::position(*song(), transport())) : 120;
}
void Session::setTempo(double value) {
    if (busy || !song() || !std::isfinite(value)) return;
    if (audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de alterar o andamento.");
    syncClock();
    value = jlimit(60., 300., value);
    if (std::abs(value - tempoBPM()) < .0000001) return;
    const auto before = snapshot();
    const auto oldSong = *song();
    if (const auto *part = tempoEditing::region(oldSong, transport())) {
        const auto targets = tempoEditing::regionChange(oldSong, *part, value - tempoBPM());
        if (targets.empty()) return;
        core.setMarkers(targets, {}, true);
    } else if (const auto *active = tempoEditing::active(oldSong, tempoEditing::position(oldSong, transport()))) {
        auto marker = *active; marker.tempoBPM = value;
        core.setMarkers({marker}, {}, true);
    } else core.setProjectTiming(value, oldSong.beatsPerBar, oldSong.beatUnit, oldSong.timeSettings);
    bool retimed = false;
    const auto &updated = *song();
    for (size_t i = 0; i < oldSong.tracks.size(); ++i)
        for (size_t j = 0; j < oldSong.tracks[i].clips.size(); ++j) {
            const auto &old = oldSong.tracks[i].clips[j];
            const auto &now = updated.tracks[i].clips[j];
            retimed |= old.startTime != now.startTime || old.duration != now.duration || old.playbackRate != now.playbackRate;
        }
    if (retimed) prepare();
    else { audio.refreshTiming(updated); publishTransport(); }
    undoHistory.push_back(before);
    if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
    redoHistory.clear(); dirty = true; message.clear(); notify();
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
    if (transport().playing || transport().subPlay.playing) core.execute({jaras::CommandKind::stopAll});
    if (p.id == project().id) core.applyProjectEdit(std::move(p));
    else core.loadProject(std::move(p));
    original = raw;
    prepare();
    dirty = true;
    notify();
}
void Session::undo() {
    if (!canUndo() || busy)
        return;
    if (audio.isRecording() || ((transport().playing || transport().subPlay.playing) &&
        !undoHistory.back().effects))
        throw std::runtime_error("Pare para desfazer alterações.");
    auto value = undoHistory.back();
    if (value.effects) redoHistory.emplace_back(currentEffects(*value.effects));
    else redoHistory.emplace_back(snapshot());
    undoHistory.pop_back();
    if (value.effects) applyEffects(*value.effects, false);
    else restoreSnapshot(value.project);
}
void Session::redo() {
    if (!canRedo() || busy)
        return;
    if (audio.isRecording() || ((transport().playing || transport().subPlay.playing) &&
        !redoHistory.back().effects))
        throw std::runtime_error("Pare para refazer alterações.");
    auto value = redoHistory.back();
    if (value.effects) undoHistory.emplace_back(currentEffects(*value.effects));
    else undoHistory.emplace_back(snapshot());
    redoHistory.pop_back();
    if (value.effects) applyEffects(*value.effects, false);
    else restoreSnapshot(value.project);
}
void Session::importAudio(const Array<File> &files, double at) { importMedia(files,at,{},false,0); }
void Session::importMedia(const Array<File> &files,double at,ID targetTrack,bool sameTrack,double gap) {
    if(busy||files.isEmpty())return;
    if(transport().playing||transport().subPlay.playing)throw std::runtime_error("Pare antes de importar mídia.");
    if(!song()||!std::isfinite(at)||at<0||!std::isfinite(gap)||gap<0||gap>60)throw std::runtime_error("Posição ou intervalo de importação inválido.");
    auto songID=song()->id,projectID=project().id;auto directory=mediaDirectory;
    auto target=std::find_if(song()->tracks.begin(),song()->tracks.end(),[&](auto &t){return t.id==targetTrack;});
    if(!targetTrack.empty()&&target==song()->tracks.end())throw std::runtime_error("A pista de destino não existe mais.");
    const auto targetRole=target==song()->tracks.end()?jaras::TrackRole{}:target->role;
    auto weak=std::weak_ptr<int>(alive);busy=true;importProgress=0;message=String::fromUTF8("Importando mídia…");notify();
    worker.addJob([this,weak,files,at,targetTrack,sameTrack,gap,songID,projectID,directory,targetRole]{
        struct Source {File file;double duration;bool projection;};
        std::vector<Source> sources;std::vector<jaras::Track> tracks;Array<File> copied;String error;
        try {
            AudioFormatManager formats;registerAudioFormats(formats);
            // Validate the whole batch before copying any media.
            for(const auto &file:files) {
                if(!file.existsAsFile())throw std::runtime_error("Selecione arquivos de mídia, não pastas.");
                if(std::any_of(sources.begin(),sources.end(),[&](auto &s){return s.file==file;}))continue;
                double duration=0;bool projection=false;
                if(file.hasFileExtension("png;jpg;jpeg;bmp;gif;tif;tiff")) {
                    if(!ImageFileFormat::loadFrom(file).isValid())throw std::runtime_error("Imagem inválida: "+utf8(file.getFileName()));
                    duration=10;projection=true;
                } else if(file.hasFileExtension("mp4;mov;m4v;avi;mkv;webm;wmv")) {
                    auto info=inspectMediaSource(file);duration=info.duration;projection=info.video;
                    if(!info.audio&&!info.video)throw std::runtime_error("Mídia sem áudio ou vídeo.");
                    if(info.audio){std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));if(!reader)throw std::runtime_error("Não foi possível decodificar o áudio do vídeo.");}
                } else {
                    std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
                    if(!reader||reader->sampleRate<=0)throw std::runtime_error("Arquivo de mídia não suportado: "+utf8(file.getFileName()));
                    duration=reader->lengthInSamples/reader->sampleRate;
                }
                if(!std::isfinite(duration)||duration<=0)throw std::runtime_error("Arquivo de mídia vazio.");
                if(!projection&&!jaras::fixedTrackName(targetRole).empty())throw std::runtime_error("Solte arquivos de áudio em uma pista padrão.");
                if(!sources.empty()&&sources.front().projection!=projection)throw std::runtime_error("Arraste áudio e vídeo separadamente.");
                sources.push_back({file,duration,projection});
            }
            double cursor=at;
            for(size_t i=0;i<sources.size();++i) {
                const auto &source=sources[i];jaras::AudioClip clip;clip.id=uuid();clip.name=utf8(source.file.getFileNameWithoutExtension());clip.startTime=sameTrack?cursor:at;clip.duration=source.duration;
                auto relative=String(source.projection?"Videos/":"Stems/")+text(clip.id)+source.file.getFileExtension().toLowerCase();
                auto destination=directory.getChildFile(relative);destination.getParentDirectory().createDirectory();copied.add(destination);
                if(!source.file.copyFileTo(destination))throw std::runtime_error("Não foi possível copiar a mídia para o projeto.");
                clip.audioFile=jaras::AudioFile{utf8(relative),{}};
                if(!source.projection){std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(source.file));if(!reader)throw std::runtime_error("Não foi possível ler o áudio.");clip.waveform=waveform(*reader);}
                if(!sameTrack||tracks.empty()){jaras::Track track;track.id=i==0&&!targetTrack.empty()?targetTrack:uuid();track.name=clip.name;track.role.id=i==0&&!targetTrack.empty()?targetRole.id:"other";track.color=0x828282;tracks.push_back(std::move(track));}
                tracks.back().clips.push_back(std::move(clip));cursor+=source.duration+gap;
                MessageManager::callAsync([this,weak,i,total=sources.size()]{if(!weak.expired()){importProgress=double(i+1)/total;if(changed)changed();}});
            }
        }catch(const std::exception &e){error=String::fromUTF8(e.what());}
        MessageManager::callAsync([this,weak,tracks=std::move(tracks),copied,songID,projectID,targetTrack,error]()mutable{
            if(weak.expired()){for(auto &f:copied)f.deleteFile();return;}
            busy=false;
            try {
                if(error.isNotEmpty())throw std::runtime_error(utf8(error));
                if(project().id!=projectID)throw std::runtime_error("O projeto mudou durante a importação.");
                edit([&](jaras::Project &project){
                    auto song=std::find_if(project.songs.begin(),project.songs.end(),[&](auto &s){return s.id==songID;});
                    if(song==project.songs.end())throw std::runtime_error("O grid de destino não existe mais.");
                    if(!targetTrack.empty()&&std::none_of(song->tracks.begin(),song->tracks.end(),[&](auto &t){return t.id==targetTrack;}))throw std::runtime_error("A pista de destino não existe mais.");
                    for(auto &imported:tracks){
                        auto found=std::find_if(song->tracks.begin(),song->tracks.end(),[&](auto &t){return t.id==imported.id;});
                        if(found==song->tracks.end()){if(song->tracks.size()>=512)throw std::runtime_error("Limite de pistas atingido.");song->tracks.push_back(std::move(imported));found=std::prev(song->tracks.end());}
                        else {
                            // Move the batch as a unit past existing material, preserving
                            // the user's sequence and interval without overlapping items.
                            double shift=0;bool collision=true;
                            while(collision){collision=false;for(const auto &clip:imported.clips)for(const auto &existing:found->clips){
                                const bool sameLayer=!jaras::isTeleprompterRole(found->role)||bool(clip.audioFile)==bool(existing.audioFile);
                                if(sameLayer&&clip.startTime+shift<existing.startTime+existing.duration-1e-8&&clip.startTime+shift+clip.duration>existing.startTime+1e-8){shift=existing.startTime+existing.duration-clip.startTime;collision=true;}
                            }}
                            for(auto &clip:imported.clips){clip.startTime+=shift;found->clips.push_back(std::move(clip));}
                        }
                        for(const auto &clip:found->clips)song->duration=std::max(song->duration,clip.startTime+clip.duration);
                        std::stable_sort(found->clips.begin(),found->clips.end(),[](auto &a,auto &b){return a.startTime<b.startTime;});
                    }
                });
                message=String::fromUTF8("Mídia importada.");
            }catch(const std::exception &e){for(auto &f:copied)f.deleteFile();message=String::fromUTF8(e.what());}
            notify();
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
void Session::renderItems(std::set<ID> ids,bool glue,int midiChannels) {
    if(busy || !song() || ids.empty())return;
    if(transport().playing || transport().subPlay.playing || audio.isRecording())throw std::runtime_error("Pare a reprodução antes de renderizar itens.");
    if(canPlay && !canPlay())throw std::runtime_error("Valide sua licença para renderizar áudio.");
    if(!mediaDirectory.isDirectory() || document==File{})throw std::runtime_error("Salve o projeto antes de renderizar itens.");
    const auto source=project();const auto sourceSong=*song();const auto directory=mediaDirectory;
    exportCancelled=false;busy=true;importProgress=0;message=String::fromUTF8(glue?"Unificando itens…":"Renderizando itens…");notify();
    auto weak=std::weak_ptr<int>(alive);
    worker.addJob([this,weak,source,sourceSong,directory,ids,glue,midiChannels] {
        std::vector<itemRender::Replacement> replacements;String error;
        try{replacements=itemRender::render(source,sourceSong,directory,ids,glue,midiChannels,exportCancelled,[this,weak](double progress){MessageManager::callAsync([this,weak,progress]{if(!weak.expired()){importProgress=progress;if(changed)changed();}});});
            AudioFormatManager formats;registerAudioFormats(formats);for(auto &r:replacements)if(r.generated.existsAsFile()){std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(r.generated));if(!reader)throw std::runtime_error("Não foi possível ler o item renderizado.");r.clip.waveform=waveform(*reader);}
        }catch(const std::exception &e){error=String::fromUTF8(e.what());}
        MessageManager::callAsync([this,weak,source,sourceSong,replacements=std::move(replacements),error]() mutable {
            auto discard=[&]{for(const auto &r:replacements)if(r.generated!=File{})r.generated.deleteFile();};
            if(weak.expired()){discard();return;}busy=false;
            if(error.isEmpty() && (project().id!=source.id || !song() || song()->id!=sourceSong.id || exportCancelled.load()))error=String::fromUTF8("Operação cancelada.");
            if(error.isEmpty())try {edit([&](jaras::Project &p){for(auto &s:p.songs)if(s.id==sourceSong.id)for(auto &t:s.tracks)for(const auto &r:replacements)if(t.id==r.track){t.clips.erase(std::remove_if(t.clips.begin(),t.clips.end(),[&](const auto &c){return r.originals.count(c.id)>0;}),t.clips.end());t.clips.push_back(r.clip);std::stable_sort(t.clips.begin(),t.clips.end(),[](const auto &a,const auto &b){return a.startTime<b.startTime;});}});}
            catch(const std::exception &e){error=String::fromUTF8(e.what());}
            if(error.isNotEmpty())discard();message=error;notify();
        });
    });
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
        updateTransportFadeout();
        if (playbackUpdate)
            playbackUpdate(transport());
        if (tick)
            tick();
    } catch (const std::exception &e) {
        message = String::fromUTF8(e.what());
        core.execute({jaras::CommandKind::stopAll});
        publishTransport();
        cancelTransportFadeout();
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
