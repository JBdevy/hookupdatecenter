#pragma once
#include "Auth.h"
#include "Session.h"
#include "GridItemClipboard.h"

namespace catlive {
class NativeFrontendWaveforms;

// UI-thread adapter: the native frontend uses the existing Session/AudioEngine.
// No component tree, audio graph or second project model is created here.
class FrontendBridge final : private Timer {
  public:
    using Emit = std::function<void(const String &)>;
    FrontendBridge(Session &, Auth &, Emit, bool compactPresentation = false);
    ~FrontendBridge() override;
    void setOwnerWindow(void *value) { ownerWindow = value; }
    void receive(const String &json);
    void publishSnapshot();
    void openProject(const File &);
    void requestClose();
    void recoverPresentation(const String &, std::function<void()> retry);
    std::function<void()> onCloseApproved;

  private:
    Session &session;
    Auth &auth;
    Emit emit;
    const bool compactPresentation;
    void *ownerWindow = nullptr;
    std::unique_ptr<NativeFrontendWaveforms> waveforms;
    struct RTAState;
    std::unique_ptr<RTAState> rta;
    std::shared_ptr<int> lifetime = std::make_shared<int>(0);
    std::set<ID> selectedTracks, selectedItems, selectedRegions, meterTracks;
    std::optional<GridItemClipboard> itemClipboard;
    std::optional<DWORD> itemClipboardSequence;
    uint64 lastRevision = std::numeric_limits<uint64>::max();
    String lastStatus, lastAuthStatus;
    ID lastProject;
    String confirmationToken;
    std::function<void(String)> confirmation;
    bool pendingDocumentAction = false;
    bool previousBusy = false, previousDirty = false;
    bool snapshotRequested = false;
    bool previousInstrumentAllowed = false;
    std::function<bool()> previousCanPlay, previousIsPlaying;
    std::function<void(String)> previousAudioWarning, previousFadeoutWarning;
    void timerCallback() override;
    void send(var);
    void reply(const var &id, var result = {}, String error = {});
    void notice(String title, String message);
    var transportJSON() const;
    void publishTelemetry();
    void validateProject(const var &, const var &) const;
    void validateClipboardScope(const var &) const;
    void refreshClipboard();
    var clipboardJSON() const;
    void requireEditable() const;
    const jaras::Track &requireTrack(const ID &) const;
    void setSelection(const var &);
    void mixer(const var &);
    var effects(const String &action, const var &);
    void ask(String kind, String title, String message, Array<var> buttons,
             std::function<void(String)>);
    void confirmLeaving(std::function<void(bool)>);
    void load(const File &, std::function<void(String)>);
    File chooseFile(bool saving, bool audioSample = false);
    void save(const File &, std::function<void(bool)>);
};
}
