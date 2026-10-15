#pragma once
#include "RemoteProtocol.h"
#include "Session.h"
#include "StageState.h"
namespace catlive::remote {
class Presentation final {
  public:
    Presentation(Session &value, StageState &stageValue) : session(value), stage(stageValue) {}
    std::function<void()> save;
    var snapshot(int panel) {
        const auto &p = session.project();
        const auto *song = session.song();
        const auto &t = session.transport();
        auto result = object();
        put(result, "sequence", (int64)0);
        put(result, "project", wireID(p.id));
        put(result, "projectName", text(p.name));
        if (song)
            put(result, "song", wireID(song->id));
        put(result, "songName", song ? text(song->name) : String());
        Array<var> songs, tracks, regions, allRegions, playlists, markers;
        for (const auto &item : p.songs) {
            auto v = object();
            put(v, "id", wireID(item.id));
            put(v, "name", text(item.name));
            songs.add(v);
        }
        const auto setlist = p.regionSetlist.value_or(jaras::RegionSetlist{});
        const jaras::RegionPlaylist *selected = nullptr;
        for (const auto &item : setlist.playlists)
            if (song && item.songId == song->id) {
                auto v = object();
                put(v, "id", wireID(item.id));
                put(v, "name", text(item.name));
                playlists.add(v);
                if (setlist.selectedId == item.id)
                    selected = &item;
            }
        if (selected)
            put(result, "selectedPlaylist", wireID(selected->id));
        if (song) {
            for (const auto &track : song->tracks) {
                auto v = object();
                put(v, "id", wireID(track.id));
                put(v, "name", text(track.name));
                put(v, "color", (int)(theme::track(track).getARGB() & 0xffffff));
                put(v, "volume", track.volume);
                put(v, "pan", track.pan);
                put(v, "mute", track.mute);
                put(v, "solo", track.solo);
                put(v, "heightScale", track.heightScale.value_or(1));
                if (track.parentTrackID)
                    put(v, "parentTrack", wireID(*track.parentTrackID));
                if (track.stereoLinkPartner)
                    put(v, "linkedTrack", wireID(*track.stereoLinkPartner));
                Array<var> clips;
                for (const auto &clip : track.clips) {
                    auto c = object();
                    put(c, "id", wireID(clip.id));
                    put(c, "name", text(clip.name));
                    put(c, "start", clip.startTime);
                    put(c, "duration", clip.duration);
                    put(c, "gain", clip.gain.value_or(1));
                    put(c, "muted", clip.muted);
                    put(c, "lane", clip.recordingLane.value_or(0));
                    clips.add(c);
                }
                put(v, "clips", clips);
                tracks.add(v);
            }
            for (const auto &part : song->parts) {
                auto v = object();
                put(v, "id", wireID(part.id));
                put(v, "name", text(part.name));
                put(v, "start", part.startTime);
                put(v, "end", part.endTime);
                put(v, "color", (int)part.color.value_or(0x64b64a));
                put(v, "nameColor",
                    (int)(stage.preferences
                              .setlistColour(selected != nullptr, part.parentRegionID.has_value())
                              .getARGB() &
                          0xffffff));
                if (part.parentRegionID)
                    put(v, "parentRegion", wireID(*part.parentRegionID));
                allRegions.add(v);
            }
            if (selected) {
                for (const auto &id : selected->regionIds)
                    for (const auto &region : allRegions)
                        if (str(region, "id") == wireID(id))
                            regions.add(region);
            } else
                for (const auto &region : allRegions)
                    if (get(region, "parentRegion").isVoid())
                        regions.add(region);
            if (song->markers)
                for (const auto &marker : *song->markers) {
                    auto v = object();
                    put(v, "id", wireID(marker.id));
                    put(v, "name", text(marker.name));
                    put(v, "position", marker.position);
                    put(v, "color", (int)marker.color);
                    put(v, "section", marker.section.value_or(false));
                    markers.add(v);
                }
        }
        put(result, "songs", songs);
        put(result, "tracks", tracks);
        put(result, "regions", regions);
        put(result, "timelineRegions", allRegions);
        put(result, "playlists", playlists);
        put(result, "markers", markers);
        if (t.regionId) {
            put(result, "currentRegion", wireID(*t.regionId));
            put(result, "focusedRegion", wireID(*t.regionId));
        }
        if (t.queuedRegionId)
            put(result, "queuedRegion", wireID(*t.queuedRegionId));
        put(result, "position", t.position);
        put(result, "editPosition", t.editPosition);
        put(result, "subPlayPosition", t.subPlay.position);
        put(result, "duration", song ? song->duration : 0);
        put(result, "bpm", song ? song->bpm : 120);
        put(result, "playing", t.playing);
        put(result, "paused", t.paused);
        put(result, "subPlaying", t.subPlay.playing);
        put(result, "loop", t.loop.enabled);
        if (t.loop.start)
            put(result, "loopStart", *t.loop.start);
        if (t.loop.end)
            put(result, "loopEnd", *t.loop.end);
        put(result, "masterVolume", p.masterVolume);
        put(result, "masterMute", p.masterMute);
        put(result, "masterSolo", p.masterSolo);
        put(result, "masterMono", p.masterMono);
        put(result, "pendingSave", session.dirty);
        put(result, "saving", session.busy);
        put(result, "message", String());
        put(result, "multiLoopsBypassed", t.multiLoopsBypassed);
        put(result, "setlistLiveEnabled", setlist.liveEnabled.value_or(false));
        put(result, "regionAuto", setlist.autoAdvance);
        put(result, "prepareOnly", setlist.prepareWithoutPlayback.value_or(false));
        put(result, "setlistFontStyle", stage.preferences.fontStyle());
        Array<var> played;
        if (setlist.playedLiveRegionIDs)
            for (const auto &id : *setlist.playedLiveRegionIDs)
                played.add(wireID(id));
        put(result, "playedLiveRegionIDs", played);
        Array<var> blocks;
        if (setlist.blocks && song)
            for (const auto &block : *setlist.blocks)
                if (block.songId == song->id && block.playlistId == setlist.selectedId) {
                    auto v = object();
                    put(v, "id", wireID(block.id));
                    put(v, "name", text(block.name));
                    put(v, "color", (int)block.color);
                    put(v, "symbol", block.symbol.value_or(true));
                    if (block.beforeRegionId)
                        put(v, "beforeRegion", wireID(*block.beforeRegionId));
                    blocks.add(v);
                }
        put(result, "setlistBlocks", blocks);
        if (timerTarget != stage.target || timerRunning != stage.running ||
            timerStarted != stage.started) {
            timerTarget = stage.target;
            timerRunning = stage.running;
            timerStarted = stage.started;
            timerRevision = uuid();
        }
        auto timer = object();
        put(timer, "revision", wireID(timerRevision));
        put(timer, "targetSeconds", stage.target);
        put(timer, "running", stage.running);
        put(timer, "remainingSeconds", stage.seconds());
        if (!timerCommand.empty())
            put(timer, "commandID", wireID(timerCommand));
        put(result, "timer", timer);
        if (panel != 0)
            put(result, "notices", notices());
        if (panel == 1 || panel == 2) {
            Array<var> tp;
            tp.add(teleprompter(panel));
            put(result, "teleprompters", tp);
        }
        return result;
    }
    bool apply(const Command &c) {
        if (wireID(c.project) != wireID(session.project().id))
            return false;
        const auto a = c.action;
        if (a == "timerStart" || a == "timerStop") {
            timerCommand = c.id;
            timerRevision = uuid();
            stage.reset();
            if (a == "timerStart") {
                stage.target = (int)c.value;
                stage.saveTimer();
                stage.start();
            }
            return true;
        }
        if (a == "noticeSend") {
            Image image;
            if (c.value >= 0) {
                MemoryBlock bytes;
                if (bytes.fromBase64Encoding(
                        stage.preferences.value("jaras.notices.image." + String((int)c.value))
                            .toString()))
                    image = ImageFileFormat::loadFrom(bytes.getData(), bytes.getSize());
            }
            if (c.message.trim().isEmpty() && !image.isValid())
                return false;
            stage.sendNotice(c.message, image);
            return true;
        }
        if (a == "noticeClear") {
            stage.clearNotice();
            return true;
        }
        if (a == "noticePin") {
            if (stage.pinned != (c.value == 1))
                stage.togglePin();
            return true;
        }
        if (a == "noticeDestination") {
            auto value = stage.preferences.value("jaras.notices.appearance", object()).clone();
            put(value, Identifier("window" + String((int)c.value)), *c.enabled);
            return stage.preferences.set("jaras.notices.appearance", value).wasOk();
        }
        if (a == "noticeSaveTemplate") {
            auto templates = list(stage.preferences.value("jaras.notices.templates"));
            while (templates.size() < 3)
                templates.add("");
            templates.set((int)c.value, c.message);
            return stage.preferences.set("jaras.notices.templates", templates).wasOk();
        }
        const auto *song = session.song();
        if (session.busy || !song || wireID(c.song) != wireID(song->id))
            return false;
        const auto track =
            std::find_if(song->tracks.begin(), song->tracks.end(),
                         [&](const auto &v) { return wireID(v.id) == wireID(c.target); });
        const auto region =
            std::find_if(song->parts.begin(), song->parts.end(),
                         [&](const auto &v) { return wireID(v.id) == wireID(c.target); });
        if (StringArray{"volume", "pan", "mute", "solo", "resetMeterPeak"}.contains(a) &&
            !c.target.empty() && track == song->tracks.end())
            return false;
        ID target = c.target;
        if (track != song->tracks.end())
            target = track->id;
        if (region != song->parts.end())
            target = region->id;
        if (a == "clipGain" || a == "clipMute") {
            bool found = false;
            for (const auto &t : song->tracks)
                if (jaras::fixedTrackName(t.role).empty())
                    for (const auto &clip : t.clips)
                        if (wireID(clip.id) == wireID(c.target)) {
                            target = clip.id;
                            found = true;
                        }
            if (!found)
                return false;
        }
        if (a == "selectRegion" || a == "pitch" || a == "editRegion")
            if (region == song->parts.end())
                return false;
        if (a == "save") {
            if (save)
                save();
            return true;
        }
        if (a == "pitch" || a == "editRegion") {
            const auto sid = song->id;
            session.edit([&](jaras::Project &p) {
                for (auto &s : p.songs)
                    if (s.id == sid)
                        for (auto &part : s.parts)
                            if (part.id == target) {
                                if (a == "pitch")
                                    part.pitchSemitones = (int)c.value;
                                else {
                                    part.name = utf8(c.message.trim());
                                    part.color = (unsigned)c.value;
                                }
                            }
            });
            return true;
        }
        if (a == "selectPlaylist" || a == "toggleRegionAuto" || a == "toggleSetlistLive" ||
            a == "renamePlaylist" || a == "duplicatePlaylist" || a == "deletePlaylist") {
            auto state = session.project().regionSetlist.value_or(jaras::RegionSetlist{});
            auto playlist =
                std::find_if(state.playlists.begin(), state.playlists.end(), [&](const auto &v) {
                    return v.songId == song->id && wireID(v.id) == wireID(c.target);
                });
            if (a == "toggleRegionAuto")
                state.autoAdvance = !state.autoAdvance;
            else if (a == "toggleSetlistLive")
                state.liveEnabled = !state.liveEnabled.value_or(false);
            else {
                if (!c.target.empty() && playlist == state.playlists.end())
                    return false;
                if (a == "selectPlaylist")
                    state.selectedId = c.target.empty() ? std::optional<ID>() : playlist->id;
                else if (a == "renamePlaylist")
                    playlist->name = utf8(c.message.trim());
                else if (a == "duplicatePlaylist") {
                    auto copy = *playlist;
                    copy.id = uuid();
                    copy.name += " (cópia)";
                    if (state.blocks) {
                        auto blocks = *state.blocks;
                        for (auto block : blocks)
                            if (block.playlistId == playlist->id) {
                                block.id = uuid();
                                block.playlistId = copy.id;
                                state.blocks->push_back(block);
                            }
                    }
                    state.selectedId = copy.id;
                    state.playlists.push_back(copy);
                } else if (a == "deletePlaylist") {
                    const auto id = playlist->id;
                    state.playlists.erase(playlist);
                    if (state.selectedId == id)
                        state.selectedId.reset();
                    if (state.blocks)
                        state.blocks->erase(
                            std::remove_if(state.blocks->begin(), state.blocks->end(),
                                           [&](const auto &v) { return v.playlistId == id; }),
                            state.blocks->end());
                }
            }
            session.configureSetlist(state);
            return true;
        }
        if (a == "selectSong") {
            const auto &songs = session.project().songs;
            const auto found = std::find_if(songs.begin(), songs.end(), [&](const auto &s) {
                return wireID(s.id) == wireID(c.target);
            });
            if (found == songs.end())
                return false;
            target = found->id;
        }
        static const std::map<String, jaras::CommandKind> commands{
            {"play", jaras::CommandKind::play},
            {"pause", jaras::CommandKind::pause},
            {"stop", jaras::CommandKind::stop},
            {"subPlay", jaras::CommandKind::subPlay},
            {"subStop", jaras::CommandKind::subStop},
            {"toggleLoop", jaras::CommandKind::toggleLoop},
            {"seek", jaras::CommandKind::seek},
            {"queueSection", jaras::CommandKind::queueSection},
            {"cancelSection", jaras::CommandKind::cancelSection},
            {"toggleMultiLoopBypass", jaras::CommandKind::toggleMultiLoopBypass},
            {"volume", jaras::CommandKind::volume},
            {"pan", jaras::CommandKind::pan},
            {"mute", jaras::CommandKind::mute},
            {"solo", jaras::CommandKind::solo},
            {"masterMono", jaras::CommandKind::masterMono},
            {"selectRegion", jaras::CommandKind::selectRegion},
            {"selectSong", jaras::CommandKind::select},
            {"tempo", jaras::CommandKind::tempo},
            {"clipGain", jaras::CommandKind::clipGain},
            {"clipMute", jaras::CommandKind::clipMute}};
        const auto found = commands.find(a);
        if (found == commands.end())
            return false;
        session.command(found->second, target, c.value);
        return true;
    }
    Bytes image(const Command &c) {
        if (wireID(c.project) != wireID(session.project().id))
            return {};
        Image image;
        if (wireID(c.target) == wireID(noticeImageID) && stage.noticeActive())
            image = stage.noticeImage;
        else if (const auto *song = session.song())
            for (const auto &track : song->tracks)
                if (jaras::isTeleprompterRole(track.role))
                    for (const auto &clip : track.clips)
                        if (wireID(clip.id) == wireID(c.target) && clip.audioFile) {
                            const auto file = ProjectCodec::resolveMedia(session.mediaDirectory,
                                                                         clip.audioFile->path);
                            if (file.hasFileExtension("png;jpg;jpeg;bmp;gif") &&
                                file.getSize() <= 10 * 1024 * 1024)
                                image = ImageFileFormat::loadFrom(file);
                        }
        Bytes result{0x4a, 0x4c, 2, 4};
        const Uuid project(wireID(c.project)), id(wireID(c.target));
        append(result, project.getRawData(), 16);
        append(result, id.getRawData(), 16);
        if (image.isValid()) {
            const auto scale = std::min(1., 1920. / std::max(image.getWidth(), image.getHeight()));
            image = image.rescaled(std::max(1, (int)(image.getWidth() * scale)),
                                   std::max(1, (int)(image.getHeight() * scale)));
            MemoryOutputStream output;
            JPEGImageFormat format;
            format.setQuality(.8f);
            format.writeImageToStream(image, output);
            if (output.getDataSize() <= 1572864)
                append(result, output.getData(), output.getDataSize());
        }
        return result;
    }

