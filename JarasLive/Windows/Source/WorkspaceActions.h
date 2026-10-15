// Included after the workspace and setlist implementation.
namespace catlive {
void Workspace::performAction(const String &action, float value, int trackNumber) {
    const auto *song = session.song();
    if (!song)
        return;
    ID track;
    for (const auto &definition : actionDefinitions())
        if (action == definition.id && definition.track) {
            const auto *target = actionTrack(*song, selectedTrack, trackNumber);
            if (!target)
                throw std::runtime_error("Pista indisponível para esta ação.");
            track = target->id;
            break;
        }
    auto command = [&](jaras::CommandKind kind, const ID &id = ID{}, double number = 0) {
        session.command(kind, id, number);
    };
    if (action == "selectTrack") {
        selectedTrack = track;
        repaint();
    } else if (action == "muteTrack")
        command(jaras::CommandKind::mute, track);
    else if (action == "soloTrack")
        command(jaras::CommandKind::solo, track);
    else if (action == "muteMaster")
        command(jaras::CommandKind::mute);
    else if (action == "soloMaster")
        command(jaras::CommandKind::solo);
    else if (action == "volumeTrack")
        command(jaras::CommandKind::volume, track, midiFaderGain(value));
    else if (action == "volumeMaster")
        command(jaras::CommandKind::volume, {}, midiFaderGain(value));
    else if (action == "panTrack")
        command(jaras::CommandKind::pan, track, value * 2 - 1);
    else if (action == "playStop")
        command(session.transport().playing ? jaras::CommandKind::stop : jaras::CommandKind::play);
    else if (action == "play")
        command(jaras::CommandKind::play);
    else if (action == "stop")
        command(jaras::CommandKind::stop);
    else if (action == "pause")
        command(jaras::CommandKind::pause);
    else if (action == "subPlayStop")
        command(session.transport().subPlay.playing ? jaras::CommandKind::subStop
                                                    : jaras::CommandKind::subPlay);
    else if (action == "subPlay")
        command(jaras::CommandKind::subPlay);
    else if (action == "repeatPlayback")
        command(jaras::CommandKind::toggleLoop);
    else if (action == "toggleMultiLoopBypass")
        command(jaras::CommandKind::toggleMultiLoopBypass);
    else if (action == "ignoreNext")
        command(jaras::CommandKind::ignoreNext);
    else if (action == "tempoDown" || action == "tempoUp")
        session.configureTiming(jlimit(60., 300., song->bpm + (action == "tempoUp" ? 1 : -1)),
                                song->beatsPerBar, song->beatUnit,
                                song->timeSettings.value_or(jaras::ProjectTimeSettings{}));
    else if (action == "tapTempo") {
        const double now = Time::getMillisecondCounterHiRes() / 1000, interval = now - lastTap;
        lastTap = now;
        if (interval < .2 || interval > 2) {
            tapIntervals.clear();
            return;
        }
        tapIntervals.push_back(interval);
        if (tapIntervals.size() > 6)
            tapIntervals.erase(tapIntervals.begin());
        double sum = 0;
        for (auto x : tapIntervals)
            sum += x;
        session.configureTiming(jlimit(60., 300., 60 * tapIntervals.size() / sum),
                                song->beatsPerBar, song->beatUnit,
                                song->timeSettings.value_or(jaras::ProjectTimeSettings{}));
    } else if (action == "tunerDown" || action == "tunerUp") {
        if (!tuner->region())
            return;
        const auto region = tuner->region()->id;
        const auto songID = song->id;
        const int delta = action == "tunerUp" ? 1 : -1;
        session.edit([&](jaras::Project &p) {
            jaras::Engine edit;
            edit.loadProject(p);
            edit.execute({jaras::CommandKind::select, songID});
            int current = 0;
            for (const auto &part : edit.currentSong()->parts)
                if (part.id == region)
                    current = part.pitchSemitones.value_or(0);
            const auto &parts = edit.currentSong()->parts;
            auto selected = std::find_if(parts.begin(), parts.end(),
                                         [&](const auto &p) { return p.id == region; });
            auto tracks =
                selected->pitchTrackIDs.value_or(regionPitch::defaults(*edit.currentSong(), false));
            auto groups =
                selected->pitchGroupIDs.value_or(regionPitch::defaults(*edit.currentSong(), true));
            edit.setRegionPitch(region, jlimit(-12, 12, current + delta), std::move(tracks),
                                std::move(groups));
            p = edit.project();
        });
    } else if (action == "addTrack")
        createTrack();
    else if (action == "projectStart" || action == "projectEnd")
        command(jaras::CommandKind::editSeek, {}, action == "projectStart" ? 0 : song->duration);
    else if (action == "nextRegion" || action == "previousRegion" || action == "setlistUp" ||
             action == "setlistDown" || action == "partsUp" || action == "partsDown") {
        std::vector<const jaras::Part *> parts;
        const bool child = action.startsWith("parts");
        for (const auto &part : song->parts)
            if (child ? part.parentRegionID == session.transport().regionId : !part.parentRegionID)
                parts.push_back(&part);
        std::sort(parts.begin(), parts.end(),
                  [](auto *a, auto *b) { return a->startTime < b->startTime; });
        if (!child) {
            const auto ordered = setlist->orderedRoots();
            parts.clear();
            for (const auto &id : ordered)
                for (const auto &part : song->parts)
                    if (part.id == id) {
                        parts.push_back(&part);
                        break;
                    }
        }
        if (parts.empty())
            return;
        const bool forward = action == "nextRegion" || action.endsWith("Down");
        int index = -1;
        for (int i = 0; i < (int)parts.size(); ++i)
            if (parts[(size_t)i]->id == session.transport().regionId)
                index = i;
        if (child) {
            const auto pos = session.transport().editPosition;
            index = 0;
            for (int i = 0; i < (int)parts.size(); ++i)
                if (parts[(size_t)i]->startTime <= pos)
                    index = i;
        }
        index = jlimit(0, (int)parts.size() - 1, index + (forward ? 1 : -1));
        command(child                         ? jaras::CommandKind::editSeek
                : session.transport().playing ? jaras::CommandKind::queueRegion
                                              : jaras::CommandKind::selectRegion,
                child ? ID{} : parts[(size_t)index]->id,
                child ? parts[(size_t)index]->startTime : 0);
    } else if (action == "nextTimelinePoint" || action == "previousTimelinePoint") {
        std::vector<double> points{0, song->duration};
        for (const auto &part : song->parts) {
            points.push_back(part.startTime);
            points.push_back(part.endTime);
        }
        if (song->markers)
            for (const auto &marker : *song->markers)
                points.push_back(marker.position);
        std::sort(points.begin(), points.end());
        const auto at = session.transport().editPosition;
        double dest = at;
        if (action == "nextTimelinePoint") {
            for (auto point : points)
                if (point > at + .0001) {
                    dest = point;
                    break;
                }
        } else
            for (auto point : points)
                if (point < at - .0001)
                    dest = point;
        command(jaras::CommandKind::editSeek, {}, dest);
    } else if (action == "toggleAuto") {
        auto state = session.project().regionSetlist.value_or(jaras::RegionSetlist{});
        state.autoAdvance = !state.autoAdvance;
        session.configureSetlist(state);
    } else if (action == "toggleTracks")
        showMixer();
    else if (action == "toggleSetlist") {
        setlistVisible = !setlistVisible;
        resized();
    } else if (action == "toggleParts")
        setlist->toggleParts();
    else if (action == "toggleVideo" || action == "toggleTeleprompter") {
        const String name = action == "toggleVideo" ? "Video" : "Teleprompter 1";
        auto it = floatingWindows.find(name);
        if (it != floatingWindows.end() && it->second->isVisible())
            it->second->setVisible(false);
        else if (action == "toggleVideo")
            openVideo();
        else
            showTeleprompter();
    } else if (action == "splitItems") {
        const auto songID = song->id, chosen = selectedClip;
        const auto at = session.transport().editPosition;
        session.edit([&](jaras::Project &p) {
            for (auto &s : p.songs)
                if (s.id == songID)
                    clipEditing::split(s, chosen, at);
        });
    } else if (action == "normalizeItems") {
        if (selectedClip.empty())
            return;
        ModalSheet::open(*this, "Normalizar",
                         std::make_unique<NormalizationPanel>(session, appearance, selectedClip),
                         360, 230);
    } else if (action == "createTempoMarker") {
        const auto songID = song->id;
        const double at = session.transport().editPosition;
        session.edit([&](jaras::Project &p) {
            jaras::Engine edit;
            edit.loadProject(p);
            edit.execute({jaras::CommandKind::select, songID});
            edit.setMarker(uuid(), "TEMPO", at, 0x999999, song->bpm, song->beatsPerBar,
                           song->beatUnit, std::string("global"));
            p = edit.project();
        });
    }
}
} // namespace catlive
