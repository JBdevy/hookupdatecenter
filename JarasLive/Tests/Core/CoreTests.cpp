#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Import/TrackTaxonomy.hpp"
#include <iostream>
#include <limits>
#include <stdexcept>
using namespace jaras;
static void expect(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
static void testAutoUntilBlockEnd() {
    Project project; project.id = "block-project"; project.name = "Blocks";
    project.songs = {{"block-song", "Songs", 80, 120, {},
        {{"a", "A", 0, 10}, {"b", "B", 10, 20}, {"c", "C", 20, 30},
         {"d", "D", 30, 40}, {"e", "E", 40, 50}, {"f", "F", 50, 60}}}};
    RegionSetlist state; state.autoAdvance = true; state.selectedId = "block-list";
    state.playlists = {{"block-list", "Show", "block-song", {"a", "b", "c", "d", "e", "f"}}};
    state.blocks = std::vector<SetlistBlock>{
        {"opening", "block-song", "block-list", "Opening", 0, "a"},
        {"middle", "block-song", "block-list", "Middle", 0, "c"},
        {"closing", "block-song", "block-list", "Closing", 0, "e"}};
    project.regionSetlist = state;
    const auto start = [](Engine& engine, const ID& id) {
        engine.execute({CommandKind::selectRegion, id}); engine.execute({CommandKind::play});
    };
    Engine legacy; legacy.loadProject(project); start(legacy, "b");
    expect(legacy.transport().queuedRegionId == "c", "block limit defaults off for existing projects");
    legacy.advance(10);
    expect(legacy.transport().playing && legacy.transport().regionId == "c", "default Auto crosses block headings");

    state.autoUntilBlockEnd = true; project.regionSetlist = state;
    Engine limited; limited.loadProject(project); start(limited, "a");
    expect(limited.transport().queuedRegionId == "b", "block limit queues songs within the current block");
    limited.advance(80);
    expect(!limited.transport().playing && limited.transport().position == 20 && limited.transport().regionId == "b" && !limited.transport().queuedRegionId,
           "large ticks stop exactly at the last song of the block");
    expect(limited.project().regionSetlist->autoAdvance && limited.project().regionSetlist->autoUntilBlockEnd,
           "reaching a block boundary leaves Auto and its block policy enabled");
    auto cosmetic = *limited.project().regionSetlist;
    cosmetic.blocks->front().name = "Cosmetic"; cosmetic.blocks->front().color = 0x987654;
    cosmetic.liveEnabled = true; cosmetic.playedLiveRegionIDs = std::vector<ID>{"b"};
    const auto stopped = limited.transport();
    limited.configureRegionSetlist(cosmetic);
    expect(limited.transport().regionId == stopped.regionId && limited.transport().position == stopped.position &&
           limited.transport().editPosition == stopped.editPosition && limited.transport().playing == stopped.playing &&
           limited.transport().queuedRegionId == stopped.queuedRegionId && limited.transport().queueStartedAt == stopped.queueStartedAt &&
           limited.transport().subPlay.position == stopped.subPlay.position && limited.transport().subPlay.playing == stopped.subPlay.playing,
           "cosmetic and Live edits preserve stopped transport exactly at a contiguous block boundary");
    start(limited, "c");
    expect(limited.transport().queuedRegionId == "d", "manual selection starts automatic queueing in the new block");
    limited.advance(30);
    expect(!limited.transport().playing && limited.transport().position == 40, "manually selected block also stops before its following block");

    Engine manual; manual.loadProject(project); start(manual, "a");
    manual.execute({CommandKind::queueRegion, "c"});
    auto edited = state; edited.blocks->at(1).name = "Renamed";
    manual.configureRegionSetlist(edited);
    expect(manual.transport().queuedRegionId == "c" && manual.project().regionSetlist->autoUntilBlockEnd,
           "manual queue crosses a block boundary without disabling the persistent policy");
    manual.advance(30);
    expect(!manual.transport().playing && manual.transport().position == 40 && manual.transport().regionId == "d",
           "after a manual cross-block queue, Auto runs only to the end of that destination block");

    Engine rename; rename.loadProject(project); start(rename, "a"); rename.advance(2);
    const double queueOrigin = rename.transport().queueStartedAt;
    edited = state; edited.blocks->front().name = "New name"; edited.blocks->front().color = 0x123456; edited.blocks->front().symbol = false;
    rename.configureRegionSetlist(edited);
    expect(rename.transport().queuedRegionId == "b" && rename.transport().queueStartedAt == queueOrigin,
           "block name, color and symbol edits preserve the existing queue countdown");
    edited.blocks->at(1).beforeRegionId = "b";
    rename.configureRegionSetlist(edited);
    expect(!rename.transport().queuedRegionId && rename.transport().position == 2, "moving a block heading retracts a newly forbidden automatic queue");
    edited.blocks->at(1).beforeRegionId = "c";
    rename.configureRegionSetlist(edited);
    expect(rename.transport().queuedRegionId == "b", "moving the heading back restores a permitted automatic queue");
    auto projectEdit = rename.project(); projectEdit.regionSetlist->blocks->at(1).beforeRegionId = "b";
    rename.applyProjectEdit(projectEdit);
    expect(!rename.transport().queuedRegionId, "full project edits also revalidate block boundaries");
    projectEdit.regionSetlist->blocks->at(1).beforeRegionId = "c"; rename.applyProjectEdit(projectEdit);
    expect(rename.transport().queuedRegionId == "b", "undoing a boundary edit restores queueing without a transport restart");

    auto reordered = project;
    reordered.regionSetlist->playlists[0].regionIds = {"c", "a", "b", "d", "e", "f"};
    reordered.regionSetlist->blocks->at(1).beforeRegionId = "d";
    reordered.regionSetlist->blocks->front().beforeRegionId = "c";
    Engine order; order.loadProject(reordered); start(order, "c");
    expect(order.transport().queuedRegionId == "a", "block policy follows playlist sequence rather than timeline order");
    order.advance(30);
    expect(!order.transport().playing && order.transport().position == 20 && order.transport().regionId == "b",
           "reordered playlist stops at its next heading even when time moves backwards");

    auto all = project; all.regionSetlist->selectedId.reset();
    all.regionSetlist->blocks->push_back({"all-boundary", "block-song", {}, "All regions", 0, "c"});
    all.regionSetlist->blocks->push_back({"empty-end", "block-song", {}, "Empty", 0, {}});
    Engine allRegions; allRegions.loadProject(all); start(allRegions, "a");
    expect(allRegions.transport().queuedRegionId == "b", "All regions ignores headings belonging to a playlist");
    allRegions.advance(20);
    expect(!allRegions.transport().playing && allRegions.transport().position == 20,
           "an unheaded leading group in All regions stops before its first applicable heading");
    Engine scoped; scoped.loadProject(project); start(scoped, "b");
    edited = state; edited.blocks->at(1).playlistId.reset(); scoped.configureRegionSetlist(edited);
    expect(scoped.transport().queuedRegionId == "c", "playlist playback ignores a boundary belonging to All regions");

    for (bool applyWholeProject : {false, true}) {
        auto runningProject = project; runningProject.regionSetlist->autoUntilBlockEnd = false;
        runningProject.regionSetlist->automaticSubplay = true;
        Engine running; running.loadProject(runningProject); start(running, "b"); running.advance(9);
        expect(running.transport().subPlay.playing && running.transport().queuedRegionId == "c", "fixture starts next-block automatic Subplay before enabling limit");
        auto next = running.project(); next.regionSetlist->autoUntilBlockEnd = true;
        if (applyWholeProject) running.applyProjectEdit(next); else running.configureRegionSetlist(*next.regionSetlist);
        expect(!running.transport().queuedRegionId && !running.transport().subPlay.playing && running.transport().playing && running.transport().position == 19,
               "enabling the limit retracts next-block queue and its automatic Subplay without moving main playback");
        running.advance(2);
        expect(!running.transport().playing && running.transport().position == 20, "changed policy takes effect at the current block end");
    }
    for (int manualSubplay : {0, 1, 2}) {
        auto runningProject = project; runningProject.regionSetlist->autoUntilBlockEnd = false;
        runningProject.regionSetlist->automaticSubplay = manualSubplay != 0;
        Engine running; running.loadProject(runningProject); start(running, "b"); running.advance(9);
        if (manualSubplay == 1) running.execute({CommandKind::subStop});
        if (manualSubplay == 2) running.execute({CommandKind::subSeek, "", 21});
        else running.execute({CommandKind::subPlay});
        const double manualPosition = running.transport().subPlay.position;
        auto next = *running.project().regionSetlist; next.autoUntilBlockEnd = true;
        running.configureRegionSetlist(next);
        expect(!running.transport().queuedRegionId && running.transport().subPlay.playing && running.transport().subPlay.position == manualPosition,
               "enabling the limit preserves manually started, restarted or repositioned Subplay");
    }
    auto crossProject = project; crossProject.regionSetlist->automaticSubplay = true;
    Engine cross; cross.loadProject(crossProject); start(cross, "a"); cross.advance(9); cross.advance(1);
    expect(cross.transport().regionId == "b" && cross.transport().subPlayPromotion == 1 && !cross.transport().queuedRegionId,
           "automatic Subplay still promotes inside a block and never prepares its next block");
    cross.advance(9);
    expect(!cross.transport().playing && cross.transport().position == 20 && !cross.transport().subPlay.playing,
           "Subplay handoff preserves the block end stop");
    Engine manualCross; manualCross.loadProject(crossProject); start(manualCross, "b");
    manualCross.execute({CommandKind::queueRegion, "c"}); manualCross.advance(9);
    manualCross.configureRegionSetlist(*manualCross.project().regionSetlist);
    expect(manualCross.transport().queuedRegionId == "c" && manualCross.transport().subPlay.playing,
           "automatic Subplay for a manually chosen cross-block queue remains allowed");
    manualCross.advance(1); manualCross.advance(19);
    expect(!manualCross.transport().playing && manualCross.transport().position == 40 && manualCross.project().regionSetlist->autoUntilBlockEnd,
           "manual queue with automatic Subplay resumes the same limit in its destination block");

    auto pausedProject = crossProject; pausedProject.regionSetlist->autoUntilBlockEnd = false;
    Engine paused; paused.loadProject(pausedProject); start(paused, "b"); paused.advance(9); paused.execute({CommandKind::pause});
    edited = *paused.project().regionSetlist; edited.autoUntilBlockEnd = true; paused.configureRegionSetlist(edited);
    paused.execute({CommandKind::play});
    expect(!paused.transport().subPlay.playing && !paused.transport().queuedRegionId, "invalidated automatic Subplay cannot resume from Pause");
    paused.advance(2);
    expect(!paused.transport().playing && paused.transport().position == 20, "paused policy change stops at the same block boundary");

    auto readyProject = crossProject; readyProject.regionSetlist->prepareWithoutPlayback = true;
    Engine ready; ready.loadProject(readyProject); start(ready, "a"); ready.advance(10);
    expect(!ready.transport().playing && ready.transport().regionId == "b" && ready.transport().position == 10,
           "Without playback prepares the next song within a block");
    ready.execute({CommandKind::play}); ready.advance(10);
    expect(!ready.transport().playing && ready.transport().regionId == "b" && ready.transport().position == 20 && !ready.transport().queuedRegionId,
           "Without playback does not prepare the first song of the next block");

    auto drawer = project;
    Part child{"drawer-child", "Child", 2, 5}; child.parentRegionID = "a";
    drawer.songs[0].parts.push_back(child);
    drawer.regionSetlist->playlists[0].regionIds.insert(drawer.regionSetlist->playlists[0].regionIds.begin() + 1, child.id);
    drawer.regionSetlist->blocks->at(1).beforeRegionId = "b";
    Engine unified; unified.loadProject(drawer); start(unified, child.id);
    expect(!unified.transport().queuedRegionId, "drawer child inherits its listed parent's block boundary, skipping hidden child IDs");
    unified.advance(20);
    expect(!unified.transport().playing && unified.transport().position == 10,
           "unified playback stops at the parent's end, not the child end");
    drawer.regionSetlist->blocks->at(1).beforeRegionId = child.id;
    Engine hidden; hidden.loadProject(drawer); start(hidden, child.id);
    expect(hidden.transport().queuedRegionId == "b", "hidden drawer child anchors do not introduce a visible block boundary");

    Engine toggle; toggle.loadProject(project); start(toggle, "b");
    edited = state; edited.autoUntilBlockEnd = false; toggle.configureRegionSetlist(edited);
    expect(toggle.transport().queuedRegionId == "c", "turning off block limit immediately restores normal Auto queue");
    toggle.execute({CommandKind::queueRegion, "e"});
    edited.autoUntilBlockEnd = true; toggle.configureRegionSetlist(edited);
    auto manualEdit = toggle.project(); manualEdit.regionSetlist->blocks->at(1).beforeRegionId = "b";
    toggle.applyProjectEdit(manualEdit);
    expect(toggle.transport().queuedRegionId == "e", "setting and full project edits never retract a manually chosen cross-block queue");
}
static void testSubplaySurvivesOutgoingEnd() {
    for (bool automatic : {false, true}) for (bool stop : {false, true}) for (bool queued : {false, true}) {
        Project project; project.id = "sub-end"; project.name = "Subplay boundary";
        project.songs = {{"song", "Timeline", 100, 120, {}, {{"a", "Outgoing", 0, 10}, {"b", "Incoming", 30, 50}, {"c", "Queued", 60, 80}}}};
        RegionSetlist list; list.autoAdvance = automatic; list.stopAtRegionEnd = stop;
        project.regionSetlist = list;
        Engine engine; engine.loadProject(project);
        engine.execute({CommandKind::selectRegion, "a"}); engine.execute({CommandKind::play});
        engine.advance(8);
        if (queued) engine.execute({CommandKind::queueRegion, "b"});
        engine.execute({CommandKind::subPlay}); engine.execute({CommandKind::subSeek, "", 30});
        engine.advance(2.25);
        expect(engine.transport().playing && !engine.transport().subPlay.playing && engine.transport().subPlayPromotion == 1 &&
               engine.transport().regionId == "b" && engine.transport().position == 32.25,
               "outgoing end promotes running Subplay before STOP, with or without Auto/queue");
        expect(engine.transport().editPosition == 32.25,
               "promotion carries the edit cursor to the incoming Subplay position");
        engine.advance(0.5);
        expect(engine.transport().playing && engine.transport().position == 32.75 && engine.transport().subPlayPromotion == 1,
               "incoming playback keeps advancing without repeating or inheriting outgoing STOP");
        expect(engine.transport().editPosition == 32.25, "promoted edit cursor remains at the handoff position");
        engine.execute({CommandKind::stopAll});
        expect(!engine.transport().playing && !engine.transport().subPlay.playing, "explicit Stop All still stops both heads");
    }
    for (bool prepare : {false, true}) {
        Project project; project.id = "auto-sub-stop"; project.name = "Pre-roll";
        project.songs = {{"song", "Timeline", 60, 120, {}, {{"a", "A", 0, 10}, {"b", "B", 20, 40}}}};
        RegionSetlist list; list.autoAdvance = true; list.stopAtRegionEnd = true;
        list.automaticSubplay = true; list.prepareWithoutPlayback = prepare;
        project.regionSetlist = list;
        Engine engine; engine.loadProject(project); engine.execute({CommandKind::selectRegion, "a"});
        engine.execute({CommandKind::play}); engine.advance(9);
        if (prepare) engine.execute({CommandKind::subPlay});
        expect(engine.transport().subPlay.playing, "fixture has an active manual or automatic pre-roll");
        engine.advance(1.25);
        expect(engine.transport().playing && engine.transport().position == 21.25 && engine.transport().subPlayPromotion == 1,
               "STOP and prepare-only policies cannot silence a song that already started");
    }
    // The final region may also be the end of the complete timeline. Incoming
    // Subplay earlier in that same timeline must survive that boundary too.
    Project project; project.id = "timeline-end"; project.name = "End";
    project.songs = {{"song", "Timeline", 100, 120, {}, {}}};
    Engine engine; engine.loadProject(project); engine.execute({CommandKind::seek, "", 98});
    engine.execute({CommandKind::play}); engine.execute({CommandKind::subPlay});
    engine.execute({CommandKind::subSeek, "", 20}); engine.advance(2.25);
    expect(engine.transport().playing && engine.transport().position == 22.25 && engine.transport().subPlayPromotion == 1,
           "timeline end without a region promotes the already-running secondary head");
}

static void testRegionStopRespectsQueue() {
    for (bool automatic : {false, true}) for (bool prepare : {false, true}) for (bool drawer : {false, true}) {
        Project project; project.id = "stop-queue"; project.name = "STOP queue priority";
        project.songs = {{"song", "Timeline", 80, 120, {},
            {{"a", "Outgoing", 0, 10}, {"b", "Skipped", 20, 30}, {"c", "Queued", 40, 50}}}};
        if (drawer) {
            Part child{"child", "Drawer song", 0, 5}; child.parentRegionID = "a";
            project.songs[0].parts.push_back(child);
        }
        RegionSetlist list; list.autoAdvance = automatic; list.stopAtRegionEnd = true;
        list.prepareWithoutPlayback = prepare; project.regionSetlist = list;
        Engine engine; engine.loadProject(project);
        engine.execute({CommandKind::selectRegion, drawer ? "child" : "a"}); engine.execute({CommandKind::play});
        engine.execute({CommandKind::queueRegion, "c"});
        engine.execute({CommandKind::editSeek, "", 2});
        engine.advance(9.75);
        expect(engine.transport().playing && engine.transport().position == 9.75 && engine.transport().queuedRegionId == "c",
               "STOP preserves manual queue and waits for the whole outgoing region, including drawers");
        expect(engine.transport().editPosition == 2, "arming a song does not move the edit cursor before the jump");
        engine.advance(0.5);
        expect(engine.transport().regionId == "c" && engine.transport().playing == !prepare &&
               engine.transport().position == (prepare ? 40 : 40.25) && !engine.transport().queuedRegionId,
               "queued song takes precedence over STOP; explicit prepare-only mode still prepares without playing");
        expect(engine.transport().editPosition == 40, "queue handoff carries the edit cursor to the exact song start");
        expect(engine.transport().sectionJumpSerial == (prepare ? 0 : 1),
               "queue transition emits the same discontinuity serial as a smooth seek, without emitting it for prepare-only");
        if (!prepare) {
            engine.advance(10);
            expect(!engine.transport().playing && engine.transport().position == 50,
                   "STOP still stops at the incoming song's own end when its queue is empty");
        }
    }
    Project project; project.id = "stop-auto-queue"; project.name = "Automatic queue";
    project.songs = {{"song", "Timeline", 40, 120, {}, {{"a", "A", 0, 10}, {"b", "B", 20, 30}}}};
    RegionSetlist list; list.autoAdvance = true; list.stopAtRegionEnd = true; project.regionSetlist = list;
    Engine engine; engine.loadProject(project); engine.execute({CommandKind::selectRegion, "a"}); engine.execute({CommandKind::play});
    engine.advance(10.25);
    expect(engine.transport().playing && engine.transport().regionId == "b" && engine.transport().position == 20.25,
           "STOP also honors a queue populated by AUTO without Subplay");
    engine.advance(10);
    expect(!engine.transport().playing && engine.transport().position == 30,
           "AUTO plus STOP ends normally after the final queued song");
}

int main() {
    testRegionStopRespectsQueue();
    testSubplaySurvivesOutgoingEnd();
    testAutoUntilBlockEnd();
    Project p; p.id="project"; p.name="Show"; p.songs={{"one","One",10,120,{{"track","Click",{"click"}}},{}},{"two","Two",20,100,{},{}},{"three","Three",30,90,{},{}}};
    p.setlists={{"setlist","Setlist",{"one","two","three"}}};
    ProjectTimeSettings relativeTime; relativeTime.timebase = ProjectTimebase::relative;
    p.songs[0].timeSettings = relativeTime;
    Engine tempo; tempo.loadProject(p); tempo.execute({CommandKind::play}); tempo.advance(1);
    tempo.execute({CommandKind::tempo, "", 90});
    tempo.execute({CommandKind::beatsPerBar, "", 6}); tempo.execute({CommandKind::beatUnit, "", 8});
    expect(tempo.currentSong()->bpm == 90 && tempo.currentSong()->beatsPerBar == 6 && tempo.currentSong()->beatUnit == 8, "tempo and meter update the grid model");
    expect(tempo.transport().playing && std::abs(tempo.transport().position - 4.0/3) < 1e-9, "timing edits preserve playback and musical position");
    expect(tempo.project().songs[1].bpm == 100, "timing edit belongs to current arrangement");
    bool invalidTempo = false; try { tempo.execute({CommandKind::tempo, "", 0}); } catch (...) { invalidTempo = true; }
    expect(invalidTempo && tempo.currentSong()->bpm == 90, "invalid tempo is rejected without mutation");
    bool invalidMeter = false; try { tempo.execute({CommandKind::beatUnit, "", 3}); } catch (...) { invalidMeter = true; }
    expect(invalidMeter && tempo.currentSong()->beatUnit == 8, "invalid beat unit is rejected without mutation");
    validate(tempo.project());
    ProjectTimeSettings freeTime; freeTime.timebase = ProjectTimebase::free; freeTime.divisions = 8;
    Engine freeGrid; freeGrid.loadProject(p); freeGrid.execute({CommandKind::editSeek, "", 2});
    freeGrid.setProjectTiming(240, 3, 8, freeTime);
    expect(freeGrid.currentSong()->duration == 10 && freeGrid.transport().editPosition == 2, "free grid keeps absolute timeline and cursor positions");
    expect(freeGrid.currentSong()->timeSettings->divisions == 8 && freeGrid.currentSong()->beatsPerBar == 3, "project timing settings update together");
    freeGrid.execute({CommandKind::tempo, "", 120});
    expect(freeGrid.currentSong()->duration == 10 && freeGrid.transport().editPosition == 2, "toolbar tempo also respects free grid");
    freeTime.divisions = 16;
    bool invalidDivisions = false; try { freeGrid.setProjectTiming(200, 4, 4, freeTime); } catch (...) { invalidDivisions = true; }
    expect(invalidDivisions && freeGrid.currentSong()->bpm == 120 && freeGrid.currentSong()->beatsPerBar == 3, "invalid settings never partially apply tempo or meter");
    Project stretchProject = p;
    AudioClip stretchClip; stretchClip.id = "stretched"; stretchClip.name = "Audio";
    stretchClip.startTime = 2; stretchClip.duration = 6; stretchClip.sourceOffset = 0.5;
    stretchProject.songs[0].tracks[0].clips = {stretchClip};
    stretchProject.songs[0].parts = {{"tempo-region", "Region", 2, 8, 0x123456}};
    stretchProject.songs[0].markers = std::vector<TimelineMarker>{{"tempo-marker", "Marker", 3, 0xabcdef}};
    Engine stretched; stretched.loadProject(stretchProject);
    stretched.execute({CommandKind::editSeek, "", 2}); stretched.execute({CommandKind::play});
    stretched.execute({CommandKind::subSeek, "", 4}); stretched.execute({CommandKind::subPlay});
    stretched.execute({CommandKind::tempo, "", 240});
    const auto& changed = stretched.project().songs[0];
    expect(changed.tracks[0].clips[0].startTime == 1 && changed.tracks[0].clips[0].duration == 3 && changed.tracks[0].clips[0].playbackRate == 2, "all audio timing follows BPM proportionally");
    expect(changed.tracks[0].clips[0].sourceOffset == 0.5 && changed.parts[0].endTime == 4 && changed.markers->at(0).position == 1.5, "source offset remains in file seconds; regions and markers follow tempo");
    expect(stretched.transport().position == 1 && stretched.transport().subPlay.position == 2 && stretched.transport().subPlay.playing, "both playback heads preserve their musical position");
    stretched.execute({CommandKind::tempo, "", 120});
    expect(stretched.currentSong()->tracks[0].clips[0].duration == 6 && stretched.currentSong()->tracks[0].clips[0].playbackRate == 1, "restoring tempo restores original audio speed");
    stretched.execute({CommandKind::subStop}); stretched.execute({CommandKind::stop});
    expect(stretched.transport().position == 2, "stop anchor follows the tempo changes");
    for (double invalid : {59.0,301.0}) {
        bool rejected = false; try { stretched.execute({CommandKind::tempo,"",invalid}); } catch (...) { rejected = true; }
        expect(rejected && stretched.currentSong()->bpm == 120, "BPM range is enforced by the engine");
    }
    validate(stretched.project());
    Project grouped = p;
    grouped.songs[0].tracks.push_back({"b", "Piano", {"keys"}});
    grouped.songs[0].tracks.push_back({"c", "Guitar", {"guitar"}});
    grouped.songs[0].tracks.push_back({"d", "Pad", {"keys"}});
    Engine groups; groups.loadProject(grouped); groups.execute({CommandKind::play}); groups.advance(1);
    groups.groupTracks({"d", "b"});
    auto groupedTracks = groups.project().songs[0].tracks;
    expect(groupedTracks[1].id == "b" && groupedTracks[2].id == "d" && groupedTracks[2].parentTrackID == "b", "group uses uppermost selected track and gathers nonadjacent children");
    expect(groups.transport().playing && groups.transport().position == 1, "group preserves transport");
    expect(groupedTracks[2].patch && groupedTracks[2].patch->firstChannel == -2 && !groupedTracks[2].secondaryPatch, "group creation defaults children to Master Group and second send to None");
    expect(groupedTracks[1].patch && groupedTracks[1].patch->firstChannel == 0, "folder defaults to Master");
    groups.setOutputPatch("d", 3, 2, 1);
    expect(groups.project().songs[0].tracks[2].secondaryPatch->firstChannel == 3, "second send is independent");
    groups.setOutputPatch("", 5, 2, 1);
    expect(groups.project().masterSecondaryPatch->firstChannel == 5, "Master supports second hardware output");
    bool routingCycle = false; try { groups.setOutputPatch("b", -2, 2); } catch (...) { routingCycle = true; }
    expect(routingCycle, "root folder cannot feed itself through Master Group");
    bool masterCycle = false; try { groups.setOutputPatch("", 0, 2); } catch (...) { masterCycle = true; }
    expect(masterCycle, "Master cannot feed itself");
    validate(groups.project());
    groups.reorderTrack("b", "track");
    expect(groups.project().songs[0].tracks[0].id == "b" && groups.project().songs[0].tracks[1].id == "d", "folder drag moves children with it");
    validate(groups.project());
    groups.reorderTrack("d", "");
    expect(!groups.project().songs[0].tracks.back().parentTrackID, "child may move out of folder");
    validate(groups.project());
    bool invalidGroup = false; try { groups.groupTracks({"b", "missing"}); } catch (...) { invalidGroup = true; }
    expect(invalidGroup && !groups.project().songs[0].tracks.back().parentTrackID, "invalid group changes nothing");
    groups.groupTracks({"b", "d"}); groups.groupTracks({"track", "b"}); validate(groups.project());
    expect(groups.project().songs[0].tracks[1].parentTrackID == "b", "regrouping keeps existing children");
    {
        Project nested = p;
        auto& tracks = nested.songs[0].tracks;
        tracks = {{"outer", "Outer", {"other"}}, {"member", "Member", {"other"}},
                  {"last", "Last", {"other"}}, {"incoming", "Incoming", {"other"}},
                  {"inner", "Inner", {"other"}}, {"leaf", "Leaf", {"other"}}};
        tracks[1].parentTrackID = "outer"; tracks[2].parentTrackID = "outer";
        tracks[4].parentTrackID = "incoming"; tracks[5].parentTrackID = "inner";
        tracks[3].volume = 0.37; tracks[3].outputs = std::vector<OutputPatch>{{0,2},{5,2}};
        tracks[4].patch = OutputPatch{-2,2}; tracks[5].patch = OutputPatch{-2,2};
        Engine tree; tree.loadProject(nested); tree.execute({CommandKind::play}); tree.advance(1);
        tree.reorderTrack("incoming", "member");
        auto result = tree.currentSong()->tracks;
        expect(result[2].id == "last" && result[3].id == "incoming" && result[3].parentTrackID == "outer", "nested drop appends after destination's last child");
        expect(result[4].parentTrackID == "incoming" && result[5].parentTrackID == "inner", "nested drop preserves all descendant folders");
        expect(result[3].volume == 0.37 && result[3].outputPatches()[0].firstChannel == -2 && result[3].outputPatches()[1].firstChannel == 5, "folder feeds its new parent while preserving gain and hardware send");
        expect(tree.transport().playing && tree.transport().position == 1, "nested drop does not reset transport");
        tree.reorderTrack("outer", "leaf");
        expect(tree.currentSong()->tracks[0].id == "outer" && !tree.currentSong()->tracks[0].parentTrackID, "self-descendant drop is a no-op");
        tree.reorderTrack("incoming", "");
        result = tree.currentSong()->tracks;
        expect(!result[3].parentTrackID && result[3].outputPatches()[0].firstChannel == 0 && result[4].parentTrackID == "incoming", "moving nested tree out restores root output and keeps inner routes");
        validate(tree.project());
        nested.songs[0].tracks[0].routing = TrackRouting{};
        nested.songs[0].tracks[0].routing->transmitters = {"incoming"};
        tree.execute({CommandKind::stopAll}); tree.loadProject(nested);
        bool rejected = false;
        try { tree.reorderTrack("incoming", "member"); } catch (...) { rejected = true; }
        expect(rejected && !tree.currentSong()->tracks[3].parentTrackID && tree.currentSong()->tracks[3].outputPatches()[0].firstChannel == 0, "feedback-producing nested drop rolls back atomically");
    }
    {
        auto project = p;
        auto& tracks = project.songs[0].tracks;
        tracks = {{"outer", "Outer", {"other"}}, {"inner", "Inner", {"other"}},
                  {"folder", "Folder", {"other"}}, {"leaf", "Leaf", {"other"}},
                  {"last", "Last", {"other"}}, {"outside", "Outside", {"other"}}};
        tracks[1].parentTrackID = "outer"; tracks[2].parentTrackID = "inner";
        tracks[3].parentTrackID = "folder"; tracks[4].parentTrackID = "inner";
        tracks[2].patch = OutputPatch{-2,2}; tracks[3].patch = OutputPatch{-2,2};
        Engine tree; tree.loadProject(project);
        tree.reorderTrack("folder", "inner");
        auto result = tree.currentSong()->tracks;
        expect(result[1].id == "folder" && result[1].parentTrackID == "outer" && result[2].parentTrackID == "folder" && result[3].id == "inner", "dragging a nested folder above its own parent lifts it before that parent with children intact");
        tree.reorderTrack("folder", "outer");
        result = tree.currentSong()->tracks;
        expect(result[0].id == "folder" && !result[0].parentTrackID && result[0].outputPatches()[0].firstChannel == 0 && result[1].parentTrackID == "folder", "dragging above a root folder detaches the child subtree and restores its master output");
        tree.reorderTrack("leaf", "folder");
        result = tree.currentSong()->tracks;
        expect(result[0].id == "leaf" && !result[0].parentTrackID && result[1].id == "folder", "an individual child exits above its folder");
        validate(tree.project());
    }
    Project ignoreProject = p; ignoreProject.songs[0].duration = 120;
    ignoreProject.songs[0].parts = {{"ignore-root", "Special", 0, 60}, {"ignore-first", "One", 0, 25}, {"ignore-second", "Two", 20, 40}, {"ignore-third", "Three", 40, 60}, {"ignore-queue", "Queued", 80, 100}};
    for (int i = 1; i <= 3; ++i) ignoreProject.songs[0].parts[i].parentRegionID = "ignore-root";
    AudioClip ignoredSource; ignoredSource.id = "ignore-audio"; ignoredSource.name = "Tail"; ignoredSource.startTime = 0; ignoredSource.duration = 25; ignoredSource.audioFile = AudioFile{"tail.wav"};
    ignoreProject.songs[0].tracks[0].clips = {ignoredSource};
    Engine ignore; ignore.loadProject(ignoreProject); ignore.execute({CommandKind::selectRegion, "ignore-first"}); ignore.execute({CommandKind::play}); ignore.advance(10);
    ignore.execute({CommandKind::ignoreNext});
    expect(ignore.transport().ignoreNextAfter == 20 && ignore.transport().ignoreNextEnd == 25, "Ignore Next retains the current song's overlapping tail");
    ignore.advance(14); expect(ignore.transport().playing && ignore.transport().position == 24, "Ignore Next waits for last current audio");
    ignore.advance(2); expect(!ignore.transport().playing && ignore.transport().position == 25 && !ignore.transport().ignoreNextAfter, "Ignore Next stops exactly at audio end without queue");
    ignore.execute({CommandKind::selectRegion, "ignore-first"}); ignore.execute({CommandKind::play}); ignore.execute({CommandKind::queueRegion, "ignore-queue"}); ignore.execute({CommandKind::ignoreNext}); ignore.advance(26);
    expect(ignore.transport().playing && ignore.transport().regionId == "ignore-queue" && ignore.transport().position == 81 && !ignore.transport().ignoreNextAfter, "Ignore Next consumes boundary once and resumes the queued song");
    ignore.execute({CommandKind::stopAll}); ignore.execute({CommandKind::selectRegion, "ignore-first"}); ignore.execute({CommandKind::play}); ignore.execute({CommandKind::ignoreNext}); ignore.execute({CommandKind::ignoreNext}); ignore.advance(26);
    expect(ignore.transport().playing && !ignore.transport().ignoreNextAfter && ignore.transport().position == 26, "Ignore Next toggles off without seeking or stopping");
    ignore.execute({CommandKind::stopAll}); ignore.execute({CommandKind::selectRegion, "ignore-first"}); ignore.execute({CommandKind::play}); ignore.advance(24);
    ignore.execute({CommandKind::ignoreNext});
    expect(ignore.transport().ignoreNextRegionId == "ignore-first" && ignore.transport().ignoreNextAfter == 20 && ignore.transport().ignoreNextEnd == 25, "late Ignore Next targets the previous song while its audio still plays");
    ignore.execute({CommandKind::ignoreNext});
    expect(!ignore.transport().ignoreNextAfter && ignore.transport().position == 24, "late toggle off restores the next song without moving the cursor");
    ignore.execute({CommandKind::ignoreNext});
    expect(ignore.transport().ignoreNextRegionId == "ignore-first", "toggling on again after crossing a marker retains the audible tail");
    ignore.advance(2); expect(!ignore.transport().playing && ignore.transport().position == 25, "late Ignore Next uses actual file end");
    ignore.execute({CommandKind::stopAll}); ignore.execute({CommandKind::selectRegion, "ignore-third"}); ignore.execute({CommandKind::play}); ignore.execute({CommandKind::ignoreNext});
    expect(!ignore.transport().ignoreNextAfter, "last drawer song cannot ignore a nonexistent next song");
    ignore.setRegionPitch("ignore-first", 12, {"track"}, {});
    ignore.setRegionPitch("ignore-second", -12, {"track"}, {});
    expect(ignore.project().songs[0].parts[1].pitchSemitones == 12 && ignore.project().songs[0].parts[2].pitchSemitones == -12, "each drawer song owns its pitch settings");
    bool pitchRejected = false; try { ignore.setRegionPitch("ignore-first", 13, {"track"}, {}); } catch (...) { pitchRejected = true; }
    expect(pitchRejected && ignore.project().songs[0].parts[1].pitchSemitones == 12, "region pitch rejects out of range without changing state");
    bool lowPitchRejected = false; try { ignore.setRegionPitch("ignore-second", -13, {"track"}, {}); } catch (...) { lowPitchRejected = true; }
    expect(lowPitchRejected && ignore.project().songs[0].parts[2].pitchSemitones == -12, "region pitch rejects values below one octave without changing state");
    Engine restoredPitch; restoredPitch.loadProject(ignore.project());
    expect(restoredPitch.project().songs[0].parts[1].pitchSemitones == 12 && restoredPitch.project().songs[0].parts[2].pitchSemitones == -12, "full-octave region tuner values survive loading the project");
    Project editable = p;
    editable.songs[0].tracks[0].clips.push_back({"clip", {}, "Clip", 2, 3, 0, {0.5}});
    Project trackOrderProject = editable;
    trackOrderProject.songs[0].parts = {{"track-order-region", "Song", 2, 5}};
    trackOrderProject.songs[0].tracks.push_back({"second-normal", "Keys", {"keys"}});
    Engine fixedTrackOrder; fixedTrackOrder.loadProject(trackOrderProject);
    fixedTrackOrder.addTrack("video-first", "Ignored", {"video"});
    fixedTrackOrder.addTrack("teleprompter", "Ignored", {"teleprompt"});
    fixedTrackOrder.addTrack("video-second", "Ignored", {"video"});
    fixedTrackOrder.addTrack("timecode", "Ignored", {"timecode"});
    auto trackIDs = [](const Engine& engine) { std::vector<ID> ids; for (const auto& track : engine.project().songs[0].tracks) ids.push_back(track.id); return ids; };
    const std::vector<ID> canonicalTrackIDs{"timecode", "teleprompter", "video-first", "video-second", "track", "second-normal"};
    expect(trackIDs(fixedTrackOrder) == canonicalTrackIDs, "special track creation always uses Timecode, Teleprompter, Video prefix");
    const auto timecodeItem = fixedTrackOrder.project().songs[0].tracks[0].clips[0];
    fixedTrackOrder.execute({CommandKind::play}); fixedTrackOrder.advance(0.5);
    fixedTrackOrder.reorderTrack("timecode", "track");
    expect(trackIDs(fixedTrackOrder) == canonicalTrackIDs, "dragging a special track cannot move it into normal tracks");
    fixedTrackOrder.reorderTrack("second-normal", "timecode");
    expect(trackIDs(fixedTrackOrder) == std::vector<ID>({"timecode", "teleprompter", "video-first", "video-second", "second-normal", "track"}), "normal drag before a special track stays below the special prefix");
    fixedTrackOrder.groupTracks({"track", "second-normal"});
    expect(fixedTrackOrder.project().songs[0].tracks[5].parentTrackID == "second-normal", "normal grouping remains contiguous below special tracks");
    auto oldTrackOrder = fixedTrackOrder.project();
    auto oldSpecial = std::move(oldTrackOrder.songs[0].tracks[0]);
    oldTrackOrder.songs[0].tracks.erase(oldTrackOrder.songs[0].tracks.begin());
    oldTrackOrder.songs[0].tracks.push_back(std::move(oldSpecial));
    fixedTrackOrder.applyProjectEdit(oldTrackOrder);
    expect(fixedTrackOrder.project().songs[0].tracks[0].id == "timecode", "project edits and undo normalize older special track order");
    expect(fixedTrackOrder.transport().playing && fixedTrackOrder.transport().position == 0.5, "ordering preserves live transport");
    const auto& orderedTimecodeItem = fixedTrackOrder.project().songs[0].tracks[0].clips[0];
    expect(orderedTimecodeItem.id == timecodeItem.id && orderedTimecodeItem.startTime == timecodeItem.startTime && orderedTimecodeItem.duration == timecodeItem.duration, "ordering preserves fixed timecode region items");
    Engine loadOldTrackOrder; loadOldTrackOrder.loadProject(oldTrackOrder);
    expect(trackIDs(loadOldTrackOrder) == trackIDs(fixedTrackOrder), "loading older track order normalizes without rejecting the document");
    validate(loadOldTrackOrder.project());
    Track importedVideo{"video-import", "Video", {"video"}};
    importedVideo.clips.push_back({"video-import-clip", {}, "Video", 6, 2});
    fixedTrackOrder.insertAudioTracks("one", {importedVideo});
    expect(trackIDs(fixedTrackOrder) == std::vector<ID>({"timecode", "teleprompter", "video-first", "video-second", "video-import", "second-normal", "track"}), "imported special tracks enter their canonical prefix slot");
    auto deletedSpecialOrder = fixedTrackOrder.project();
    deletedSpecialOrder.songs[0].tracks.erase(deletedSpecialOrder.songs[0].tracks.begin() + 1);
    fixedTrackOrder.applyProjectEdit(deletedSpecialOrder);
    expect(trackIDs(fixedTrackOrder)[1] == "video-first", "deleting a special track leaves no empty prefix slot");
    Engine textTracks; textTracks.loadProject(editable);
    textTracks.addTrack("chords-one", "Ignored", {"chords"});
    textTracks.addTrack("lyrics", "Ignored", {"teleprompt"});
    textTracks.addTrack("chords-two", "Ignored", {"chords"});
    textTracks.addTrack("text-video", "Ignored", {"video"});
    expect(trackIDs(textTracks) == std::vector<ID>({"chords-one", "chords-two", "lyrics", "text-video", "track"}), "Chords tracks precede teleprompter and video and allow multiple instances");
    AudioClip textItem{"text-item", {}, "Chords", 2, 10}; textItem.text = u8"C♯m / G♭ — Refrão 🎵";
    textTracks.addRecordedClip("chords-one", textItem);
    textTracks.execute({CommandKind::play}); textTracks.advance(0.5);
    textTracks.execute({CommandKind::subSeek, "", 4}); textTracks.execute({CommandKind::subPlay});
    std::string maximumEmoji; for (int n = 0; n < 30; ++n) maximumEmoji += u8"🎤";
    textTracks.setClipText("text-item", maximumEmoji);
    expect(textTracks.project().songs[0].tracks[0].clips[0].text == maximumEmoji, "Chords text permits 30 Unicode emoji rather than counting UTF-8 bytes");
    for (const auto& invalidText : {maximumEmoji + "A", std::string("\xc0\xaf"), std::string("\xed\xa0\x80"), std::string("\xf4\x90\x80\x80")}) {
        bool rejectedText = false; try { textTracks.setClipText("text-item", invalidText); } catch (...) { rejectedText = true; }
        expect(rejectedText && textTracks.project().songs[0].tracks[0].clips[0].text == maximumEmoji, "overlength or malformed Unicode text edits are atomic");
    }
    for (const auto* id : {"missing", "clip"}) {
        bool rejectedText = false; try { textTracks.setClipText(id, "invalid"); } catch (...) { rejectedText = true; }
        expect(rejectedText && textTracks.project().songs[0].tracks[0].clips[0].text == maximumEmoji, "text setter rejects unknown or audio items atomically");
    }
    bool crossedTextTrack = false; try { textTracks.moveClip("text-item", 3, "chords-two"); } catch (...) { crossedTextTrack = true; }
    expect(crossedTextTrack && textTracks.project().songs[0].tracks[0].clips[0].text == maximumEmoji && textTracks.project().songs[0].tracks[1].clips.empty(), "text item stays on its own Chords track even when destination kind matches");
    textTracks.moveClip("text-item", 3, "chords-one");
    bool crossedTextKind = false; try { textTracks.moveClip("text-item", 4, "lyrics"); } catch (...) { crossedTextKind = true; }
    expect(crossedTextKind && textTracks.project().songs[0].tracks[0].clips[0].startTime == 3, "text item cannot cross into a different special kind");
    bool textMediaRejected = false; Track textMedia{"chords-one", "Chords", {"chords"}}; textMedia.clips.push_back({"invalid-media", {}, "Audio", 0, 1});
    try { textTracks.insertAudioTracks("one", {textMedia}); } catch (...) { textMediaRejected = true; }
    expect(textMediaRejected && textTracks.project().songs[0].tracks[0].clips.size() == 1, "media import cannot populate a Chords text track");
    auto textAudio = textItem; textAudio.id = "text-audio"; textAudio.audioFile = AudioFile{"Steams/invalid.wav", {}};
    textMediaRejected = false; try { textTracks.addRecordedClip("lyrics", textAudio); } catch (...) { textMediaRejected = true; }
    expect(textMediaRejected && textTracks.project().songs[0].tracks[2].clips.empty(), "text insertion rejects audio metadata before committing");
    std::string lyricsMaximum; for (int n=0; n<400; ++n) lyricsMaximum += u8"🎵";
    AudioClip lyricsItem{"lyrics-item", {}, "Teleprompter",2,10}; lyricsItem.text=lyricsMaximum;
    textTracks.addRecordedClip("lyrics",lyricsItem);
    expect(textTracks.project().songs[0].tracks[2].clips[0].text==lyricsMaximum,"Teleprompter permits 400 Unicode characters");
    bool lyricsTooLong=false;
    try { textTracks.setClipText("lyrics-item",lyricsMaximum+"A"); } catch(...) { lyricsTooLong=true; }
    expect(lyricsTooLong && textTracks.project().songs[0].tracks[2].clips[0].text==lyricsMaximum,"Teleprompter rejects character 401 without changing existing text");
    for (const auto kind : {CommandKind::mute, CommandKind::solo, CommandKind::volume, CommandKind::pan}) {
        bool rejectedControl = false; try { textTracks.execute({kind, "chords-one", 0.5}); } catch (...) { rejectedControl = true; }
        expect(rejectedControl, "audio controls are unavailable on Chords tracks");
    }
    expect(textTracks.transport().playing && textTracks.transport().position == 0.5 && textTracks.transport().subPlay.playing && textTracks.transport().subPlay.position == 4, "text creation and edits preserve both live clocks");
    validate(textTracks.project());
    {
        auto repeatedText = textTracks.project();
        repeatedText.songs[0].duration = std::max(repeatedText.songs[0].duration, 26.0);
        auto& repeated = repeatedText.songs[0].tracks[2].clips[0];
        repeated.startTime = 0; repeated.duration = 26;
        repeated.loopStart = 0; repeated.loopLength = 10; repeated.sourceOffset = 8;
        Engine textRepeat; textRepeat.loadProject(repeatedText);
        expect(textRepeat.project().songs[0].tracks[2].clips[0].loopLength == 10 && textRepeat.project().songs[0].tracks[2].clips[0].sourceOffset == 8,
               "stretched lyrics retain visual repeat timing through core project load");
        repeated.audioFile = AudioFile{"Stems/not-text.wav", {}};
        bool rejected = false; try { validate(repeatedText); } catch (...) { rejected = true; }
        expect(rejected, "visual text repetition cannot permit audio media on text items");
    }
    for (const auto* role : {"teleprompt", "video", "chords"}) {
        auto singleLane = editable;
        auto& track = singleLane.songs[0].tracks[0];
        track.role = {role}; track.name = fixedTrackName(track.role);
        track.clips = {{"lane-first", {}, "First", 1, 2}, {"lane-second", {}, "Second", 5, 2}};
        if (std::string(role) != "video") for (auto& item : track.clips) item.text = "Text";
        singleLane.songs[0].tracks.push_back({"same-kind-destination", track.name, {role}});
        Engine lane; lane.loadProject(singleLane); lane.execute({CommandKind::play}); lane.advance(0.25);
        lane.execute({CommandKind::subSeek, "", 8}); lane.execute({CommandKind::subPlay});
        bool overlapRejected = false; try { lane.moveClip("lane-second", 2); } catch (...) { overlapRejected = true; }
        expect(overlapRejected && lane.project().songs[0].tracks[0].clips[1].startTime == 5, "single-lane special move rejects overlap atomically");
        bool rowRejected = false; try { lane.moveClip("lane-first", 1, "same-kind-destination"); } catch (...) { rowRejected = true; }
        expect(rowRejected && lane.project().songs[0].tracks[1].clips.empty(), "special items cannot leave their original track");
        auto overlap = lane.project().songs[0].tracks[0].clips[0]; overlap.id = "overlap-new"; overlap.startTime = 2;
        bool addRejected = false; try { lane.addRecordedClip("track", overlap); } catch (...) { addRejected = true; }
        expect(addRejected && lane.project().songs[0].tracks[0].clips.size() == 2, "special add rejects overlapping items before commit");
        lane.moveClip("lane-second", 3);
        expect(lane.project().songs[0].tracks[0].clips.back().startTime == 3, "adjacent single-lane special items remain valid");
        expect(lane.transport().playing && lane.transport().position == 0.25 && lane.transport().subPlay.playing && lane.transport().subPlay.position == 8, "special item edits preserve both live clocks");
        validate(lane.project());
    }
    fixedTrackOrder.applyProjectEdit(oldTrackOrder);
    expect(trackIDs(fixedTrackOrder) == trackIDs(loadOldTrackOrder), "undo restores the canonical special prefix and normal groups");
    Engine timecodeSpan; timecodeSpan.loadProject(oldTrackOrder);
    auto trimmedTimecode = timecodeSpan.project();
    trimmedTimecode.songs[0].timeSettings = relativeTime;
    auto& trimmedTimecodeClip = trimmedTimecode.songs[0].tracks[0].clips[0];
    const auto timecodeClipID = trimmedTimecodeClip.id;
    trimmedTimecodeClip.timecodeStartOffset = -1; trimmedTimecodeClip.timecodeEndOffset = 8; trimmedTimecodeClip.sourceOffset = 3;
    timecodeSpan.applyProjectEdit(trimmedTimecode);
    expect(timecodeSpan.project().songs[0].tracks[0].clips[0].startTime == 1 && timecodeSpan.project().songs[0].tracks[0].clips[0].duration == 12 && timecodeSpan.project().songs[0].duration == 13, "Timecode can extend both sides without source repetition and grows the timeline");
    timecodeSpan.moveRegion("track-order-region", 20);
    expect(timecodeSpan.project().songs[0].tracks[0].clips[0].startTime == 19 && timecodeSpan.project().songs[0].tracks[0].clips[0].duration == 12, "Timecode span overrides follow their owning region on move");
    timecodeSpan.resizeRegion("track-order-region", 20, 25);
    expect(timecodeSpan.project().songs[0].tracks[0].clips[0].duration == 14 && timecodeSpan.project().songs[0].duration == 33, "region edge edits keep the relative Timecode span attached");
    timecodeSpan.execute({CommandKind::tempo, "", 240});
    auto scaledTimecode = timecodeSpan.project(); timecodeSpan.applyProjectEdit(scaledTimecode);
    const auto& scaledTimecodeClip = timecodeSpan.project().songs[0].tracks[0].clips[0];
    expect(scaledTimecodeClip.startTime == 9.5 && scaledTimecodeClip.duration == 7 && scaledTimecodeClip.timecodeStartOffset == -0.5 && scaledTimecodeClip.timecodeEndOffset == 4, "Timecode span offsets scale with BPM and survive subsequent edits");
    expect(scaledTimecodeClip.sourceOffset == 3 && !scaledTimecodeClip.loopStart && !scaledTimecodeClip.loopLength, "Timecode edge edits never loop or alter the source offset");
    bool timecodeRegionRejected = false;
    try { timecodeSpan.regionsFromClips({{"clip", "normal-from-item"}, {timecodeClipID, "tc-from-item"}}); } catch (...) { timecodeRegionRejected = true; }
    expect(timecodeRegionRejected && timecodeSpan.project().songs[0].parts.size() == 1, "derived Timecode items cannot create regions even in an atomic mixed batch");
    bool timecodeMoveRejected = false; try { timecodeSpan.moveClip(timecodeClipID, 100); } catch (...) { timecodeMoveRejected = true; }
    expect(timecodeMoveRejected && timecodeSpan.project().songs[0].tracks[0].clips[0].startTime == 9.5, "Timecode item cannot move independently of its region");
    auto loopedTimecode = timecodeSpan.project(); loopedTimecode.songs[0].tracks[0].clips[0].loopLength = 3;
    bool timecodeLoopRejected = false; try { timecodeSpan.applyProjectEdit(loopedTimecode); } catch (...) { timecodeLoopRejected = true; }
    expect(timecodeLoopRejected && !timecodeSpan.project().songs[0].tracks[0].clips[0].loopLength, "Timecode never repeats its source through clip loop fields");
    Project mediaMoveProject = editable;
    mediaMoveProject.songs[0].tracks[0].clips[0].audioFile = AudioFile{"Steams/audio.wav", {}};
    Track videoMoveTrack{"video-move", "Video", {"video"}};
    videoMoveTrack.clips.push_back({"video-move-item", {}, "Movie", 2, 3});
    videoMoveTrack.clips[0].audioFile = AudioFile{"Videos/movie.mov", {}};
    mediaMoveProject.songs[0].tracks.push_back(videoMoveTrack);
    mediaMoveProject.songs[0].tracks.push_back({"audio-move", "Audio", {"other"}});
    Engine mediaMoves; mediaMoves.loadProject(mediaMoveProject);
    mediaMoves.moveClip("video-move-item", 4, "audio-move");
    const auto& mediaDestination = mediaMoves.project().songs[0].tracks.back();
    expect(mediaDestination.id == "audio-move" && mediaDestination.clips[0].id == "video-move-item" && mediaDestination.clips[0].startTime == 4, "video can move into a standard audio track");
    bool audioToLegacyVideoRejected = false;
    try { mediaMoves.moveClip("clip", 4, "video-move"); } catch (...) { audioToLegacyVideoRejected = true; }
    expect(audioToLegacyVideoRejected, "ordinary audio cannot move into the legacy special Video track");
    Project crossMediaProject = mediaMoveProject;
    crossMediaProject.songs[0].tracks.push_back({"teleprompter-move", "Teleprompter", {"teleprompt"}});
    Engine crossMedia; crossMedia.loadProject(crossMediaProject);
    crossMedia.moveClip("video-move-item", 6, "teleprompter-move");
    const auto& teleprompterAfterMove = crossMedia.project().songs[0].tracks.front();
    expect(teleprompterAfterMove.id == "teleprompter-move" && teleprompterAfterMove.clips.size() == 1 && teleprompterAfterMove.clips[0].startTime == 6,
           "a video item moves from Video to Teleprompter");
    crossMedia.moveClip("video-move-item", 8, "video-move");
    expect(crossMedia.project().songs[0].tracks[1].clips.size() == 1 && crossMedia.project().songs[0].tracks[1].clips[0].startTime == 8,
           "a Teleprompter video item moves back to Video");
    auto mislabeledVideo = editable; mislabeledVideo.songs[0].tracks[0].clips[0].audioFile = AudioFile{"Videos/movie.wav", {}};
    mislabeledVideo.songs[0].tracks.push_back({"audio-move", "Audio", {"other"}});
    mediaMoves.execute({CommandKind::stopAll});
    mediaMoves.loadProject(mislabeledVideo);
    expect(mediaMoves.project().songs[0].tracks[0].clips[0].audioFile->path == "Videos/movie.wav", "managed movie soundtracks are permitted on standard tracks");
    Project capacityProject = editable;
    capacityProject.songs[0].tracks.clear();
    for (int index = 0; index < 1000; ++index) capacityProject.songs[0].tracks.push_back({"capacity-" + std::to_string(index), "Track", {"other"}});
    validate(capacityProject);
    Engine trackCapacity; trackCapacity.loadProject(capacityProject);
    trackCapacity.addTrack("extra-created", "Extra", {"other"});
    expect(trackCapacity.project().songs[0].tracks.size() == 1001, "creation supports more than 1000 tracks");
    Track capacityImport{"extra-imported", "Extra", {"other"}};
    capacityImport.clips.push_back({"capacity-clip", {}, "Audio", 0, 1});
    trackCapacity.insertAudioTracks("one", {capacityImport});
    expect(trackCapacity.project().songs[0].tracks.size() == 1002, "audio import supports more than 1000 tracks");
    capacityProject.songs[1].tracks.push_back({"extra-capacity", "Extra", {"other"}});
    validate(capacityProject);
    Project itemFXProject = editable;
    itemFXProject.songs[0].tracks[0].clips[0].gain = 0.5;
    itemFXProject.songs[0].tracks[0].clips[0].sourceOffset = 1;
    itemFXProject.songs[0].tracks[0].clips[0].loopStart = 0;
    itemFXProject.songs[0].tracks[0].clips[0].loopLength = 2;
    Engine itemEffects; itemEffects.loadProject(itemFXProject);
    itemEffects.execute({CommandKind::play}); itemEffects.advance(0.5);
    itemEffects.execute({CommandKind::subSeek, "", 4}); itemEffects.execute({CommandKind::subPlay});
    const std::string itemFXJSON = R"({"inserted":["EQ","Delay"],"eqEnabled":true,"delayMix":25})";
    itemEffects.setClipFX("clip", itemFXJSON);
    const auto& itemWithFX = itemEffects.project().songs[0].tracks[0].clips[0];
    expect(itemWithFX.fxJSON == itemFXJSON && !itemEffects.project().songs[0].tracks[0].fxJSON, "item effects remain independent of track effects");
    expect(itemWithFX.gain == 0.5 && itemWithFX.sourceOffset == 1 && itemWithFX.loopLength == 2 && itemWithFX.waveform == std::vector<double>{0.5}, "item effect editing preserves audio metadata");
    expect(itemEffects.transport().playing && itemEffects.transport().position == 0.5 && itemEffects.transport().subPlay.playing && itemEffects.transport().subPlay.position == 4, "item FX preserves both live clocks");
    expect(!itemWithFX.fxBypassed, "item FX bypass starts optional and inactive");
    for (bool bypassed : {true, false, true}) {
        itemEffects.setClipFXBypass("clip", bypassed);
        expect(itemWithFX.fxBypassed == bypassed && itemWithFX.fxJSON == itemFXJSON, "global bypass preserves all individual effect settings and enable flags");
        expect(itemWithFX.gain == 0.5 && itemWithFX.sourceOffset == 1 && itemWithFX.loopLength == 2 && itemWithFX.waveform == std::vector<double>{0.5}, "global bypass preserves audio metadata");
        expect(itemEffects.transport().playing && itemEffects.transport().position == 0.5 && itemEffects.transport().subPlay.playing && itemEffects.transport().subPlay.position == 4, "global bypass preserves both playback heads");
    }
    bool missingItemBypass = false; try { itemEffects.setClipFXBypass("missing", false); } catch (...) { missingItemBypass = true; }
    expect(missingItemBypass && itemWithFX.fxBypassed == true && itemWithFX.fxJSON == itemFXJSON, "unknown global bypass target is atomic");
    Engine specialBypass; specialBypass.loadProject(timecodeSpan.project());
    bool specialItemBypass = false; try { specialBypass.setClipFXBypass(timecodeClipID, true); } catch (...) { specialItemBypass = true; }
    expect(specialItemBypass && !specialBypass.project().songs[0].tracks[0].clips[0].fxBypassed, "special item cannot receive global FX bypass");
    for (bool bypassed : {false, true}) {
        auto invalidSpecialBypass = timecodeSpan.project(); invalidSpecialBypass.songs[0].tracks[0].clips[0].fxBypassed = bypassed;
        bool invalidBypassLoad = false; try { validate(invalidSpecialBypass); } catch (...) { invalidBypassLoad = true; }
        expect(invalidBypassLoad, "special clip bypass flags are rejected on load, including explicit false");
    }
    for (const auto* badFX : {R"({"inserted":["Instruments"]})", R"({"inserted":["Unknown"]})", R"({"inserted":["EQ","EQ"]})", R"({"inserted":[],"instrumentID":"Piano"})", R"({"inserted":[],"instrumentBypassed":true})", "[]", "{"}) {
        bool rejected = false; try { itemEffects.setClipFX("clip", badFX); } catch (...) { rejected = true; }
        expect(rejected && itemEffects.project().songs[0].tracks[0].clips[0].fxJSON == itemFXJSON, "invalid item FX is atomic");
    }
    bool missingItemFX = false; try { itemEffects.setClipFX("missing", itemFXJSON); } catch (...) { missingItemFX = true; }
    expect(missingItemFX && itemEffects.project().songs[0].tracks[0].clips[0].fxJSON == itemFXJSON, "unknown item FX target is atomic");
    validate(itemEffects.project());
    auto invalidItemFX = itemEffects.project(); invalidItemFX.songs[0].tracks[0].clips[0].fxJSON = R"({"inserted":["Instruments"]})";
    bool invalidItemFXLoad = false; try { validate(invalidItemFX); } catch (...) { invalidItemFXLoad = true; }
    expect(invalidItemFXLoad, "project load rejects item instruments");
    Project batchProject = editable;
    batchProject.songs[0].tracks[0].clips[0].name = "Song.One.MP3";
    batchProject.songs[0].tracks[0].clips.push_back({"later-clip", {}, "Second.wav", 6, 3});
    Engine batch; batch.loadProject(batchProject);
    batch.regionsFromClips({{"clip", "first-region"}, {"later-clip", "second-region"}});
    expect(batch.project().songs[0].parts.size() == 2 && batch.project().songs[0].parts[0].name == "Song.One" && batch.project().songs[0].parts[1].name == "Second", "batch region creation strips only audio extensions and preserves horizontal items");
    bool invalidBatch = false;
    try { batch.regionsFromClips({{"clip", "duplicate"}, {"missing", "invalid"}}); } catch (...) { invalidBatch = true; }
    expect(invalidBatch && batch.project().songs[0].parts.size() == 2, "invalid region batch is atomic");
    Engine editor; editor.loadProject(editable);
    editor.regionFromClip("clip", "region");
    expect(editor.project().songs[0].parts[0].startTime == 2 && editor.project().songs[0].parts[0].endTime == 5, "region matches selected clip boundaries");
    expect(editor.project().songs[0].parts[0].color.has_value(), "new region stores its generated color");
    editor.editRegion("region", "Edited region", 0x12ABEF);
    expect(editor.project().songs[0].parts[0].name == "Edited region" && editor.project().songs[0].parts[0].color == 0x12ABEF, "region name and RGB color are editable");
    editor.regionFromClip("clip", "region-again");
    expect(editor.project().songs[0].parts.size() == 1, "reselecting does not duplicate a region");
    editor.resizeRegion("region",2,4);
    editor.regionFromClip("clip","same-start-different-end");
    expect(editor.currentSong()->parts.size()==1 && editor.currentSong()->parts[0].endTime==4,"same region start is blocked even when the end differs");
    editor.resizeRegion("region",2,5);

    editor.execute({CommandKind::play}); editor.advance(1);
    editor.setMarker("manual-delete", "Manual", 2, 0x00ff88);
    bool duplicateMarker=false;
    try { editor.setMarker("manual-duplicate","Duplicate",2,0x00ff88); } catch(...) { duplicateMarker=true; }
    expect(duplicateMarker && editor.currentSong()->markers->size()==1,"duplicate marker creation is rejected atomically");

    const auto* unchangedTracks = editor.project().songs[0].tracks.data();
    editor.deleteManualMarker("manual-delete");
    expect(editor.project().songs[0].markers->empty() && editor.transport().playing && editor.transport().position == 1, "manual marker deletion preserves running transport");
    expect(editor.project().songs[0].tracks.data() == unchangedTracks, "manual marker deletion never copies or rebuilds tracks and waveforms");
    bool missingMarkerRejected = false;
    try { editor.deleteManualMarker("manual-delete"); } catch (...) { missingMarkerRejected = true; }
    expect(missingMarkerRejected, "unknown marker cannot be deleted");

    editor.moveClip("clip", 600);
    expect(editor.project().songs[0].duration == 603 && editor.project().songs[0].tracks[0].clips[0].startTime == 600, "clip may move past old song end");
    expect(editor.transport().playing && editor.transport().position == 1, "clip editing preserves transport");
    bool invalidMove = false; try { editor.moveClip("clip", -1); } catch (...) { invalidMove = true; }
    expect(invalidMove && editor.project().songs[0].tracks[0].clips[0].startTime == 600, "invalid move is atomic");
    Project stacked = editable;
    stacked.songs[0].tracks[0].clips.push_back({"clip2", {}, "Second", 2, 3});
    stacked.songs[0].tracks[0].clips.push_back({"clip3", {}, "Third", 2, 3});
    stacked.songs[0].tracks[0].clips.push_back({"clip4", {}, "Fourth", 5, 3});
    validate(stacked);
    Engine editingState; editingState.loadProject(stacked);
    editingState.execute({CommandKind::play}); editingState.advance(1);
    auto editedProject = stacked; editedProject.songs[0].tracks[0].clips.clear();
    editingState.applyProjectEdit(editedProject);
    expect(editingState.transport().playing && editingState.transport().position == 1, "deleting items preserves playback clock");
    editingState.applyProjectEdit(stacked);
    expect(editingState.project().songs[0].tracks[0].clips.size() == 4 && editingState.transport().position == 1, "undo restores items without relocating the transport");
    editedProject.id = "wrong-project";
    bool wrongEdit = false; try { editingState.applyProjectEdit(editedProject); } catch (...) { wrongEdit = true; }
    expect(wrongEdit && editingState.project().songs[0].tracks[0].clips.size() == 4, "invalid undo is atomic");
    Engine stacking; stacking.loadProject(stacked);
    bool fourthRejected = false; try { stacking.moveClip("clip4", 3); } catch (...) { fourthRejected = true; }
    expect(!fourthRejected && stacking.project().songs[0].tracks[0].clips[3].startTime == 3, "fourth simultaneous item is supported");
    Project transfer = stacked;
    transfer.songs[0].tracks.push_back({"destination", "Destination", {"keys"}});
    Engine crossing; crossing.loadProject(transfer);
    crossing.moveClip("clip4", 2, "destination");
    expect(crossing.project().songs[0].tracks[0].clips.size() == 3 && crossing.project().songs[0].tracks[1].clips[0].id == "clip4", "vertical move transfers item without duplicating");
    bool fullTrack = false;
    try { crossing.moveClip("clip4", 2, "track"); } catch (...) { fullTrack = true; }
    expect(!fullTrack && crossing.project().songs[0].tracks[1].clips.empty(), "vertical move permits additional overlapping items");
    crossing.moveClip("clip4", 5, "track");
    expect(crossing.project().songs[0].tracks[1].clips.empty(), "item can move back at a free time");
    Engine importing; importing.loadProject(stacked);
    importing.execute({CommandKind::play}); importing.advance(0.5);
    Track addition{"track", "Must not replace track settings", {"other"}};
    addition.volume = 0.1;
    addition.clips.push_back({"imported", {}, "Imported", 20, 4});
    Track newTrack{"new-track", "New", {"keys"}};
    newTrack.clips.push_back({"new-clip", {}, "New clip", 20, 5});
    importing.insertAudioTracks("one", {addition, newTrack});
    expect(importing.project().songs[0].tracks[0].name == stacked.songs[0].tracks[0].name && importing.project().songs[0].tracks[0].volume == stacked.songs[0].tracks[0].volume, "audio drop preserves destination track settings");
    expect(importing.project().songs[0].duration == 25 && importing.project().songs[0].tracks.size() == 2, "audio drop extends timeline and inserts new tracks");
    expect(importing.transport().playing && importing.transport().position == 0.5, "audio drop preserves running transport");
    addition.clips[0].id = "invalid-overlap"; addition.clips[0].startTime = -2;
    newTrack.id = "should-not-be-inserted"; newTrack.clips[0].id = "rollback-clip";
    bool importRejected = false;
    try { importing.insertAudioTracks("one", {newTrack, addition}); } catch (...) { importRejected = true; }
    expect(importRejected && importing.project().songs[0].tracks.size() == 2 && importing.project().songs[0].tracks[0].clips.size() == 5, "invalid batch rolls back all dropped items and tracks");
    Engine group; group.loadProject(editable); group.regionFromClip("clip", "group-region");
    group.moveRegion("group-region", 40);
    expect(group.project().songs[0].parts[0].startTime == 40 && group.project().songs[0].parts[0].endTime == 43, "region move preserves duration");
    expect(group.project().songs[0].tracks[0].clips[0].startTime == 40 && group.project().songs[0].duration == 43, "contained items move with region beyond previous end");
    group.moveRegion("group-region", 0);
    expect(group.project().songs[0].tracks[0].clips[0].startTime == 0, "region and item can return to timeline start");
    bool invalidRegionMove = false; try { group.moveRegion("group-region", -1); } catch (...) { invalidRegionMove = true; }
    expect(invalidRegionMove && group.project().songs[0].parts[0].startTime == 0, "invalid region move changes nothing");
    // Moving a region moves every contained media type and its tempo/cue flags.
    Project cargo; cargo.id="cargo-project"; cargo.name="Region contents";
    Song cargoSong; cargoSong.id="cargo-song"; cargoSong.name="Song"; cargoSong.duration=100;
    cargoSong.parts={{"cargo-root","Root",10,20},{"cargo-child","Child",12,18},{"cargo-next","Next",20,30}};
    cargoSong.parts[1].parentRegionID="cargo-root";
    for (const std::string role : {"other","video","teleprompt","teleprompt2","chords","timecode"}) {
        Track track; track.id="cargo-track-"+role; track.role={role};
        track.name=role=="other" ? "Audio" : fixedTrackName(track.role);
        AudioClip clip; clip.id="cargo-item-"+role; clip.name="Inside"; clip.startTime=12; clip.duration=4;
        if (isTeleprompterRole(track.role) || role=="chords") clip.text="Text";
        if (role=="video") { clip.audioFile=AudioFile{"Videos/source.mov"}; clip.sourceOffset=1; }
        if (role=="other") { clip.audioFile=AudioFile{"Stems/source.wav"}; clip.sourceOffset=2; clip.gain=0.5; }
        if (role=="timecode") { track.importedTimecodeItems=true; clip.timecode=TimecodeSettings{}; clip.timecode->offset=3600; }
        track.clips={clip}; cargoSong.tracks.push_back(track);
    }
    TimelineMarker cargoTempo{"cargo-tempo","Tempo",13,0}; cargoTempo.tempoBPM=140; cargoTempo.tempoTimebase="relative";
    cargoSong.markers=std::vector<TimelineMarker>{{"cargo-start","Start",10,0},cargoTempo,{"cargo-cue","Cue",16,0},{"cargo-owned","Child",12,0,"cargo-root"},{"cargo-edge","Next",20,0},{"cargo-outside","Outside",5,0}};
    cargo.songs={cargoSong}; Engine cargoEngine; cargoEngine.loadProject(cargo);
    cargoEngine.moveRegion("cargo-root",40);
    const auto& movedCargo=cargoEngine.project().songs[0];
    expect(movedCargo.parts[0].startTime==40 && movedCargo.parts[1].startTime==42 && movedCargo.parts[2].startTime==20,"root and child move once while neighboring region stays");
    const std::vector<double> cargoPositions{40,43,46,42,20,5};
    for(size_t index=0;index<cargoPositions.size();++index) expect(movedCargo.markers->at(index).position==cargoPositions[index],"tempo and ordinary markers follow region, end boundary stays with next region");
    expect(movedCargo.markers->at(1).tempoBPM==140 && movedCargo.markers->at(1).tempoTimebase=="relative","moving tempo flag preserves BPM/timebase and does not stretch items");
    for(const auto& track:movedCargo.tracks) {
        expect(track.clips[0].startTime==42 && track.clips[0].duration==4,"all contained track kinds move with the same displacement");
        if(track.role.id=="timecode") expect(track.clips[0].timecode->offset==3600,"regenerated imported timecode retains its clock configuration");
        if(track.role.id=="other") expect(track.clips[0].sourceOffset==2 && track.clips[0].gain==0.5,"audio source trim and gain remain unchanged");
    }
    cargoEngine.moveRegion("cargo-root",10);
    for(const auto& track:cargoEngine.project().songs[0].tracks) expect(track.clips[0].startTime==12,"return movement restores relative media positions");
    cargo.songs[0].markers->push_back({"cargo-obstacle","Obstacle",43,0});
    cargoEngine.loadProject(cargo); cargoEngine.moveRegion("cargo-root",40);
    const auto& repelled=cargoEngine.project().songs[0];
    expect(std::abs(repelled.parts[0].startTime-40.01)<1e-8,"marker collision repels the whole region to nearest free side");
    expect(std::abs(repelled.markers->at(1).position-43.01)<1e-8 && repelled.markers->back().position==43,"tempo marker is separated from stationary normal marker");
    for(const auto& track:repelled.tracks) expect(std::abs(track.clips[0].startTime-42.01)<1e-8,"repulsion preserves offsets of every media item");
    cargoEngine.loadProject(cargo); cargoEngine.moveRegion("cargo-root",39.999);
    expect(std::abs(cargoEngine.project().songs[0].parts[0].startTime-39.99)<1e-8,"repulsion can choose the left side without moving stationary marker");
    // Passing over material never transfers membership, even after save/reload.
    Project attachment; attachment.id="attachment-project"; attachment.name="Attachments";
    Song attachmentSong; attachmentSong.id="attachment-song"; attachmentSong.name="Show"; attachmentSong.duration=100;
    attachmentSong.parts={{"attachment-a","A",10,20},{"attachment-b","B",40,60}};
    Track attachmentTrack{"attachment-track","Audio",{"other"}};
    attachmentTrack.clips={{"attachment-own",{},"Own",12,2},{"attachment-other",{},"Other",45,2},{"attachment-free",{},"Free",75,2}};
    attachmentSong.tracks={attachmentTrack};
    attachmentSong.markers=std::vector<TimelineMarker>{{"attachment-cue","Own cue",14,0},{"attachment-foreign","Foreign",47,0},{"attachment-loose","Loose",78,0}};
    attachment.songs={attachmentSong}; Engine attachments; attachments.loadProject(attachment);
    attachments.moveRegion("attachment-a",40);
    Project persistedAttachments = attachments.project();
    attachments.loadProject(persistedAttachments); // Ownership, including nil for loose material, survives reload.
    attachments.moveRegion("attachment-a",10);
    const auto& restoredAttachments=attachments.project().songs[0];
    expect(restoredAttachments.tracks[0].clips[0].startTime==12 && restoredAttachments.tracks[0].clips[1].startTime==45,"leaving another region never steals its audio");
    expect(restoredAttachments.markers->at(0).position==14 && restoredAttachments.markers->at(1).position==47,"leaving another region never steals its markers");
    attachments.moveRegion("attachment-a",70); attachments.moveRegion("attachment-a",10);
    expect(attachments.project().songs[0].tracks[0].clips[2].startTime==75 && attachments.project().songs[0].markers->at(2).position==78,"passing over loose items and markers leaves them stationary");
    attachments.moveClip("attachment-free",15,""); // An explicit item placement attaches it.
    attachments.setMarker("attachment-loose","Placed cue",18,0);
    attachments.moveRegion("attachment-a",70);
    expect(attachments.project().songs[0].tracks[0].clips.back().startTime==75,"an explicitly placed item travels with its assigned region");
    expect(attachments.project().songs[0].markers->back().position==78,"an explicitly placed marker travels with its assigned region");
    attachments.moveClip("attachment-free",95,"");
    attachments.moveRegion("attachment-a",10);
    expect(attachments.project().songs[0].tracks[0].clips.back().startTime==95,"explicitly moving an item outside detaches it");
    attachments.execute({CommandKind::toggleMultiLoopBypass});
    attachments.loadProject(attachments.project());
    expect(attachments.transport().multiLoopsBypassed,"global bypass survives a native project reload");
    attachments.execute({CommandKind::toggleMultiLoopBypass});
    attachments.loadProject(attachments.project());
    expect(!attachments.transport().multiLoopsBypassed,"global bypass also preserves its disabled state");
    Engine sizing; sizing.loadProject(editable); sizing.regionFromClip("clip", "resize");
    sizing.resizeRegion("resize", 1, 50);
    expect(sizing.project().songs[0].parts[0].startTime == 1 && sizing.project().songs[0].parts[0].endTime == 50, "both region boundaries resize");
    expect(sizing.project().songs[0].tracks[0].clips[0].startTime == 2 && sizing.project().songs[0].tracks[0].clips[0].duration == 3, "region resize leaves audio items untouched");
    sizing.resizeRegion("resize", 2, 4);
    bool badResize = false; try { sizing.resizeRegion("resize", 4, 4); } catch (...) { badResize = true; }
    expect(badResize && sizing.project().songs[0].parts[0].startTime == 2, "invalid resize is atomic");
    Project nested = editable;
    nested.songs[0].parts = {{"outer", "Outer", 0, 8}, {"inner", "Inner", 2, 4}};
    validate(nested);
    Engine nesting; nesting.loadProject(nested);
    nesting.resizeRegion("inner", 3, 7);
    nested.songs[0].parts.push_back({"third", "Third", 3, 5});
    bool thirdRegion = false; try { validate(nested); } catch (...) { thirdRegion = true; }
    expect(thirdRegion, "only two simultaneous region lanes allowed");
    Project regionShow = editable;
    regionShow.songs[0].parts = {{"r1", "First", 2, 5}, {"r2", "Second", 7, 9}};
    RegionSetlist regionLists;
    regionLists.playlists = {{"playlist", "My playlist", "one", {"r1", "r2"}}};
    regionLists.selectedId = "playlist"; regionLists.autoAdvance = true;
    regionLists.blocks = std::vector<SetlistBlock>{{"block1", "one", "playlist", "Bloco 01", 0x45c68b, "r2"}};
    regionShow.regionSetlist = regionLists;
    expect(!regionLists.prepareWithoutPlayback.value_or(false), "prepare without playback is off by default");
    for (bool automaticQueue : {false, true}) {
        auto clickProject = regionShow; clickProject.regionSetlist->autoAdvance = automaticQueue;
        Engine clicks; clicks.loadProject(clickProject);
        clicks.execute({CommandKind::selectRegion, "r1"}); clicks.execute({CommandKind::play});
        if (!automaticQueue) clicks.execute({CommandKind::queueRegion, "r2"});
        clicks.execute({CommandKind::loopStart, "", 2}); clicks.execute({CommandKind::loopEnd, "", 5}); clicks.execute({CommandKind::toggleLoop});
        clicks.advance(0.25);
        const auto before = clicks.transport();
        clicks.execute({CommandKind::queueRegion, "r1"});
        expect(clicks.transport().queuedRegionId == "r2" && clicks.transport().queueStartedAt == before.queueStartedAt &&
               clicks.transport().position == before.position && clicks.transport().subPlay.position == before.subPlay.position,
               "clicking the playing region preserves the manual/automatic queue, countdown and both cursors");
        expect(clicks.project().regionSetlist->autoAdvance == automaticQueue, "playing region click preserves Auto");
        clicks.execute({CommandKind::queueRegion, "r2"});
        expect(!clicks.transport().queuedRegionId && !clicks.project().regionSetlist->autoAdvance,
               "clicking the queued region removes it and disables Auto");
        expect(clicks.transport().playing && clicks.transport().position == before.position && clicks.transport().regionId == "r1" &&
               clicks.transport().loop.enabled && clicks.transport().loop.start == 2 && clicks.transport().loop.end == 5,
               "queue cancellation preserves playback and Repeat, unlike Escape");
        clicks.advance(0.25);
        expect(!clicks.transport().queuedRegionId, "a cancelled automatic queue stays cancelled on the next transport tick");
        clicks.execute({CommandKind::queueRegion, "r2"});
        expect(clicks.transport().queuedRegionId == "r2" && !clicks.project().regionSetlist->autoAdvance,
               "the cancelled song can be queued again manually without enabling Auto");
    }
    for (bool automaticQueue : {false, true}) {
        auto crossProject = regionShow; crossProject.regionSetlist->autoAdvance = automaticQueue;
        crossProject.regionSetlist->automaticSubplay = true; crossProject.regionSetlist->automaticSubplaySeconds = 1;
        Engine cross; cross.loadProject(crossProject); cross.execute({CommandKind::selectRegion, "r1"}); cross.execute({CommandKind::play});
        if (!automaticQueue) cross.execute({CommandKind::queueRegion, "r2"});
        cross.advance(1.5); expect(!cross.transport().subPlay.playing, "automatic subplay waits for its lead time");
        cross.advance(0.75); expect(cross.transport().subPlay.playing && cross.transport().subPlay.position == 7.25, "automatic subplay accounts only for elapsed after the trigger");
        cross.advance(0.75); expect(cross.transport().regionId == "r2" && cross.transport().position == 8 && cross.transport().subPlayPromotion == 1, "manual and automatic queues promote without restarting audio");
    }
    auto ignoredCrossProject = ignoreProject; ignoredCrossProject.regionSetlist = RegionSetlist{};
    ignoredCrossProject.regionSetlist->automaticSubplay = true; ignoredCrossProject.regionSetlist->automaticSubplaySeconds = 2;
    Engine ignoredCross; ignoredCross.loadProject(ignoredCrossProject);
    ignoredCross.execute({CommandKind::selectRegion, "ignore-first"}); ignoredCross.execute({CommandKind::play});
    ignoredCross.execute({CommandKind::queueRegion, "ignore-queue"}); ignoredCross.execute({CommandKind::ignoreNext});
    ignoredCross.advance(22); expect(!ignoredCross.transport().subPlay.playing, "Ignore Next lead time uses the real current audio end");
    ignoredCross.advance(2); expect(ignoredCross.transport().subPlay.playing && ignoredCross.transport().subPlay.position == 81, "Ignore Next starts queue before its shortened boundary");
    ignoredCross.advance(1); expect(ignoredCross.transport().position == 82 && ignoredCross.transport().subPlayPromotion == 1, "Ignore Next preserves the automatic subplay handoff");
    auto readyProject = regionShow; readyProject.regionSetlist->prepareWithoutPlayback = true; readyProject.regionSetlist->automaticSubplay = true;
    Engine ready; ready.loadProject(readyProject);
    ready.execute({CommandKind::selectRegion, "r1"}); ready.execute({CommandKind::play});
    ready.advance(3.5);
    expect(!ready.transport().playing && !ready.transport().paused && ready.transport().position == 7 && ready.transport().editPosition == 7 && ready.transport().regionId == "r2" && !ready.transport().queuedRegionId, "prepare mode selects queued start without playing or overshoot");
    ready.execute({CommandKind::play});
    expect(ready.transport().playing && ready.transport().position == 7, "prepared queue is ready for the next Play");
    ready.execute({CommandKind::stop}); ready.execute({CommandKind::selectRegion, "r1"}); ready.execute({CommandKind::play});
    ready.advance(0.5); ready.execute({CommandKind::subPlay}); ready.advance(0.1); ready.execute({CommandKind::stop});
    expect(ready.transport().playing && ready.transport().regionId == "r2" && ready.transport().subPlayPromotion == 1, "prepare mode preserves active Sub Play promotion on Stop");
    Engine earlyStop; earlyStop.loadProject(regionShow);
    earlyStop.execute({CommandKind::selectRegion, "r1"}); earlyStop.execute({CommandKind::play}); earlyStop.advance(0.5); earlyStop.execute({CommandKind::stop});
    expect(!earlyStop.transport().playing && earlyStop.transport().position == 7 && earlyStop.transport().editPosition == 7 && earlyStop.transport().regionId == "r2" && !earlyStop.transport().queuedRegionId, "Stop prepares queued song even with prepare mode off");
    auto manualReady = readyProject; manualReady.regionSetlist->autoAdvance = false;
    Engine manualPrepare; manualPrepare.loadProject(manualReady);
    manualPrepare.execute({CommandKind::selectRegion, "r1"}); manualPrepare.execute({CommandKind::play}); manualPrepare.execute({CommandKind::queueRegion, "r2"}); manualPrepare.advance(3);
    expect(!manualPrepare.transport().playing && manualPrepare.transport().regionId == "r2", "prepare mode also supports manually queued songs");
    Engine regionPlayback; regionPlayback.loadProject(regionShow);
    regionPlayback.execute({CommandKind::selectRegion, "r1"});
    regionPlayback.execute({CommandKind::play});
    expect(regionPlayback.transport().queuedRegionId == "r2", "Auto queues next playlist region immediately");
    regionPlayback.advance(3);
    expect(regionPlayback.transport().playing && regionPlayback.transport().position == 7 && regionPlayback.transport().regionId == "r2", "exact region boundary jumps directly with play uninterrupted");
    expect(!regionPlayback.transport().queuedRegionId, "consumed queue clears at final playlist region");
    regionPlayback.advance(2);
    expect(!regionPlayback.transport().playing && regionPlayback.transport().position == 9, "Auto stops at end of final region");
    regionPlayback.execute({CommandKind::stop});
    regionPlayback.execute({CommandKind::selectRegion, "r1"}); regionPlayback.execute({CommandKind::play});
    regionPlayback.advance(0.25);
    const auto queuedBeforeBlockEdit = regionPlayback.transport().queuedRegionId;
    const double queueStartBeforeBlockEdit = regionPlayback.transport().queueStartedAt;
    regionLists.blocks->front().name = "Renamed block";
    regionPlayback.configureRegionSetlist(regionLists);
    expect(regionPlayback.transport().queuedRegionId == queuedBeforeBlockEdit && regionPlayback.transport().queueStartedAt == queueStartBeforeBlockEdit, "editing blocks preserves the running queue and countdown origin");
    regionPlayback.advance(3.0);
    expect(regionPlayback.transport().playing && std::abs(regionPlayback.transport().position - 7.25) < 1e-9, "boundary crossing preserves fractional elapsed time without a gap");
    regionPlayback.execute({CommandKind::stop});
    expect(regionPlayback.transport().position == 7 && regionPlayback.transport().regionId == "r2", "Stop after Auto transition returns to current region start");
    regionLists.autoAdvance = false; regionPlayback.configureRegionSetlist(regionLists);
    regionPlayback.execute({CommandKind::selectRegion, "r1"}); regionPlayback.execute({CommandKind::play});
    regionPlayback.execute({CommandKind::queueRegion, "r2"}); regionPlayback.advance(3);
    expect(regionPlayback.transport().playing && regionPlayback.transport().position == 7, "manual queue also jumps with Auto off");
    regionPlayback.advance(0.4); regionPlayback.execute({CommandKind::stop});
    expect(regionPlayback.transport().position == 7, "Stop after manual queue returns to current region start");
    regionPlayback.execute({CommandKind::play});
    regionLists.autoAdvance = true; regionLists.playlists[0].regionIds = {"r2", "r1"};
    regionPlayback.configureRegionSetlist(regionLists);
    expect(regionPlayback.transport().queuedRegionId == "r1", "Auto follows playlist order instead of grid position");
    regionLists.autoAdvance = false; regionPlayback.configureRegionSetlist(regionLists);
    expect(!regionPlayback.transport().queuedRegionId, "turning Auto off clears its generated queue");
    auto invalidList = regionLists; invalidList.playlists[0].name = "  ";
    bool noName = false; try { regionPlayback.configureRegionSetlist(invalidList); } catch (...) { noName = true; }
    expect(noName && regionPlayback.project().regionSetlist->playlists[0].name == "My playlist", "empty playlist names rejected atomically");
    auto invalidBlock = regionLists;
    invalidBlock.blocks->front().beforeRegionId = "missing";
    bool badBlock = false; try { regionPlayback.configureRegionSetlist(invalidBlock); } catch (...) { badBlock = true; }
    expect(badBlock && regionPlayback.project().regionSetlist->blocks->front().beforeRegionId == "r2", "invalid block anchors rejected atomically");
    Engine gated; gated.loadProject(p);
    gated.execute({CommandKind::subSeek,"",2}); gated.execute({CommandKind::subPlay}); gated.advance(1);
    expect(!gated.transport().subPlay.playing && gated.transport().subPlay.position == 2, "sub play cannot start without main play");
    gated.execute({CommandKind::play}); gated.execute({CommandKind::subPlay}); gated.advance(1);
    expect(gated.transport().subPlay.playing, "sub play enabled while main plays");
    gated.execute({CommandKind::stop});
    expect(gated.transport().playing && !gated.transport().subPlay.playing && gated.transport().position == 3 && gated.transport().editPosition == 3 && gated.transport().subPlayPromotion == 1, "main stop promotes the current subplay position without stopping");
    gated.execute({CommandKind::stop});
    expect(!gated.transport().playing && gated.transport().position == 2, "next stop returns to promoted playback start");
    gated.execute({CommandKind::select,"three"}); gated.execute({CommandKind::seek,"",29});
    gated.execute({CommandKind::play}); gated.execute({CommandKind::subPlay}); gated.advance(2);
    expect(gated.transport().playing && !gated.transport().subPlay.playing && gated.transport().position == 2 && gated.transport().subPlayPromotion == 2, "natural main ending promotes Subplay just like stopping the outgoing head manually");
    Engine returning; returning.loadProject(p);
    returning.execute({CommandKind::seek,"",3}); returning.execute({CommandKind::play}); returning.advance(2);
    returning.execute({CommandKind::play}); returning.execute({CommandKind::stop});
    expect(returning.transport().position==3 && !returning.transport().playing,"stop returns to original play point; repeated play does not replace it");
    returning.execute({CommandKind::seek,"",4}); returning.execute({CommandKind::stop});
    expect(returning.transport().position==4,"stop while idle preserves new cue");
    returning.execute({CommandKind::play}); returning.execute({CommandKind::subSeek,"",6}); returning.execute({CommandKind::subPlay}); returning.advance(1);
    returning.execute({CommandKind::stopAll});
    expect(returning.transport().position==4 && returning.transport().subPlay.position==6 && !returning.transport().subPlay.playing,"stop all restores independent start points");
    Engine e; e.loadProject(p); e.execute({CommandKind::play}); e.advance(2); expect(e.transport().playing && e.transport().position==2,"play advances");
    e.execute({CommandKind::subSeek,"",6}); e.execute({CommandKind::subPlay}); e.advance(1);
    expect(e.transport().position==3 && e.transport().subPlay.position==7 && e.transport().subPlay.playing,"independent simultaneous cursors");
    e.execute({CommandKind::subStop}); expect(e.transport().playing,"sub stop preserves main");
    e.execute({CommandKind::seek,"",2});
    e.execute({CommandKind::queue,"three"}); expect(e.nextSongId()=="three","queue overrides next"); e.advance(9); expect(e.transport().songId=="three" && e.transport().position==1 && !e.transport().queue.songId,"queued target consumed");
    e.execute({CommandKind::previous}); expect(e.transport().songId=="two","previous"); e.execute({CommandKind::next}); expect(e.transport().songId=="three","next");
    e.execute({CommandKind::loopStart,"",0}); e.execute({CommandKind::loopEnd,"",30});
    e.execute({CommandKind::toggleLoop}); e.advance(35); expect(e.transport().playing && e.transport().position==5,"loop wraps");
    e.finishCurrentSong(true); e.advance(40); expect(!e.transport().playing && e.transport().position==30,"revocation waits for boundary even with loop");
    e.execute({CommandKind::volume,"track",0.3}); expect(e.project().songs[0].tracks[0].volume==0.3,"mixer volume");
    e.execute({CommandKind::mute,"track"}); expect(e.project().songs[0].tracks[0].mute,"mute");
    TrackTaxonomy taxonomy; expect(taxonomy.classify("MÉTRÔNOMO.wav").id=="click","accents and case"); expect(taxonomy.classify("Sanfona L.wav").id=="accordion","role independent of channel suffix"); expect(taxonomy.classify("clickbait.wav").id=="other","word boundaries"); taxonomy.addAlias("violao",{"acousticGuitar"}); expect(taxonomy.classify("Violão.wav").id=="acousticGuitar","extensible taxonomy");
    p.songs[0].tracks[0].audioFile=AudioFile{"../private.wav",{}}; bool rejected=false; try { validate(p); } catch(...) { rejected=true; } expect(rejected,"portable paths");
    Engine editCursor; editCursor.loadProject(editable);
    editCursor.execute({CommandKind::editSeek,"",2}); editCursor.execute({CommandKind::play}); editCursor.advance(1);
    expect(editCursor.transport().position == 3 && editCursor.transport().editPosition == 2, "playback leaves editing cursor parked");
    editCursor.execute({CommandKind::editSeek,"",7});
    expect(editCursor.transport().position == 3 && editCursor.transport().editPosition == 7 && editCursor.transport().subPlay.position == 0, "left editing seek affects neither running playback nor subplay");
    editCursor.execute({CommandKind::stop}); editCursor.execute({CommandKind::play});
    expect(editCursor.transport().position == 7, "new playback starts at editing cursor");
    Engine paused; paused.loadProject(editable);
    paused.execute({CommandKind::editSeek,"",2}); paused.execute({CommandKind::play}); paused.advance(1);
    paused.execute({CommandKind::subSeek,"",4}); paused.execute({CommandKind::subPlay}); paused.advance(1);
    const double pausedMain = paused.transport().position, pausedSub = paused.transport().subPlay.position;
    paused.execute({CommandKind::pause}); paused.advance(3);
    expect(paused.transport().paused && !paused.transport().playing && !paused.transport().subPlay.playing && paused.transport().position == pausedMain && paused.transport().subPlay.position == pausedSub, "pause freezes both cursors in place");
    paused.execute({CommandKind::play});
    expect(paused.transport().position == pausedMain && paused.transport().subPlay.position == pausedSub && paused.transport().subPlay.playing, "play resumes both paused positions");
    paused.execute({CommandKind::stop});
    expect(paused.transport().playing && paused.transport().position == pausedSub && !paused.transport().paused && !paused.transport().subPlay.playing, "stop after resume promotes the resumed subplay");
    e.execute({CommandKind::volume,"track",std::pow(10.0, 12.0 / 20.0)});
    expect(std::abs(e.project().songs[0].tracks[0].volume - 3.9810717055) < 0.000001, "track fader supports +12 dB linear gain");
    validate(e.project());
    e.execute({CommandKind::volume,"track",0});
    expect(e.project().songs[0].tracks[0].volume == 0, "track fader minus infinity is silent");
    e.execute({CommandKind::volume,"",std::pow(10.0, 12.0 / 20.0)});
    e.execute({CommandKind::mute});
    expect(e.project().masterMute && e.project().masterVolume > 3.98, "master has independent gain and mute");
    e.execute({CommandKind::mute});
    expect(!e.project().masterMute && e.project().songs[0].tracks[0].volume == 0, "master mute preserves track gain");
    validate(e.project());
    Engine itemMute; itemMute.loadProject(editable);
    const auto itemID = itemMute.project().songs[0].tracks[0].clips[0].id;
    const bool trackMuteBefore = itemMute.project().songs[0].tracks[0].mute;
    itemMute.execute({CommandKind::clipMute, itemID});
    expect(itemMute.project().songs[0].tracks[0].clips[0].muted && itemMute.project().songs[0].tracks[0].mute == trackMuteBefore, "item mute is independent of track mute");
    itemMute.execute({CommandKind::clipMute, itemID});
    expect(!itemMute.project().songs[0].tracks[0].clips[0].muted, "item mute toggles off");
    Engine itemGain; itemGain.loadProject(stacked);
    itemGain.execute({CommandKind::play}); itemGain.execute({CommandKind::subSeek, "", 2}); itemGain.execute({CommandKind::subPlay}); itemGain.advance(1);
    itemGain.execute({CommandKind::clipGain, "clip2", 0.25});
    expect(itemGain.project().songs[0].tracks[0].clips[1].gain == 0.25 && !itemGain.project().songs[0].tracks[0].clips[0].gain && !itemGain.project().songs[0].tracks[0].clips[2].gain, "item gain command changes only the requested clip");
    expect(itemGain.transport().playing && itemGain.transport().position == 1 && itemGain.transport().subPlay.playing && itemGain.transport().subPlay.position == 3, "item gain preserves both playback heads");
    for (double invalid : {-0.01, std::pow(10.0, 24.0 / 20.0) + 0.01, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()}) {
        bool rejected = false; try { itemGain.execute({CommandKind::clipGain, "clip2", invalid}); } catch (...) { rejected = true; }
        expect(rejected && itemGain.project().songs[0].tracks[0].clips[1].gain == 0.25 && itemGain.transport().position == 1 && itemGain.transport().subPlay.position == 3, "invalid item gain is atomic");
    }
    bool missingGainItem = false; try { itemGain.execute({CommandKind::clipGain, "missing", 0.5}); } catch (...) { missingGainItem = true; }
    expect(missingGainItem && itemGain.project().songs[0].tracks[0].clips[1].gain == 0.25, "unknown gain target cannot mutate another clip");
    itemGain.execute({CommandKind::clipGain, "clip2", 0});
    expect(itemGain.project().songs[0].tracks[0].clips[1].gain == 0, "item gain supports silence");
    itemGain.execute({CommandKind::clipGain, "clip2", std::pow(10.0, 24.0 / 20.0)});
    expect(itemGain.project().songs[0].tracks[0].clips[1].gain == std::pow(10.0, 24.0 / 20.0), "item gain supports exactly +24 dB");
    for (const auto* specialRole : {"video", "teleprompt", "timecode", "chords"}) {
        auto specialGainProject = editable;
        specialGainProject.songs[0].parts = {{"special-region", "Special", 0, 9}};
        specialGainProject.songs[0].tracks[0].role.id = specialRole;
        specialGainProject.songs[0].tracks[0].name = fixedTrackName({specialRole});
        if (std::string(specialRole) == "teleprompt" || std::string(specialRole) == "chords") {
            specialGainProject.songs[0].tracks[0].clips[0].waveform.clear();
            specialGainProject.songs[0].tracks[0].clips[0].text = "";
        }
        Engine specialGain; specialGain.loadProject(specialGainProject);
        const auto specialClipID = specialGain.project().songs[0].tracks[0].clips[0].id;
        const auto specialGainBefore = specialGain.project().songs[0].tracks[0].clips[0].gain;
        bool rejected = false; try { specialGain.execute({CommandKind::clipGain, specialClipID, 0.25}); } catch (...) { rejected = true; }
        expect(rejected && specialGain.project().songs[0].tracks[0].clips[0].gain == specialGainBefore, "special clips reject gain editing atomically");
    }
    const auto trackID = itemMute.project().songs[0].tracks[0].id;
    itemMute.editTrack(trackID, "Edited track", 0x20cc80);
    expect(itemMute.project().songs[0].tracks[0].name == "Edited track" && itemMute.project().songs[0].tracks[0].color == 0x20cc80 && itemMute.project().songs[0].tracks[0].clips[0].id == itemID, "track name and color edit preserves items");
    Project handoff = regionShow;
    handoff.songs[0].duration = 30;
    handoff.songs[0].parts = {{"r1", "First", 2, 5}, {"r2", "Second", 10, 20}, {"r3", "Third", 22, 28}};
    handoff.regionSetlist->playlists[0].regionIds = {"r1", "r2", "r3"};
    Engine overlap; overlap.loadProject(handoff);
    overlap.execute({CommandKind::selectRegion, "r1"}); overlap.execute({CommandKind::play});
    overlap.advance(1);
    const auto editBefore = overlap.transport().editPosition;
    overlap.execute({CommandKind::subPlay}); overlap.advance(1);
    expect(overlap.transport().position == 4 && overlap.transport().editPosition == editBefore && overlap.transport().subPlay.position == 11, "queued subplay does not move the main or editing cursor early");
    overlap.advance(1.25);
    expect(overlap.transport().position == 12.25 && overlap.transport().editPosition == 12.25 && overlap.transport().regionId == "r2", "handoff uses current subplay position including fractional elapsed time");
    expect(!overlap.transport().subPlay.playing && overlap.transport().subPlayPromotion == 1 && overlap.transport().queuedRegionId == "r3", "promoted playback clears subplay and advances the queue once");
    overlap.execute({CommandKind::stop});
    expect(overlap.transport().position == 22, "Stop without active Sub Play prepares the next queued region after promotion");
    Engine manualHandoff; manualHandoff.loadProject(handoff);
    manualHandoff.execute({CommandKind::selectRegion, "r1"}); manualHandoff.execute({CommandKind::play});
    manualHandoff.execute({CommandKind::subPlay}); manualHandoff.advance(0.75);
    manualHandoff.execute({CommandKind::stop});
    expect(manualHandoff.transport().playing && !manualHandoff.transport().subPlay.playing && manualHandoff.transport().position == 10.75 && manualHandoff.transport().subPlayPromotion == 1, "manual Stop promotes subplay before the current region ends");
    expect(manualHandoff.transport().regionId == "r2" && manualHandoff.transport().queuedRegionId == "r3", "manual promotion updates region and Auto queue");
    manualHandoff.advance(0.25);
    expect(manualHandoff.transport().position == 11 && manualHandoff.transport().subPlayPromotion == 1, "promoted playback continues exactly once");
    manualHandoff.execute({CommandKind::stop});
    expect(!manualHandoff.transport().playing && manualHandoff.transport().position == 22, "second Stop prepares the current queue after Sub Play was promoted");
    Project unified; unified.id = "unified-project"; unified.name = "Unified";
    unified.songs = {{"unified-song", "Song", 150, 120, {{"unified-track", "Audio", {"other"}}}, {}}};
    Part firstUnified{"child-one", "One", 10, 40}; firstUnified.parentRegionID = "unified";
    Part secondUnified{"child-two", "Two", 30, 60}; secondUnified.parentRegionID = "unified";
    unified.songs[0].parts = {firstUnified, secondUnified, {"unified", "Group", 10, 60}};
    unified.songs[0].markers = std::vector<TimelineMarker>{{"song-marker", "Full original song name", 30, 0xffdc52, "unified"}};
    AudioClip unifiedAudio; unifiedAudio.id = "unified-audio"; unifiedAudio.name = "Audio"; unifiedAudio.startTime = 30; unifiedAudio.duration = 20;
    unified.songs[0].tracks[0].clips = {unifiedAudio};
    Engine unifiedEngine; unifiedEngine.loadProject(unified); unifiedEngine.moveRegion("unified", 50);
    expect(unifiedEngine.project().songs[0].parts[0].startTime == 50 && unifiedEngine.project().songs[0].parts[1].startTime == 70, "moving a unified region moves all drawer songs");
    expect(unifiedEngine.project().songs[0].tracks[0].clips[0].startTime == 70 && unifiedEngine.project().songs[0].markers->at(0).position == 70, "unified movement moves audio and markers once");
    bool childMoveRejected = false; try { unifiedEngine.moveRegion("child-one", 60); } catch (...) { childMoveRejected = true; }
    expect(childMoveRejected && unifiedEngine.project().songs[0].parts[0].startTime == 50, "drawer songs cannot move independently");
    bool groupResizeRejected = false; try { unifiedEngine.resizeRegion("unified", 80, 100); } catch (...) { groupResizeRejected = true; }
    expect(groupResizeRejected && unifiedEngine.project().songs[0].parts.back().startTime == 50, "resizing cannot discard drawer songs");
    unifiedEngine.setMarker("song-marker", "Updated original song name", 70, 0x54ff93);
    bool unifiedMarkerDeleteRejected = false;
    try { unifiedEngine.deleteManualMarker("song-marker"); } catch (...) { unifiedMarkerDeleteRejected = true; }
    expect(unifiedMarkerDeleteRejected && unifiedEngine.project().songs[0].markers->size() == 1, "unified song marker cannot be deleted as a manual marker");

    expect(unifiedEngine.project().songs[0].markers->at(0).unifiedRegionID == "unified", "editing a marker keeps its unified owner");
    unified.songs[0].parts.push_back({"after-group", "After drawer", 80, 100});
    RegionSetlist drawerList; drawerList.autoAdvance = true;
    unified.regionSetlist = drawerList;
    Engine drawerPlayback; drawerPlayback.loadProject(unified);
    drawerPlayback.execute({CommandKind::selectRegion, "child-one"}); drawerPlayback.execute({CommandKind::play});
    expect(drawerPlayback.transport().queuedRegionId == "after-group", "Auto skips the whole unified drawer when playing a child");
    drawerPlayback.advance(35);
    expect(drawerPlayback.transport().playing && drawerPlayback.transport().position == 45 && drawerPlayback.transport().regionId == "child-one" && drawerPlayback.transport().queuedRegionId == "after-group", "internal marker and child end never trigger a queued jump");
    drawerPlayback.execute({CommandKind::queueRegion, "child-two"});
    drawerPlayback.execute({CommandKind::queueRegion, "unified"});
    expect(drawerPlayback.transport().queuedRegionId == "after-group" && drawerPlayback.project().regionSetlist->autoAdvance,
           "clicking the displayed playing child or collapsed parent preserves the external queue");
    drawerPlayback.execute({CommandKind::stopAll}); drawerPlayback.execute({CommandKind::selectRegion, "unified"}); drawerPlayback.execute({CommandKind::play});
    bool sameDrawerRejected = false;
    try { drawerPlayback.execute({CommandKind::queueRegion, "child-two"}); } catch (...) { sameDrawerRejected = true; }
    expect(sameDrawerRejected, "parent playback cannot queue its own child");
    drawerPlayback.execute({CommandKind::stopAll}); drawerPlayback.execute({CommandKind::selectRegion, "after-group"}); drawerPlayback.execute({CommandKind::play});
    drawerPlayback.execute({CommandKind::queueRegion, "child-two"});
    expect(drawerPlayback.transport().queuedRegionId == "child-two", "other regions can queue a drawer song");
    drawerPlayback.execute({CommandKind::queueRegion, "unified"});
    expect(!drawerPlayback.transport().queuedRegionId && !drawerPlayback.project().regionSetlist->autoAdvance,
           "clicking the collapsed queued parent cancels its queued child and disables Auto");
    drawerPlayback.execute({CommandKind::stopAll}); drawerPlayback.execute({CommandKind::selectRegion, "child-one"});
    drawerList.stopAtRegionEnd = true; drawerPlayback.configureRegionSetlist(drawerList);
    drawerPlayback.execute({CommandKind::play}); drawerPlayback.execute({CommandKind::subPlay}); drawerPlayback.advance(55);
    expect(drawerPlayback.transport().playing && !drawerPlayback.transport().subPlay.playing && drawerPlayback.transport().position == 135 && drawerPlayback.transport().subPlayPromotion == 1, "region Stop preserves and promotes an already-running Subplay");
    drawerPlayback.execute({CommandKind::stopAll});
    drawerList.stopAtRegionEnd = false; drawerPlayback.configureRegionSetlist(drawerList);
    drawerPlayback.execute({CommandKind::selectRegion, "child-one"}); drawerPlayback.execute({CommandKind::play}); drawerPlayback.advance(55);
    expect(drawerPlayback.transport().playing && drawerPlayback.transport().regionId == "after-group" && drawerPlayback.transport().position == 85, "disabling region Stop restores gapless Auto transition");
    drawerList.autoAdvance = false; drawerList.stopAtRegionEnd = true;
    drawerPlayback.execute({CommandKind::stopAll}); drawerPlayback.configureRegionSetlist(drawerList);
    drawerPlayback.execute({CommandKind::selectRegion, "unified"}); drawerPlayback.execute({CommandKind::play}); drawerPlayback.advance(55);
    expect(!drawerPlayback.transport().playing && drawerPlayback.transport().position == 60, "region Stop also stops without Auto or queued song");
    drawerList.stopAtRegionEnd = false; drawerPlayback.configureRegionSetlist(drawerList);
    drawerPlayback.execute({CommandKind::selectRegion, "after-group"}); drawerPlayback.execute({CommandKind::play});
    drawerPlayback.execute({CommandKind::queueRegion, "child-one"}); drawerPlayback.execute({CommandKind::subPlay}); drawerPlayback.execute({CommandKind::subSeek, "", 35});
    drawerPlayback.advance(15); drawerPlayback.advance(5);
    expect(drawerPlayback.transport().playing && drawerPlayback.transport().regionId == "child-one" && drawerPlayback.transport().subPlayPromotion == 2 && drawerPlayback.transport().position == 55, "incoming drawer subplay promotion preserves its running position");
    bool expandingGroupRejected = false; try { unifiedEngine.resizeRegion("unified", 40, 120); } catch (...) { expandingGroupRejected = true; }
    expect(expandingGroupRejected, "unified regions cannot expand even when all children fit");

    Engine clipboardEngine; clipboardEngine.loadProject(editable);
    clipboardEngine.execute({CommandKind::play}); clipboardEngine.advance(0.5);
    Track copiedTrack = editable.songs[0].tracks[0];
    copiedTrack.clips[0].id = "copied-item"; copiedTrack.clips[0].startTime = 20;
    copiedTrack.clips[0].gain = 0.5; copiedTrack.clips[0].muted = true;
    copiedTrack.clips[0].audioFile = AudioFile{"Steams/shared.wav", {}};
    clipboardEngine.pasteItems("one", {copiedTrack}, false);
    expect(clipboardEngine.project().songs[0].tracks[0].clips.size() == 2 && clipboardEngine.project().songs[0].tracks[0].clips[1].id == "copied-item", "copy adds a distinct item to its source track");
    expect(clipboardEngine.transport().playing && clipboardEngine.transport().position == 0.5, "paste preserves running transport");
    copiedTrack.clips[0].startTime = 40;
    clipboardEngine.pasteItems("one", {copiedTrack}, true);
    expect(clipboardEngine.project().songs[0].tracks[0].clips.size() == 2 && clipboardEngine.project().songs[0].tracks[0].clips.back().startTime == 40, "move replaces its own item instead of duplicating it");
    const auto pastedBeforeFailure = clipboardEngine.project().songs[0].tracks[0].clips.size();
    copiedTrack.clips[0].id = "missing-move";
    bool missingMove = false; try { clipboardEngine.pasteItems("one", {copiedTrack}, true); } catch (...) { missingMove = true; }
    expect(missingMove && clipboardEngine.project().songs[0].tracks[0].clips.size() == pastedBeforeFailure, "failed move is atomic");
    Project tpMediaProject = editable;
    Track tpMedia{"tp-media", "Teleprompter", {"teleprompt"}};
    AudioClip lyric{"lyric-item", {}, "Text", 0, 5}; lyric.text = "Lyrics";
    AudioClip tpMovie{"tp-movie", {}, "Movie", 0, 10}; tpMovie.audioFile = AudioFile{"Videos/teleprompter.mov", {}};
    tpMedia.clips = {lyric, tpMovie}; tpMediaProject.songs[0].tracks.push_back(tpMedia);
    validate(tpMediaProject);
    Engine tpMediaEngine; tpMediaEngine.loadProject(tpMediaProject);
    tpMediaEngine.moveClip("tp-movie", 1);
    expect(tpMediaEngine.project().songs[0].tracks[0].clips.back().startTime == 1, "teleprompter media moves horizontally over its text layer");
    bool mediaTextEdit = false; try { tpMediaEngine.setClipText("tp-movie", "Wrong"); } catch (...) { mediaTextEdit = true; }
    expect(mediaTextEdit, "teleprompter media never receives editable text");
    tpMedia.clips = {tpMovie}; tpMedia.clips[0].id = "tp-movie-second";
    bool mediaOverlap = false; try { tpMediaEngine.insertAudioTracks("one", {tpMedia}); } catch (...) { mediaOverlap = true; }
    expect(mediaOverlap && tpMediaEngine.project().songs[0].tracks[0].clips.size() == 2, "teleprompter allows media over text but rejects overlapping media");
    {
        Project routes; routes.id="route-project"; routes.name="Routes";
        Song song; song.id="route-song"; song.name="Routes"; song.duration=10;
        for(int i=0;i<6;++i) { Track t; t.id="route-"+std::to_string(i);t.name=t.id;song.tracks.push_back(t); }
        routes.songs={song}; Engine dynamic; dynamic.loadProject(routes); dynamic.execute({CommandKind::play});
        dynamic.setOutputPatches("route-0", {{0,2},{1,2},{3,2},{5,1}});
        dynamic.setOutputPatches("", {{1,2},{3,2},{5,2}});
        TrackRouting sends; sends.transmitters={"route-1","route-2","route-3","route-4","route-5"}; sends.receives.clear();
        dynamic.setTrackRouting({{"route-0",sends}});
        expect(dynamic.project().masterOutputs->size()==3 && dynamic.currentSong()->tracks[0].outputPatches().size()==4, "dynamic output lists are not restricted to two instances");
        expect(dynamic.currentSong()->tracks[0].routing->transmitters.size()==5 && dynamic.transport().playing, "dynamic sends preserve transport");
        TrackRouting cycle; cycle.transmitters={std::nullopt,std::nullopt,std::nullopt,"route-0"}; bool rejected=false;
        try { dynamic.setTrackRouting({{"route-5",cycle}}); } catch(...) { rejected=true; }
        expect(rejected && !dynamic.currentSong()->tracks[5].routing, "feedback in any slot is rejected atomically");
        dynamic.setOutputPatches("route-0", {}); expect(dynamic.currentSong()->tracks[0].outputPatches().empty(), "all outputs can be removed");
    }
    {
        Project media; media.id="video-audio-test"; media.name="Video controls"; media.songs={{"video-song","Song",10,120,{},{}}};
        Track video; video.id="video-controls"; video.name="Video"; video.role={"video"};
        Track timecode; timecode.id="timecode-controls"; timecode.name="Timecode"; timecode.role={"timecode"};
        media.songs[0].tracks.push_back(video); media.songs[0].tracks.push_back(timecode);
        Engine engine; engine.loadProject(media);
        engine.execute({CommandKind::volume,video.id,0.5}); engine.execute({CommandKind::solo,video.id});
        engine.execute({CommandKind::mute,video.id}); engine.execute({CommandKind::volume,timecode.id,0.25});
        validate(engine.project());
        auto track = std::find_if(engine.currentSong()->tracks.begin(),engine.currentSong()->tracks.end(),[&](const auto& value){return value.id==video.id;});
        expect(track!=engine.currentSong()->tracks.end() && track->volume==0.5 && track->solo && track->mute,"video audio controls are persisted");
        TimelineMarker a{"detected-a","TEMPO",0.123,0x999999}; a.tempoBPM=120; a.tempoReferenceBPM=120; a.tempoBeats=4; a.tempoUnit=4; a.tempoTimebase="global";
        TimelineMarker b{"detected-b","TEMPO",8.123,0x999999}; b.tempoBPM=90; b.tempoBeats=4; b.tempoUnit=4; b.tempoTimebase="global";
        engine.setMarkers({a,b}); expect(engine.currentSong()->markers->size()==2,"tempo sections commit as one batch");
        engine.setMarker(a.id, "TEMPO", a.position, a.color, 150, 4, 4, "global");
        expect(engine.currentSong()->markers->front().tempoReferenceBPM == 120, "editing detected tempo preserves source reference");
        const auto saved = engine.currentSong()->markers->size(); b.id="invalid-tempo"; b.tempoBPM=400;
        bool rejected=false; try {engine.setMarkers({b});} catch(...) {rejected=true;}
        expect(rejected && engine.currentSong()->markers->size()==saved,"invalid tempo batch is atomic");
    }
    {
        Project p; p.id="tempo-resize"; p.name="Tempo resize";
        Song song{"resize-song","Song",30,120,{},{}};
        song.timeSettings=ProjectTimeSettings{}; song.timeSettings->timebase=ProjectTimebase::relative;
        song.parts={{"one","First",2,12},{"two","Second",17,27}};
        Track track; track.id="audio";track.name="Audio";
        AudioClip a; a.id="first";a.name="First";a.startTime=2;a.duration=10;a.sourceOffset=1;a.audioFile=AudioFile{"stems/first.wav"};a.gain=0.5;a.muted=true;
        AudioClip b=a;b.id="second";b.name="Second";b.startTime=17;b.sourceOffset=0;
        track.clips={a,b};song.tracks={track};p.songs={song};
        Engine e;e.loadProject(p);
        TimelineMarker first{"tempo-one","TEMPO",2,0x999999}; first.tempoBPM=120;first.tempoBeats=4;first.tempoUnit=4;first.tempoTimebase="global";first.tempoReferenceBPM=120;
        TimelineMarker second=first;second.id="tempo-two";second.position=17;
        e.setMarkers({first,second});e.execute({CommandKind::seek,"",10});
        e.setMarker(first.id,"TEMPO",2,0x999999,240,4,4,"global");
        const auto& changed=*e.currentSong();
        expect(changed.parts[0].endTime==7 && changed.parts[1].startTime==12 && changed.parts[1].endTime==22,"tempo resizes regions while retaining the five-second gap");
        expect(changed.tracks[0].clips[0].duration==5 && changed.tracks[0].clips[1].duration==10,"tempo edit preserves all source audio instead of cutting the tail");
        expect(changed.tracks[0].clips[0].sourceOffset==1 && changed.tracks[0].clips[0].gain==0.5 && changed.tracks[0].clips[0].muted,"tempo warp preserves item edits");
        expect(changed.markers->at(1).position==12 && e.transport().position==6,"following tempo markers and cursor follow the same map");
        e.setMarker(first.id,"TEMPO",2,0x999999,120,4,4,"global");
        expect(e.currentSong()->parts[0].endTime==12 && e.currentSong()->parts[1].startTime==17 && e.currentSong()->tracks[0].clips[0].duration==10,"reversing a tempo edit restores durations and gaps");
        expect(e.transport().position==10,"cursor reverses the tempo mapping");
        song.parts={{"one","First",0,12},{"two","Second",10,20},{"group","Special",0,20}};
        song.parts[0].parentRegionID="group";song.parts[1].parentRegionID="group";
        song.tracks[0].clips[0].startTime=0;song.tracks[0].clips[0].duration=12;
        song.tracks[0].clips[1].startTime=10;song.tracks[0].clips[1].duration=10;
        p.songs={song};e.loadProject(p);first.position=0;second.position=10;e.setMarkers({first,second});
        e.setMarker(second.id,"TEMPO",10,0x999999,240,4,4,"global");
        expect(e.currentSong()->tracks[0].clips[0].duration==12 && e.currentSong()->parts[0].endTime==12,"next song tempo cannot resize the preceding song tail");
        expect(e.currentSong()->tracks[0].clips[1].duration==5 && e.currentSong()->parts[2].endTime==15,"drawer song and unified parent resize together");
        e.setMarker(second.id,"TEMPO",10,0x999999,120,4,4,"global");
        expect(e.currentSong()->tracks[0].clips[0].duration==12 && e.currentSong()->tracks[0].clips[1].duration==10,"drawer tempo reversal preserves independent tails");

    }
    {
        Project project; project.id="tempo-ownership"; project.name="Tempo ownership";
        Song song{"owner-song","Song",100,120,{},{}};
        song.parts={{"owner-a","A",10,20},{"owner-b","B",20,30}};
        song.regionOwnershipInitialized=true;
        const auto tempoMarker=[](ID id,double position) {
            TimelineMarker marker{std::move(id),"TEMPO",position,0x999999};
            marker.tempoBPM=120; marker.tempoBeats=4; marker.tempoUnit=4; marker.tempoTimebase="free";
            return marker;
        };
        auto loose=tempoMarker("owner-loose",14), outside=tempoMarker("owner-outside",41);
        song.markers=std::vector<TimelineMarker>{loose,outside}; project.songs={song};
        Engine engine; engine.loadProject(project);
        const auto marker=[&](const ID& id)->const TimelineMarker& {
            for(const auto& value:*engine.currentSong()->markers) if(value.id==id) return value;
            throw std::runtime_error("Missing ownership test marker");
        };
        engine.setMarker("owner-manual","TEMPO",16,0x999999,120,4,4,"free");
        engine.setMarker(loose.id,"TEMPO",14,0x999999,121,4,4,"free");
        expect(marker("owner-manual").regionOwnerID=="owner-a" && !marker(loose.id).regionOwnerID,"single-marker placement attaches while an in-place edit preserves explicit nil ownership");
        auto batch=tempoMarker("owner-batch",18), boundary=tempoMarker("owner-boundary",20);
        engine.setMarkers({batch,boundary});
        expect(marker(batch.id).regionOwnerID=="owner-a" && marker(boundary.id).regionOwnerID=="owner-b","detected tempo batch attaches new markers and gives an adjacent boundary to the next region");
        expect(!regionOwns(*engine.currentSong(),"owner-a",marker(boundary.id).regionOwnerID),"deleting the preceding region must exclude the next region's boundary tempo");
        auto manual=tempoMarker("owner-manual",16); manual.tempoBPM=125;
        loose.tempoBPM=125;
        engine.setMarkers({manual,loose});
        expect(marker(manual.id).regionOwnerID=="owner-a" && !marker(loose.id).regionOwnerID,"batch edits without serialized owners retain owned and intentionally loose memberships");
        engine.moveRegion("owner-a",40);
        expect(marker(manual.id).position==46 && marker(batch.id).position==48,"new and edited tempo markers travel with their region");
        expect(marker(loose.id).position==14 && marker(outside.id).position==41 && marker(boundary.id).position==20,"moving a region preserves loose tempo and the adjacent region's boundary");
        outside.tempoBPM=130; engine.setMarkers({outside},{},true);
        expect(!marker(outside.id).regionOwnerID,"retime batch cannot capture a loose marker covered by a moved region");
        engine.loadProject(engine.project()); engine.moveRegion("owner-a",10);
        expect(marker(outside.id).position==41 && marker(manual.id).position==16,"save/reload and leaving a loose marker preserve established memberships");
        batch.position=22; manual.position=70; engine.setMarkers({batch,manual});
        expect(marker(batch.id).regionOwnerID=="owner-b" && !marker(manual.id).regionOwnerID,"explicit batch movement attaches to the destination region or detaches outside");
        engine.setMarkers({}, {batch.id,manual.id});
        expect(engine.currentSong()->markers->size()==3 && marker(boundary.id).regionOwnerID=="owner-b" && !marker(loose.id).regionOwnerID,"batch deletion preserves neighboring boundary and loose markers");
        engine.setMarkers({loose},{loose.id});
        expect(marker(loose.id).regionOwnerID=="owner-a","explicit deletion followed by reinsertion establishes new placement ownership");
    }
    {
        Project project; project.id="retime-ownership"; project.name="Retime ownership";
        Song song{"retime-owner-song","Song",50,120,{},{}};
        song.timeSettings=ProjectTimeSettings{}; song.timeSettings->timebase=ProjectTimebase::relative;
        song.parts={{"retime-owner-a","A",10,20},{"retime-owner-b","B",20,30}};
        song.regionOwnershipInitialized=true;
        TimelineMarker first{"retime-owner-first","TEMPO",10,0x999999};
        first.tempoBPM=120; first.tempoBeats=4; first.tempoUnit=4; first.tempoTimebase="global"; first.tempoReferenceBPM=120;
        auto loose=first; loose.id="retime-owner-loose"; loose.position=15;
        song.markers=std::vector<TimelineMarker>{loose}; project.songs={song};
        Engine engine; engine.loadProject(project);
        auto boundary=first; boundary.id="retime-owner-boundary"; boundary.position=20;
        engine.setMarkers({first,boundary});
        first.tempoBPM=240; engine.setMarkers({first,loose,boundary},{},true);
        const auto& markers=*engine.currentSong()->markers;
        expect(markers[0].position==12.5 && !markers[0].regionOwnerID,"real tempo warp moves a loose marker in time without assigning ownership");
        expect(markers[1].position==10 && markers[1].regionOwnerID=="retime-owner-a" && markers[2].position==17.5 && markers[2].regionOwnerID=="retime-owner-b","real tempo warp retains owned start and adjacent boundary memberships");
        expect(engine.currentSong()->parts[0].endTime==17.5 && engine.currentSong()->parts[1].startTime==17.5,"batch ownership preserves the established tempo mapping");
        engine.moveRegion("retime-owner-a",35);
        expect(engine.currentSong()->markers->at(0).position==12.5 && engine.currentSong()->markers->at(1).position==35 && engine.currentSong()->markers->at(2).position==17.5,"after retiming only the region's owned tempo marker follows its movement");
    }
    std::cout << "JARAS_CORE_OK\n";
}