  private:
    Session &session;
    StageState &stage;
    ID timerRevision = uuid(), timerCommand, noticeImageID = uuid();
    int timerTarget = -1;
    bool timerRunning = false;
    double timerStarted = -1, noticeSent = -1;
    var notices() {
        auto result = object();
        auto templates = list(stage.preferences.value("jaras.notices.templates"));
        while (templates.size() < 3)
            templates.add("");
        while (templates.size() > 3)
            templates.removeLast();
        Array<var> slots;
        for (int i = 0; i < 3; ++i)
            slots.add(stage.preferences.value("jaras.notices.image." + String(i))
                          .toString()
                          .isNotEmpty());
        const auto settings = stage.preferences.value("jaras.notices.appearance", object());
        put(result, "templates", templates);
        put(result, "imageSlots", slots);
        put(result, "message", stage.notice);
        put(result, "active", stage.noticeActive());
        put(result, "pinned", stage.pinned);
        put(result, "remaining", jlimit(0, 20, (int)std::ceil(stage.remaining())));
        put(result, "window1", flag(settings, "window1", true));
        put(result, "window2", flag(settings, "window2", true));
        put(result, "textColor", (int)num(settings, "text", 0xffffff));
        put(result, "backgroundColor", (int)num(settings, "background", 0));
        put(result, "flashColor", (int)num(settings, "flash", 0xffdc52));
        put(result, "font", str(settings, "font", "Arial"));
        put(result, "scale", num(settings, "scale", 100));
        put(result, "emoji",
            flag(settings, "emojiEnabled") ? str(settings, "emoji", String::fromUTF8("⚠️"))
                                           : String());
        put(result, "cleanDisplay", flag(settings, "cleanDisplay", true));
        put(result, "sentAt", stage.noticeSent);
        if (noticeSent != stage.noticeSent) {
            noticeSent = stage.noticeSent;
            noticeImageID = uuid();
        }
        if (stage.noticeImage.isValid() && stage.noticeActive())
            put(result, "imageID", wireID(noticeImageID));
        return result;
    }
    var teleprompter(int index) {
        auto result = object();
        const auto settings = stage.settings(index);
        const auto *song = session.song();
        const auto &t = session.transport();
        const double position = t.playing ? t.position : t.editPosition;
        String lyrics, chords, name, queued;
        double progress = 0;
        if (song) {
            name = text(song->name);
            for (const auto &part : song->parts) {
                if (t.regionId == part.id)
                    name = text(part.name);
                if (t.queuedRegionId == part.id)
                    queued = text(part.name);
            }
            for (const auto &track : song->tracks)
                if (!track.mute)
                    for (const auto &clip : track.clips)
                        if (!clip.muted && position >= clip.startTime &&
                            position < clip.startTime + clip.duration) {
                            if (track.role.id == (index == 1 ? "teleprompt" : "teleprompt2")) {
                                if (clip.text)
                                    lyrics = text(*clip.text);
                                progress = clip.duration > 0
                                               ? jlimit(0., 1.,
                                                        (position - clip.startTime) / clip.duration)
                                               : 0;
                                if (clip.audioFile) {
                                    put(result, "mediaName", text(clip.name));
                                    put(result, "imageID", wireID(clip.id));
                                }
                            } else if (track.role.id == "chords" && clip.text)
                                chords = text(*clip.text);
                        }
        }
        put(result, "index", index);
        put(result, "text", lyrics);
        put(result, "chords", chords);
        put(result, "song", name);
        put(result, "queued", queued);
        put(result, "progress", progress);
        put(result, "preview", stage.preview);
        put(result, "blocks", Array<var>{});
        auto style = object();
        for (auto key : {"textColor", "chordColor", "clockColor", "localClockColor", "borderColor",
                         "textBoxColor", "progressColor"})
            put(style, key, get(settings, key, 0xffffff));
        put(style, "songColor", get(settings, "songNameColor", 0x00ff55));
        put(style, "queueColor", get(settings, "queueNameColor", 0xffea00));
        put(style, "font", str(settings, "fontFamily", "system"));
        put(style, "chordFont", str(settings, "chordFontFamily", "system"));
        put(style, "textAlignment", str(settings, "textAlignment", "center"));
        put(style, "textScale", num(settings, "textScale", 100));
        put(style, "chordScale", num(settings, "chordScale", 50));
        for (auto item :
             {std::pair<const char *, const char *>{"windowBorder", "windowBorderEnabled"},
              {"textBox", "textBoxEnabled"},
              {"songEnabled", "songNameEnabled"},
              {"queueEnabled", "queueNameEnabled"},
              {"clockEnabled", "clockEnabled"},
              {"localClockEnabled", "localClockEnabled"},
              {"chordsEnabled", "chordsEnabled"},
              {"progressEnabled", "progressEnabled"}})
            put(style, item.first, flag(settings, item.second));
        for (auto item : {std::pair<const char *, const char *>{"clockPosition", "clockPosition"},
                          {"songPosition", "songNamePosition"},
                          {"queuePosition", "queueNamePosition"},
                          {"chordPosition", "chordPosition"},
                          {"progressPosition", "progressPosition"}})
            put(style, item.first, str(settings, item.second, "top"));
        put(result, "style", style);
        put(result, "settings", settings);
        return result;
    }
};
} // namespace catlive::remote
