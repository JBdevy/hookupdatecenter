#include "../../Core/Transport/Engine.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace jaras;

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static void near(double value, double expected, const char* message) {
    require(std::abs(value - expected) < 1e-9, message);
}
static Project fixture(bool initialized) {
    Project result; result.id = "boundary-project"; result.name = "Rounded import";
    Song song; song.id = "song"; song.name = "Timeline"; song.duration = 15000;
    song.regionOwnershipInitialized = initialized;
    // Real imported timing: region text has six decimal places; an item's
    // tempo-derived position carries more precision, 0.432 us before the edge.
    song.parts = {{"region", "Song", 11958.400000432, 12174.900000432}};
    Track track{"track", "Audio", {"other"}};
    const auto item = [](ID id, double position) {
        AudioClip result; result.id = id; result.name = id;
        result.startTime = position; result.duration = 216.5;
        result.audioFile = AudioFile{"Stems/source.wav"}; return result;
    };
    track.clips = {item("rounded", 11958.4), item("loose-inside", 11960),
                   item("loose-before", 11958.39), item("future-loose", 13000),
                   item("exact-loose", song.parts[0].startTime)};
    song.tracks = {track};
    song.markers = std::vector<TimelineMarker>{{"rounded-marker", "Cue", 11958.4, 0},
        {"loose-marker", "Loose cue", 11970, 0}, {"future-marker", "Future cue", 13010, 0}};
    result.songs = {song}; return result;
}
static const AudioClip& clip(const Engine& engine, const ID& id) {
    for (const auto& item : engine.currentSong()->tracks[0].clips) if (item.id == id) return item;
    throw std::runtime_error("Missing test item");
}
static const TimelineMarker& marker(const Engine& engine, const ID& id) {
    for (const auto& item : *engine.currentSong()->markers) if (item.id == id) return item;
    throw std::runtime_error("Missing test marker");
}
int main() {
    try {
        for (bool initialized : {false, true}) {
            Engine engine; engine.loadProject(fixture(initialized));
            require(clip(engine, "rounded").regionOwnerID == "region", "rounded onset must belong to its region on first import and on legacy initialized load");
            require(marker(engine, "rounded-marker").regionOwnerID == "region", "rounded cue onset must belong to its region");
            require(engine.currentSong()->regionOwnershipVersion == 2, "ownership repair is persisted as version 2");
            if (initialized) {
                require(!clip(engine, "loose-inside").regionOwnerID && !clip(engine, "exact-loose").regionOwnerID,
                        "migration never recaptures an intentionally loose item within or exactly on a region");
                require(!marker(engine, "loose-marker").regionOwnerID, "migration preserves loose markers inside a region");
            }
            require(!clip(engine, "loose-before").regionOwnerID, "sub-microsecond repair cannot acquire audibly earlier items");
            const double originalStart = engine.currentSong()->parts[0].startTime;
            engine.moveRegion("region", 14000);
            near(clip(engine, "rounded").startTime, 11958.4 + 14000 - originalStart, "region move carries rounded audio by exactly the same delta");
            near(marker(engine, "rounded-marker").position, clip(engine, "rounded").startTime, "region move carries rounded cue with audio");
            near(clip(engine, "rounded").duration, 216.5, "ownership repair and movement do not stretch audio");
            engine.loadProject(engine.project()); engine.moveRegion("region", originalStart);
            near(clip(engine, "rounded").startTime, 11958.4, "save/reload and roundtrip move preserve original sample timing");
        }
        {
            Engine engine; engine.loadProject(fixture(true));
            // A region newly moved across another loose onset must remain
            // unattached even in the same microsecond boundary zone.
            engine.moveRegion("region", 13000.000000432);
            engine.loadProject(engine.project());
            require(!clip(engine, "future-loose").regionOwnerID && !marker(engine, "future-marker").regionOwnerID,
                    "versioned reload must not recapture material covered by a moved region");
            engine.moveRegion("region", 14000);
            near(clip(engine, "future-loose").startTime, 13000, "loose onset remains stationary after region leaves");
            near(marker(engine, "future-marker").position, 13010, "loose marker remains stationary after region leaves");
            engine.moveClip("future-loose", 13999.9999996);
            require(clip(engine, "future-loose").regionOwnerID == "region", "explicit placement at rounded edge attaches normally");
        }
        {
            auto project = fixture(true); project.songs[0].regionOwnershipVersion = 2;
            Engine engine; engine.loadProject(project);
            require(!clip(engine, "rounded").regionOwnerID, "current documents preserve explicit nil even at a rounded boundary");
        }
        std::cout << "REGION_ROUNDED_IMPORT_MIGRATION_MOVE_AND_NO_CAPTURE_OK\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
