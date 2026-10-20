#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Transport/PlaybackScope.hpp"
#include <stdexcept>
#include <iostream>
using namespace jaras;
static void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
int main() {
    Project project; project.id = "p"; project.name = "Playback entry";
    project.songs = {{"song", "Timeline", 100, 120, {},
        {{"group", "Group", 0, 60}, {"a", "A", 0, 30}, {"b", "B", 20, 45},
         {"c", "C", 40, 60}, {"other", "Other", 80, 100}}}};
    auto& song = project.songs[0];
    for (int i = 1; i <= 3; ++i) song.parts[i].parentRegionID = "group";
    song.regionOwnershipInitialized = true; song.regionOwnershipVersion = 2;
    Track track; track.id = "track"; track.name = "Stems"; track.role.id = "other";
    AudioClip a; a.id = "a-clip"; a.name = "A tail"; a.startTime = 0; a.duration = 30;
    a.audioFile = AudioFile{"a.wav"}; a.regionOwnerID = "a";
    auto b = a; b.id = "b-clip"; b.name = "B rounded"; b.startTime = 20 - 0.0000004; b.duration = 25; b.regionOwnerID = "b";
    auto lateA = a; lateA.id = "a-late"; lateA.startTime = 22; lateA.duration = 10;
    track.clips = {a, b, lateA}; song.tracks = {track};
    Engine engine; engine.loadProject(project);
    const auto scope = [&] { return playbackScope(*engine.currentSong(), engine.transport()); };
    const auto allows = [&](const AudioClip& clip) { return scope().allows(playbackItemStart(*engine.currentSong(), clip)); };
    engine.execute({CommandKind::editSeek, "", 24}); engine.execute({CommandKind::play});
    check(engine.transport().regionId == "group" && engine.transport().playbackStartRegionId == "b", "grid entry resolves B without changing UI root");
    check(!allows(a) && !allows(lateA) && allows(b), "direct grid start excludes A tails and retains B despite rounded onset");
    engine.execute({CommandKind::pause}); engine.execute({CommandKind::play});
    check(!allows(a) && allows(b), "pause/resume keeps entry");
    engine.execute({CommandKind::ignoreNext});
    check(engine.transport().ignoreNextRegionId == "b" && engine.transport().ignoreNextAfter == 40, "Ignore Next from mid-B never targets inaudible A");
    engine.execute({CommandKind::ignoreNext});
    engine.execute({CommandKind::stopAll}); engine.execute({CommandKind::selectRegion, "a"}); engine.execute({CommandKind::play}); engine.advance(24);
    check(allows(a) && allows(b) && allows(lateA), "continuous A-to-B retains original tails");
    engine.execute({CommandKind::ignoreNext});
    check(engine.transport().ignoreNextRegionId == "a" && engine.transport().ignoreNextEnd == 32, "late Ignore Next follows owned tails including moved onset");
    check(allows(a) && allows(lateA) && !allows(b), "Ignore Next excludes B including onset just before rounded marker");
    engine.execute({CommandKind::ignoreNext});
    engine.execute({CommandKind::seek, "", 24});
    check(!allows(a) && allows(b), "live manual seek replaces continuous entry");
    engine.execute({CommandKind::editSeek, "", 4});
    check(!allows(a), "editing return needle during playback does not change audible scope");
    engine.execute({CommandKind::subSeek, "", 24}); engine.execute({CommandKind::subPlay});
    check(engine.transport().subPlaybackStartRegionId == "b", "secondary manual entry resolves B");
    engine.execute({CommandKind::stop});
    check(engine.transport().playbackStartRegionId == "b" && !allows(a), "secondary promotion preserves entry without a queued child");
    engine.execute({CommandKind::stopAll}); engine.execute({CommandKind::selectRegion, "other"}); engine.execute({CommandKind::play});
    engine.execute({CommandKind::queueRegion, "b"}); engine.advance(21);
    check(engine.transport().playbackStartRegionId == "b" && allows(b) && !allows(a), "queued transition establishes incoming scope");
    auto loose = a; loose.regionOwnerID.reset(); check(allows(loose), "intentionally unattached items stay global");
    engine.execute({CommandKind::stopAll}); engine.execute({CommandKind::selectRegion, "c"}); engine.execute({CommandKind::play}); engine.execute({CommandKind::ignoreNext});
    check(!engine.transport().ignoreNextAfter, "last child has no next to ignore");
    auto shifted = song;
    shifted.markers = std::vector<TimelineMarker>{{"flag-b", "B", 17.5, 0}};
    shifted.markers->front().sourceRegionID = "b";
    shifted.markers->front().unifiedRegionID = "group";
    TransportState shiftedTransport;
    shiftedTransport.playbackStartRegionId = playbackEntryRegion(shifted, 19);
    check(shiftedTransport.playbackStartRegionId == "b", "entry follows visible moved flag");
    const auto shiftedScope = playbackScope(shifted, shiftedTransport);
    auto pickup = a; pickup.startTime = 18.2;
    check(shiftedScope.minimum == 17.5 && shiftedScope.allows(playbackItemStart(shifted, pickup)), "regency pickup after moved flag is audible");
    pickup.startTime = 17.5;
    check(shiftedScope.allows(playbackItemStart(shifted, pickup)), "click at visible moved flag is audible");
    check(!shiftedScope.allows(playbackItemStart(shifted, a)) && !shiftedScope.allows(playbackItemStart(shifted, lateA)), "previous tails and deliberately moved items stay excluded");
    {
        // Real Escudo arrangement: Abertura continues 4.479 seconds after the
        // Escudo marker. The old shortest-region rule captured its new items.
        auto saved = project;
        auto& s = saved.songs[0];
        const double start = 51915.98192699533;
        s.duration = 52366.98192699533;
        s.parts = {{"group", "H", 51829.96116741481, s.duration},
            {"a", "Abertura", 51829.96116741481, 51920.46116741484},
            {"b", "Escudo", start, 52194.98192699533},
            {"c", "Eu sou de Jesus", 52189.48192699533, s.duration}};
        for (int i = 1; i <= 3; ++i) s.parts[i].parentRegionID = "group";
        s.regionOwnershipVersion = 2;
        auto outgoing = a; outgoing.startTime = s.parts[1].startTime; outgoing.duration = 90.5;
        auto click = a; click.id = "click"; click.startTime = start; click.duration = 279;
        auto regency = a; regency.id = "regency"; regency.startTime = start + 0.676358073; regency.duration = 1.4542;
        auto rounded = click; rounded.id = "rounded"; rounded.startTime -= 0.0000004;
        auto detached = click; detached.id = "loose"; detached.regionOwnerID.reset();
        s.tracks[0].clips = {outgoing, click, regency, rounded, detached};
        s.markers = std::vector<TimelineMarker>{{"cue", "Cue", start + 1, 0}};
        s.markers->front().regionOwnerID = "a";
        check(regionOwnerAt(s, start) == "b" && regionOwnerAt(s, regency.startTime) == "b",
            "incoming placements follow song start, not shortest overlapping song");
        engine.execute({CommandKind::stopAll}); engine.loadProject(saved);
        engine.execute({CommandKind::selectRegion, "b"}); engine.execute({CommandKind::play});
        const auto& migrated = *engine.currentSong();
        check(migrated.regionOwnershipVersion == 3, "overlap migration is versioned");
        const auto& clips = migrated.tracks[0].clips;
        check(!allows(clips[0]), "Abertura tail stays silent on direct Escudo start");
        for (int i = 1; i <= 3; ++i)
            check(clips[i].regionOwnerID == "b" && allows(clips[i]), "Escudo click, regency and rounded onsets are restored");
        check(!clips[4].regionOwnerID, "intentionally loose items are not adopted");
        check(migrated.markers->front().regionOwnerID == "b", "cue ownership follows repaired incoming song");
        check(clips[1].startTime == click.startTime && clips[2].duration == regency.duration,
            "repair never shifts or trims media");
        engine.execute({CommandKind::stopAll}); engine.execute({CommandKind::selectRegion, "a"});
        engine.execute({CommandKind::play}); engine.execute({CommandKind::ignoreNext});
        check(allows(engine.currentSong()->tracks[0].clips[0]) && !allows(engine.currentSong()->tracks[0].clips[1]),
            "Ignore Next still plays Abertura and excludes Escudo");
        auto current = engine.project();
        current.songs[0].tracks[0].clips[1].regionOwnerID = "a";
        engine.execute({CommandKind::stopAll}); engine.loadProject(current);
        check(engine.currentSong()->tracks[0].clips[1].regionOwnerID == "a",
            "version 3 reload preserves subsequent explicit ownership");
        auto imported = saved; imported.songs[0].regionOwnershipInitialized = false;
        engine.loadProject(imported);
        check(engine.currentSong()->tracks[0].clips[1].regionOwnerID == "b",
            "new imports use the same incoming-onset rule");
    }
    std::cout << "PLAYBACK_ENTRY_OWNERSHIP_AND_IGNORE_NEXT_OK\n";
}
