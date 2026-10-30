#include "FrontendBridge.h"
#include "NativeFrontendWaveforms.h"
#include "Localization.h"
#include "TempoEditing.h"
#include "FXSchema.h"
#include "FXChain.h"
#include "CatDynamicsAssets.h"
#include "Appearance.h"
#include "ClipEditing.h"
#include "FrontendPresentation.h"
#include "GridMediaClipboard.h"
#include <shobjidl.h>
#include <wrl/client.h>

namespace catlive {
namespace {
var optionalID(const std::optional<ID> &value) { return value ? var(text(*value)) : var(); }
var ids(const std::set<ID> &values) {
    Array<var> result;
    for (const auto &value : values) result.add(text(value));
    return result;
}


var button(const String &id, const String &label) {
    auto result = object(); put(result, "id", id); put(result, "label", label); return result;
}
String localized(const char *en, const char *pt) { return String::fromUTF8(localization::english ? en : pt); }
double finiteNumber(const var &value, const Identifier &key) {
    const auto data = get(value, key);
    if ((!data.isInt() && !data.isInt64() && !data.isDouble()) || !std::isfinite((double)data))
        throw std::invalid_argument("A finite number is required.");
    return (double)data;
}
}

struct FrontendBridge::RTAState {
    ID track; String key;
    std::array<std::shared_ptr<analysis::Capture>, 2> sources;
    std::array<analysis::Frame, 2> frames;
    std::array<std::uint64_t, 2> serial{};
    analysis::Analyzer analyzer;
    double lastPoll = 0, rate = 48000;
    ~RTAState() { for (auto &source : sources) if (source) source->removeReader(); }
};
FrontendBridge::FrontendBridge(Session &s, Auth &a, Emit output, bool compact)
    : session(s), auth(a), emit(std::move(output)), compactPresentation(compact), waveforms(std::make_unique<NativeFrontendWaveforms>(s)) {
    previousCanPlay = session.canPlay;
    previousIsPlaying = auth.isPlaying;
    previousAudioWarning = session.audioOutputWarning;
    previousFadeoutWarning = session.transportFadeoutWarning;
    previousInstrumentAllowed = session.audio.instrumentAllowed.load();
    session.audio.instrumentAllowed = auth.allowed();
    session.canPlay = [this] { return auth.allowed() && !auth.pendingRevocation && (!previousCanPlay || previousCanPlay()); };
    auth.isPlaying = [this] { return session.transport().playing || session.transport().subPlay.playing; };
    session.audioOutputWarning = [this](String message) { notice("CatLive", message); };
    session.transportFadeoutWarning = [this](String message) { notice("CatLive", message); };
    startTimerHz(20);
}
FrontendBridge::~FrontendBridge() {
    stopTimer(); lifetime.reset(); waveforms.reset(); rta.reset(); session.endMixerGesture();
    session.canPlay = std::move(previousCanPlay); auth.isPlaying = std::move(previousIsPlaying);
    session.audioOutputWarning = std::move(previousAudioWarning);
    session.transportFadeoutWarning = std::move(previousFadeoutWarning);
    session.audio.instrumentAllowed = previousInstrumentAllowed;
}
void FrontendBridge::send(var value) { if (emit) emit(JSON::toString(value, true, 17)); }
void FrontendBridge::reply(const var &id, var result, String error) {
    auto value = object(); put(value, "type", "reply"); put(value, "id", id); put(value, "ok", error.isEmpty());
    if (error.isNotEmpty()) put(value, "error", error); else put(value, "result", result);
    send(value);
}
void FrontendBridge::notice(String title, String message) {
    auto value = object(); put(value, "type", "notice"); put(value, "title", title); put(value, "message", message); send(value);
}
var FrontendBridge::transportJSON() const {
    const auto state = session.presentationTransport();
    auto value = object();
    put(value, "playing", state.playing); put(value, "position", state.position);
    put(value, "editPosition", state.editPosition); put(value, "bpm", session.tempoBPM());
    const auto *song = session.song();
    const auto *tempo = song ? tempoEditing::active(*song, tempoEditing::position(*song, state)) : nullptr;
    put(value, "beats", tempo ? tempo->tempoBeats.value_or(song->beatsPerBar) : song ? song->beatsPerBar : 4);
    put(value, "unit", tempo ? tempo->tempoUnit.value_or(song->beatUnit) : song ? song->beatUnit : 4);
    put(value, "selectedRegionID", optionalID(session.focusedRegion));
    put(value, "regionID", optionalID(state.regionId));
    put(value, "queuedRegionID", optionalID(state.queuedPlaylistEntryId ? state.queuedPlaylistEntryId : state.queuedRegionId));
    put(value, "playlistEntryID", optionalID(state.playlistEntryId));
    put(value, "songID", optionalID(state.songId)); put(value, "recording", session.audio.isRecording());
    put(value, "paused", state.paused); put(value, "loop", state.loop.enabled);
    put(value, "subPlaying", state.subPlay.playing); put(value, "subPosition", state.subPlay.position);
    put(value, "metronome", session.audio.metronomeEnabled.load());
    return value;
}
void FrontendBridge::publishSnapshot() {
    session.audio.instrumentAllowed = auth.allowed();
    refreshClipboard();
    // Do not call Session::snapshot here: that captures external plugin state.
    // The UI only needs the already-owned project, encoded on the UI thread.
    if (lastProject != session.project().id) {
        lastProject = session.project().id; selectedTracks.clear(); selectedItems.clear(); selectedRegions.clear(); meterTracks.clear();
        waveforms->invalidate(); rta.reset();
    }
    const auto encoded = compactPresentation ? frontendPresentation::project(session.project()) : ProjectCodec::encode(session.project(), session.original);
    var current;
    if(compactPresentation) {if(session.song()) current=frontendPresentation::song(*session.song());}
    else for (const auto &song : list(get(encoded, "songs")))
        if (session.song() && utf8(str(song, "id")) == session.song()->id) { current = song; break; }
    auto value = object(), selection = object(), access = object(), document = object();
    put(selection, "trackIDs", ids(selectedTracks)); put(selection, "itemIDs", ids(selectedItems)); put(selection, "regionIDs", ids(selectedRegions));
    put(access, "allowed", auth.allowed()); put(access, "busy", auth.busy); put(access, "title", auth.title);
    put(access, "message", auth.message); put(access, "requiresDeviceName", auth.requiresDeviceName);
    put(document, "path", session.document == File() ? String() : session.document.getFullPathName());
    put(document, "name", session.document == File() ? text(session.project().name) : session.document.getFileName());
    put(document, "projectID", text(session.project().id));
    put(value, "type", "snapshot"); put(value, "revision", (int64)session.revision);
    put(value, "project", encoded); put(value, "song", current); put(value, "selection", selection);
    put(value, "clipboard", clipboardJSON());
    put(value, "transport", transportJSON()); put(value, "dirty", session.dirty); put(value, "document", document);
    put(value, "language", localization::english ? "en" : "pt"); put(value, "auth", access);
    put(value, "busy", session.busy); put(value, "progress", session.importProgress); put(value, "status", session.message);
    put(value, "canUndo", session.canUndo()); put(value, "canRedo", session.canRedo());
    put(value, "readOnly", jaras::projectSync::readOnly());
    auto arms=object(), armed=object();
    if(const auto *song=session.song())for(const auto &track:song->tracks) {
        put(arms,Identifier(text(track.id)),session.recordArm(track.id));
        put(armed,Identifier(text(track.id)),session.recordingArmed(track.id));
    }
    put(value,"recordArms",arms);
    put(value,"recordArmed",armed);
    send(value);
    lastRevision = session.revision; previousBusy = session.busy; previousDirty = session.dirty;
    snapshotRequested = false;
    lastStatus = session.message;
    lastAuthStatus = String((int)auth.allowed()) + String((int)auth.busy) + auth.title + auth.message + String((int)auth.requiresDeviceName);
}
void FrontendBridge::publishTelemetry() {
    auto value = object(); Array<var> meters;
    const auto meter = [&](const ID &id) {
        const auto levels = session.audio.meterLevels(id);
        auto result = object(); put(result, "trackID", text(id)); put(result, "left", levels[0]); put(result, "right", levels[1]);
        put(result, "peak", session.audio.heldPeak(id)); return result;
    };
    meters.add(meter({}));
    // UI reports its visible rows. Hidden/offscreen meters do not get polled or
    // serialized; the master remains available even before the first viewport.
    for (const auto &id : meterTracks) meters.add(meter(id));
    put(value, "type", "telemetry"); put(value, "transport", transportJSON()); put(value, "meters", meters);
    put(value, "projectID", text(session.project().id)); send(value);
}
void FrontendBridge::timerCallback() {
    refreshClipboard();
    if (rta && Time::getMillisecondCounterHiRes() * .001 - rta->lastPoll > 1) rta.reset();
    const auto authState = String((int)auth.allowed()) + String((int)auth.busy) + auth.title + auth.message + String((int)auth.requiresDeviceName);
    if (snapshotRequested || session.revision != lastRevision || session.dirty != previousDirty || session.busy != previousBusy ||
        session.message != lastStatus || authState != lastAuthStatus) publishSnapshot();
    publishTelemetry();
}
var FrontendBridge::effects(const String &action, const var &payload) {
    const auto track = utf8(str(payload, "trackID"));
    if (!track.empty()) requireTrack(track);
    if (action == "effectsGet") {
        auto settings = fxchain::settings(session, track);
        if (!settings.isObject()) settings = object();
        auto result = object(); put(result, "settings", fxschema::complete(settings, true));
        put(result, "sampleRate", session.audio.sampleRate()); return result;
    }
    const auto key = str(payload, "key");
    if (action == "effectsRTA") {
        if (!flag(payload, "enabled", true)) { rta.reset(); return object(); }
        if (!rta || rta->track != track || rta->key != key) {
            rta = std::make_unique<RTAState>(); rta->track = track; rta->key = key;
            rta->rate = session.audio.sampleRate();
        }
        const auto next = session.audio.eqAnalysis(track, key);
        for (size_t i = 0; i < next.size(); ++i) if (rta->sources[i] != next[i]) {
            if (rta->sources[i]) rta->sources[i]->removeReader();
            rta->sources[i] = next[i]; rta->serial[i] = next[i] ? next[i]->serial() : 0;
            if (next[i]) next[i]->addReader();
        }
        size_t count = 0; bool ready = false;
        for (size_t i = 0; i < next.size(); ++i) if (next[i]) {
            ready = true; rta->rate = next[i]->sampleRate();
            if (next[i]->read(rta->frames[count]) && rta->frames[count].serial != rta->serial[i]) {
                rta->serial[i] = rta->frames[count].serial; ++count;
            }
        }
        const auto now = Time::getMillisecondCounterHiRes() * .001;
        const auto spectrum = rta->analyzer.analyze(rta->frames.data(), count, rta->lastPoll > 0 ? now-rta->lastPoll : .05);
        rta->lastPoll = now;
        Array<var> input, output;
        for (float value : spectrum.input) input.add(value);
        for (float value : spectrum.output) output.add(value);
        auto result = object(); put(result, "input", input); put(result, "output", output); put(result, "ready", ready);
        put(result, "minFrequency", 20.); put(result, "maxFrequency", 20000.); put(result, "sampleRate", rta->rate); return result;
    }
    requireEditable();
    if (action == "effectsChooseSample") {
        const auto path = str(payload, "path");
        if (path.isNotEmpty() && !File::isAbsolutePath(path)) throw std::invalid_argument("Choose an absolute sample path.");
        const auto file = path.isEmpty() ? chooseFile(false, true) : File(path);
        auto chain = fxchain::settings(session, track);
        auto target = chain; String kind = key;
        for (auto instance : list(get(chain, "instances")))
            if (key == "Native:" + str(instance, "id") || key == "Instance:" + str(instance, "id")) {
                target = get(instance, "settings"); kind = str(instance, "kind"); break;
            }
        if (kind != "CatLive Trigger" || !list(get(chain, "inserted")).contains(var(key)) || !target.isObject())
            throw std::invalid_argument("The Trigger is no longer inserted.");
        if (file != File()) {
            auto trigger = get(target, "trigger"); if (!trigger.isObject()) trigger = object();
            for (const auto &[name, value] : std::initializer_list<std::pair<const char *, double>>{
                {"threshold",-30},{"retrigger",.08},{"gain",0},{"mix",100},{"attack",0},{"decay",.1},{"sustain",1},{"release",.02}})
                if (get(trigger, Identifier(name)).isVoid()) put(trigger, Identifier(name), value);
            put(trigger, "samplePath", dynamicsAssets::importSample(file, session.mediaDirectory));
            put(target, "trigger", trigger); session.configureEffects(track, chain); snapshotRequested = true;
        }
        auto result = object(); put(result, "settings", chain); put(result, "sampleRate", session.audio.sampleRate()); return result;
    }
    const auto settings = get(payload, "settings");
    if (!settings.isObject()) throw std::invalid_argument("FX settings are required.");
    if (action == "effectsCommit") {
        session.configureEffects(track, settings); snapshotRequested = true; return object();
    }
    if (action != "effectsPreview") throw std::invalid_argument("Unknown FX action.");
    const auto kind = str(payload, "kind");
    const auto chain = fxchain::settings(session, track);
    if (!list(get(chain, "inserted")).contains(var(key))) throw std::invalid_argument("The effect is no longer inserted.");
    String actualKind = key;
    for (const auto &instance : list(get(chain, "instances")))
        if (key == "Native:" + str(instance, "id") || key == "Instance:" + str(instance, "id")) actualKind = str(instance, "kind");
    if (kind != actualKind) throw std::invalid_argument("The effect type changed.");
    if (kind == "CatLive Trigger" || kind == "Cat Gate") session.audio.previewDynamics(track, key, settings);
    else if (kind == "EQ" || kind == "Compressor" || kind == "Delay" || kind == "Reverb" || kind == "Limiter" || kind == "Pitch")
        session.audio.previewNativeParameters(track, key, kind, settings, get(payload, "chainSettings"));
    else throw std::invalid_argument("This effect requires its dedicated editor.");
    return object();
}
void FrontendBridge::validateProject(const var &request, const var &payload) const {
    auto expected = str(payload, "projectID", str(payload, "projectId", str(request, "projectID")));
    if (expected.isNotEmpty() && utf8(expected) != session.project().id)
        throw std::runtime_error("The project changed. Refresh the current project before editing.");
}
void FrontendBridge::validateClipboardScope(const var &payload) const {
    // These new commands are tied to the grid that produced the keystroke.
    // Legacy bridge commands retain their existing optional scope fields.
    if (utf8(str(payload,"projectID")) != session.project().id || !session.song() ||
        utf8(str(payload,"songID")) != session.song()->id)
        throw std::runtime_error("The timeline changed. Copy the items again in the current timeline.");
}
void FrontendBridge::refreshClipboard() {
    if (!itemClipboard) return;
    if (itemClipboard->project == session.project().id &&
        std::any_of(session.project().songs.begin(),session.project().songs.end(),[&](const auto &song){return song.id==itemClipboard->song;}) &&
        gridMediaClipboard::ownsItems(true,itemClipboardSequence,GetClipboardSequenceNumber())) return;
    itemClipboard.reset(); itemClipboardSequence.reset(); snapshotRequested = true;
}
var FrontendBridge::clipboardJSON() const {
    auto value=object(); Array<var> cut;
    put(value,"available",itemClipboard.has_value());
    put(value,"moving",itemClipboard && itemClipboard->moving);
    put(value,"projectID",itemClipboard ? text(itemClipboard->project) : String());
    put(value,"songID",itemClipboard ? text(itemClipboard->song) : String());
    if(itemClipboard && itemClipboard->moving)
        for(const auto &track:itemClipboard->tracks)for(const auto &clip:track.clips)cut.add(text(clip.id));
    put(value,"cutItemIDs",cut);return value;
}
void FrontendBridge::requireEditable() const {
    jaras::projectSync::requireWritable();
    if (session.busy) throw std::runtime_error("Wait for the current operation to finish.");
}
const jaras::Track &FrontendBridge::requireTrack(const ID &id) const {
    if (session.song()) for (const auto &track : session.song()->tracks) if (track.id == id) return track;
    throw std::invalid_argument("Unknown track.");
}
void FrontendBridge::setSelection(const var &payload) {
    std::set<ID> tracks, items, regions;
    if (get(payload, "trackIDs").isArray()) {
        for (const auto &value : list(get(payload, "trackIDs"))) { const auto id = utf8(value.toString()); requireTrack(id); tracks.insert(id); }
        selectedTracks = std::move(tracks);
        session.setRecordingSelection(selectedTracks.empty() ? ID{} : *selectedTracks.begin(), selectedTracks);
    }
    if (get(payload, "itemIDs").isArray()) {
        for (const auto &value : list(get(payload, "itemIDs"))) {
            const auto id = utf8(value.toString()); bool found = false;
            if (session.song()) for (const auto &track : session.song()->tracks)
                for (const auto &clip : track.clips) if (clip.id == id) found = true;
            if (!found) throw std::invalid_argument("Unknown item."); items.insert(id);
        }
        selectedItems = std::move(items);
    }
    if (get(payload, "regionIDs").isArray()) {
        for (const auto &value : list(get(payload, "regionIDs"))) regions.insert(utf8(value.toString()));
        selectedRegions = std::move(regions);
    }
}
void FrontendBridge::mixer(const var &payload) {
    requireEditable();
    const auto name = str(payload, "kind"), phase = str(payload, "phase");
    const auto id = utf8(str(payload, "trackID"));
    using C = jaras::CommandKind;
    C kind;
    if (name == "volume" || name == "masterVolume") kind = C::volume;
    else if (name == "pan") kind = C::pan;
    else if (name == "mute") kind = C::mute;
    else if (name == "solo") kind = C::solo;
    else if (name == "phase") kind = C::phase;
    else throw std::invalid_argument("Unknown mixer control.");
    if (name != "masterVolume") requireTrack(id);
    const bool scalar = kind == C::volume || kind == C::pan;
    const double amount = scalar ? finiteNumber(payload, "value") : 0;
    std::set<ID> targets;
    for (const auto &entry : list(get(payload, "targets"))) { const auto target = utf8(entry.toString()); requireTrack(target); targets.insert(target); }
    if (phase == "begin" && name != "masterVolume") session.beginMixerGesture(kind, id);
    if (name == "masterVolume") session.command(C::volume, {}, amount);
    else if (scalar) session.mixerCommand(kind, id, targets, amount);
    else {
        const auto &track = requireTrack(id);
        const bool current = kind == C::mute ? track.mute : kind == C::solo ? track.solo : track.phaseInverted.value_or(false);
        const auto supplied = get(payload, "value");
        if (supplied.isVoid() || current != (bool)supplied) session.mixerCommand(kind, id, targets);
    }
    if (phase == "end") session.endMixerGesture();
}

File FrontendBridge::chooseFile(bool saving, bool audioSample) {
    // Native dialogs pump the same message queue. Keep another-instance/open
    // requests from replacing this document while Save As is still choosing it.
    const ScopedValueSetter<bool> documentGuard(pendingDocumentAction, true);
    const auto projectID = session.project().id;
    Microsoft::WRL::ComPtr<IFileDialog> dialog;
    const auto result = saving
        ? CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog))
        : CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(result)) throw std::runtime_error("Could not open the file selector.");
    DWORD flags = 0; dialog->GetOptions(&flags);
    dialog->SetOptions(flags | FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR | (saving ? FOS_OVERWRITEPROMPT : FOS_FILEMUSTEXIST));
    const COMDLG_FILTERSPEC projects[] = {{L"CatLive project (*.jl)", L"*.jl"}};
    const COMDLG_FILTERSPEC samples[] = {{L"Audio sample (*.wav; *.mp3)", L"*.wav;*.mp3"}};
    dialog->SetFileTypes(1, audioSample ? samples : projects); dialog->SetDefaultExtension(audioSample ? L"wav" : L"jl");
    if (saving) dialog->SetFileName((text(session.project().name) + ".jl").toWideCharPointer());
    const auto folder = session.document == File() ? File::getSpecialLocation(File::userDocumentsDirectory) : session.document.getParentDirectory();
    Microsoft::WRL::ComPtr<IShellItem> item;
    if (SUCCEEDED(SHCreateItemFromParsingName(folder.getFullPathName().toWideCharPointer(), nullptr, IID_PPV_ARGS(&item)))) dialog->SetFolder(item.Get());
    const auto shown = dialog->Show(static_cast<HWND>(ownerWindow));
    if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return {};
    if (FAILED(shown)) throw std::runtime_error("The file selector failed.");
    if (projectID != session.project().id) throw std::runtime_error("The project changed while the file selector was open.");
    Microsoft::WRL::ComPtr<IShellItem> selected;
    if (FAILED(dialog->GetResult(&selected))) throw std::runtime_error("Could not read the selected file.");
    PWSTR path = nullptr;
    if (FAILED(selected->GetDisplayName(SIGDN_FILESYSPATH, &path))) throw std::runtime_error("Choose a local project file.");
    const File file{String(path)}; CoTaskMemFree(path); return file;
}
void FrontendBridge::save(const File &requested, std::function<void(bool)> complete) {
    requireEditable();
    auto destination = requested != File() ? requested : session.document;
    if (destination == File()) destination = chooseFile(true);
    if (destination == File()) { complete(false); return; }
    const auto weak = std::weak_ptr<int>(lifetime);
    session.saveAsync(destination, [this, weak, complete=std::move(complete)](String error) {
        if (weak.expired()) return;
        publishSnapshot();
        if (error.isNotEmpty()) notice("CatLive", error);
        complete(error.isEmpty());
    });
}
void FrontendBridge::ask(String kind, String title, String message, Array<var> buttons,
                         std::function<void(String)> callback) {
    confirmationToken = text(uuid()); confirmation = std::move(callback);
    auto value = object(); put(value, "type", "confirm"); put(value, "token", confirmationToken);
    put(value, "kind", kind); put(value, "title", title); put(value, "message", message); put(value, "buttons", buttons); send(value);
}
void FrontendBridge::confirmLeaving(std::function<void(bool)> complete) {
    requireEditable();
    if (session.transport().playing || session.transport().subPlay.playing || session.audio.isRecording()) {
        ask("playing", localized("Playback is running", "A reprodução está em andamento"),
            localized("Stop playback and continue?", "Parar a reprodução e continuar?"),
            {button("cancel", localized("Cancel", "Cancelar")), button("stop", localized("Stop and continue", "Parar e continuar"))},
            [this, complete](String choice) {
                if (choice != "stop") { complete(false); return; }
                try { session.command(jaras::CommandKind::stopAll); confirmLeaving(complete); }
                catch (const std::exception &error) { notice("CatLive", String::fromUTF8(error.what())); complete(false); }
            });
        return;
    }
    if (session.dirty) {
        ask("unsaved", localized("Save project?", "Salvar o projeto?"), text(session.project().name),
            {button("cancel", localized("Cancel", "Cancelar")), button("discard", localized("Don't save", "Não salvar")), button("save", localized("Save", "Salvar"))},
            [this, complete](String choice) {
                if (choice == "discard") complete(true);
                else if (choice == "save") {
                    try { save({}, complete); }
                    catch (const std::exception &error) { notice("CatLive", String::fromUTF8(error.what())); complete(false); }
                }
                else complete(false);
            });
        return;
    }
    complete(true);
}
void FrontendBridge::load(const File &file, std::function<void(String)> completed) {
    if (!file.existsAsFile() || !file.hasFileExtension("jl")) throw std::invalid_argument("Choose an existing CatLive .jl project.");
    waveforms->invalidate(); rta.reset(); session.endMixerGesture();
    const auto weak = std::weak_ptr<int>(lifetime);
    const auto finish = [this, weak, completed](String error) {
        if (weak.expired()) return;
        pendingDocumentAction = false;
        // Opening the same file (or a copy retaining its UUIDs) is still a new
        // document lifetime, as in Workspace::projectOpened.
        if(error.isEmpty()){itemClipboard.reset();itemClipboardSequence.reset();}
        selectedTracks.clear(); selectedItems.clear(); selectedRegions.clear(); publishSnapshot();
        if (completed) completed(error);
    };
    session.loadAsync(file, {}, {}, finish, [this, weak, file, finish](StringArray files) {
        if (weak.expired()) return;
        pendingDocumentAction = true;
        ask("missingMedia", localized("Missing media", "Mídias ausentes"), files.joinIntoString("\n"),
            {button("cancel", localized("Cancel", "Cancelar")), button("ignore", localized("Open without missing media", "Abrir sem as mídias ausentes"))},
            [this, file, finish](String choice) {
                pendingDocumentAction = false;
                if (choice != "ignore") { finish("Canceled"); return; }
                try { session.loadAsync(file, {}, {}, finish); }
                catch (const std::exception &error) { finish(String::fromUTF8(error.what())); }
            });
    });
}
void FrontendBridge::openProject(const File &file) {
    if (pendingDocumentAction) return;
    pendingDocumentAction = true;
    try {
        confirmLeaving([this, file](bool proceed) {
            pendingDocumentAction = false;
            if (proceed) {
                try { load(file, [this](String error) { if (error.isNotEmpty()) notice("CatLive", error); }); }
                catch (const std::exception &error) { notice("CatLive", String::fromUTF8(error.what())); }
            }
        });
    } catch (const std::exception &error) { pendingDocumentAction = false; notice("CatLive", String::fromUTF8(error.what())); }
}
void FrontendBridge::requestClose() {
    if (pendingDocumentAction) return;
    pendingDocumentAction = true;
    try {
        confirmLeaving([this](bool proceed) {
            pendingDocumentAction = false;
            if (proceed && onCloseApproved) onCloseApproved();
        });
    } catch (const std::exception &error) { pendingDocumentAction = false; notice("CatLive", String::fromUTF8(error.what())); }
}
void FrontendBridge::recoverPresentation(const String &error,std::function<void()> retry) {
    // A failed renderer cannot draw an ImGui confirmation. Keep Session alive
    // and use a native recovery prompt instead of discarding unsaved work.
    auto owner=static_cast<HWND>(ownerWindow);
    if(!session.dirty) {
        const auto message=localized("The interface could not continue. Retry?\n\n","A interface não pôde continuar. Tentar novamente?\n\n")+error;
        if(MessageBoxW(owner,message.toWideCharPointer(),L"CatLive",MB_RETRYCANCEL|MB_ICONERROR)==IDRETRY) retry();
        else if(onCloseApproved)onCloseApproved();
        return;
    }
    const auto message=localized(
        "The interface could not continue. Your project is still in memory.\nYes: save and close.\nNo: close without saving.\nCancel: retry the interface.\n\n",
        "A interface não pôde continuar. Seu projeto continua na memória.\nSim: salvar e fechar.\nNão: fechar sem salvar.\nCancelar: tentar abrir a interface novamente.\n\n")+error;
    const int choice=MessageBoxW(owner,message.toWideCharPointer(),L"CatLive",MB_YESNOCANCEL|MB_ICONERROR|MB_DEFBUTTON3);
    if(choice==IDNO){if(onCloseApproved)onCloseApproved();return;}
    if(choice!=IDYES){retry();return;}
    try {
        save({},[this,retry](bool saved){if(saved){if(onCloseApproved)onCloseApproved();}else retry();});
    }catch(const std::exception &failure){MessageBoxW(owner,String::fromUTF8(failure.what()).toWideCharPointer(),L"CatLive",MB_OK|MB_ICONERROR);retry();}
}

