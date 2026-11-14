#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <map>
#include <string>
#include <variant>

// Lightweight platform boundary: the constructor, time calculation,
// persistence and Remote handler below come directly from production headers.
struct String : std::string {
    using std::string::string;
    String(const std::string &s) : std::string(s) {}
    static String fromUTF8(const char *s) { return s; }
    String replace(const std::string &a, const std::string &b) const {
        std::string s = *this;
        for (size_t pos = 0; (pos = s.find(a, pos)) != std::string::npos; pos += b.size())
            s.replace(pos, a.size(), b);
        return s;
    }
};
using Value = std::variant<int, bool, std::string>;
using Object = std::map<std::string, Value>;
Object object() { return {}; }
template<class T> void put(Object &o, const char *key, T value) { o[key] = value; }
void put(Object &o, const char *key, const char *value) { o[key] = std::string(value); }
int num(const Object &o, const char *key) {
    const auto i = o.find(key); return i == o.end() ? 0 : std::get<int>(i->second);
}
bool flag(const Object &o, const char *key) {
    const auto i = o.find(key); return i != o.end() && std::get<bool>(i->second);
}
String str(const Object &o, const char *key) {
    const auto i = o.find(key); return i == o.end() ? String{} : String(std::get<std::string>(i->second));
}
template<class T> T jlimit(T low, T high, T value) { return std::clamp(value, low, high); }
struct Appearance {
    Object saved;
    Object value(const char *) const { return saved; }
    void set(const char *, Object o) { saved = std::move(o); }
};
double uptime = 100;
struct Time { static double getMillisecondCounterHiRes() { return uptime * 1000; } };
String clockText(int seconds, bool) {
    char text[40]; std::snprintf(text, sizeof(text), "%02d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60);
    return text;
}
class StageState {
  public:
    // INSERT_CONSTRUCTOR
    Appearance &preferences;
    int target = 0;
    bool running = false, autoStart = false, progressive = false;
    double started = 0;
    // INSERT_TIMER_METHODS
};
struct Command { std::string action, id; double value = 0; };
std::string uuid() { static int n = 0; return std::to_string(++n); }
struct Presentation {
    StageState &stage;
    std::string timerCommand, timerRevision;
    bool apply(const Command &c) {
        const auto &a = c.action;
        // INSERT_REMOTE_HANDLER
        return false;
    }
};
int main() {
    Appearance preferences;
    StageState stage(preferences);
    assert(!stage.progressive && !stage.running);
    Presentation remote{stage, {}, {}};
    assert(remote.apply({"timerStart", "start", 90}));
    uptime += .2;
    assert(stage.timeText() == "00:01:30");
    remote.apply({"timerSetMode", "busy", 0});
    assert(!stage.progressive && stage.running);
    uptime += 90;
    assert(stage.expired() && stage.timeText() == "00:00:00");
    uptime += 2;
    assert(stage.timeText() == "−00:00:02");
    remote.apply({"timerStop", "stop"});
    remote.apply({"timerSetMode", "up", 0});
    assert(stage.progressive && !stage.running && stage.target == 90);
    assert(stage.timeText() == "00:00:00" && !stage.expired());
    StageState restored(preferences);
    assert(restored.progressive && restored.target == 90 && !restored.running);
    remote.apply({"timerStartProgressive", "start-up"});
    uptime += .2;
    assert(stage.timeText() == "00:00:00" && !stage.expired());
    uptime += 65;
    assert(stage.timeText() == "00:01:05" && !stage.expired());
    remote.apply({"timerStop", "stop-up"});
    remote.apply({"timerSetMode", "down", 1});
    assert(!stage.progressive && stage.target == 90 && stage.timeText() == "00:01:30");
    remote.apply({"timerStart", "start-down", 5});
    assert(stage.running && !stage.progressive && stage.target == 5);
    assert(remote.timerCommand == "start-down");
    std::cout << "WINDOWS_TIMER_MODES_REMOTE_START_STOP_ROUNDING_PERSISTENCE_OK\n";
}
