#include "PlaylistOccurrences.h"
#include "Localization.h"
#include "Session.h"
#include "MediaSource.h"
#include "ItemRender.h"
#include "AudioSeparation.h"
#include "ItemLayout.h"
#include "Appearance.h"
#include "TrackTree.h"
#include "MediaCleanup.h"
#include "ClickTempo.h"
#include "TempoEditing.h"
#include "RecordingProject.h"
#include "TrackEditing.h"
#include "TimelineMovementLock.h"
#include "FXPresets.h"
#include "FXSchema.h"
#include "WaveformCache.h"
#include "ProjectMediaRecovery.h"
#include "ClipEditing.h"
#include "FinishedSetlistSelection.h"
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
            for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
                // Match the Mac overview: decoded MP3 and floating-point PCM
                // may exceed full scale. Bound the drawing, never the audio.
                const double peak = std::abs((double)buffer.getSample(ch, n));
                if (std::isfinite(peak))
                    peaks[bin] = std::max(peaks[bin], std::min(1., peak));
            }
        }
    }
    return peaks;
}
} // namespace
Session::Session(std::shared_ptr<AudioDeviceManager> host) : audio(48000, false, std::move(host)) {
    newProject();
    startTimerHz(8);
}
Session::~Session() {
    stopTimer();
    cancelBPMDetection();
    exportCancelled = true;
    if(loadCancellation)loadCancellation->store(true);
    if(graphCancellation)graphCancellation->store(true);
    alive.reset();
    saveWorker.removeAllJobs(true, -1);
    worker.removeAllJobs(true, 30000);
    bpmWorker.removeAllJobs(true, -1);
}
void Session::notify() {
    ++revision;
    if (changed)
        changed();
}
void Session::notifyTiming(bool geometry) {
    ++revision;
    if (timingChanged) timingChanged(geometry);
    else if (changed) changed();
}
void Session::notifyMixer() {
    ++revision;
    if(mixerChanged)mixerChanged();
    else if(changed)changed();
}
jaras::Project Session::makeEmptyProject(String name) {
    jaras::Project p;
    p.id = uuid();
    p.masterColor = 0x414141;
    p.name = utf8(name.trim().isEmpty() ? "Untitled" : name.trim());
    p.createdAt = p.updatedAt = utf8(Time::getCurrentTime().toISO8601(true));
    p.songs.push_back(emptySong("Timeline"));
    p.setlists.push_back({uuid(), p.name, {p.songs.front().id}});
    return p;
}
void Session::newProject(String name) {
    if (activeSave) throw std::runtime_error("Aguarde o projeto terminar de salvar antes de criar outro.");
    if(jaras::projectSync::readOnly() && (transport().playing || transport().subPlay.playing)) return;
    jaras::projectSync::Internal initialProject;
    if (busy)
        return;
    if (audio.isRecording())
        throw std::runtime_error("Pare a gravação antes de criar outro projeto.");
    cancelBPMDetection();
    core.execute({jaras::CommandKind::stopAll});
    auto p = makeEmptyProject(name);
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
    recordingItems.clear();
    recordArms.clear();
    recordSelections.clear(); endMixerGesture();
    dirty = false;
    message.clear();
    prepare();
    notify();
}
void Session::createRecordingProject(String name, int channels, const File &target) {
    if (busy || audio.isRecording())
        throw std::runtime_error("Conclua a gravação e aguarde antes de criar um projeto.");
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
    if (song() && preparedSong == song()->id &&
        (transport().playing || transport().subPlay.playing || (!inspection && audio.hasLiveDevice()))) {
        prepareLiveGraph();
        return;
    }
    if (graphCancellation) graphCancellation->store(true);
    graphCancellation.reset();
    presentationQueues.reset();
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
    if (activeSave) throw std::runtime_error("Aguarde o projeto terminar de salvar antes de abrir outro.");
    if (busy || audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de abrir outro projeto.");
    auto raw = ProjectCodec::read(file);
    loadPrepared(file, raw, ProjectCodec::decode(raw));
}
void Session::loadPrepared(const File &file, var raw, jaras::Project p) {
    cancelBPMDetection();
    auto previous = snapshot();
    auto previousFile = document, previousMedia = mediaDirectory;
    try {
        core.execute({jaras::CommandKind::stopAll});
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
        message.clear();
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
// Shared preparation work owns all of its inputs and never dereferences a
// Session outside a live message-thread callback. Closing the browser/app can
// cancel it without joining a worker that is waiting for a VST3 UI constructor.
struct ProjectPreparationQueue {
    std::atomic<bool> closing{false};
    ThreadPool jobs{1};
    ~ProjectPreparationQueue() { closing=true; jobs.removeAllJobs(true,-1); }
    bool addJob(std::function<void()> operation) {
        if(closing.load())return false;
        jobs.addJob(std::move(operation));return true;
    }
};
static ProjectPreparationQueue &projectPreparationQueue() {
    static ProjectPreparationQueue queue;
    return queue;
}
void Session::prepareLiveGraph() {
    if (!song()) return;
    if (graphCancellation) graphCancellation->store(true);
    const auto cancellation = std::make_shared<std::atomic<bool>>(false);
    graphCancellation = cancellation;
    const auto weak = std::weak_ptr<int>(alive);
    const auto projectCopy = project();
    const auto songCopy = *song();
    const auto directory = mediaDirectory;
    const auto rate = audio.sampleRate();
    const auto offline = audio.preparesOffline();
    const auto state = audio.state();
    const auto signatureFor = [](const jaras::Project &source) {
        auto metadata = source;
        for (auto &song : metadata.songs) for (auto &track : song.tracks) for (auto &clip : track.clips) {
            clip.waveform.clear(); clip.waveformChannels.clear();
        }
        return JSON::toString(ProjectCodec::encode(metadata));
    };
    const auto signature = signatureFor(projectCopy);
    // The active graph stays connected. Construction, decoding and destruction
    // of the retired graph never run on the callback or the message thread.
    auto prepared = std::shared_ptr<AudioEngine>(new AudioEngine(rate, offline), [](AudioEngine *value) {
        if (!projectPreparationQueue().addJob([value] { delete value; })) delete value;
    });
    projectPreparationQueue().addJob([this, weak, cancellation, prepared, projectCopy, songCopy,
                                      directory, signature, signatureFor, state, offline] {
        String error;
        const auto checkpoint = [weak, cancellation] {
            if (weak.expired() || cancellation->load()) throw NativeFX::PreparationCancelled();
        };
        try {
            AudioEngine::PreparationControl control;
            control.checkpoint = checkpoint;
            control.pluginDispatcher = [checkpoint, weak, cancellation](std::function<void()> operation) {
                checkpoint();
                struct Result { WaitableEvent done; std::exception_ptr error; };
                auto result = std::make_shared<Result>();
                if (!MessageManager::callAsync([weak, cancellation, result, operation = std::move(operation)] {
                    try {
                        if (weak.expired() || cancellation->load()) throw NativeFX::PreparationCancelled();
                        operation();
                    } catch (...) { result->error = std::current_exception(); }
                    result->done.signal();
                })) throw NativeFX::PreparationCancelled();
                while (!result->done.wait(10)) checkpoint();
                checkpoint();
                if (result->error) std::rethrow_exception(result->error);
            };
            checkpoint();
            prepared->prepareSong(songCopy, directory,
                projectCopy.masterFXJSON ? JSON::parse(text(*projectCopy.masterFXJSON)) : var(),
                &projectCopy, &control);
            prepared->setMixer(projectCopy, songCopy);
            if (offline) prepared->setOffline(true);
            prepared->transport(state);
            checkpoint();
        } catch (const std::exception &e) { error = String::fromUTF8(e.what()); }
        catch (...) { error = String::fromUTF8("Não foi possível atualizar o áudio do projeto."); }
        auto commit = std::make_shared<std::function<void()>>();
        const auto weakCommit = std::weak_ptr<std::function<void()>>(commit);
        *commit = [this, weak, cancellation, prepared, signature, signatureFor, error, weakCommit] {
            if (weak.expired() || cancellation->load() || graphCancellation != cancellation) return;
            // A recording started while preparation was in flight: retain its
            // input/FX graph until the take is finalised, then apply the edit.
            if (audio.isRecording()) {
                if (auto retry = weakCommit.lock()) Timer::callAfterDelay(50, [retry] { (*retry)(); });
                return;
            }
            if (error.isEmpty() &&
                (signature != signatureFor(project()) ||
                 audio.sampleRate() != prepared->sampleRate() ||
                 audio.preparesOffline() != prepared->preparesOffline())) {
                prepareLiveGraph(); // Coalesce edits made while the earlier graph was built.
                return;
            }
            try {
                if (error.isNotEmpty()) throw std::runtime_error(utf8(error));
                syncClock();
                if (cancellation->load() || graphCancellation != cancellation) return;
                if (signature != signatureFor(project())) {
                    prepareLiveGraph();
                    return;
                }
                audio.adoptPreparedSong(*prepared, true);
                if (song()) audio.setMixer(project(), *song());
                updateRecordArms();
                publishTransport(true, true);
            } catch (const std::exception &e) { message = String::fromUTF8(e.what()); }
            if (graphCancellation == cancellation) graphCancellation.reset();
            notify();
        };
        MessageManager::callAsync([commit] { (*commit)(); });
    });
}
void Session::loadAsync(const File &file, std::function<void(String, double)> progress,
                        std::function<void()> beforeCommit, std::function<void(String)> completed,
                        std::function<void(StringArray)> missingMedia) {
    if (activeSave) {
        const auto weak = std::weak_ptr<int>(alive);
        waitForSave([this, weak, file, progress, beforeCommit, completed, missingMedia](String error) {
            if (weak.expired()) return;
            if (error.isNotEmpty()) { if (completed) completed(error); return; }
            loadAsync(file, progress, beforeCommit, completed, missingMedia);
        });
        return;
    }
    if (busy) return; // Single flight, including queued clicks on Recent Projects.
    if (audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de abrir outro projeto.");
    cancelBPMDetection();
    busy = true; exportCancelled = false;
    const auto cancellation=std::make_shared<std::atomic<bool>>(false);
    loadCancellation=cancellation;
    message = localization::translate(String::fromUTF8("Carregando projeto…")); importProgress = 0;
    if (progress) progress(message, -1);
    const auto weak = std::weak_ptr<int>(alive);
    const auto sampleRate=audio.sampleRate();
    const auto offline=audio.preparesOffline();
    const bool multiLoopsBypassed=transport().multiLoopsBypassed;
    struct PreparedLoad {
        jaras::Engine core;
        std::unique_ptr<AudioEngine> audio;
        var raw;
        File document,mediaDirectory;
        std::set<std::string> observedMedia;
        std::deque<HistoryEntry> undoHistory,redoHistory;
        ID song;
        String warning;
    };
    // The old document, histories, DSP, SF2 banks and decoders are also retired
    // here after the swap, rather than being destroyed in the UI callback.
    auto prepared=std::shared_ptr<PreparedLoad>(new PreparedLoad,[](PreparedLoad *value) {
        if(!projectPreparationQueue().addJob([value]{delete value;}))delete value;
    });
    prepared->document=file;prepared->mediaDirectory=file.getParentDirectory();
    projectPreparationQueue().addJob([this, weak, cancellation, prepared, sampleRate, offline, multiLoopsBypassed, progress, beforeCommit, completed, missingMedia] {
        String failure;
        const auto checkpoint=[weak,cancellation] {
            if(weak.expired()||cancellation->load())throw NativeFX::PreparationCancelled();
        };
        const auto report = [this, weak, cancellation, progress](String text, double amount) {
            MessageManager::callAsync([this, weak, cancellation, progress, text, amount] {
                if(weak.expired()||loadCancellation!=cancellation||cancellation->load())return;
                message = text; importProgress = amount;
                if (progress) progress(text, amount);
            });
        };
        try {
            checkpoint();
            prepared->raw = ProjectCodec::read(prepared->document);
            auto incoming=ProjectCodec::decode(prepared->raw);
            checkpoint();
            if (missingMedia) {
                auto paths = projectMediaRecovery::missingPaths(incoming, prepared->mediaDirectory);
                if (!paths.isEmpty()) {
                    MessageManager::callAsync([this, weak, cancellation, paths, missingMedia, completed] {
                        if (weak.expired() || loadCancellation != cancellation) return;
                        busy = false; loadCancellation.reset();
                        if (cancellation->load()) {
                            if (completed) completed(String::fromUTF8("Abertura cancelada."));
                            return;
                        }
                        message.clear(); notify();
                        missingMedia(paths);
                    });
                    return;
                }
            }
            // Validate and establish the saved selection on an isolated core.
            // No encode/snapshot of the live project's opaque FX states is needed.
            const auto savedCursor=incoming.savedCursor;
            jaras::projectSync::Internal preparingSavedProject;
            prepared->core.loadProject(std::move(incoming));
            if(multiLoopsBypassed)prepared->core.execute({jaras::CommandKind::toggleMultiLoopBypass});
            const auto &project=prepared->core.project();
            if(savedCursor&&std::any_of(project.songs.begin(),project.songs.end(),[&](const auto &song){return song.id==savedCursor->songID;})) {
                prepared->core.execute({jaras::CommandKind::select,savedCursor->songID});
                prepared->core.execute({jaras::CommandKind::seek,{},savedCursor->position});
                prepared->core.execute({jaras::CommandKind::editSeek,{},savedCursor->position});
            }
            std::set<String> files;
            for (const auto &song : project.songs) for (const auto &track : song.tracks)
                for (const auto &clip : track.clips) {
                    const auto source = clip.audioFile ? clip.audioFile : track.audioFile;
                    if (source && !clip.midi && !jaras::isTeleprompterRole(track.role))
                        files.insert(ProjectCodec::resolveMedia(prepared->mediaDirectory, source->path, false).getFullPathName());
                }
            int done = 0; const auto total = (int)files.size();
            report(localization::translate(String::fromUTF8("Preparing waveforms…")) + " " + "0/" + String(total), total ? 0 : 1);
            for (const auto &path : files) {
                checkpoint();
                WaveformCache::preload(File(path), cancellation.get());
                checkpoint();
                ++done;
                report(localization::translate(String::fromUTF8("Preparing waveforms…")) + " " + String(done) + "/" + String(total), double(done) / total);
            }
            checkpoint();
            prepared->audio=std::make_unique<AudioEngine>(sampleRate,offline);
            AudioEngine::PreparationControl control;
            control.checkpoint=checkpoint;
            double lastReport=-1;
            control.progress=[&](int count,int totalWork) {
                const auto now=Time::getMillisecondCounterHiRes();
                if(count==0||count==totalWork||now-lastReport>=25) {
                    lastReport=now;
                    report(localization::translate(String::fromUTF8("Preparing audio…")) + " "+String(count)+"/"+String(totalWork),double(count)/totalWork);
                }
            };
            control.pluginDispatcher=[checkpoint,weak,cancellation](std::function<void()> operation) {
                checkpoint();
                struct Result { WaitableEvent done; std::exception_ptr error; };
                auto result=std::make_shared<Result>();
                if(!MessageManager::callAsync([weak,cancellation,result,operation=std::move(operation)] {
                    try {
                        if(weak.expired()||cancellation->load())throw NativeFX::PreparationCancelled();
                        operation();
                    } catch(...) {result->error=std::current_exception();}
                    result->done.signal();
                }))throw NativeFX::PreparationCancelled();
                while(!result->done.wait(10))checkpoint();
                checkpoint();
                if(result->error)std::rethrow_exception(result->error);
            };
            if(const auto *song=prepared->core.currentSong()) {
                prepared->song=song->id;
                prepared->audio->prepareSong(*song,prepared->mediaDirectory,
                    project.masterFXJSON?JSON::parse(text(*project.masterFXJSON)):var(),&project,&control);
                if(offline)prepared->audio->setOffline(true);
            }
            prepared->observedMedia=mediaCleanup::references(project);
            if(!prepared->audio->missingFiles.isEmpty())
                prepared->warning=String::fromUTF8("Mídias ausentes: ")+String(prepared->audio->missingFiles.size())+". Religue a pasta original antes do show.";
            else if(!prepared->audio->unsupported.isEmpty())
                prepared->warning=String::fromUTF8("Este projeto contém processamento Apple que ainda precisa ser convertido: ")+prepared->audio->unsupported.joinIntoString(", ");
            checkpoint();
        } catch (const std::exception &e) { failure = String::fromUTF8(e.what()); }
        catch (...) { failure=String::fromUTF8("Não foi possível preparar o áudio do projeto."); }
        MessageManager::callAsync([this, weak, cancellation, prepared, failure, beforeCommit, completed]() mutable {
            if(weak.expired()||loadCancellation!=cancellation)return;
            String error=failure;
            try {
                if(cancellation->load())throw NativeFX::PreparationCancelled();
                if(error.isEmpty()) {
                    if(audio.isRecording())
                        throw std::runtime_error("Conclua a gravação antes de abrir outro projeto.");
                    if(audio.sampleRate()!=prepared->audio->sampleRate()||audio.preparesOffline()!=prepared->audio->preparesOffline())
                        throw std::runtime_error("A configuração de áudio mudou durante a abertura. Abra o projeto novamente.");
                    if(beforeCommit)beforeCommit(); // Native editors still own the outgoing graph until here.
                    if(cancellation->load())throw NativeFX::PreparationCancelled();
                    if (graphCancellation) graphCancellation->store(true);
                    graphCancellation.reset();
                    audio.adoptPreparedSong(*prepared->audio);
                    static_assert(std::is_nothrow_move_constructible_v<jaras::Engine> && std::is_nothrow_move_assignable_v<jaras::Engine>);
                    std::swap(core,prepared->core);std::swap(original,prepared->raw);
                    std::swap(document,prepared->document);std::swap(mediaDirectory,prepared->mediaDirectory);
                    observedMedia.swap(prepared->observedMedia);
                    undoHistory.swap(prepared->undoHistory);redoHistory.swap(prepared->redoHistory);
                    preparedSong.swap(prepared->song);
                    subCursorPreviewUntil=0;focusedRegion.reset();++setlistFocusRevision;
                    presentationQueues.reset();fadeoutRequested=false;fadeoutTracks.clear();
                    updateRecordArms();publishTransport();
                    dirty=false;message=prepared->warning;importProgress=1;
                }
            } catch(const std::exception &e) {error=String::fromUTF8(e.what());}
            busy=false;loadCancellation.reset();
            if(error.isNotEmpty())message=error;
            notify();
            if(completed)completed(error);
        });
    });
}
static void captureExternalProjectState(const AudioEngine &audio,jaras::Project &p) {
    auto capture=[&](const ID &id,std::optional<std::string> &json){
        if(!json)return;auto settings=JSON::parse(text(*json));audio.captureExternalEffects(id,settings);
        json=utf8(JSON::toString(settings,true,17));
    };
    capture({},p.masterFXJSON);
    for(auto &song:p.songs)for(auto &track:song.tracks){
        capture(track.id,track.fxJSON);
        for(auto &clip:track.clips)capture(clip.id,clip.fxJSON);
    }
}
var Session::snapshot() const {
    auto p=project();captureExternalProjectState(audio,p);
    return ProjectCodec::encode(p, original);
}
void Session::renameProject(String value) {
    jaras::projectSync::requireWritable();
    if (busy || activeSave || audio.isRecording()) throw std::runtime_error("Finish the current operation before renaming the project.");
    const auto name = value.trim(), stem = name.upToFirstOccurrenceOf(".", false, false).toUpperCase();
    StringArray reserved {"CON", "PRN", "AUX", "NUL"};
    for (int i=1;i<=9;++i) { reserved.add("COM"+String(i)); reserved.add("LPT"+String(i)); }
    if (name.isEmpty() || name.length()>180 || name.endsWithChar('.') || name.containsAnyOf("<>:\"/\\|?*") ||
        reserved.contains(stem) || std::any_of(name.begin(),name.end(),[](juce_wchar c){return c<32;}))
        throw std::runtime_error("Enter a valid project name.");
    const auto previous = document;
    const auto destination = previous == File() ? File() : previous.getSiblingFile(name+".jl");
    if (destination != previous && destination.exists()) throw std::runtime_error("A project with this name already exists.");
    edit([&](jaras::Project &p){p.name=utf8(name);},false);
    if (previous != File()) {
        save(previous);
        if (destination != previous && !previous.moveFileTo(destination)) throw std::runtime_error("Could not rename the project file.");
        document=destination;
        notify();
    }
}
struct Session::ProjectSave {
    jaras::Project project;
    var original, encoded;
    File target, sourceDocument, sourceDirectory;
    mediaCleanup::Paths remembered, references;
    uint64 revision = 0;
    bool changesDirectory = false;
    std::vector<std::function<void(String)>> completions;
};
std::shared_ptr<Session::ProjectSave> Session::captureSave(const File &file) {
    jaras::projectSync::requireWritable();
    if (audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de salvar o projeto.");
    if (busy)
        throw std::runtime_error("Aguarde a operação atual terminar.");
    auto operation = std::make_shared<ProjectSave>();
    operation->target = file.withFileExtension("jl");
    operation->sourceDocument = document;
    operation->sourceDirectory = mediaDirectory;
    operation->changesDirectory = operation->target.getParentDirectory() != mediaDirectory;
    operation->project = project();
    auto &p = operation->project;
    if (!p.projectSyncID) p.projectSyncID = utf8(Uuid().toDashedString().toUpperCase());
    if (transport().songId)
        p.savedCursor = jaras::SavedProjectCursor{*transport().songId, transport().editPosition};
    p.updatedAt = utf8(Time::getCurrentTime().toISO8601(true));
    // VST state capture belongs to the message thread. Everything after this
    // point owns a detached snapshot and can serialize/write away from the UI.
    captureExternalProjectState(audio, p);
    operation->original = original;
    if (!operation->changesDirectory) operation->remembered = observedMedia;
    return operation;
}
void Session::writeSave(ProjectSave &operation) {
    auto &p = operation.project;
    const auto &target = operation.target;
    const auto targetDir = target.getParentDirectory();
    const bool savingCurrentDocument = target == operation.sourceDocument;
    if (targetDir.createDirectory().failed())
        throw std::runtime_error("Não foi possível criar a pasta do projeto.");
    for (const auto &other : targetDir.findChildFiles(File::findFiles, false, "*.jl"))
        if (other != target && !ProjectCodec::isMacMetadata(other) && !(savingCurrentDocument && target.existsAsFile()))
            throw std::runtime_error("Escolha uma pasta separada para cada projeto CatLive.");
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
    dynamicsAssets::collect(p, paths);
    for (const auto &id : instrumentAssets::identities(p)) {
        auto source = instrumentAssets::resolve(id, operation.sourceDirectory),
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
    if (targetDir != operation.sourceDirectory)
        for (const auto &relative : paths) {
            auto source = ProjectCodec::resolveMedia(operation.sourceDirectory, relative);
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
    operation.encoded = ProjectCodec::encode(p, operation.original);
    operation.references = mediaCleanup::references(p);
    mediaCleanup::remember(p, target, operation.remembered);
    ProjectCodec::write(target, operation.encoded, savingCurrentDocument);
}
void Session::save(const File &file) {
    if (activeSave) throw std::runtime_error("Aguarde o projeto terminar de salvar.");
    auto operation = captureSave(file);
    writeSave(*operation);
    core.applyProjectEdit(std::move(operation->project));
    original = std::move(operation->encoded);
    document = operation->target;
    mediaDirectory = document.getParentDirectory();
    observedMedia = std::move(operation->references);
    dirty = false;
    message = localization::translate("Salvo") + " · " + Time::getCurrentTime().formatted("%d/%m/%Y %H:%M");
    notify();
}
void Session::waitForSave(std::function<void(String)> completed) {
    if (!completed) return;
    if (activeSave) activeSave->completions.push_back(std::move(completed));
    else completed({});
}
void Session::setReductionDraft(const var &draft) {
    const auto encoded = utf8(JSON::toString(draft, true));
    if (project().reductionDraftJSON == encoded) return;
    auto next = project(); next.reductionDraftJSON = encoded;
    core.applyProjectEdit(std::move(next));
    dirty = true; ++revision;
    // Reduction preferences do not alter the playback graph or timeline.
    if (tick) tick();
}
void Session::saveReductionDraft() {
    if (!dirty || !document.existsAsFile()) return;
    if (isSaving()) {
        const auto weak = std::weak_ptr<int>(alive);
        const auto projectID = project().id; const auto file = document;
        waitForSave([this, weak, projectID, file](String error) {
            if (weak.expired() || error.isNotEmpty() || project().id != projectID || document != file) return;
            saveReductionDraft();
        });
        return;
    }
    try { saveAsync(document); }
    catch (const std::exception &error) { message = String::fromUTF8(error.what()); }
}
void Session::saveAsync(const File &file, std::function<void(String)> completed) {
    const auto target = file.withFileExtension("jl");
    if (activeSave) {
        if (activeSave->target != target)
            throw std::runtime_error("Aguarde o projeto terminar de salvar antes de escolher outro destino.");
        waitForSave(std::move(completed));
        return;
    }
    auto operation = captureSave(target);
    if (completed) operation->completions.push_back(std::move(completed));
    activeSave = operation;
    // Save As moves the media root. Hold media edits until the new root is
    // complete; a regular Save keeps editing and transport available.
    if (operation->changesDirectory) busy = true;
    message = localization::translate(String::fromUTF8("Salvando…"));
    operation->revision = revision;
    if (tick) tick(); else if (changed) changed();
    const auto weak = std::weak_ptr<int>(alive);
    saveWorker.addJob([this, weak, operation] {
        String failure;
        try { writeSave(*operation); }
        catch (const std::exception &e) { failure = String::fromUTF8(e.what()); }
        MessageManager::callAsync([this, weak, operation, failure]() mutable {
            if (weak.expired()) return;
            if (activeSave != operation) return;
            const bool sameDocument = project().id == operation->project.id &&
                document == operation->sourceDocument && mediaDirectory == operation->sourceDirectory;
            if (failure.isEmpty() && sameDocument) {
                // Never restore the old project snapshot here: the user may
                // have edited, moved the cursor, or queued another song meanwhile.
                if (operation->project.projectSyncID)
                    core.setProjectSyncID(*operation->project.projectSyncID);
                original = std::move(operation->encoded);
                document = operation->target;
                mediaDirectory = document.getParentDirectory();
                observedMedia.insert(operation->references.begin(), operation->references.end());
                if (revision == operation->revision) dirty = false;
                message = localization::translate("Salvo") + " · " + Time::getCurrentTime().formatted("%d/%m/%Y %H:%M");
            } else if (failure.isEmpty()) {
                failure = String::fromUTF8("O projeto foi salvo, mas outra sessão foi aberta durante a gravação do arquivo.");
            }
            if (operation->changesDirectory) busy = false;
            activeSave.reset();
            if (failure.isNotEmpty()) message = failure;
            if (failure.isEmpty() && operation->changesDirectory) notify();
            else if (tick) tick(); else if (changed) changed();
            for (auto &completion : operation->completions) if (completion) completion(failure);
        });
    });
}
void Session::cleanTimelineMedia(std::function<void(String)> completed) {
    if (busy || audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de limpar as mídias.");
    if (!document.existsAsFile())
        throw std::runtime_error("Salve o projeto antes de limpar as mídias.");
    save(document);
    const auto projectCopy = project();
    const auto raw = snapshot();
    const auto file = document;
    const auto known = observedMedia;
    const auto activeFiles = audio.activeMediaPaths();
    busy = true;
    importProgress = 0;
    undoHistory.clear();
    redoHistory.clear();
    message = String::fromUTF8("Limpando mídias excluídas da timeline…");
    notify();
    const auto weak = std::weak_ptr<int>(alive);
    worker.addJob([this, weak, projectCopy, raw, file, known, activeFiles, completed] {
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
                }, activeFiles);
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
                                String::fromUTF8(" arquivo(s) removido(s). Backups antigos excluídos.")
                          : failure;
            notify();
            if (completed)
                completed(failure);
        });
    });
}
jaras::TransportState Session::presentationTransport() const {
    auto value = transport();
    // The core/UI state is sampled at 8 Hz. The running needle and viewport
    // must use the device's sample clock even when no plugin adds latency.
    if (audio.transportClockPending() ||
        (audio.presentationLatencyFrames() == 0 && !audio.hasLiveDevice())) return value;
    const auto audible = audio.presentationState();
    value.position = audible.position;
    if (audible.subPlaying) value.subPlay.position = audible.subPosition;
    value.playing = audible.playing;
    value.subPlay.playing = audible.subPlaying;
    presentationQueues.apply(value);
    if (value.playing && song()) {
        const jaras::Part *current = nullptr;
        for (const auto &part : song()->parts)
            if (value.position >= part.startTime && value.position < part.endTime &&
                (!current || part.endTime - part.startTime < current->endTime - current->startTime)) current = &part;
        value.regionId = current ? std::optional<ID>(current->id) : std::nullopt;
    }
    return value;
}
void Session::reconcileSetlistSelectionAfterAdvance(const jaras::TransportState &before) {
    if(clearFinishedSetlistSelection(project(),focusedRegion,before,transport())) {
        focusedRegion.reset(); ++setlistFocusRevision;
        if(selectionChanged) selectionChanged();
    }
    const auto &after=transport();
    if(before.playing && !after.playing && !after.paused && !after.subPlay.playing &&
       !before.queuedRegionId && !after.queuedRegionId && before.songId==after.songId && focusedRegion) {
        core.execute({jaras::CommandKind::selectRegion,*focusedRegion});
        ++setlistFocusRevision;
        if(selectionChanged) selectionChanged();
    }
}
void Session::syncClock() {
    // A prepared seek is not applied until the next device callback. Do not
    // advance the core with samples from the old head or resend that seek in
    // this interval. The callback resets elapsed at the actual commit boundary.
    if(audio.transportClockPending())return;
    auto elapsed = audio.takeElapsed();
    if (elapsed <= 0)
        return;
    // Compare clocks from the same observation, before advancing the model.
    // Region/scope resolution can outlast a device block; reading the audio
    // head afterwards mistakes that valid progress for drift and rewinds it.
    const auto actual = audio.state();
    const auto before = transport();
    const auto old = before.songId;
    const auto oldJump = before.sectionJumpSerial;
    const auto oldPromotion = before.subPlayPromotion;
    const auto markedCount=[](const auto &project) -> size_t {
        return project.regionSetlist && project.regionSetlist->playedLiveRegionIDs
            ? project.regionSetlist->playedLiveRegionIDs->size() : 0;
    };
    const auto liveMarksBefore=markedCount(project());
    core.advance(elapsed);
    reconcileSetlistSelectionAfterAdvance(before);
    if(markedCount(project())!=liveMarksBefore) { dirty=true; ++revision; }
    presentationQueues.advance(elapsed, audio.presentationLatencyFrames() / audio.sampleRate(),
                               before, transport());
    if (old != transport().songId && song())
        prepare();
    else {
        const auto &expected = transport();
        auto *device = audio.devices.getCurrentAudioDevice();
        double tolerance =
            device
                ? std::max(.003, device->getCurrentBufferSizeSamples() / audio.sampleRate() * 1.5)
                : .003;
        const bool aligned = expected.playing == actual.playing &&
            expected.subPlay.playing == actual.subPlaying &&
            std::abs(expected.position - actual.position) <= tolerance &&
            (!expected.subPlay.playing || std::abs(expected.subPlay.position - actual.subPosition) <= tolerance);
        const bool transition = oldJump != expected.sectionJumpSerial || oldPromotion != expected.subPlayPromotion;
        // Parts can arm a loop while advancing into its first marker. Send
        // its bounds immediately, before the first wrap, so the callback owns
        // that jump just as it owns every subsequent lap.
        const bool loopChanged=before.loop.enabled!=expected.loop.enabled ||
            before.loop.start!=expected.loop.start || before.loop.end!=expected.loop.end;
        if (!aligned || transition || loopChanged || before.queuedSectionMarkerId != expected.queuedSectionMarkerId || before.exclusivePlaybackRegionId!=expected.exclusivePlaybackRegionId || before.subExclusivePlaybackRegionId!=expected.subExclusivePlaybackRegionId)
            // Loops already wrap at a sample boundary inside the audio engine.
            // Acknowledge the core's loop event without replaying its onset.
            publishTransport(transition, aligned);
    }
}
void Session::publishTransport(bool preserveLatency, bool routingOnly) {
    const auto &t = transport();
    AudioEngine::State state;
    state.preserveLatency = preserveLatency;
    state.promotion = t.subPlayPromotion;
    state.position = t.position;
    state.timecodePreferred = audio.timecodePreferred(t.regionId);
    state.playing = t.playing;
    state.subPosition = t.subPlay.position;
    state.subPlaying = t.subPlay.playing;
    if (song()) {
        state.scope[0] = jaras::playbackScope(*song(), t);
        state.scope[1] = jaras::playbackScope(*song(), t, true);
        state.exclusiveScope[0]=jaras::exclusiveSubplayScope(*song(),t);
        state.exclusiveScope[1]=jaras::exclusiveSubplayScope(*song(),t,true);
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
    if (routingOnly) audio.updateTransportRouting(state);
    else if(!inspection && audio.hasLiveDevice())audio.transportAsync(state);
    else audio.transport(state);
    if(!inspection && audio.hasLiveDevice()) {
        std::optional<AudioEngine::State> destination;
        if(song() && t.playing) {
            std::optional<double> at;
            if(t.queuedSectionMarkerId) {
                // A region ID is the virtual INICIO section, just as in the
                // shared transport. It has no physical timeline marker.
                for(const auto &part:song()->parts)if(part.id==*t.queuedSectionMarkerId)at=part.startTime;
                if(!at && song()->markers)
                    for(const auto &marker:*song()->markers)if(marker.id==*t.queuedSectionMarkerId)at=marker.position;
            }
            if(!at && t.queuedRegionId)
                for(const auto &part:song()->parts)if(part.id==*t.queuedRegionId)at=jaras::playbackRegionStart(*song(),part);
            if(at) {
                auto future=t;future.position=*at;future.playbackStartRegionId=jaras::playbackEntryRegion(*song(),*at);
                future.ignoreNextAfter.reset();
                destination.emplace();destination->playing=true;destination->subPlaying=true;
                destination->position=*at;destination->subPosition=*at;
                destination->scope[0]=destination->scope[1]=jaras::playbackScope(*song(),future);
            }
        }
        audio.prewarmTransportDestination(destination);
    }
}
void Session::warnTransportFadeout(String warning) {
    if (transportFadeoutWarning) transportFadeoutWarning(warning);
    else message = warning;
}
void Session::toggleTransportFadeout(bool enabled, const std::set<ID> &tracks, double seconds) {
    if (jaras::projectSync::readOnly()) return;
    if (fadeoutRequested) { cancelTransportFadeout(); return; }
    if (!transport().playing) return;
    if (!enabled) { warnTransportFadeout("Ative Fadeout no clique direito do Play."); return; }
    if (transport().subPlay.playing) { warnTransportFadeout("Pare o Subplay antes de iniciar o Fadeout."); return; }
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
void Session::clearTimeRange() {
    if (jaras::projectSync::readOnly()) return; timeSelection.reset(); }
void Session::selectTimeRange(double from, double to) {
    if (jaras::projectSync::readOnly()) return;
    if (busy || !song() || !std::isfinite(from) || !std::isfinite(to)) return;
    if (audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de alterar a área de loop.");
    const double start=std::max(0.,std::min(from,to)), end=std::max(0.,std::max(from,to));
    if (end<=start) { clearTimeRange(); return; }
    timeSelection=TimeSelection{project().id,song()->id,start,end};
    if (transport().loop.enabled && !transport().multiLoop) {
        syncClock();
        core.execute({jaras::CommandKind::loopStart,{},start});
        core.execute({jaras::CommandKind::loopEnd,{},end});
        publishTransport(true);
    }
}
bool Session::controlAllowedDuringSave(jaras::CommandKind kind) const {
    if (!activeSave || !activeSave->changesDirectory) return false;
    switch (kind) {
        case jaras::CommandKind::play: case jaras::CommandKind::stop:
        case jaras::CommandKind::stopAll: case jaras::CommandKind::pause:
        case jaras::CommandKind::subPlay: case jaras::CommandKind::subStop:
        case jaras::CommandKind::seek: case jaras::CommandKind::editSeek:
        case jaras::CommandKind::subSeek: case jaras::CommandKind::cancelSection:
        case jaras::CommandKind::escape: case jaras::CommandKind::toggleLoop:
        case jaras::CommandKind::volume: case jaras::CommandKind::pan:
        case jaras::CommandKind::mute: case jaras::CommandKind::solo:
        case jaras::CommandKind::phase: case jaras::CommandKind::masterMono:
            return true;
        default: return false;
    }
}
void Session::command(jaras::CommandKind kind, const ID &target, double value) {
    if (jaras::projectSync::readOnly()) return;
    if (fadeoutRequested && kind == jaras::CommandKind::subPlay) {
        warnTransportFadeout(String::fromUTF8("Subplay indisponível enquanto o Fadeout está acontecendo.")); return;
    }
    if (kind == jaras::CommandKind::volume && trackFaderLocked(target)) return;
    if (busy && !controlAllowedDuringSave(kind))
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
    if (start) {
        const auto unavailable=audio.outputAvailabilityError();
        if (unavailable.isNotEmpty()) throw std::runtime_error(utf8(unavailable));
    }
    if (start && canPlay && !canPlay()) {
        message = String::fromUTF8("Faça login ou ative o trial para reproduzir.");
        notify();
        return;
    }
    auto old = transport().songId;
    const bool wasPlaying = transport().playing;
    const bool cancellingTransport = transport().loop.enabled || transport().queuedSectionMarkerId ||
                                     transport().queuedRegionId || transport().queue.songId ||
                                     (project().regionSetlist && project().regionSetlist->autoAdvance);
    if (kind == jaras::CommandKind::toggleLoop && !transport().loop.enabled)
        if (const auto range=selectedTimeRange()) {
            core.execute({jaras::CommandKind::loopStart,{},range->first});
            core.execute({jaras::CommandKind::loopEnd,{},range->second});
        }
    const auto beforeCommand = transport();
    core.execute({kind, target, value});
    presentationQueues.command(kind, beforeCommand, transport());
    if (beforeCommand.loop.enabled && !transport().loop.enabled) clearTimeRange();
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
    if (kind == jaras::CommandKind::queueRegion && beforeCommand.playing &&
        beforeCommand.queuedRegionId && !transport().queuedRegionId)
        focusSetlistRegion(std::nullopt, true);
    else if (kind == jaras::CommandKind::selectRegion || kind == jaras::CommandKind::queueRegion)
        focusSetlistRegion(target, true);
    else if (kind == jaras::CommandKind::editSeek || (kind == jaras::CommandKind::queueSection && !transport().playing))
        focusTimelineRegion(transport().editPosition);
    else if (kind == jaras::CommandKind::play && !wasPlaying && transport().playlistEntryId)
        focusSetlistRegion(transport().playlistEntryId, true);
    else if (kind == jaras::CommandKind::seek || (kind == jaras::CommandKind::play && !wasPlaying))
        focusTimelineRegion(transport().position, true);
    const bool mixer = kind == jaras::CommandKind::volume || kind == jaras::CommandKind::pan ||
                       kind == jaras::CommandKind::mute || kind == jaras::CommandKind::solo ||
                       kind == jaras::CommandKind::phase || kind == jaras::CommandKind::masterMono;
    if (mixer) {
        dirty = true;
        if (song())
            audio.setMixer(project(), *song());
    } else {
        const auto &afterCommand = transport();
        const bool unchangedHeads = beforeCommand.songId == afterCommand.songId &&
            beforeCommand.position == afterCommand.position &&
            (beforeCommand.subPlay.position == afterCommand.subPlay.position ||
             (!beforeCommand.subPlay.playing && !afterCommand.subPlay.playing)) &&
            beforeCommand.playing == afterCommand.playing &&
            beforeCommand.subPlay.playing == afterCommand.subPlay.playing;
        // Queueing a section/region changes routing, not the running source
        // clocks. Do not re-prime and restart every stem merely to arm a jump.
        publishTransport(unchangedHeads, unchangedHeads);
    }
    startTimerHz(transport().playing || transport().subPlay.playing ? 60 : 8);
    if (fadeoutRequested && !completingFadeout && !transport().playing) cancelTransportFadeout();
    const bool stoppedAtQueuedSelection = (kind == jaras::CommandKind::stop || kind == jaras::CommandKind::stopAll) &&
        !transport().playing && (beforeCommand.regionId != transport().regionId || beforeCommand.editPosition != transport().editPosition);
    if(stoppedAtQueuedSelection) focusSetlistRegion(transport().playlistEntryId ? transport().playlistEntryId : transport().regionId,true);
    if(mixer) notifyMixer();
    else if ((kind == jaras::CommandKind::selectRegion || stoppedAtQueuedSelection) && old == transport().songId && selectionChanged)
        selectionChanged();
    else if (old == transport().songId && transportChanged &&
             (kind == jaras::CommandKind::queueRegion || kind == jaras::CommandKind::queueSection ||
              kind == jaras::CommandKind::cancelSection || kind == jaras::CommandKind::play ||
              kind == jaras::CommandKind::stop || kind == jaras::CommandKind::stopAll ||
              kind == jaras::CommandKind::pause || kind == jaras::CommandKind::subPlay ||
              kind == jaras::CommandKind::subStop || kind == jaras::CommandKind::subSeek ||
              kind == jaras::CommandKind::seek || kind == jaras::CommandKind::editSeek ||
              kind == jaras::CommandKind::ignoreNext)) {
        ++revision;transportChanged();
    }
    else
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
    }
    focusSetlistRegion(std::move(next), force);
}
void Session::focusSetlistRegion(std::optional<ID> next, bool force) {
    const auto *current = song();
    if (!current) return;
    if (next) {
        auto state = project().regionSetlist.value_or(jaras::RegionSetlist{});
        const jaras::RegionPlaylist *selected = nullptr;
        for (const auto &playlist : state.playlists)
            if (state.selectedId == playlist.id && playlist.songId == current->id) selected = &playlist;
        const auto source = selected ? selected->resolvedRegionId(*next) : *next;
        const auto part = std::find_if(current->parts.begin(), current->parts.end(),
                                       [&](const auto &part) { return part.id == source; });
        if (part == current->parts.end()) return;
        const auto listedID = part->parentRegionID.value_or(part->id);
        if (selected && !selected->containsEntry(*next)) {
            const auto occurrence = std::find_if(selected->regionIds.begin(), selected->regionIds.end(),
                [&](const auto &id) { return selected->resolvedRegionId(id) == listedID; });
            if (occurrence == selected->regionIds.end()) {
                state.selectedId.reset();
                auto before = snapshot();
                core.configureRegionSetlist(std::move(state));
                undoHistory.push_back(std::move(before));
                if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
                redoHistory.clear(); dirty = true; force = true;
            } else if (selected->isDuplicate(*occurrence) && !part->parentRegionID) next = *occurrence;
        }
    }
    if (focusedRegion != next || force) { focusedRegion = next; ++setlistFocusRevision; }
}
void Session::updateRecordArms() {
    if (const auto *current = song())
        for (const auto &track : current->tracks)
            audio.armTrack(track.id, recordingArmed(track.id));
}
void Session::setRecordingSelection(const ID &id, const std::set<ID> &targets) {
    if (audio.isRecording())
        return;
    const auto selected = id.empty() ? std::set<ID>{} : targets.count(id) ? targets : std::set<ID>{id};
    if (recordSelections == selected)
        return;
    recordSelections = selected;
    updateRecordArms();
}
void Session::cycleRecordArm(const ID &id, const std::set<ID> &targets) {
    if (jaras::projectSync::readOnly()) return;
    if (audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de alterar as pistas armadas.");
    const int next = (recordArm(id) + 1) % 3;
    if (const auto *current = song()) {
        for (const auto &track : current->tracks)
            if ((targets.count(id) ? targets.count(track.id) != 0 : track.id == id) && jaras::fixedTrackName(track.role).empty())
                recordArms[track.id] = next;
        updateRecordArms(); notify();
    }
}
void Session::mixerCommand(jaras::CommandKind kind, const ID &id, const std::set<ID> &selection, double value) {
    if (jaras::projectSync::readOnly()) return;
    if ((busy && !controlAllowedDuringSave(kind)) || !song()) return;
    // These commands change scalar controls only. Never copy the arrangement's
    // item peaks/plugin state just to toggle M/S or move a fader.
    const auto& tracks = mixerGestureSource == id && mixerGestureProject == project().id && mixerGestureKind == kind ? mixerGestureTracks : song()->tracks;
    const auto source = std::find_if(tracks.begin(), tracks.end(), [&](const auto &t) { return t.id == id; });
    if (source == tracks.end()) return;
    const bool volume = kind == jaras::CommandKind::volume, pan = kind == jaras::CommandKind::pan;
    auto state = [&](const auto &t) { return kind == jaras::CommandKind::mute ? t.mute : kind == jaras::CommandKind::solo ? t.solo : t.phaseInverted.value_or(false); };
    const bool desired = !state(*source);
    const double sourceVolume=source->volume,sourcePan=source->pan;
    std::vector<ID> order{id};
    for (const auto &t : tracks) if (selection.count(id) && selection.count(t.id) && t.id != id) order.push_back(t.id);
    std::set<ID> applied;
    for (const auto &target : order) {
        if (applied.count(target) || (volume && trackFaderLocked(target))) continue;
        const auto at = std::find_if(tracks.begin(), tracks.end(), [&](const auto &t) { return t.id == target; });
        if (at == tracks.end()) continue;
        if (jaras::fixedTrackName(at->role).size() && at->role.id != "generatedClick" && at->role.id != "timecode") continue;
        if (volume || pan) {
            const double next = volume ? jlimit(0., std::pow(10., 12./20), sourceVolume <= 0 || value <= 0 ? value : at->volume * value / sourceVolume)
                                       : jlimit(-1., 1., at->pan + value - sourcePan);
            core.execute({kind, target, next});
        } else if (state(*at) != desired) core.execute({kind, target});
        applied.insert(target);
        if ((volume || pan) && at->stereoLinkPartner) applied.insert(*at->stereoLinkPartner);
    }
    dirty = true; audio.setMixer(project(), *song()); notifyMixer();
}
void Session::toggleRecording() {
    if (jaras::projectSync::readOnly()) return;
    if (audio.isRecording()) {
        auto takes = audio.stopTrackRecording();
        core.execute({jaras::CommandKind::stopAll});
        publishTransport();
        const auto directory = mediaDirectory;
        const auto projectID = project().id, songID = recordingSong;
        const auto start = recordingStart;
        const auto previews = recordingItems;
        const auto drops = audio.recordingOverflows();
        const std::weak_ptr<int> lifetime = alive;
        busy = true;
        message = String::fromUTF8("Finalizando gravação…");
        notify();
        worker.addJob([this, lifetime, directory, projectID, songID, start, drops, previews,
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
                for (const auto &item : previews) if (item.track == take.track) {
                    clip.id = item.clip.id;
                    clip.recordingLane = item.clip.recordingLane;
                    clip.name = item.clip.name;
                    break;
                }
                clip.startTime = start;
                clip.duration = take.duration;
                if (clip.name.empty()) clip.name = utf8(take.file == File() ? String("MIDI take")
                                                     : take.file.getFileNameWithoutExtension());
                if (take.midi) clip.midi = std::move(take.midi);
                else {
                    clip.audioFile = jaras::AudioFile{
                        utf8(take.file.getRelativePathFrom(directory).replaceCharacter('\\', '/')), {}};
                    try {
                        if (auto reader = std::unique_ptr<AudioFormatReader>(formats.createReaderFor(take.file)))
                            WaveformCache::preload(take.file);
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
                recordingItems.clear(); ++revision;
                if (project().id != projectID) { notify(); return; }
                try {
                    if (!clips.empty()) editTimeline([&](jaras::Project &project) {
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
                                : clips.empty() ? String::fromUTF8("Gravação encerrada.") : String::fromUTF8("Gravação adicionada às pistas armadas.");
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
    std::vector<RecordingItem> previews;
    std::set<String> recordingNames;
    for (const auto &s : project().songs) for (const auto &t : s.tracks) for (const auto &clip : t.clips)
        recordingNames.insert(text(clip.name).toLowerCase());
    const auto stemsFolder = mediaDirectory.getChildFile("Stems");
    const auto nameExists = [&](const String &name) {
        if (recordingNames.count(name.toLowerCase())) return true;
        for (const auto *extension : {".wav", ".aiff", ".aif", ".mp3", ".mid"})
            if (stemsFolder.getChildFile(name + extension).exists()) return true;
        return false;
    };
    const auto allocateName = [&](String track) {
        track = File::createLegalFileName(track.trim()); if (track.isEmpty()) track = "Track";
        auto name = track;
        for (int index = 1; nameExists(name); ++index)
            name = track + " - " + String(index).paddedLeft('0', 3);
        recordingNames.insert(name.toLowerCase()); return name;
    };
    for (const auto &track : song()->tracks)
        if (recordingArmed(track.id) && jaras::fixedTrackName(track.role).empty()) {
            TrackCapture::Target target;
            target.track = track.id;
            target.output = track.role.id == "vinhetas" || track.recordingOutput.value_or(false);
            target.midi = track.recordingChannels == 0 && track.role.id != "vinhetas";
            target.channels = track.recordingChannels.value_or(2);
            if (target.midi)
                target.channels = 2;
            target.bus = target.output || (track.fxJSON &&
                         !instrumentAssets::settings(JSON::parse(text(*track.fxJSON))).empty());
            target.input = track.inputPatch ? track.inputPatch->firstChannel : 1;
            if (!target.midi && !target.bus && !track.inputPatch)
                throw std::runtime_error(
                    utf8(localization::translate("Choose the input in the Patch of track %s.").replace("%s", text(track.name))));
            const auto encoding = recordingEncoding::resolve(track.recordingFormat, advancedFormat, bits, bitrate);
            const auto takeName = allocateName(text(track.name));
            if (!target.midi)
                target.file = mediaDirectory.getChildFile("Stems").getChildFile(takeName + text(encoding.extension));
            target.bits = encoding.bits;
            target.floatingPoint = encoding.floatingPoint;
            target.bitrate = encoding.bitrate;
            target.outputPostFader = track.recordingPostFader.value_or(true);
            target.outputPostFX = track.recordingPostFX.value_or(true);
            // Output taps already contain the chosen stages. Inputs are always dry.
            target.postFader = false;
            target.postFX = false;
            target.gain = (float)track.volume;
            target.mediaDirectory = mediaDirectory;
            target.effects = track.fxJSON ? JSON::parse(text(*track.fxJSON)) : var{};
            if (target.postFX) audio.captureExternalEffects(track.id, target.effects);
            RecordingItem item;
            item.track = track.id;
            item.clip.id = uuid();
            item.clip.name = utf8(takeName);
            item.clip.startTime = recordingStart;
            // Reserve a lane for the whole remaining recording, without adding
            // placeholder clips to the audio graph or reallocating it each frame.
            double end = std::max(recordingStart + 1., song()->duration);
            for (const auto &clip : track.clips) end = std::max(end, clip.startTime + clip.duration);
            item.clip.duration = end - recordingStart;
            item.clip.recordingLane = ItemLanes(track).count;
            item.preview = std::make_shared<RecordingPreview>(audio.sampleRate(), target.channels);
            target.preview = item.preview;
            previews.push_back(std::move(item));
            targets.push_back(std::move(target));
        }
    audio.startTrackRecording(targets, bits, song()->bpm);
    recordingItems = std::move(previews); ++revision;
    try {
        if (!transport().playing) command(jaras::CommandKind::play);
    } catch (...) {
        audio.stopTrackRecording(); recordingItems.clear(); ++revision;
        throw;
    }
    message = String::fromUTF8("Gravando áudio · clique em REC ou Stop para concluir");
    notify();
}
void Session::cancelBPMDetection() {
    if (!bpmCancellation) return;
    bpmCancellation->store(true);
    bpmCancellation.reset();
    if (message.startsWith(String::fromUTF8("Detectando BPM"))) message.clear();
}
Session::MarkerHistory Session::markerHistory(const ID &id) const {
    for (const auto &song : project().songs) if (song.id == id) return {id, song.markers};
    throw std::runtime_error("A música foi removida do projeto.");
}
void Session::applyMarkerHistory(const MarkerHistory &state, bool recordHistory) {
    syncClock();
    auto before = markerHistory(state.song);
    auto updated = project();
    for (auto &song : updated.songs) if (song.id == state.song) song.markers = state.markers;
    // Tempo detection adds absolute/global markers; no clip geometry changes.
    // Preserve live plugin instances/state and the decoder graph, also on Undo.
    core.applyProjectEdit(std::move(updated));
    if (song() && song()->id == state.song) audio.refreshTiming(*song());
    publishTransport(false,true);
    if (recordHistory) {
        undoHistory.emplace_back(std::move(before));
        if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
        redoHistory.clear();
    }
    dirty = true;
    notify();
}
void Session::detectRegionBPM(std::set<ID> ids) {
    if (busy || isDetectingBPM() || !song() || ids.empty()) return;
    if (audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de detectar o BPM.");
    const auto sourceSong = *song(); const auto projectID = project().id;
    const auto signature = clickTempo::inputSignature(sourceSong, ids);
    const auto directory = mediaDirectory; const std::weak_ptr<int> lifetime = alive;
    const auto cancelled = std::make_shared<std::atomic<bool>>(false);
    bpmCancellation = cancelled;
    message = localization::translate(String::fromUTF8("Detectando BPM…")); notify();
    // Analysis never owns Session::busy: cursor, selection and Click controls
    // remain interactive, and opening a project does not wait in this queue.
    bpmWorker.addJob([this, sourceSong, signature, projectID, directory, ids, lifetime, cancelled] {
        struct Stamp { File file; int64 size, modified; };
        std::vector<Stamp> sources;
        std::map<ID, std::vector<jaras::TimelineMarker>> detected;
        std::map<std::string, std::vector<clickTempo::Transient>> cached;
        StringArray failures;
        try {
            for (const auto &part : sourceSong.parts) if (ids.count(part.id)) {
                if (lifetime.expired() || cancelled->load()) break;
                try {
                    auto values = clickTempo::markers(sourceSong, part, [&](const auto &file) {
                        auto found = cached.find(file.path);
                        if (found == cached.end()) {
                            const auto path = ProjectCodec::resolveMedia(directory, file.path);
                            if (path.existsAsFile()) sources.push_back({path, path.getSize(), path.getLastModificationTime().toMilliseconds()});
                            found = cached.emplace(file.path, clickTempo::transients(path, cancelled.get())).first;
                        }
                        return found->second;
                    }, cancelled.get());
                    if (cancelled->load()) break;
                    if (values.empty()) failures.add(text(part.name) + String::fromUTF8(": Nenhum andamento estável encontrado na pista Click."));
                    else detected.emplace(part.id, std::move(values));
                } catch (const std::exception &e) {
                    if (!cancelled->load()) failures.add(text(part.name) + ": " + String::fromUTF8(e.what()));
                }
            }
        } catch (const std::exception &e) { failures.add(String::fromUTF8(e.what())); }
        catch (...) { failures.add(String::fromUTF8("Não foi possível concluir a detecção de BPM.")); }
        MessageManager::callAsync([this, lifetime, projectID, songID=sourceSong.id, signature, ids, cancelled,
                                   detected=std::move(detected), sources=std::move(sources), failures] {
            if (lifetime.expired() || bpmCancellation != cancelled) return;
            bpmCancellation.reset();
            if (busy || project().id != projectID || !song() || song()->id != songID) {
                if (message.startsWith(String::fromUTF8("Detectando BPM"))) message.clear();
                notify(); return;
            }
            if (cancelled->load()) { message.clear(); notify(); return; }
            const bool sourceChanged = std::any_of(sources.begin(), sources.end(), [](const auto &source) {
                return !source.file.existsAsFile() || source.file.getSize() != source.size ||
                       source.file.getLastModificationTime().toMilliseconds() != source.modified;
            });
            if (sourceChanged || clickTempo::inputSignature(*song(), ids) != signature) {
                message = String::fromUTF8("A região ou o áudio Click mudou durante a análise. Detecte o BPM novamente.");
                notify(); return;
            }
            // Recording may have started while the worker was analysing.
            if (audio.isRecording()) {
                message = String::fromUTF8("Conclua a gravação e detecte o BPM novamente."); notify(); return;
            }
            try {
                if (!detected.empty()) {
                    auto updated = *song();
                    for (const auto &part : updated.parts)
                        if (auto at = detected.find(part.id); at != detected.end()) clickTempo::insert(updated, part, at->second);
                    applyMarkerHistory({songID, std::move(updated.markers)}, true);
                }
                message = failures.joinIntoString(String::fromUTF8(" · "));
            } catch (const std::exception &e) { message = String::fromUTF8(e.what()); }
            notify();
        });
    });
}
ID Session::duplicatePlaylistRegion(const ID &playlistID, const ID &entryID) {
    if (busy || jaras::projectSync::readOnly() || !song()) return {};
    auto state=project().regionSetlist.value_or(jaras::RegionSetlist{});
    if(state.selectedId!=playlistID)return {};
    for(auto &playlist:state.playlists)if(playlist.id==playlistID && playlist.songId==song()->id && playlist.containsEntry(entryID)) {
        const auto source=playlist.resolvedRegionId(entryID);
        const auto part=std::find_if(song()->parts.begin(),song()->parts.end(),[&](const auto &part){return part.id==source && !part.parentRegionID;});
        if(part==song()->parts.end())return {};
        const auto copy=uuid();
        if(!playlistOccurrences::duplicate(playlist,entryID,copy))return {};
        configureSetlist(std::move(state));return copy;
    }
    return {};
}
void Session::configureSetlist(jaras::RegionSetlist state) {
    if (jaras::projectSync::readOnly() || busy) return;
    applySetlistHistory({std::move(state)}, true);
}
void Session::applySetlistHistory(const SetlistHistory &state, bool recordHistory) {
    syncClock();
    SetlistHistory before{project().regionSetlist};
    const auto beforeTransport=transport();
    core.configureRegionSetlist(state.state.value_or(jaras::RegionSetlist{}));
    if (!state.state) { auto p=project(); p.regionSetlist.reset(); core.applyProjectEdit(std::move(p)); }
    const auto exclusive=[](const auto &value) { return value && value->subplayExclusiveTrackIDs
        ? *value->subplayExclusiveTrackIDs : std::vector<ID>{}; };
    const bool mixerRoutingChanged=exclusive(before.state)!=exclusive(project().regionSetlist);
    if (recordHistory) {
        undoHistory.emplace_back(std::move(before));
        if (undoHistory.size()>40) undoHistory.erase(undoHistory.begin());
        redoHistory.clear();
    }
    if(song() && mixerRoutingChanged) audio.setMixer(project(),*song());
    const auto &afterTransport=transport();
    const bool sameHeads=beforeTransport.songId==afterTransport.songId &&
        beforeTransport.position==afterTransport.position && beforeTransport.playing==afterTransport.playing &&
        (beforeTransport.subPlay.position==afterTransport.subPlay.position ||
         (!beforeTransport.subPlay.playing && !afterTransport.subPlay.playing)) &&
        beforeTransport.subPlay.playing==afterTransport.subPlay.playing;
    // Playlist membership, selection and Stop/Auto policies update routing;
    // they do not replay the last UI-clock snapshot on the audio callback.
    dirty=true; publishTransport(sameHeads,sameHeads); ++revision;
    if (setlistChanged) setlistChanged(); else if (changed) changed();
}
void Session::moveMarker(const ID &id, double position) {
    if (jaras::projectSync::readOnly() || busy || !song() || !song()->markers) return;
    const auto at=std::find_if(song()->markers->begin(),song()->markers->end(),[&](const auto &m){return m.id==id;});
    if(at==song()->markers->end() || at->position==position) return;
    auto moved=*at; moved.position=position;
    auto before=markerHistory(song()->id);
    syncClock(); core.setMarkers({moved},{},false);
    audio.refreshTiming(*song()); publishTransport(false,true);
    undoHistory.emplace_back(std::move(before));
    if(undoHistory.size()>40) undoHistory.erase(undoHistory.begin());
    redoHistory.clear(); dirty=true; notify();
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
void Session::resizeItem(const ID &id, double start, double end) {
    if (jaras::projectSync::readOnly()) return;
    if (busy || !song()) return;
    if (audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de alterar a estrutura do projeto.");
    syncClock();
    auto project = core.project();
    clipEditing::resize(project, id, start, end);
    if (timelineGrid::changesLockedGeometry(core.project(), project))
        throw std::runtime_error("Desbloqueie o cadeado para mover ou redimensionar itens, regiões e marcadores.");
    commitItemTiming(std::move(project), id, true);
}
Session::ItemTimingHistory Session::itemTimingHistory(const ID &id) const {
    for (const auto &song : project().songs) for (const auto &track : song.tracks)
        for (const auto &clip : track.clips) if (clip.id == id) return {song.id, clip, song.duration};
    throw std::runtime_error("O item não existe mais.");
}
void Session::applyItemTiming(const ItemTimingHistory &history, bool recordHistory) {
    syncClock();
    auto project = core.project();
    for (auto &song : project.songs) if (song.id == history.song)
        for (auto &track : song.tracks) for (auto &clip : track.clips) if (clip.id == history.clip.id) {
            const auto &saved = history.clip;
            clip.startTime = saved.startTime; clip.duration = saved.duration;
            clip.sourceOffset = saved.sourceOffset; clip.loopStart = saved.loopStart; clip.loopLength = saved.loopLength;
            clip.timecodeStartOffset = saved.timecodeStartOffset; clip.timecodeEndOffset = saved.timecodeEndOffset;
            song.duration = history.songDuration;
        }
    commitItemTiming(std::move(project), history.clip.id, recordHistory);
}
void Session::commitItemTiming(jaras::Project project, const ID &id, bool recordHistory) {
    const auto before = itemTimingHistory(id);
    auto next = core;
    // Run the same ownership/timecode normalization and validation as any edit
    // before publishing timing to the live graph.
    next.applyProjectEdit(std::move(project));
    const auto *updated = next.currentSong();
    if (!updated) return;
    const jaras::AudioClip *item = nullptr;
    for (const auto &track : updated->tracks)
        for (const auto &clip : track.clips) if (clip.id == id) item = &clip;
    if (!item) throw std::runtime_error("O item não existe mais.");
    audio.refreshItemTiming(*updated, *item);
    // Do not call prepare() or publishTransport(): neither transport head nor
    // an unrelated reader, instrument, FX instance or delay history changed.
    core.applyProjectEdit(next.project());
    if (recordHistory) {
        undoHistory.emplace_back(before);
        if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
        redoHistory.clear();
    }
    dirty = true;
    notify();
}
Session::TrackHierarchyHistory Session::trackHierarchyHistory(const ID &id) const {
    TrackHierarchyHistory result;result.song=id;
    for(const auto &song:project().songs)if(song.id==id)for(const auto &t:song.tracks)
        result.rows.push_back({t.id,t.parentTrackID,t.patch,t.secondaryPatch,t.outputs});
    return result;
}
void Session::editTrackHierarchy(const ID &id,const std::function<void(jaras::Song &)> &change) {
    if(busy||jaras::projectSync::readOnly())return;
    if(audio.isRecording())throw std::runtime_error("Conclua a gravação antes de mover pistas.");
    auto p=project();
    for(auto &song:p.songs)if(song.id==id){
        change(song);
        TrackHierarchyHistory result;result.song=id;
        for(const auto &t:song.tracks)result.rows.push_back({t.id,t.parentTrackID,t.patch,t.secondaryPatch,t.outputs});
        applyTrackHierarchy(result,true);return;
    }
}
void Session::applyTrackHierarchy(const TrackHierarchyHistory &history,bool recordHistory) {
    const auto before=trackHierarchyHistory(history.song);auto p=project();
    for(auto &song:p.songs)if(song.id==history.song){
        if(song.tracks.size()!=history.rows.size())throw std::runtime_error("Track hierarchy changed.");
        std::vector<jaras::Track> ordered;ordered.reserve(song.tracks.size());std::set<ID> seen;
        for(const auto &row:history.rows){
            auto found=std::find_if(song.tracks.begin(),song.tracks.end(),[&](const auto &t){return t.id==row.id;});
            if(found==song.tracks.end()||!seen.insert(row.id).second)throw std::runtime_error("Track hierarchy changed.");
            auto track=std::move(*found);track.parentTrackID=row.parent;track.patch=row.patch;track.secondaryPatch=row.secondary;track.outputs=row.outputs;
            ordered.push_back(std::move(track));
        }
        song.tracks=std::move(ordered);
    }
    syncClock();auto next=core;next.applyProjectEdit(std::move(p));
    bool prepared=true;
    if(next.currentSong()&&next.currentSong()->id==history.song)
        prepared=!graphCancellation&&audio.refreshTrackRouting(*next.currentSong());
    core.applyProjectEdit(next.project());
    if(!prepared)prepareLiveGraph();
    if(recordHistory){undoHistory.emplace_back(before);if(undoHistory.size()>40)undoHistory.erase(undoHistory.begin());redoHistory.clear();}
    dirty=true;notify();
}
void Session::editTimeline(const std::function<void(jaras::Project &)> &change, bool allowTimingEdit) {
    if (busy || jaras::projectSync::readOnly()) return;
    if (audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de alterar a estrutura do projeto.");
    auto updated = project();
    change(updated);
    if (!allowTimingEdit && timelineGrid::changesLockedGeometry(project(), updated))
        throw std::runtime_error("Desbloqueie o cadeado para alterar regiões e marcadores.");
    applyTimelineHistory({std::move(updated)}, true);
}
void Session::editTrackSettings(const std::function<void(jaras::Project &)> &change, bool routing) {
    if (busy || jaras::projectSync::readOnly()) return;
    if (routing && audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de alterar o roteamento.");
    auto updated = project(); change(updated);
    applyTimelineHistory({std::move(updated), false, false, true, routing}, true);
}
void Session::editItemControls(const std::function<void(jaras::Project &)> &change) {
    if (busy || jaras::projectSync::readOnly()) return;
    auto updated = project();
    change(updated);
    applyTimelineHistory({std::move(updated),false,true}, true);
}
void Session::applyTimelineHistory(const TimelineHistory &state, bool recordHistory) {
    if (state.tempo) {
        syncClock();
        auto before = core.timingSnapshot();
        const auto previous = std::find_if(before.songs.begin(), before.songs.end(), [&](const auto& s) { return song() && s.id == song()->id; });
        core.restoreTimingSnapshot(state.project);
        if (song() && previous != before.songs.end()) {
            if (graphCancellation) prepareLiveGraph();
            else { audio.refreshTempo(*previous, *song()); publishTransport(true, true); }
        }
        if (recordHistory) {
            undoHistory.emplace_back(TimelineHistory{std::move(before), true});
            if (undoHistory.size() > 40) undoHistory.pop_front();
            redoHistory.clear();
        }
        dirty = true; notifyTiming(true); return;
    }
    jaras::validate(state.project);
    syncClock();
    TimelineHistory before{project(), state.tempo, state.itemControls, state.mixerControls, state.routingControls};
    const auto oldSong = song() ? std::optional<jaras::Song>(*song()) : std::nullopt;
    core.applyProjectEdit(state.project);
    if (song()) {
        if (state.mixerControls) {
            if (state.routingControls || graphCancellation) prepareLiveGraph();
            else { audio.setMixer(project(), *song()); updateRecordArms(); }
        } else if (state.itemControls && !graphCancellation && oldSong) {
            std::map<ID,const jaras::AudioClip*> previous;
            for(const auto &track:oldSong->tracks)for(const auto &clip:track.clips)previous.emplace(clip.id,&clip);
            for(const auto &track:song()->tracks)for(const auto &clip:track.clips) {
                const auto found=previous.find(clip.id);if(found==previous.end())continue;
                const auto &old=*found->second;
                if(std::tie(old.gain,old.pan,old.muted,old.phaseInverted,old.normalizationGain,old.fxBypassed,
                            old.fadeIn,old.fadeOut,old.fadeInCurve,old.fadeInSCurve,old.fadeOutCurve,old.fadeOutSCurve)==
                   std::tie(clip.gain,clip.pan,clip.muted,clip.phaseInverted,clip.normalizationGain,clip.fxBypassed,
                            clip.fadeIn,clip.fadeOut,clip.fadeInCurve,clip.fadeInSCurve,clip.fadeOutCurve,clip.fadeOutSCurve))continue;
                if(clip.midi && !clip.frozenMIDI.value_or(false))audio.previewMIDIItem(*song(),clip);
                else audio.setItemControls(clip);
            }
        } else if (graphCancellation) prepareLiveGraph();
        else if (state.tempo && oldSong) {
            audio.refreshTempo(*oldSong, *song());
            publishTransport(true, true);
        } else {
            // A moved/trimmed item on its existing track keeps its reader and
            // FX. Refresh only its time mapping before reconciling presence.
            if(oldSong) {
                std::map<ID,std::pair<ID,const jaras::AudioClip*>> previous;
                for(const auto &track:oldSong->tracks)for(const auto &clip:track.clips)
                    previous.emplace(clip.id,std::make_pair(track.id,&clip));
                for(const auto &track:song()->tracks)for(const auto &clip:track.clips) {
                    const auto found=previous.find(clip.id);
                    if(found==previous.end() || found->second.first!=track.id)continue;
                    const auto &old=*found->second.second;
                    if(std::tie(old.startTime,old.duration,old.sourceOffset,old.playbackRate,old.loopStart,old.loopLength)!=
                       std::tie(clip.startTime,clip.duration,clip.sourceOffset,clip.playbackRate,clip.loopStart,clip.loopLength))
                        audio.refreshItemTiming(*song(),clip);
                }
            }
            if (audio.refreshItemPresence(*song())) {
                audio.refreshTiming(*song());
                // A document edit does not seek either running head. The
                // callback can advance while the item/region mapping is being
                // prepared; republishing the core's sampled position here
                // replays that elapsed audio on mouse-up (also for text/video).
                publishTransport(false, true);
            } else prepareLiveGraph();
        }
    }
    if (recordHistory) {
        undoHistory.emplace_back(std::move(before));
        if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
        redoHistory.clear();
    }
    dirty = true; if (state.mixerControls) notifyMixer(); else notify();
}
void Session::edit(const std::function<void(jaras::Project &)> &change, bool rebuild, bool allowTimingEdit) {
    if (jaras::projectSync::readOnly()) return;
    if (busy)
        return;
    if (rebuild && audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de alterar a estrutura do projeto.");
    syncClock();
        auto before = snapshot();
    auto p = ProjectCodec::decode(before);
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
void Session::setTrackInstrumentIcon(const std::set<ID> &ids, std::optional<std::string> icon) {
    if(busy || jaras::projectSync::readOnly() || ids.empty()) return;
    if(icon && icon->empty()) icon.reset();
    auto p=project();
    bool changed=false;
    for(auto &song:p.songs) for(auto &track:song.tracks) if(ids.count(track.id) && track.instrumentIcon!=icon) {
        track.instrumentIcon=icon;changed=true;
    }
    if(!changed) return;
    syncClock();core.applyProjectEdit(std::move(p));
    // Icons are project metadata outside Undo, including existing redo snapshots.
    auto rebase=[&](auto &history) {
        for(auto &entry:history) {
            if(entry.timeline)
                for(auto &song:entry.timeline->project.songs) for(auto &track:song.tracks)
                    if(ids.count(track.id)) track.instrumentIcon=icon;
            if(entry.project.isObject()) {
                entry.project=entry.project.clone();
                for(auto song:list(get(entry.project,"songs"))) for(auto track:list(get(song,"tracks")))
                    if(ids.count(utf8(str(track,"id")))) {
                        if(icon) put(track,"instrumentIcon",text(*icon));
                        else if(auto *object=track.getDynamicObject()) object->removeProperty("instrumentIcon");
                    }
            }
        }
    };
    rebase(undoHistory);rebase(redoHistory);
    dirty=true;notify();
}
void Session::configureEffects(const ID &id, const var &settings) {
    if (jaras::projectSync::readOnly()) return;
    configureEffects(std::map<ID, var>{{id, settings}});
}
std::map<ID, var> Session::currentEffects(const std::map<ID, var> &targets) const {
    std::map<ID, var> result;
    for (const auto &[id, ignored] : targets) {
        if (id.empty()) result[id] = project().masterFXJSON ? JSON::parse(text(*project().masterFXJSON)) : var();
        else for (const auto &song : project().songs) for (const auto &track : song.tracks) {
            if (track.id == id) result[id] = track.fxJSON ? JSON::parse(text(*track.fxJSON)) : var();
            for (const auto &clip : track.clips)
                if (clip.id == id) result[id] = clip.fxJSON ? JSON::parse(text(*clip.fxJSON)) : var();
        }
    }
    for(auto &[id,settings]:result)audio.captureExternalEffects(id,settings);
    return result;
}
void Session::configureEffects(const std::map<ID, var> &changes) {
    if (jaras::projectSync::readOnly()) return;
    auto live=changes;
    for(auto &[id,settings]:live){settings=settings.clone();audio.captureExternalEffects(id,settings);}
    applyEffects(live, true);
}
String Session::copyEffect(const ID &source, const String &effect, const ID &destination, const String &before) {
    if (busy || !song()) return {};
    const auto valid = [&](const ID &id) {
        return id.empty() || std::any_of(song()->tracks.begin(), song()->tracks.end(), [&](const auto &track) {
            return track.id == id && jaras::fixedTrackName(track.role).empty();
        });
    };
    if (!valid(source) || !valid(destination)) return {};
    // This reads the live VST3 component/controller state, including libraries
    // and edits made in the plugin window since the last project save.
    const auto captured = currentEffects({{source, var()}, {destination, var()}});
    const auto original = captured.at(source);
    auto result = captured.at(destination).clone();
    if (!result.isObject()) result = fxschema::defaults();
    auto chain = list(get(result, "inserted"));
    if (!list(get(original, "inserted")).contains(var(effect)) ||
        (before.isNotEmpty() && !chain.contains(var(before)))) return {};
    String key;
    for (auto plugin : list(get(original, "externalPlugins"))) {
        if ("External:" + str(plugin, "id") != effect) continue;
        plugin = plugin.clone(); put(plugin, "id", text(uuid()));
        auto plugins = list(get(result, "externalPlugins")); plugins.add(plugin); put(result, "externalPlugins", plugins);
        key = "External:" + str(plugin, "id"); break;
    }
    if (key.isEmpty()) {
        String kind = effect; var parameters = original;
        for (const auto &instance : list(get(original, "instances"))) {
            if (effect != "Native:" + str(instance, "id") && effect != "Instance:" + str(instance, "id")) continue;
            kind = str(instance, "kind"); parameters = get(instance, "settings"); break;
        }
        if (kind == "Instruments" && destination.empty()) return {};
        auto isolated = fxschema::defaults();
        if (kind == "CatStemSeparation 5") {
            if (chain.contains(var(kind))) throw std::runtime_error("Esta pista já possui CatStemSeparation 5.");
            for (const auto property : {"stemSeparatorEnabled", "stemMix"})
                if (!get(parameters, property).isVoid()) put(result, property, get(parameters, property).clone());
            key = kind;
        } else {
            if (fxpresets::fields(kind).isEmpty()) return {};
            for (const auto &property : fxpresets::fields(kind))
                if (!get(parameters, Identifier(property)).isVoid()) put(isolated, Identifier(property), get(parameters, Identifier(property)).clone());
            put(isolated, "inserted", Array<var>{kind});
            auto instance = object(); const auto identifier = text(uuid());
            put(instance, "id", identifier); put(instance, "kind", kind); put(instance, "settings", isolated);
            auto instances = list(get(result, "instances")); instances.add(instance); put(result, "instances", instances);
            key = "Native:" + identifier;
        }
    }
    chain.insert(before.isEmpty() ? chain.size() : chain.indexOf(var(before)), key);
    put(result, "inserted", chain);
    configureEffects(destination, result);
    return key;
}
void Session::applyEffects(const std::map<ID, var> &changes, bool recordHistory) {
    if (busy || changes.empty())
        return;
    syncClock();
    auto before = currentEffects(changes);
    auto p = project();
    auto canonical = changes;
    for (auto &[id, settings] : canonical) settings = fxschema::complete(settings);
    for (const auto &[id, settings] : canonical) {
        const std::optional<std::string> json = settings.isVoid() ? std::nullopt : std::optional<std::string>(utf8(JSON::toString(settings, true, 17)));
        bool found = id.empty();
        if (id.empty()) p.masterFXJSON = json;
        else for (auto &song : p.songs) for (auto &track : song.tracks) {
            if (track.id == id) { track.fxJSON = json; found = true; }
            for (auto &clip : track.clips)
                if (clip.id == id) { clip.fxJSON = json; found = true; }
        }
        if (!found) throw std::runtime_error("A faixa deste efeito não existe mais.");
    }
    jaras::validate(p);
    try {
        for (const auto &[id, settings] : canonical) audio.setEffects(id, settings);
    } catch (...) {
        const auto failure = std::current_exception();
        bool restored = true;
        // Preparation may reuse a live processor. Restore every destination,
        // including the one that failed, before keeping the old project/Undo.
        for (const auto &[id, settings] : before)
            try { audio.setEffects(id, settings); } catch (...) { restored = false; }
        if (!restored) {
            core.execute({jaras::CommandKind::stopAll});
            publishTransport();
            throw std::runtime_error("Não foi possível aplicar os efeitos nem restaurar todo o áudio. A reprodução foi parada; reabra o projeto salvo.");
        }
        std::rethrow_exception(failure);
    }
    core.applyProjectEdit(std::move(p));
    if (recordHistory) {
        undoHistory.emplace_back(std::move(before));
        if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
        redoHistory.clear();
    }
    dirty = true;
    notify();
}
Session::ItemPitchHistory Session::itemPitchHistory(const ID &id) const {
    for (const auto &song : project().songs) for (const auto &track : song.tracks)
        for (const auto &clip : track.clips) if (clip.id == id) return {song.id, id, clip.pitchSemitones};
    throw std::runtime_error("Unknown item");
}
void Session::applyItemPitchHistory(ItemPitchHistory state, bool recordHistory) {
    syncClock();
    const auto before = itemPitchHistory(state.item);
    if (before.semitones == state.semitones) return;
    core.setClipPitchState(state.item, state.semitones);
    try {
        if (song() && song()->id == state.song) {
            if (graphCancellation) prepareLiveGraph();
            else audio.refreshItemPitch(*song(), state.item);
        }
    } catch (...) { core.setClipPitchState(before.item, before.semitones); throw; }
    if (recordHistory) {
        undoHistory.emplace_back(before);
        if (undoHistory.size() > 40) undoHistory.pop_front();
        redoHistory.clear();
    }
    dirty = true; message.clear(); notifyTiming(false);
}
void Session::setItemPitch(const ID &id, double semitones) {
    if (busy || jaras::projectSync::readOnly()) return;
    auto state = itemPitchHistory(id); state.semitones = semitones;
    applyItemPitchHistory(std::move(state), true);
}
Session::PitchHistory Session::pitchHistory(const ID& id) const {
    if (song()) for (const auto& part : song()->parts) if (part.id == id)
        return {id, part.pitchSemitones, part.pitchTrackIDs, part.pitchGroupIDs};
    throw std::runtime_error("Unknown region");
}
void Session::applyPitchHistory(PitchHistory state, bool recordHistory) {
    syncClock();
    const auto before = pitchHistory(state.region);
    if (before.semitones == state.semitones && before.tracks == state.tracks && before.groups == state.groups) return;
    core.setRegionPitchState(state.region, state.semitones, std::move(state.tracks), std::move(state.groups));
    try { audio.refreshRegionPitch(*song(), state.region); }
    catch (...) { core.setRegionPitchState(before.region, before.semitones, before.tracks, before.groups); throw; }
    if (recordHistory) {
        undoHistory.emplace_back(before);
        if (undoHistory.size() > 40) undoHistory.pop_front();
        redoHistory.clear();
    }
    dirty = true; message.clear(); notifyTiming(false);
}
void Session::setRegionPitch(const ID &id, int semitones, std::vector<ID> tracks, std::vector<ID> groups) {
    if (busy || !song() || jaras::projectSync::readOnly()) return;
    applyPitchHistory({id, semitones, std::move(tracks), std::move(groups)}, true);
}
double Session::tempoBPM() const {
    return song() ? tempoEditing::bpm(*song(), tempoEditing::position(*song(), transport())) : 120;
}
void Session::setMeter(int beats, int unit) {
    if (busy || !song() || (song()->beatsPerBar == beats && song()->beatUnit == unit)) return;
    syncClock();
    const auto before = snapshot();
    core.setProjectTiming(song()->bpm, beats, unit, song()->timeSettings);
    audio.refreshTiming(*song()); publishTransport(false,true);
    undoHistory.emplace_back(before);
    if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
    redoHistory.clear(); dirty = true; message.clear(); notify();
}
void Session::setTempo(double value) {
    if (jaras::projectSync::readOnly()) return;
    if (busy || !song() || !std::isfinite(value)) return;
    if (audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de alterar o andamento.");
    const auto profile=SystemStats::getEnvironmentVariable("CATLIVE_PROFILE_TEMPO",{});
    auto measurements=object();auto stage=Time::getMillisecondCounterHiRes();
    const auto mark=[&](const char* name){if(profile.isNotEmpty()){const auto now=Time::getMillisecondCounterHiRes();put(measurements,name,now-stage);stage=now;}};
    syncClock();mark("clock");
    value = jlimit(60., 300., value);
    if (std::abs(value - tempoBPM()) < .0000001) return;
    TimelineHistory before{core.timingSnapshot(), true};
    // Timing history owns metadata only; peak samples stay in the live document.
    const auto &oldSong = *std::find_if(before.project.songs.begin(), before.project.songs.end(),
                                     [&](const auto &candidate) { return candidate.id == song()->id; });mark("historyAndSongCopy");
    if (const auto *part = tempoEditing::region(oldSong, transport())) {
        const auto targets = tempoEditing::regionChange(oldSong, *part, value - tempoBPM());
        if (targets.empty()) return;
        core.setMarkers(targets, {}, true);
    } else if (const auto *active = tempoEditing::active(oldSong, tempoEditing::position(oldSong, transport()))) {
        auto marker = *active; marker.tempoBPM = value;
        core.setMarkers({marker}, {}, true);
    } else core.setProjectTiming(value, oldSong.beatsPerBar, oldSong.beatUnit, oldSong.timeSettings);
    mark("coreTiming");
    const auto &updated = *song();
    // A structural edit in flight still owns a graph replacement. Otherwise
    // retime the running voices without recreating readers, FX or FFT state.
    if (graphCancellation) prepareLiveGraph();
    else {
        audio.refreshTempo(oldSong, updated);mark("audioTiming");
        publishTransport(true, true);mark("publishTransport");
    }
    undoHistory.emplace_back(std::move(before));
    if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
    redoHistory.clear(); dirty = true; message.clear();mark("historyCommit");notifyTiming(true);mark("workspace");
    if(profile.isNotEmpty())File(profile).appendText(JSON::toString(measurements,true)+"\n");
}
void Session::configureTiming(double bpm, int beats, int unit,
                              jaras::ProjectTimeSettings settings) {
    if (jaras::projectSync::readOnly()) return;
    if (busy || audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de alterar o tempo do projeto.");
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
    if (p.id != project().id) core.execute({jaras::CommandKind::stopAll});
    if (p.id == project().id) core.applyProjectEdit(std::move(p));
    else core.loadProject(std::move(p));
    original = raw;
    prepare();
    dirty = true;
    notify();
}
void Session::undo() {
    if (jaras::projectSync::readOnly()) return;
    if (!canUndo() || busy)
        return;
    if (audio.isRecording())
        throw std::runtime_error("Pare para desfazer alterações.");
    auto value = undoHistory.back();
    if (value.timeline) redoHistory.emplace_back(TimelineHistory{value.timeline->tempo ? core.timingSnapshot() : project(), value.timeline->tempo, value.timeline->itemControls, value.timeline->mixerControls, value.timeline->routingControls});
    else if (value.pitch) redoHistory.emplace_back(pitchHistory(value.pitch->region));
    else if (value.itemPitch) redoHistory.emplace_back(itemPitchHistory(value.itemPitch->item));
    else if (value.setlist) redoHistory.emplace_back(SetlistHistory{project().regionSetlist});
    else if (value.effects) redoHistory.emplace_back(currentEffects(*value.effects));
    else if (value.markers) redoHistory.emplace_back(markerHistory(value.markers->song));
    else if (value.itemTiming) redoHistory.emplace_back(itemTimingHistory(value.itemTiming->clip.id));
    else if (value.items) redoHistory.emplace_back(itemHistory(*value.items));
    else if (value.hierarchy) redoHistory.emplace_back(trackHierarchyHistory(value.hierarchy->song));
    else redoHistory.emplace_back(snapshot());
    undoHistory.pop_back();
    if (value.timeline) applyTimelineHistory(*value.timeline, false);
    else if (value.pitch) applyPitchHistory(*value.pitch, false);
    else if (value.itemPitch) applyItemPitchHistory(*value.itemPitch, false);
    else if (value.setlist) applySetlistHistory(*value.setlist, false);
    else if (value.effects) applyEffects(*value.effects, false);
    else if (value.markers) applyMarkerHistory(*value.markers, false);
    else if (value.itemTiming) applyItemTiming(*value.itemTiming, false);
    else if (value.items) applyItemHistory(*value.items, false);
    else if (value.hierarchy) applyTrackHierarchy(*value.hierarchy, false);
    else restoreSnapshot(value.project);
}
void Session::redo() {
    if (jaras::projectSync::readOnly()) return;
    if (!canRedo() || busy)
        return;
    if (audio.isRecording())
        throw std::runtime_error("Pare para refazer alterações.");
    auto value = redoHistory.back();
    if (value.timeline) undoHistory.emplace_back(TimelineHistory{value.timeline->tempo ? core.timingSnapshot() : project(), value.timeline->tempo, value.timeline->itemControls, value.timeline->mixerControls, value.timeline->routingControls});
    else if (value.pitch) undoHistory.emplace_back(pitchHistory(value.pitch->region));
    else if (value.itemPitch) undoHistory.emplace_back(itemPitchHistory(value.itemPitch->item));
    else if (value.setlist) undoHistory.emplace_back(SetlistHistory{project().regionSetlist});
    else if (value.effects) undoHistory.emplace_back(currentEffects(*value.effects));
    else if (value.markers) undoHistory.emplace_back(markerHistory(value.markers->song));
    else if (value.itemTiming) undoHistory.emplace_back(itemTimingHistory(value.itemTiming->clip.id));
    else if (value.items) undoHistory.emplace_back(itemHistory(*value.items));
    else if (value.hierarchy) undoHistory.emplace_back(trackHierarchyHistory(value.hierarchy->song));
    else undoHistory.emplace_back(snapshot());
    redoHistory.pop_back();
    if (value.timeline) applyTimelineHistory(*value.timeline, false);
    else if (value.pitch) applyPitchHistory(*value.pitch, false);
    else if (value.itemPitch) applyItemPitchHistory(*value.itemPitch, false);
    else if (value.setlist) applySetlistHistory(*value.setlist, false);
    else if (value.effects) applyEffects(*value.effects, false);
    else if (value.markers) applyMarkerHistory(*value.markers, false);
    else if (value.itemTiming) applyItemTiming(*value.itemTiming, false);
    else if (value.items) applyItemHistory(*value.items, false);
    else if (value.hierarchy) applyTrackHierarchy(*value.hierarchy, false);
    else restoreSnapshot(value.project);
}
void Session::importAudio(const Array<File> &files, double at) { importMedia(files,at,{},MediaDropLayout::separateTracks,0); }
void Session::importMedia(const Array<File> &files,double at,ID targetTrack,MediaDropLayout layout,double gap,
                          std::function<void(String)> completion, bool deferWaveform) {
    if(busy||files.isEmpty())return;
    if(audio.isRecording())throw std::runtime_error("Conclua a gravação antes de importar mídia.");
    if(!song()||!std::isfinite(at)||at<0||!std::isfinite(gap)||gap<0||gap>60)throw std::runtime_error("Posição ou intervalo de importação inválido.");
    auto songID=song()->id,projectID=project().id;auto directory=mediaDirectory;
    auto target=std::find_if(song()->tracks.begin(),song()->tracks.end(),[&](auto &t){return t.id==targetTrack;});
    if(!targetTrack.empty()&&target==song()->tracks.end())throw std::runtime_error("A pista de destino não existe mais.");
    const auto targetRole=target==song()->tracks.end()?jaras::TrackRole{}:target->role;
    if(targetRole.id=="programChange")throw std::runtime_error("A pista Program Change aceita apenas comandos MIDI Program Change.");
    auto weak=std::weak_ptr<int>(alive);busy=true;importProgress=0;message=String::fromUTF8("Importando mídia…");notify();
    worker.addJob([this,weak,files,at,targetTrack,layout,gap,songID,projectID,directory,targetRole,completion,deferWaveform]{
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
                if((!projection||layout==MediaDropLayout::stacked)&&!jaras::fixedTrackName(targetRole).empty())throw std::runtime_error("Solte arquivos de áudio em uma pista padrão.");
                if(!sources.empty()&&sources.front().projection!=projection)throw std::runtime_error("Arraste áudio e vídeo separadamente.");
                sources.push_back({file,duration,projection});
            }
            double cursor=at;
            for(size_t i=0;i<sources.size();++i) {
                const auto &source=sources[i];jaras::AudioClip clip;clip.id=uuid();clip.name=utf8(source.file.getFileNameWithoutExtension());clip.startTime=layout==MediaDropLayout::sameTrack?cursor:at;clip.duration=source.duration;
                auto relative=String(source.projection?"Videos/":"Stems/")+text(clip.id)+source.file.getFileExtension().toLowerCase();
                auto destination=directory.getChildFile(relative);destination.getParentDirectory().createDirectory();copied.add(destination);
                if(!source.file.copyFileTo(destination))throw std::runtime_error("Não foi possível copiar a mídia para o projeto.");
                clip.audioFile=jaras::AudioFile{utf8(relative),{}};
                if(!source.projection&&!deferWaveform){std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(source.file));if(!reader)throw std::runtime_error("Não foi possível ler o áudio.");clip.waveform=waveform(*reader);}
                if(layout==MediaDropLayout::separateTracks||tracks.empty()){jaras::Track track;track.id=i==0&&!targetTrack.empty()?targetTrack:uuid();track.name=clip.name;track.role.id=i==0&&!targetTrack.empty()?targetRole.id:"other";track.color=0x828282;tracks.push_back(std::move(track));}
                tracks.back().clips.push_back(std::move(clip));cursor+=source.duration+gap;
                MessageManager::callAsync([this,weak,i,total=sources.size()]{if(!weak.expired()){importProgress=double(i+1)/total;if(changed)changed();}});
            }
        }catch(const std::exception &e){error=String::fromUTF8(e.what());}
        MessageManager::callAsync([this,weak,tracks=std::move(tracks),copied,songID,projectID,targetTrack,layout,error,completion]()mutable{
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
                        if(found==song->tracks.end()){song->tracks.push_back(std::move(imported));found=std::prev(song->tracks.end());}
                        else {
                            // Move the batch as a unit past existing material, preserving
                            // the user's sequence and interval. Stacked import explicitly keeps
                            // simultaneous items in separate visual lanes on the same track.
                            double shift=0;bool collision=layout!=MediaDropLayout::stacked;
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
            }catch(const std::exception &e){for(auto &f:copied)f.deleteFile();error=String::fromUTF8(e.what());message=error;}
            notify();
            if(!weak.expired()&&completion)completion(error);
        });
    });
}
void Session::addTrack(String name, String role) {
    auto id = song() ? song()->id : ID{};
    edit([&](jaras::Project &p) {
        for (auto &s : p.songs)
            if (s.id == id) {
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
void Session::renderItems(std::set<ID> ids,bool glue,int midiChannels,std::function<void(std::set<ID>)> completed) {
    if(busy || !song() || ids.empty())return;
    if(audio.isRecording())throw std::runtime_error("Conclua a gravação antes de renderizar itens.");
    if(canPlay && !canPlay())throw std::runtime_error("Valide sua licença para renderizar áudio.");
    if(!mediaDirectory.isDirectory() || document==File{})throw std::runtime_error("Salve o projeto antes de renderizar itens.");
    const auto source=project();const auto sourceSong=*song();const auto directory=mediaDirectory;
    exportCancelled=false;busy=true;importProgress=0;message=String::fromUTF8(glue?"Unificando itens…":"Renderizando itens…");notify();
    auto weak=std::weak_ptr<int>(alive);
    worker.addJob([this,weak,source,sourceSong,directory,ids,glue,midiChannels,completed] {
        std::vector<itemRender::Replacement> replacements;String error;
        try{replacements=itemRender::render(source,sourceSong,directory,ids,glue,midiChannels,exportCancelled,[this,weak](double progress){MessageManager::callAsync([this,weak,progress]{if(!weak.expired()){importProgress=progress;if(changed)changed();}});});
            AudioFormatManager formats;registerAudioFormats(formats);for(auto &r:replacements)if(r.generated.existsAsFile()){std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(r.generated));if(!reader)throw std::runtime_error("Não foi possível ler o item renderizado.");r.clip.waveform=waveform(*reader);}
        }catch(const std::exception &e){error=String::fromUTF8(e.what());}
        MessageManager::callAsync([this,weak,source,sourceSong,replacements=std::move(replacements),error,completed]() mutable {
            auto discard=[&]{for(const auto &r:replacements)if(r.generated!=File{})r.generated.deleteFile();};
            if(weak.expired()){discard();return;}busy=false;
            if(error.isEmpty() && (project().id!=source.id || !song() || song()->id!=sourceSong.id || exportCancelled.load()))error=String::fromUTF8("Operação cancelada.");
            if(error.isEmpty())try {edit([&](jaras::Project &p){for(auto &s:p.songs)if(s.id==sourceSong.id)for(auto &t:s.tracks)for(const auto &r:replacements)if(t.id==r.track){t.clips.erase(std::remove_if(t.clips.begin(),t.clips.end(),[&](const auto &c){return r.originals.count(c.id)>0;}),t.clips.end());t.clips.push_back(r.clip);std::stable_sort(t.clips.begin(),t.clips.end(),[](const auto &a,const auto &b){return a.startTime<b.startTime;});}});}
            catch(const std::exception &e){error=String::fromUTF8(e.what());}
            if(error.isNotEmpty())discard();importProgress=error.isEmpty()?1:0;message=error;notify();
            if(error.isEmpty() && completed){std::set<ID> rendered;for(const auto &r:replacements)rendered.insert(r.clip.id);completed(std::move(rendered));}
        });
    });
}
void Session::separateAudioItem(ID id,std::function<void(std::set<ID>)> completed) {
    if(busy||!song())return;
    if(audio.isRecording())throw std::runtime_error("Conclua a gravação antes de separar áudio.");
    if(canPlay&&!canPlay())throw std::runtime_error("Valide sua licença para separar áudio.");
    if(document==File{}||!mediaDirectory.isDirectory())throw std::runtime_error("Salve o projeto antes de separar áudio.");
    const auto source=project();const auto sourceSong=*song();const auto directory=mediaDirectory;
    for(const auto &track:sourceSong.tracks)for(const auto &clip:track.clips)if(clip.id==id) {
        if(!audioSeparation::eligible(track,clip))throw std::runtime_error("Selecione apenas um item de áudio.");
        exportCancelled=false;busy=true;importProgress=0;message=String::fromUTF8("Preparando a separação de áudio…");notify();
        auto weak=std::weak_ptr<int>(alive);
        worker.addJob([this,weak,source,sourceSong,directory,track,clip,completed] {
            audioSeparation::Result result;String error;
            try {
                result=audioSeparation::render(source,sourceSong,track,clip,directory,exportCancelled,[this,weak](double value,String text) {
                    MessageManager::callAsync([this,weak,value,text]{if(!weak.expired()){importProgress=value;message=text;if(changed)changed();}});
                });
                AudioFormatManager formats;registerAudioFormats(formats);
                for(size_t row=0;row<result.tracks.size();++row) {
                    std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(result.files[row]));
                    if(!reader)throw std::runtime_error("Não foi possível ler o áudio separado.");
                    result.tracks[row].clips[0].waveform=waveform(*reader);
                }
            }catch(const std::exception &failure){error=String::fromUTF8(failure.what());}
            MessageManager::callAsync([this,weak,source,sourceSong,track,clip,result=std::move(result),error,completed]() mutable {
                auto discard=[&]{for(const auto &file:result.files)file.deleteFile();};
                if(weak.expired()){discard();return;}busy=false;
                if(error.isEmpty()&&(project().id!=source.id||!song()||song()->id!=sourceSong.id||exportCancelled.load()||jaras::projectSync::readOnly()))error=String::fromUTF8("Separação cancelada.");
                if(error.isEmpty())try{edit([&](jaras::Project &project){audioSeparation::commit(project,sourceSong.id,track.id,clip,result.tracks);});}
                catch(const std::exception &failure){error=String::fromUTF8(failure.what());}
                if(error.isNotEmpty())discard();
                importProgress=error.isEmpty()?1:importProgress;message=error.isEmpty()?String::fromUTF8("Separação concluída. O original foi preservado e silenciado."):error;notify();
                if(error.isEmpty()&&completed){std::set<ID> ids;for(const auto &stem:result.tracks)ids.insert(stem.clips[0].id);completed(std::move(ids));}
            });
        });return;
    }
    throw std::runtime_error("O item de áudio não está mais disponível.");
}
void Session::exportAudio(ExportRequest request) {
    if (busy || !song())
        return;
    if (audio.isRecording())
        throw std::runtime_error("Conclua a gravação antes de exportar.");
    if (canPlay && !canPlay())
        throw std::runtime_error("Valide sua licença para exportar áudio.");
    const auto projectCopy = project();
    const auto songCopy = *song();
    const auto directory = mediaDirectory;
    exportCancelled = false; exportFailed = false;
    { const ScopedLock guard(exportProgressLock); exportPreview = {}; exportPreview.total = int(request.jobs.size()); }
    busy = true;
    importProgress = 0;
    message = String::fromUTF8("Renderizando áudio…");
    notify();
    auto weak = std::weak_ptr<int>(alive);
    worker.addJob([this, weak, projectCopy, songCopy, directory, request = std::move(request)] {
        String error;
        try {
            audioExport::render(projectCopy, songCopy, directory, request, exportCancelled, {},
                [this](const AudioExportProgress &progress) {
                    // The export panel polls this small snapshot. Do not rebuild
                    // the entire workspace for each rendered waveform update.
                    const ScopedLock guard(exportProgressLock); exportPreview = progress;
                });
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
        }
        MessageManager::callAsync([this, weak, error, count = (int)request.jobs.size()] {
            if (weak.expired())
                return;
            busy = false; exportFailed = error.isNotEmpty();
            if (!exportFailed) importProgress = 1;
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
std::optional<jaras::ProgramChangeMarker> Session::scanProgramChange(const ID &id) {
    if(busy || jaras::projectSync::readOnly() || !song())return {};
    const auto found=std::find_if(song()->tracks.begin(),song()->tracks.end(),[&](const auto &t){return t.id==id && t.role.id=="programChange";});
    if(found==song()->tracks.end())return {};
    const auto packet=audio.latestProgramChange(found->midiInput.value_or(0));
    if(!scanningProgramChange(id)) {
        programChangeScanProject=project().id;programChangeScanTrack=id;programChangeScanBaseline=packet;return {};
    }
    if(!packet || packet==programChangeScanBaseline) {
        programChangeScanTrack.clear();programChangeScanProject.clear();programChangeScanBaseline=0;
        return {};
    }
    return jaras::ProgramChangeMarker{uuid(),transport().editPosition,int(packet&127),int((packet>>7)&15)+1,{},found->midiOutput.value_or(0)};
}
ID Session::insertProgramChange(const ID &track, jaras::ProgramChangeMarker marker) {
    if(busy || jaras::projectSync::readOnly() || !song())return {};
    const auto found=std::find_if(song()->tracks.begin(),song()->tracks.end(),[&](const auto &t){return t.id==track && t.role.id=="programChange";});
    if(found==song()->tracks.end())return {};
    marker.name=utf8(text(marker.name).trim().substring(0,12));
    if(marker.name.empty())return {};
    if(std::count_if(found->programChanges.begin(),found->programChanges.end(),[&](const auto &m){return std::abs(m.position-marker.position)<.000001;})>=6)
        throw std::runtime_error("O limite é de 6 marcadores de timbre no mesmo ponto.");
    if(!marker.output)marker.output=found->midiOutput;
    if(!marker.output || *marker.output<1 || *marker.output>6)throw std::runtime_error("Escolha uma saída MIDI no Patch.");
    marker.id=uuid();
    editTrackSettings([&](auto &p){for(auto &song:p.songs)for(auto &t:song.tracks)if(t.id==track) {
        t.programChanges.push_back(marker);
        std::stable_sort(t.programChanges.begin(),t.programChanges.end(),[](const auto&a,const auto&b){return a.position<b.position;});
        song.duration=std::max(song.duration,marker.position+1);
    }},false);
    selectedProgramChange=marker.id;
    return marker.id;
}
const jaras::ProgramChangeMarker *Session::selectedProgramMarker() const {
    if(song())for(const auto &t:song()->tracks)for(const auto &m:t.programChanges)if(m.id==selectedProgramChange)return &m;
    return nullptr;
}
bool Session::copyProgramChange() {
    const auto *marker=selectedProgramMarker();if(!marker)return false;
    programChangeClipboard=*marker;programChangePasteReady=true;return true;
}
bool Session::pasteProgramChange() {
    if(!programChangeClipboard || !song())return false;
    for(const auto &track:song()->tracks)if(track.role.id=="programChange") {
        auto marker=*programChangeClipboard;marker.position=transport().editPosition;
        return !insertProgramChange(track.id,marker).empty();
    }
    return false;
}
void Session::removeProgramChange(const ID &track, const ID &marker) {
    if(selectedProgramChange==marker)selectedProgramChange.clear();
    editTrackSettings([&](auto &p){for(auto &song:p.songs)for(auto &t:song.tracks)if(t.id==track)
        t.programChanges.erase(std::remove_if(t.programChanges.begin(),t.programChanges.end(),[&](const auto &m){return m.id==marker;}),t.programChanges.end());},false);
}
void Session::removeTrack(ID id) {
    removeTracks({id});
}
void Session::removeTracks(const std::set<ID> &ids) {
    if (ids.empty() || busy || jaras::projectSync::readOnly()) return;
    if (audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de apagar pistas.");
    auto updated = project();
    for (auto &song : updated.songs) for (const auto &id : ids) trackTree::remove(song, id);
    if (timelineGrid::changesLockedGeometry(project(), updated))
        throw std::runtime_error("Desbloqueie o cadeado para apagar pistas.");
    // The history owns native models, not a JSON round trip of every waveform.
    // Capture only processors that will disappear, preserving their Undo state.
    TimelineHistory before{project()};
    std::set<ID> retained;
    for (const auto &song : updated.songs) for (const auto &track : song.tracks) retained.insert(track.id);
    auto capture=[&](const ID &id, std::optional<std::string> &json) {
        if(!json)return;
        auto settings=JSON::parse(text(*json)); audio.captureExternalEffects(id,settings);
        json=utf8(JSON::toString(settings,true,17));
    };
    bool removed=false;
    for(auto &song:before.project.songs)for(auto &track:song.tracks)if(!retained.count(track.id)) {
        removed=true; capture(track.id,track.fxJSON);
        for(auto &clip:track.clips)capture(clip.id,clip.fxJSON);
    }
    if(!removed)return;
    const auto owned=mediaCleanup::references(project()); observedMedia.insert(owned.begin(),owned.end());
    applyTimelineHistory({std::move(updated)},false);
    undoHistory.emplace_back(std::move(before));
    if(undoHistory.size()>40)undoHistory.pop_front();
    redoHistory.clear();
}
Session::ItemHistory Session::itemHistory(const ItemHistory &targets) const {
    ItemHistory result;
    for (const auto &song : project().songs) for (const auto &track : song.tracks) {
        const auto target = targets.tracks.find(track.id);
        if (target == targets.tracks.end()) continue;
        auto clips = track.clips;
        std::set<ID> retained;
        for (const auto &clip : target->second) retained.insert(clip.id);
        // Capture only plugins belonging to items being removed. Their Undo
        // remains complete even if a later structural edit retires the cache.
        for (auto &clip : clips) if (!retained.count(clip.id) && clip.fxJSON) {
            auto settings = JSON::parse(text(*clip.fxJSON));
            audio.captureExternalEffects(clip.id, settings);
            clip.fxJSON = utf8(JSON::toString(settings, true, 17));
        }
        result.tracks.emplace(track.id, std::move(clips));
    }
    return result;
}
void Session::applyItemHistory(const ItemHistory &state, bool recordHistory, const std::map<ID, ID> &splitSources) {
    syncClock();
    auto before = recordHistory ? itemHistory(state) : ItemHistory{};
    auto updated = project();
    for (auto &song : updated.songs) for (auto &track : song.tracks)
        if (const auto found = state.tracks.find(track.id); found != state.tracks.end()) track.clips = found->second;
    if (timelineGrid::changesLockedGeometry(project(), updated))
        throw std::runtime_error("Desbloqueie o cadeado para apagar ou restaurar itens.");
    auto next = core;
    next.applyProjectEdit(updated);
    // Preserve media ownership, including files referenced only by this Undo.
    const auto owned = mediaCleanup::references(project());
    observedMedia.insert(owned.begin(), owned.end());
    bool refreshed = false;
    if (!graphCancellation && song() && next.currentSong() && preparedSong == song()->id &&
        audio.cacheSplitItems(*next.currentSong(), splitSources))
        refreshed = audio.refreshItemPresence(*next.currentSong());
    core.applyProjectEdit(std::move(updated));
    if (!refreshed) prepareLiveGraph();
    if (recordHistory) {
        undoHistory.emplace_back(std::move(before));
        if (undoHistory.size() > 40) undoHistory.erase(undoHistory.begin());
        redoHistory.clear();
    }
    dirty = true;
    notify();
}
void Session::splitClips(const std::set<ID> &ids, double at) {
    if (jaras::projectSync::readOnly() || busy || !song() || !std::isfinite(at)) return;
    if (audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de cortar itens.");
    auto edited = *song();
    std::map<ID, ID> sources;
    clipEditing::splitSelected(edited, ids, at, &sources);
    if (sources.empty()) return;
    ItemHistory next;
    for (const auto &track : edited.tracks)
        if (std::any_of(track.clips.begin(), track.clips.end(), [&](const auto &clip) { return sources.count(clip.id); }))
            next.tracks.emplace(track.id, track.clips);
    applyItemHistory(next, true, sources);
}
void Session::removeClip(ID id) { removeClips({id}); }
void Session::removeClips(const std::set<ID> &ids) {
    if (jaras::projectSync::readOnly() || busy || ids.empty()) return;
    if (audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de apagar itens.");
    ItemHistory next;
    for (const auto &song : project().songs) for (const auto &track : song.tracks) {
        if (std::none_of(track.clips.begin(), track.clips.end(), [&](const auto &clip) { return ids.count(clip.id); })) continue;
        auto clips = track.clips;
        clips.erase(std::remove_if(clips.begin(), clips.end(), [&](const auto &clip) { return ids.count(clip.id); }), clips.end());
        next.tracks.emplace(track.id, std::move(clips));
    }
    if (!next.tracks.empty()) applyItemHistory(next, true);
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
        if ((transport().playing || transport().subPlay.playing) && audio.outputAvailabilityError().isNotEmpty()) {
            core.execute({jaras::CommandKind::stopAll}); publishTransport(); cancelTransportFadeout();
            message="Audio device disconnected. Playback stopped.";
            if(audioOutputWarning) audioOutputWarning(message);
            notify();
        }
        if (audio.isRecording() && audio.recordedSamples() > 0 && !audio.transportClockPending() && !audio.state().playing) {
            toggleRecording();
            return;
        }
        syncClock();
        updateTransportFadeout();
        if (playbackUpdate)
            playbackUpdate(presentationTransport());
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

namespace catlive {
void Session::applyProjectSync(const jaras::projectSync::Frame &frame, double elapsed, bool first, std::optional<ID> focused) {
    if(canPlay && !canPlay()) throw std::runtime_error("Project Sync: playback access is unavailable.");
    syncClock();
    const auto oldSong=transport().songId;
    const auto oldRegion=transport().regionId;
    const auto oldExclusiveTracks=project().regionSetlist ? project().regionSetlist->subplayExclusiveTrackIDs : std::nullopt;
    bool mixerChanged=false;
    const bool changed=core.applyProjectSync(frame, elapsed, first, &mixerChanged);
    const auto exclusiveTracks=project().regionSetlist ? project().regionSetlist->subplayExclusiveTrackIDs : std::nullopt;
    if(mixerChanged || oldExclusiveTracks!=exclusiveTracks) {dirty=true;if(song())audio.setMixer(project(),*song());}
    if(focused) {
        auto source=*focused;
        if(project().regionSetlist) for(const auto &playlist:project().regionSetlist->playlists)
            if(playlist.id==project().regionSetlist->selectedId) source=playlist.resolvedRegionId(source);
        if(!song() || !std::any_of(song()->parts.begin(),song()->parts.end(),[&](const auto &part){return part.id==source;})) focused.reset();
    }
    const bool focusChanged=focusedRegion!=focused;
    if(focusChanged) {focusedRegion=focused;++setlistFocusRevision;}
    if(changed) {
        if(oldSong!=transport().songId) { prepare(); }
        publishTransport();
    }
    if(oldSong!=transport().songId || oldRegion!=transport().regionId) {
        if(selectionChanged) selectionChanged();
    }
    if(mixerChanged || focusChanged || first) notify();
    if(playbackUpdate) playbackUpdate(transport());
    if(tick) tick();
}
}