void FrontendBridge::receive(const String &json) {
    var request; var id;
    try {
        if (json.length() > 1024 * 1024 || JSON::parse(json, request).failed() || !request.isObject())
            throw std::invalid_argument("Invalid request.");
        id = get(request, "id"); const auto action = str(request, "action"); const auto payload = get(request, "payload", object());
        if (!payload.isObject()) throw std::invalid_argument("Invalid request payload.");
        if (action == "confirm") {
            if (!confirmation || str(payload, "token") != confirmationToken) throw std::invalid_argument("This confirmation has expired.");
            auto callback = std::move(confirmation); confirmationToken.clear();
            try { callback(str(payload, "choice")); }
            catch (...) { pendingDocumentAction = false; throw; }
            reply(id); return;
        }
        validateProject(request, payload);
        if (action == "snapshot") { publishSnapshot(); reply(id); return; }
        if (action == "viewport") {
            std::set<ID> visible;
            if (!get(payload, "trackIDs").isArray()) throw std::invalid_argument("Visible track IDs are required.");
            for (const auto &entry : list(get(payload, "trackIDs"))) {
                const auto track = utf8(entry.toString()); requireTrack(track); visible.insert(track);
            }
            meterTracks = std::move(visible); reply(id); return;
        }
        if (action == "waveform") {
            const auto weak = std::weak_ptr<int>(lifetime);
            waveforms->request(payload, [this, weak, id](var result, String error) { if (!weak.expired()) reply(id, result, error); }); return;
        }
        if (action == "effectsGet" || action == "effectsRTA") { reply(id, effects(action, payload)); return; }
        if (pendingDocumentAction) throw std::runtime_error("Close the current confirmation first.");
        if (action == "effectsPreview" || action == "effectsCommit" || action == "effectsChooseSample") { reply(id, effects(action, payload)); return; }
        using C = jaras::CommandKind;
        auto itemIDs=[&] {
            std::set<ID> result;
            if(!get(payload,"itemIDs").isArray())throw std::invalid_argument("Item selection is required.");
            for(const auto &entry:list(get(payload,"itemIDs"))) {
                const auto id=utf8(entry.toString());bool found=false;
                if(const auto *song=session.song())for(const auto &track:song->tracks)for(const auto &clip:track.clips)if(clip.id==id)found=true;
                if(!found)throw std::invalid_argument("Unknown item.");result.insert(id);
            }
            if(result.empty())throw std::invalid_argument("Select an item first.");
            return result;
        };
        auto trackIDs=[&] {
            std::set<ID> result;
            if(!get(payload,"trackIDs").isArray())throw std::invalid_argument("Track selection is required.");
            for(const auto &entry:list(get(payload,"trackIDs"))){auto id=utf8(entry.toString());requireTrack(id);result.insert(id);}
            if(result.empty())throw std::invalid_argument("Select a track first.");return result;
        };
        if(action=="new") {
            requireEditable();pendingDocumentAction=true;
            confirmLeaving([this,id](bool proceed){
                if(!proceed){pendingDocumentAction=false;reply(id,{},"Canceled");return;}
                try {
                    const auto file=chooseFile(true);if(file==File()){pendingDocumentAction=false;reply(id,{},"Canceled");return;}
                    session.newProject(file.getFileNameWithoutExtension());
                    const auto weak=std::weak_ptr<int>(lifetime);
                    session.saveAsync(file,[this,weak,id](String error){if(weak.expired())return;pendingDocumentAction=false;publishSnapshot();reply(id,{},error);});
                }catch(const std::exception &error){pendingDocumentAction=false;reply(id,{},String::fromUTF8(error.what()));}
            });return;
        }
        if (action == "open") {
            requireEditable();
            const auto path = str(payload, "path");
            const auto file = path.isEmpty() ? chooseFile(false) : File(path);
            if (file == File()) { reply(id, {}, "Canceled"); return; }
            pendingDocumentAction = true;
            confirmLeaving([this, id, file](bool proceed) {
                pendingDocumentAction = false;
                if (!proceed) { reply(id, {}, "Canceled"); return; }
                try { load(file, [this, id](String error) { reply(id, {}, error); }); }
                catch (const std::exception &error) { reply(id, {}, String::fromUTF8(error.what())); }
            }); return;
        }
        if(action=="importMedia") {
            requireEditable();
            if(utf8(str(payload,"projectID"))!=session.project().id||!session.song()||utf8(str(payload,"songID"))!=session.song()->id)
                throw std::runtime_error(utf8(localized("The destination timeline changed.","O grid de destino mudou.")));
            const auto paths=get(payload,"paths");
            if(!paths.isArray()||list(paths).isEmpty()||list(paths).size()>1024)throw std::invalid_argument("Select media files to import.");
            Array<File> files;
            for(const auto& value:list(paths)) {
                if(!value.isString()||value.toString().isEmpty()||!File::isAbsolutePath(value.toString()))throw std::invalid_argument("Choose absolute local media paths.");
                const File file(value.toString());if(!files.contains(file))files.add(file);
            }
            const auto track=utf8(str(payload,"trackID"));if(!track.empty())requireTrack(track);
            const auto position=finiteNumber(payload,"seconds"),gap=finiteNumber(payload,"gap");
            if(position<0||gap<0||gap>60)throw std::invalid_argument("Invalid media position or gap.");
            const auto layout=str(payload,"layout");
            if(layout!="separateTracks"&&layout!="sameTrack"&&layout!="stacked")throw std::invalid_argument("Choose a media layout.");
            const auto weak=std::weak_ptr<int>(lifetime);
            session.importMedia(files,position,track,layout=="sameTrack"?MediaDropLayout::sameTrack:layout=="stacked"?MediaDropLayout::stacked:MediaDropLayout::separateTracks,gap,
                [this,weak,id](String error){if(weak.expired())return;publishSnapshot();reply(id,{},error);},true);
            publishSnapshot();return;
        }
        if (action == "save") {
            const auto path = str(payload, "path");
            save(path.isEmpty() ? File() : File(path),[this,id](bool success){reply(id,{},success?String():String("Save was canceled or failed."));});
            return;
        } else if (action == "play" || action == "togglePlay" || action == "pause" || action == "stop") {
            requireEditable();
            const bool starting = action == "play" || (action == "togglePlay" && !session.transport().playing);
            if (starting && (!auth.allowed() || auth.pendingRevocation)) throw std::runtime_error(utf8(localized("Sign in to play.", "Faça login para reproduzir.")));
            const auto kind = action == "stop" ? C::stop : action == "pause" ? C::pause :
                action == "togglePlay" && session.transport().playing ? C::pause : C::play;
            session.command(kind);
        } else if(action=="transport") {
            requireEditable();const auto kind=str(payload,"kind");
            const std::map<String,C> commands{{"subPlay",C::subPlay},{"subStop",C::subStop},{"toggleLoop",C::toggleLoop},
                {"ignoreNext",C::ignoreNext},{"next",C::next},{"previous",C::previous},{"stopAll",C::stopAll},
                {"queueRegion",C::queueRegion},{"cancelSection",C::cancelSection},{"queueSection",C::queueSection},{"editSeek",C::editSeek}};
            const auto found=commands.find(kind);if(found==commands.end())throw std::invalid_argument("Unknown transport command.");
            if(kind=="subPlay"&&(!auth.allowed()||auth.pendingRevocation))throw std::runtime_error(utf8(localized("Sign in to play.","Faça login para reproduzir.")));
            const double value=kind=="editSeek"?std::max(0.,finiteNumber(payload,"value")):0.;
            session.command(found->second,utf8(str(payload,"target")),value);
        } else if(action=="tempo") {requireEditable();session.setTempo(finiteNumber(payload,"value"));}
        else if(action=="metronome") {
            requireEditable();if(!get(payload,"enabled").isBool())throw std::invalid_argument("Metronome state is required.");
            const auto result=Appearance{}.set("jaras.metronome.enabled",flag(payload,"enabled"));
            if(result.failed())throw std::runtime_error(utf8(result.getErrorMessage()));
            session.audio.metronomeEnabled=flag(payload,"enabled");
        } else if(action=="record") {
            requireEditable();if(!session.audio.isRecording()&&(!auth.allowed()||auth.pendingRevocation))throw std::runtime_error(utf8(localized("Sign in to record.","Faça login para gravar.")));
            session.toggleRecording();
        } else if(action=="recordArm") {requireEditable();const auto id=utf8(str(payload,"trackID"));requireTrack(id);session.cycleRecordArm(id);}
        else if(action=="renameTrack") {requireEditable();const auto id=utf8(str(payload,"trackID"));requireTrack(id);const auto name=str(payload,"name").trim();if(name.isEmpty())throw std::invalid_argument("A track name is required.");session.renameTrack(id,name);}
        else if(action=="removeTracks") {requireEditable();session.removeTracks(trackIDs());selectedTracks.clear();}
        else if(action=="copyItems" || action=="cutItems") {
            validateClipboardScope(payload);
            if(session.busy)throw std::runtime_error("Wait for the current operation to finish.");
            const bool moving=action=="cutItems";
            if(moving) {
                requireEditable();
                if(session.project().timelineMovementLocked.value_or(false))throw std::runtime_error("Unlock item movement first.");
            }
            auto copied=GridItemClipboard::copy(session.project(),session.song()->id,itemIDs(),moving);
            if(!copied)throw std::invalid_argument("The selected items cannot be copied.");
            session.programChangeClipboard.reset();session.programChangePasteReady=false;
            itemClipboard=std::move(copied);itemClipboardSequence=GetClipboardSequenceNumber();
            reply(id);publishSnapshot();return;
        } else if(action=="pasteItems") {
            validateClipboardScope(payload);requireEditable();refreshClipboard();
            if(!itemClipboard)throw std::runtime_error("Copy items from this timeline before pasting. External file paste is not available in this interface yet.");
            if(itemClipboard->song!=session.song()->id)throw std::runtime_error("Return to the copied items' timeline before pasting.");
            if(itemClipboard->moving && session.project().timelineMovementLocked.value_or(false))throw std::runtime_error("Unlock item movement first.");
            const auto position=get(payload,"seconds").isVoid()?session.transport().editPosition:finiteNumber(payload,"seconds");
            const auto clipboard=*itemClipboard;
            const auto entries=clipboard.items(session.project(),position);
            // Preserve the shipping clipboard model and its atomic, undoable
            // Session transaction. A failed paste leaves a pending cut intact.
            session.edit([&](jaras::Project &project) {
                auto edit=session.core;edit.pasteItems(clipboard.song,entries,clipboard.moving);project=edit.project();
            });
            selectedItems.clear();selectedTracks.clear();selectedRegions.clear();
            for(const auto &track:entries) {
                selectedTracks.insert(track.id);
                for(const auto &clip:track.clips)selectedItems.insert(clip.id);
            }
            session.setRecordingSelection(selectedTracks.empty()?ID{}:*selectedTracks.begin(),selectedTracks);
            if(clipboard.moving)itemClipboard=GridItemClipboard::copy(session.project(),session.song()->id,selectedItems);
            reply(id);publishSnapshot();return;
        } else if(action=="cancelItemCut") {
            validateClipboardScope(payload);refreshClipboard();
            if(itemClipboard && itemClipboard->moving){itemClipboard.reset();itemClipboardSequence.reset();}
            reply(id);publishSnapshot();return;
        }
        else if(action=="removeItems") {requireEditable();session.removeClips(itemIDs());selectedItems.clear();}
        else if(action=="splitItems") {requireEditable();session.splitClips(itemIDs(),std::max(0.,finiteNumber(payload,"seconds")));}
        else if(action=="moveItems") {
            requireEditable();const auto items=itemIDs();const auto delta=finiteNumber(payload,"delta");
            if(session.project().timelineMovementLocked.value_or(false))throw std::runtime_error("Unlock item movement first.");
            const auto destination=utf8(str(payload,"trackID"));if(!destination.empty())requireTrack(destination);
            std::vector<std::pair<ID,double>> moves;
            if(const auto *song=session.song())for(const auto &track:song->tracks)for(const auto &clip:track.clips)if(items.count(clip.id)){
                if(clip.startTime+delta<0)throw std::invalid_argument("Items cannot move before the project start.");
                moves.emplace_back(clip.id,clip.startTime+delta);
            }
            std::sort(moves.begin(),moves.end(),[delta](const auto &a,const auto &b){return delta>0?a.second>b.second:a.second<b.second;});
            session.editTimeline([&](jaras::Project &project){for(const auto &move:moves)clipEditing::move(project,move.first,move.second,destination);});
        } else if(action=="itemControls") {
            requireEditable();const auto items=itemIDs();
            const auto gain=get(payload,"gain"),pan=get(payload,"pan"),mute=get(payload,"muted");
            const double gainValue=gain.isVoid()?1.:finiteNumber(payload,"gain"),panValue=pan.isVoid()?0.:finiteNumber(payload,"pan");
            if(gainValue<0||gainValue>15.848932||panValue< -1||panValue>1||(!mute.isVoid()&&!mute.isBool()))throw std::invalid_argument("Invalid item control value.");
            const auto songID=session.song()->id;
            session.editItemControls([&](jaras::Project &project){for(auto &song:project.songs)if(song.id==songID)for(auto &track:song.tracks)for(auto &clip:track.clips)if(items.count(clip.id)){
                if(!gain.isVoid())clip.gain=gainValue;if(!pan.isVoid())clip.pan=panValue;if(!mute.isVoid())clip.muted=(bool)mute;
            }});
        }
        else if (action == "seek") { requireEditable(); session.command(C::seek, {}, std::max(0., finiteNumber(payload, "seconds"))); }
        else if (action == "selectRegion") {
            requireEditable(); const auto region = utf8(str(payload, "entryID", str(payload, "regionID")));
            if (region.empty()) throw std::invalid_argument("A region is required.");
            session.command(C::selectRegion, region); selectedRegions = {region};
        } else if (action == "selectTracks" || action == "selection") setSelection(payload);
        else if (action == "mixer") mixer(payload);
        else if (action == "undo" || action == "redo") { requireEditable(); if (action == "undo") session.undo(); else session.redo(); }
        else if (action == "clearPeak") { const auto track = utf8(str(payload, "trackID")); if (!track.empty()) requireTrack(track); session.audio.clearPeak(track); }
        else if (action == "choosePlaylist") {
            requireEditable(); auto state = session.project().regionSetlist.value_or(jaras::RegionSetlist{});
            const auto selected = utf8(str(payload, "playlistID"));
            if (selected.empty()) state.selectedId.reset();
            else {
                const auto found = std::find_if(state.playlists.begin(), state.playlists.end(), [&](const auto &p) { return p.id == selected && session.song() && p.songId == session.song()->id; });
                if (found == state.playlists.end()) throw std::invalid_argument("Unknown playlist."); state.selectedId = selected;
            }
            session.configureSetlist(state);
        } else if (action == "addTrack") { requireEditable(); session.addTrack(str(payload, "name", "Audio")); }
        else if (action == "login") { auth.beginLogin(str(payload, "email"), str(payload, "cpf")); }
        else if (action == "deviceName") { auth.completeDeviceNaming(str(payload, "name")); }
        else if (action == "logout") { if (session.transport().playing || session.audio.isRecording()) throw std::runtime_error("Stop playback before signing out."); auth.logout(); }
        else throw std::invalid_argument("Unknown action.");
        // Parameter drags may deliver many events in a display frame. Coalesce
        // model snapshots at 20 Hz; do not encode the whole project per event.
        reply(id); snapshotRequested = true;
    } catch (const std::exception &error) { reply(id, {}, String::fromUTF8(error.what())); }
}
}
