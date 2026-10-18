#pragma once
#include <shlobj.h>
#include <cstring>
#include <cwchar>

// Included after Workspace.cpp's nested component definitions. This harness is
// reachable only through --grid-import-test in an isolated SSH desktop.
namespace catlive {
namespace mediaImportRegression {
inline void require(bool condition, const String &message) {
    if (!condition) throw std::runtime_error(utf8(message));
}
inline void pump() {
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessage(&message);
    }
    Thread::sleep(2);
}
template <typename Predicate>
void wait(Predicate complete, const String &description, int milliseconds = 15000) {
    const auto deadline = Time::getMillisecondCounterHiRes() + milliseconds;
    do {
        pump();
        if (complete()) return;
    } while (Time::getMillisecondCounterHiRes() < deadline);
    throw std::runtime_error(utf8("Timed out: " + description));
}
inline File source(const File &directory, const String &name, int frames) {
    require(directory.createDirectory().wasOk(), "Cannot create source directory");
    const auto file = directory.getChildFile(name);
    auto output = file.createOutputStream();
    require(output != nullptr, "Cannot open WAV fixture");
    WavAudioFormat format;
    std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(output.get(), 48000, 2, 24, {}, 0));
    require(writer != nullptr, "Cannot create WAV fixture");
    output.release();
    AudioBuffer<float> pcm(2, frames);
    pcm.clear();
    pcm.setSample(0, frames / 2, .5f);
    pcm.setSample(1, frames / 2, -.25f);
    require(writer->writeFromAudioSampleBuffer(pcm, 0, frames), "Cannot write WAV fixture");
    return file;
}
// Never overwrite the interactive user's clipboard. The entire harness refuses
// to run in a visible window station, and this guard requires an empty isolated
// clipboard before installing its own CF_HDROP fixture.
struct ClipboardFixture {
    HWND owner{};
    std::optional<DWORD> ownedSequence;
    explicit ClipboardFixture(HWND window) : owner(window) {}
    ~ClipboardFixture() {
        if (ownedSequence && GetClipboardSequenceNumber() == *ownedSequence && OpenClipboard(owner)) {
            EmptyClipboard();
            CloseClipboard();
        }
    }
    void set(const StringArray &paths) {
        std::vector<wchar_t> names;
        for (const auto &path : paths) {
            const auto *wide = path.toWideCharPointer();
            names.insert(names.end(), wide, wide + std::wcslen(wide) + 1);
        }
        names.push_back(0);
        const auto memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT,
                                       sizeof(DROPFILES) + names.size() * sizeof(wchar_t));
        require(memory != nullptr, "Cannot allocate clipboard fixture");
        struct Release { HGLOBAL memory; ~Release() { if (memory) GlobalFree(memory); } } release{memory};
        auto *drop = static_cast<DROPFILES *>(GlobalLock(memory));
        require(drop != nullptr, "Cannot lock clipboard fixture");
        drop->pFiles = sizeof(DROPFILES);
        drop->fWide = TRUE;
        std::memcpy(reinterpret_cast<char *>(drop) + sizeof(DROPFILES), names.data(), names.size() * sizeof(wchar_t));
        GlobalUnlock(memory);
        require(OpenClipboard(owner) != FALSE, "Cannot open isolated clipboard");
        struct Close { ~Close() { CloseClipboard(); } } close;
        require(ownedSequence ? GetClipboardSequenceNumber() == *ownedSequence : CountClipboardFormats() == 0,
                "Clipboard is not empty or no longer belongs to this test; left untouched");
        require(EmptyClipboard() != FALSE, "Cannot clear isolated clipboard");
        require(SetClipboardData(CF_HDROP, memory) != nullptr, "Cannot set CF_HDROP fixture");
        release.memory = nullptr;
        ownedSequence = GetClipboardSequenceNumber();
    }
};
// An Explorer-style data object, independent of the system clipboard. The OLE
// recipient owns the fresh STGMEDIUM returned by GetData and releases it itself.
class FileDropDataObject final : public IDataObject {
    std::atomic<ULONG> references{1};
    std::vector<wchar_t> names;
  public:
    explicit FileDropDataObject(const StringArray &paths) {
        for (const auto &path : paths) {
            const auto *wide = path.toWideCharPointer();
            names.insert(names.end(), wide, wide + std::wcslen(wide) + 1);
        }
        names.push_back(0);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (IsEqualIID(id, IID_IUnknown) || IsEqualIID(id, IID_IDataObject)) {
            *result = static_cast<IDataObject *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override {
        const auto remaining = --references;
        if (!remaining) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC *format) override {
        if (!format) return E_POINTER;
        if (format->cfFormat != CF_HDROP) return DV_E_FORMATETC;
        if (!(format->tymed & TYMED_HGLOBAL)) return DV_E_TYMED;
        if (format->dwAspect != DVASPECT_CONTENT) return DV_E_DVASPECT;
        if (format->lindex != -1) return DV_E_LINDEX;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetData(FORMATETC *format, STGMEDIUM *medium) override {
        if (!medium) return E_POINTER;
        *medium = {};
        const auto accepted = QueryGetData(format);
        if (FAILED(accepted)) return accepted;
        const auto memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT,
            sizeof(DROPFILES) + names.size() * sizeof(wchar_t));
        if (!memory) return E_OUTOFMEMORY;
        auto *drop = static_cast<DROPFILES *>(GlobalLock(memory));
        if (!drop) { GlobalFree(memory); return E_OUTOFMEMORY; }
        drop->pFiles = sizeof(DROPFILES);
        drop->fWide = TRUE;
        std::memcpy(reinterpret_cast<char *>(drop) + sizeof(DROPFILES), names.data(), names.size() * sizeof(wchar_t));
        GlobalUnlock(memory);
        medium->tymed = TYMED_HGLOBAL;
        medium->hGlobal = memory;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC *, STGMEDIUM *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC *, FORMATETC *output) override {
        if (output) output->ptd = nullptr;
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE SetData(FORMATETC *, STGMEDIUM *, BOOL) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC **output) override {
        if (!output) return E_POINTER;
        *output = nullptr;
        if (direction != DATADIR_GET) return E_NOTIMPL;
        FORMATETC format{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        return SHCreateStdEnumFmtEtc(1, &format, output);
    }
    HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC *, DWORD, IAdviseSink *, DWORD *) override { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA **) override { return OLE_E_ADVISENOTSUPPORTED; }
};
} // namespace mediaImportRegression

void Workspace::runMediaImportRegression(const File &results, std::function<void(bool)> done) {
    using namespace mediaImportRegression;
    auto report = object();
    Array<var> checks;
    bool passed = false;
    const auto began = Time::getMillisecondCounterHiRes();
    try {
        require(session.inspection, "Media import regression requires an inspection session");
        DWORD processSession = 0;
        USEROBJECTFLAGS stationFlags{};
        DWORD returned = 0;
        require(ProcessIdToSessionId(GetCurrentProcessId(), &processSession) != FALSE &&
                    GetUserObjectInformationW(GetProcessWindowStation(), UOI_FLAGS, &stationFlags,
                                              sizeof(stationFlags), &returned) != FALSE &&
                    (stationFlags.dwFlags & WSF_VISIBLE) == 0 && processSession != WTSGetActiveConsoleSessionId(),
                "Refusing UI/clipboard regression on the interactive user's desktop");
        put(report, "processSession", (int)processSession);
        require(results.createDirectory().wasOk(), "Cannot create result directory");
        require(session.song() && session.song()->tracks.empty() && projectReady && !browserVisible && !loginPanel,
                "Regression requires an open empty project");
        session.mediaDirectory = results.getChildFile("project");
        require(session.mediaDirectory.createDirectory().wasOk(), "Cannot create project media directory");
        auto *peer = getTopLevelComponent()->getPeer();
        require(peer != nullptr && timeline->getWidth() > 80 && timeline->getHeight() > 100,
                "Native window or grid layout is missing");
        const auto first = source(results.getChildFile("sources"), String::fromUTF8("Áudio 01.wav"), 48000);
        const auto second = source(results.getChildFile("sources"), "Audio 02.wav", 24000);
        const Point<int> gridPoint{std::min(200, timeline->getWidth() - 20), 95};
        const auto workspacePoint = getLocalPoint(timeline.get(), gridPoint);
        ComponentPeer::DragInfo drag;
        drag.files.add(first.getFullPathName());
        drag.position = peer->getComponent().getLocalPoint(this, workspacePoint);
        const double expectedPosition = timelineGrid::snapSelection(timeline->timeAt((float)gridPoint.x),
            *session.song(), pixelsPerSecond, session.transport(), false);
        auto noTracks = [&] { return session.song() && session.song()->tracks.empty(); };
        auto shortcut = [&](int key) {
            heldShortcutKeys.clear();
            grabKeyboardFocus();
            require(peer->handleKeyPress(KeyPress(key, ModifierKeys::ctrlModifier, 0)), "Native peer did not handle shortcut");
        };
        auto undo = [&] {
            shortcut('Z');
            wait([&] { return noTracks() && !session.busy; }, "undo whole import");
        };
        auto panel = [&]() -> MediaDropPanel * {
            for (auto *child : getChildren())
                if (auto *sheet = dynamic_cast<ModalSheet *>(child))
                    for (auto *content : sheet->getChildren())
                        if (auto *found = dynamic_cast<MediaDropPanel *>(content)) return found;
            return nullptr;
        };
        auto importFinished = [&](size_t tracks) {
            wait([&] { return !session.busy && session.song() && session.song()->tracks.size() == tracks; },
                 "external media import; status=" + fileDropStatus + "; " + session.message);
            wait([&] { return Component::getCurrentlyModalComponent() == nullptr; }, "close import dialog");
        };

        require(peer->handleDragMove(drag), "Native peer rejected external WAV drag");
        wait([&] { return externalDropFiles.size() == 1 && externalDropFiles.front().duration.has_value(); }, "drag metadata preview");
        require(noTracks() && !session.busy && externalDropPoint.has_value(), "Drag preview modified the project or failed to appear");
        require(std::abs(*externalDropFiles.front().duration - 1.) < 1e-9, "Drag preview duration is incorrect");
        require(session.mediaDirectory.findChildFiles(File::findFiles, true).isEmpty(), "Preview copied source media before drop");
        capture(results.getChildFile("drag-preview.png"));
        peer->handleDragExit(drag);
        require(externalDropFiles.empty() && !externalDropPoint, "Cancelled drag retained its preview");
        checks.add("native_peer_preview_metadata_and_cancel");

        require(peer->handleDragMove(drag) && peer->handleDragDrop(drag), "Native peer rejected WAV drop");
        importFinished(1);
        require(session.song()->tracks.front().clips.size() == 1, "Dropped WAV did not create one item");
        const auto &clip = session.song()->tracks.front().clips.front();
        require(std::abs(clip.startTime - expectedPosition) < 1e-9 &&
                    std::abs(clip.duration - 1.) < 1e-9 && clip.waveform.empty() && clip.audioFile,
                "Dropped WAV must appear with its position and media reference before waveform analysis");
        require(ProjectCodec::resolveMedia(session.mediaDirectory, clip.audioFile->path).existsAsFile() &&
                    externalDropFiles.empty(), "Dropped WAV was not copied or its preview remained");
        undo();
        checks.add("native_peer_single_drop_and_ctrl_z");

        const auto now = Time::getCurrentTime();
        const Point<float> emptyMixer{20.f, (float)(rowTop(0) + 20)};
        mouseDoubleClick(MouseEvent(Desktop::getInstance().getMainMouseSource(), emptyMixer,
            ModifierKeys(ModifierKeys::leftButtonModifier), 1.f, 0.f, 0.f, 0.f, 0.f,
            &tracksContent, &tracksContent, now, emptyMixer, now, 2, false));
        require(session.song()->tracks.size() == 1 && session.song()->tracks.front().role.id == "other" &&
                    session.song()->tracks.front().color == 0x828282u && session.song()->tracks.front().clips.empty(),
                "Double-click below mixer did not create the standard empty track");
        undo();
        checks.add("empty_mixer_double_click_and_ctrl_z");

        drag.files.add(second.getFullPathName());
        for (bool sequential : {false, true}) {
            require(peer->handleDragMove(drag) && peer->handleDragDrop(drag), "Native peer rejected batch drop");
            wait([&] { return panel() != nullptr; }, "batch import options");
            require(noTracks() && !session.busy, "Batch import started before user chose its layout");
            auto *options = panel();
            if (sequential) {
                auto *same = dynamic_cast<ToggleButton *>(options->findChildWithID("mediaDropSame"));
                auto *gap = dynamic_cast<TextEditor *>(options->findChildWithID("mediaDropGap"));
                require(same && gap, "Sequential import controls are missing");
                same->setToggleState(true, sendNotificationSync);
                if (same->onClick) same->onClick();
                gap->setText("0.25", false);
            }
            require(options->keyPressed(KeyPress(KeyPress::returnKey)), "Import dialog did not accept Enter");
            importFinished(sequential ? 1 : 2);
            const auto &tracks = session.song()->tracks;
            require(tracks.front().clips.size() == (sequential ? 2u : 1u), "Wrong item count for batch layout");
            require(!tracks.back().clips.empty(), "Last batch track has no item");
            const auto &last = sequential ? tracks.front().clips.back() : tracks.back().clips.front();
            require(std::abs(last.startTime - (expectedPosition + (sequential ? 1.25 : 0.))) < 1e-9,
                    "Batch import ignored the selected layout or interval");
            undo();
            checks.add(sequential ? "native_peer_batch_sequential_interval_and_ctrl_z" : "native_peer_batch_separate_tracks_and_ctrl_z");
        }

        {
            const auto window = static_cast<HWND>(peer->getNativeHandle());
            auto *target = reinterpret_cast<IDropTarget *>(GetPropW(window, L"OleDropTargetInterface"));
            require(target != nullptr, "Native HWND has no registered OLE drop target");
            target->AddRef();
            struct ReleaseTarget { IDropTarget *value; ~ReleaseTarget() { value->Release(); } } releaseTarget{target};
            auto *data = new FileDropDataObject({first.getFullPathName()});
            struct ReleaseData { IDataObject *value; ~ReleaseData() { value->Release(); } } releaseData{data};
            RECT client{};
            require(GetClientRect(window, &client) != FALSE, "Cannot query native client rectangle");
            POINT point{(LONG)std::lround(drag.position.x * (double)(client.right - client.left) / peer->getComponent().getWidth()),
                        (LONG)std::lround(drag.position.y * (double)(client.bottom - client.top) / peer->getComponent().getHeight())};
            require(ClientToScreen(window, &point) != FALSE, "Cannot map OLE drop to physical screen coordinates");
            const POINTL screen{point.x, point.y};
            DWORD effect = DROPEFFECT_COPY;
            require(SUCCEEDED(target->DragEnter(data, MK_LBUTTON, screen, &effect)) && effect != DROPEFFECT_NONE,
                    "Registered OLE target rejected Explorer CF_HDROP DragEnter");
            struct LeaveTarget {
                IDropTarget *value;
                bool active = true;
                ~LeaveTarget() { if (active) value->DragLeave(); }
            } leaveTarget{target};
            effect = DROPEFFECT_COPY;
            require(SUCCEEDED(target->DragOver(MK_LBUTTON, screen, &effect)) && effect != DROPEFFECT_NONE,
                    "Registered OLE target rejected DragOver at grid position");
            require(noTracks() && externalDropFiles.size() == 1, "OLE preview was not routed to the empty grid");
            effect = DROPEFFECT_COPY;
            require(SUCCEEDED(target->Drop(data, 0, screen, &effect)) && effect != DROPEFFECT_NONE,
                    "Registered OLE target rejected the Explorer drop");
            leaveTarget.active = false;
            importFinished(1);
            require(session.song()->tracks.front().clips.size() == 1 &&
                        std::abs(session.song()->tracks.front().clips.front().startTime - expectedPosition) < 1e-9,
                    "Native OLE drop did not import at the preview position");
            undo();
            checks.add("registered_ole_cf_hdrop_enter_over_drop_and_ctrl_z");
        }
        {
            ClipboardFixture clipboard(static_cast<HWND>(peer->getNativeHandle()));
            clipboard.set({first.getFullPathName()});
            itemClipboard.reset();
            itemClipboardSequence.reset();
            selectedTrack = {};
            session.command(jaras::CommandKind::seek, {}, 6.);
            const double pastePosition = session.transport().editPosition;
            shortcut('V');
            importFinished(1);
            require(session.song()->tracks.front().clips.size() == 1 &&
                        std::abs(session.song()->tracks.front().clips.front().startTime - pastePosition) < 1e-9,
                    "Ctrl+V did not import Explorer files at the edit cursor");
            undo();
            checks.add("native_peer_ctrl_v_explorer_files_and_ctrl_z");
        }
        passed = true;
    } catch (const std::exception &error) {
        put(report, "error", String::fromUTF8(error.what()));
    } catch (...) {
        put(report, "error", "Unknown media import regression failure");
    }
    clearExternalDrop();
    session.dirty = false;
    put(report, "passed", passed);
    put(report, "checks", checks);
    put(report, "fileDragEntries", fileDragEntries);
    put(report, "fileDropCount", fileDropCount);
    put(report, "fileDropStatus", fileDropStatus);
    put(report, "elapsedMilliseconds", Time::getMillisecondCounterHiRes() - began);
    const auto output = JSON::toString(report, true);
    Logger::writeToLog(output);
    if (!results.createDirectory().wasOk() || !results.getChildFile("results.json").replaceWithText(output)) passed = false;
    done(passed);
}
} // namespace catlive
