#pragma once
#include <nlohmann/json.hpp>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace integration {
using JSON = nlohmann::json;
using Clock = std::chrono::steady_clock;
constexpr int protocolVersion = 1, defaultPort = 48726;
constexpr double stateTimeout = 0.5, leaseTimeout = 3.0;
// Dedicated waits keep 120 MIDI quarter-frames/s independent of UI timers.
class TimecodeClock {
public:
    TimecodeClock(); ~TimecodeClock();
    void waitUntil(Clock::time_point deadline);
private:
    struct Impl; std::unique_ptr<Impl> impl;
};
struct Adapter { std::string id, name, address; };
struct MIDIPort { std::string id, name; };
std::vector<Adapter> adapters();
std::vector<MIDIPort> midiPorts();
std::filesystem::path documents();
std::string secureToken();
class MIDIOutput {
public:
    MIDIOutput(); ~MIDIOutput();
    void open(const std::string& id);
    void send(const std::vector<uint8_t>& bytes);
    void close();
private:
    struct Impl; std::unique_ptr<Impl> impl;
};
void sendOSC(int port, const std::string& address, int value, bool speed = false);
JSON validatePlan(const JSON& input);
void createComposition(const JSON& plan, const std::filesystem::path& file, int port,
                       const std::atomic<bool>& cancelled, const std::function<void(std::string)>& progress);
struct State {
    uint64_t sequence = 0;
    double position = 0;
    bool playing = false;
    int deck = 0, column = 0;
    uint64_t jump = 0;
    Clock::time_point received{};
    double at(Clock::time_point now) const;
    bool fresh(Clock::time_point now) const;
    static State parse(const JSON& value, Clock::time_point now);
};
// The UI owns this service; HTTP, OSC, composition creation and MTC have
// independent workers. It never opens an audio device or renders audio.
class Bridge {
public:
    explicit Bridge(std::filesystem::path directory = documents() / "CatLive Integration");
    ~Bridge();
    void start(const std::string& address, int port = defaultPort);
    void stop();
    JSON status() const;
private:
    struct Impl; std::unique_ptr<Impl> impl;
};
}
