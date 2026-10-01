#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Import/TrackTaxonomy.hpp"
#include <iostream>
#include <limits>
#include <stdexcept>
using namespace jaras;
static void expect(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
int main() {
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
    ignore.setRegionPitch("ignore-first", 6, {"track"}, {});
    ignore.setRegionPitch("ignore-second", -6, {"track"}, {});
    expect(ignore.project().songs[0].parts[1].pitchSemitones == 6 && ignore.project().songs[0].parts[2].pitchSemitones == -6, "each drawer song owns its pitch settings");
    bool pitchRejected = false; try { ignore.setRegionPitch("ignore-first", 7, {"track"}, {}); } catch (...) { pitchRejected = true; }
    expect(pitchRejected && ignore.project().songs[0].parts[1].pitchSemitones == 6, "region pitch rejects out of range without changing state");
    Project editable = p;
    editable.songs[0].tracks[0].clips.push_back({"clip", "Clip", 2, 3, 0, {0.5}});
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
    importedVideo.clips.push_back({"video-import-clip", "Video", 6, 2});
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
    AudioClip textItem{"text-item", "Chords", 2, 10}; textItem.text = u8"C♯m / G♭ — Refrão 🎵";
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
    bool textMediaRejected = false; Track textMedia{"chords-one", "Chords", {"chords"}}; textMedia.clips.push_back({"invalid-media", "Audio", 0, 1});
    try { textTracks.insertAudioTracks("one", {textMedia}); } catch (...) { textMediaRejected = true; }
    expect(textMediaRejected && textTracks.project().songs[0].tracks[0].clips.size() == 1, "media import cannot populate a Chords text track");
    auto textAudio = textItem; textAudio.id = "text-audio"; textAudio.audioFile = AudioFile{"Steams/invalid.wav", {}};
    textMediaRejected = false; try { textTracks.addRecordedClip("lyrics", textAudio); } catch (...) { textMediaRejected = true; }
    expect(textMediaRejected && textTracks.project().songs[0].tracks[2].clips.empty(), "text insertion rejects audio metadata before committing");
    std::string lyricsMaximum; for (int n=0; n<400; ++n) lyricsMaximum += u8"🎵";
    AudioClip lyricsItem{"lyrics-item","Teleprompter",2,10}; lyricsItem.text=lyricsMaximum;
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
    for (const auto* role : {"teleprompt", "video", "chords"}) {
        auto singleLane = editable;
        auto& track = singleLane.songs[0].tracks[0];
        track.role = {role}; track.name = fixedTrackName(track.role);
        track.clips = {{"lane-first", "First", 1, 2}, {"lane-second", "Second", 5, 2}};
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
    videoMoveTrack.clips.push_back({"video-move-item", "Movie", 2, 3});
    videoMoveTrack.clips[0].audioFile = AudioFile{"Videos/movie.mov", {}};
    mediaMoveProject.songs[0].tracks.push_back(videoMoveTrack);
    mediaMoveProject.songs[0].tracks.push_back({"audio-move", "Audio", {"other"}});
    Engine mediaMoves; mediaMoves.loadProject(mediaMoveProject);
    for (const auto& ids : {std::make_pair(ID("video-move-item"), ID("audio-move")), std::make_pair(ID("clip"), ID("video-move"))}) {
        bool rejected = false; try { mediaMoves.moveClip(ids.first, 4, ids.second); } catch (...) { rejected = true; }
        expect(rejected && mediaMoves.project().songs[0].tracks[0].clips[0].id == "video-move-item" && mediaMoves.project().songs[0].tracks[1].clips[0].id == "clip", "video and audio cannot cross incompatible track kinds");
    }
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
    bool videoFolderRejected = false; try { mediaMoves.loadProject(mislabeledVideo); } catch (...) { videoFolderRejected = true; }
    expect(videoFolderRejected, "managed video media cannot be loaded as a standard audio item");
    Project capacityProject = editable;
    capacityProject.songs[0].tracks.clear();
    for (int index = 0; index < 1000; ++index) capacityProject.songs[0].tracks.push_back({"capacity-" + std::to_string(index), "Track", {"other"}});
    validate(capacityProject);
    Engine trackCapacity; trackCapacity.loadProject(capacityProject);
    bool capacityRejected = false; try { trackCapacity.addTrack("extra-capacity", "Extra", {"other"}); } catch (...) { capacityRejected = true; }
    expect(capacityRejected && trackCapacity.project().songs[0].tracks.size() == 1000, "native track creation cannot exceed global 1000 track capacity");
    Track capacityImport{"extra-capacity", "Extra", {"other"}};
    capacityImport.clips.push_back({"capacity-clip", "Audio", 0, 1});
    capacityRejected = false; try { trackCapacity.insertAudioTracks("one", {capacityImport}); } catch (...) { capacityRejected = true; }
    expect(capacityRejected && trackCapacity.project().songs[0].tracks.size() == 1000, "audio import cannot bypass track capacity");
    capacityProject.songs[1].tracks.push_back({"extra-capacity", "Extra", {"other"}});
    capacityRejected = false; try { validate(capacityProject); } catch (...) { capacityRejected = true; }
    expect(capacityRejected, "track capacity applies across the whole project");
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
    batchProject.songs[0].tracks[0].clips.push_back({"later-clip", "Second.wav", 6, 3});
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
    stacked.songs[0].tracks[0].clips.push_back({"clip2", "Second", 2, 3});
    stacked.songs[0].tracks[0].clips.push_back({"clip3", "Third", 2, 3});
    stacked.songs[0].tracks[0].clips.push_back({"clip4", "Fourth", 5, 3});
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
    addition.clips.push_back({"imported", "Imported", 20, 4});
    Track newTrack{"new-track", "New", {"keys"}};
    newTrack.clips.push_back({"new-clip", "New clip", 20, 5});
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
    expect(!gated.transport().playing && !gated.transport().subPlay.playing, "natural main ending stops sub play too");
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
    expect(!drawerPlayback.transport().playing && !drawerPlayback.transport().subPlay.playing && drawerPlayback.transport().position == 60, "region Stop ends exactly at boundary before queued or SubPlay handoff");
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
    expect(drawerPlayback.transport().playing && drawerPlayback.transport().regionId == "child-one" && drawerPlayback.transport().subPlayPromotion == 1 && drawerPlayback.transport().position == 55, "incoming drawer subplay promotion preserves its running position");
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
    AudioClip lyric{"lyric-item", "Text", 0, 5}; lyric.text = "Lyrics";
    AudioClip tpMovie{"tp-movie", "Movie", 0, 10}; tpMovie.audioFile = AudioFile{"Videos/teleprompter.mov", {}};
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
    std::cout << "JARAS_CORE_OK\n";
}
