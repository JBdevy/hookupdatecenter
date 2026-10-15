#pragma once
#include "Session.h"
namespace catlive {
struct LightingCue {
    ID id;
    String name;
    double position = 0;
    bool start = false;
};
struct LightingRegion {
    ID id, songId;
    String name;
    double start = 0, end = 0, localStart = 0;
    int offset = 0;
    std::vector<LightingCue> cues;
};
struct MASettings {
    int sequence = 1, page = 1, executor = 1, timecode = 1, slot = 2;
};
struct MAExport {
    LightingRegion region;
    MASettings settings;
    String stem, macro, timecode;
    StringArray commands;
};
class Lighting final : private Thread {
  public:
    explicit Lighting(Session &);
    ~Lighting() override;
    MASettings settings;
    var assignments = object(), starts = object();
    var resolumeAssignments = object(), resolumeRegionsOnly = object();
    std::vector<LightingRegion> regions;
    std::vector<LightingRegion> resolumeRegions;
    std::set<ID> selected;
    String host = "127.0.0.1", error;
    int port = 7000, webPort = 8080;
    bool resolumeEnabled = false, includeMarkers = true;
    void refresh(bool assignMissing = true);
    void saveSettings();
    void loadSettings();
    std::vector<MAExport> buildExports(bool selectedOnly = true) const;
    String exportGrandMA2(const File &folder, bool selectedOnly = true);
    String exportMapCSV() const;
    String resolumeMapCSV() const;
    static var buildResolumeAssignments(const std::vector<LightingRegion> &, const var &,
                                        bool includeMarkers);
    static std::vector<LightingRegion> buildResolumeRegions(const jaras::Project &);
    static String cleanName(const String &, String fallback = "Marcador");
    static String safeStem(const String &);
    static String triggerTime(double);
    static String macroXML(const String &, const String &, const StringArray &);
    static String timecodeXML(const LightingRegion &, const std::vector<LightingRegion> &,
                              const MASettings &);
    static StringArray macroCommands(const LightingRegion &, const MASettings &,
                                     const String &stem);
    static var buildAssignments(const std::vector<LightingRegion> &, const var &saved,
                                bool includeMissing = true);
    bool connectResolume();
    void enableResolume(bool value);
    bool testResolume(int column = 1);
    void update(const jaras::TransportState &);
    void setMidiOutput(const String &identifier);
    String midiIdentifier;
    std::atomic<bool> mtcEnabled{false};
    void enableMTC(bool value) {
        mtcEnabled = value;
        notify();
    }
    double absolutePosition(const ID &song, double local) const;

  private:
    Session &session;
    OSCSender osc;
    std::unique_ptr<MidiOutput> midi;
    CriticalSection midiLock;
    std::atomic<double> mtcPosition{0};
    std::atomic<double> mtcBase{0};
    std::atomic<bool> mtcPlaying{false};
    int lastColumn = -1, lastDeck = -1;
    bool wasPlaying = false;
    ID lastSong;
    std::vector<std::tuple<ID, double, int, int, double, double>> resolumeCues;
    double lastResolumePosition = 0, lastResolumeClock = 0;
    bool selectionInitialised = false, mapCommitted = false;
    std::shared_ptr<int> alive = std::make_shared<int>(0);
    uint64 oscGeneration = 0;
    void run() override;
};
} // namespace catlive
