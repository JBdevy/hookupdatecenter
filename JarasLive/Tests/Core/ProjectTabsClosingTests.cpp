#include <algorithm>
#include <cassert>
#include <functional>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

// Exercise the production Windows close coordinators with deterministic UI and
// persistence completions. No driver, user file or application window is used.
struct String : std::string {
    using std::string::string;
    bool isNotEmpty() const { return !empty(); }
    static String fromUTF8(const char *text) { return String(text); }
};
namespace localization { static String translate(const char *text) { return String(text); } }
namespace jaras {
enum class CommandKind { stopAll };
namespace projectSync { static bool readOnly() { return false; } }
}
struct Component { template<class T> using SafePointer = T *; };
struct ModalComponentManager {
    static ModalComponentManager *getInstance() { static ModalComponentManager value; return &value; }
    void bringModalComponentsToFront() {}
};
struct Session {
    bool busy = false, dirty = true, saving = false;
    struct Audio { bool recording = false; bool isRecording() { return recording; } } audio;
    struct Transport { bool playing = false; struct { bool playing = false; } subPlay; } state;
    std::function<void(String)> saved;
    bool isSaving() { return saving; }
    Transport &transport() { return state; }
    void waitForSave(std::function<void(String)> callback) { saved = std::move(callback); }
    void command(jaras::CommandKind) {
        state.playing = false; state.subPlay.playing = false;
        if (audio.recording) { audio.recording = false; dirty = true; }
    }
};
struct CloseProjectSheet {
    static inline int count = 0;
    static inline bool all = false;
    static inline std::function<void(int)> pending;
    static void open(Component &, std::function<void(int)> callback, bool = false, bool = true, bool allProjects = false) {
        ++count; all = allProjects; assert(!pending); pending = std::move(callback);
    }
    static void answer(int value) { auto callback = std::move(pending); pending = {}; callback(value); }
};
struct Workspace : Component {
    Session session;
    int writes = 0, failures = 0;
    bool failSave = false, cancelSave = false;
    bool isCurrentlyBlockedByAnotherModalComponent() { return bool(CloseProjectSheet::pending); }
    void showError(String) { ++failures; }
    void chooseSave(bool, std::function<void()> done, std::function<void()> cancelled) {
        if (failSave || cancelSave) { if (cancelled) cancelled(); return; }
        ++writes; session.dirty = false; done();
    }
    void requestClose(std::function<void()>, bool = true, std::optional<bool> = {}, std::function<void()> = {});
};
// INSERT_WORKSPACE_CLOSE
struct Application {
    std::vector<Workspace *> tabWorkspaces;
    std::vector<Session *> tabSessions;
    size_t selectedTab = 0, closingInitialTab = 0;
    bool closingProjects = false, closed = false;
    explicit Application(std::vector<Workspace *> workspaces) : tabWorkspaces(std::move(workspaces)) {
        for (auto *workspace : tabWorkspaces) tabSessions.push_back(&workspace->session);
    }
    void selectProjectTab(size_t index, bool) {
        if (!tabSessions[selectedTab]->audio.isRecording()) selectedTab = index;
    }
    void beginClosing() { closed = true; }
    // INSERT_APPLICATION_CLOSE
};
int main() {
    for (int choice : {0, 1, 2}) {
        Workspace first, second, foreground;
        foreground.session.dirty = false;
        Application app({&first, &second, &foreground}); app.selectedTab = 2;
        const int previous = CloseProjectSheet::count;
        app.requestAllProjectsClosing(foreground);
        assert(CloseProjectSheet::all && !app.closed && app.closingProjects);
        assert(first.writes + second.writes + foreground.writes == 0);
        CloseProjectSheet::answer(choice);
        assert(app.closed == (choice != 0));
        assert(CloseProjectSheet::count == previous + 1);
        assert(first.writes == (choice == 1) && second.writes == (choice == 1) && foreground.writes == 0);
        assert(first.session.dirty == (choice != 1));
        if (choice == 0) assert(!app.closingProjects && app.selectedTab == 2);
    }
    for (bool failure : {false, true}) {
        Workspace first, second;
        first.failSave = failure; first.cancelSave = !failure;
        Application app({&first, &second}); app.selectedTab = 1;
        app.requestAllProjectsClosing(second); CloseProjectSheet::answer(1);
        assert(!app.closed && !app.closingProjects && first.session.dirty);
        assert(second.writes == 1 && first.writes == 0 && app.tabWorkspaces.size() == 2);
    }
    {
        Workspace first, second;
        second.session.busy = true;
        Application app({&first, &second}); app.requestAllProjectsClosing(first);
        assert(!app.closingProjects && !app.closed && first.failures == 1 && !CloseProjectSheet::pending);
    }
    {
        Workspace first, second;
        first.session.dirty = false; second.session.dirty = false;
        second.session.audio.recording = true; second.session.state.playing = true;
        Application app({&first, &second}); app.selectedTab = 1;
        app.requestAllProjectsClosing(second); CloseProjectSheet::answer(1);
        assert(app.closed && second.writes == 1 && first.writes == 0 && !second.session.audio.recording);
    }
    {
        Workspace first, second;
        second.session.saving = true;
        Application app({&first, &second}); app.selectedTab = 1;
        app.requestAllProjectsClosing(second); CloseProjectSheet::answer(1);
        assert(!app.closed && app.closingProjects && second.session.saved);
        second.session.saving = false; second.session.dirty = false; second.session.saved({});
        assert(app.closed && first.writes == 1);
    }
    {
        Workspace first, second;
        second.session.saving = true;
        Application app({&first, &second}); app.selectedTab = 1;
        app.requestAllProjectsClosing(second); CloseProjectSheet::answer(1);
        second.session.saving = false; second.session.saved("Write failed");
        assert(!app.closed && !app.closingProjects && second.failures == 1 && first.writes == 0);
    }
    std::cout << "WINDOWS_SAVE_ALL_TABS_SINGLE_DECISION_CANCEL_FAILURE_RECORDING_AND_PENDING_SAVE_OK\n";
}
