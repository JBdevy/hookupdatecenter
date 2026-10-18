#pragma once
#include "PartsPanel.h"

namespace catlive {
template <typename Register>
void addPartsPanelTests(Register &&test) {
    test("PDC queue presentation follows rendered audio and preserves ordered transitions", [] {
        const auto require = [](bool okay, const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        TransportPresentationQueues history;
        jaras::TransportState before; before.songId = uuid(); before.playing = true;
        before.queuedSectionMarkerId = uuid(); before.sectionQueueStartedAt = 3;
        before.queuedRegionId = uuid(); before.queueStartedAt = 2;
        auto consumed = before;
        consumed.queuedSectionMarkerId.reset(); consumed.queuedRegionId.reset();
        consumed.sectionJumpSerial++;
        history.advance(.25, 1.5, before, consumed);
        auto shown = consumed; history.apply(shown);
        require(shown.queuedSectionMarkerId == before.queuedSectionMarkerId &&
                shown.queuedRegionId == before.queuedRegionId && shown.sectionQueueStartedAt == 3,
                "Queue disappeared when the core consumed it, before the audible jump");
        history.advance(1.49, 1.5, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(shown.queuedSectionMarkerId == before.queuedSectionMarkerId,
                "Queue countdown ended before the complete latency had been rendered");
        // Repainting or waiting on the UI thread does not consume audio time.
        for (int n = 0; n < 100; ++n) { shown = consumed; history.apply(shown); }
        require(shown.queuedRegionId == before.queuedRegionId, "UI refresh advanced the audio clock");
        history.advance(.01, 1.5, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(!shown.queuedSectionMarkerId && !shown.queuedRegionId,
                "Consumed queue remained visible after its audible transition");

        history.reset();
        history.advance(.1, 1.5, before, consumed);
        auto automatic = consumed; automatic.queuedRegionId = uuid(); automatic.queueStartedAt = 10;
        history.advance(.5, 1.5, consumed, automatic);
        shown = automatic; history.apply(shown);
        require(shown.queuedRegionId == before.queuedRegionId, "Next automatic queue replaced the still audible outgoing queue");
        history.advance(1, 1.5, automatic, automatic);
        shown = automatic; history.apply(shown);
        require(!shown.queuedRegionId, "Queue history skipped its empty interval");
        history.advance(.5, 1.5, automatic, automatic);
        shown = automatic; history.apply(shown);
        require(shown.queuedRegionId == automatic.queuedRegionId && shown.queueStartedAt == 10,
                "Automatic queue did not appear with its own start position");

        history.reset(); history.advance(.1, 1.5, before, consumed);
        auto looping = consumed; looping.loop.enabled = true;
        history.command(jaras::CommandKind::escape, looping, consumed);
        shown = consumed; history.apply(shown);
        require(shown.queuedSectionMarkerId == before.queuedSectionMarkerId &&
                shown.queuedRegionId == before.queuedRegionId,
                "Cancelling a loop also hid a pending audible jump");
        history.command(jaras::CommandKind::cancelSection, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(!shown.queuedSectionMarkerId && shown.queuedRegionId == before.queuedRegionId,
                "Manual section cancellation was delayed or erased an unrelated region queue");
        auto manual = consumed; manual.queuedRegionId = uuid();
        history.command(jaras::CommandKind::queueRegion, consumed, manual);
        shown = manual; history.apply(shown);
        require(shown.queuedRegionId == manual.queuedRegionId, "New user queue resurrected an old pending target");
        history.reset(); history.advance(.1, 1.5, before, consumed);
        history.command(jaras::CommandKind::seek, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(!shown.queuedRegionId && !shown.queuedSectionMarkerId, "Seek retained stale queue history");
        history.advance(.1, 1.5, before, consumed);
        auto stopped = consumed; stopped.playing = false;
        auto edit = stopped; edit.position = 42;
        history.command(jaras::CommandKind::editSeek, stopped, edit);
        shown = edit; history.apply(shown);
        require(!shown.queuedRegionId, "Stopped edit seek retained a queue from the preceding audio tail");
        history.advance(.1, 1.5, before, consumed);
        history.advance(.1, 0, consumed, consumed);
        shown = consumed; history.apply(shown);
        require(!shown.queuedRegionId, "Removing PDC retained delayed queue state");
    });
    test("Parts presentation uses audible regions and does not count down to an already rendered boundary", [] {
        const auto require = [](bool okay, const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        jaras::Song song;
        const auto group = uuid(), first = uuid(), second = uuid();
        song.parts = {{group, "Group", 0, 20}, {first, "First", 0, 10}, {second, "Second", 10, 20}};
        song.parts[1].parentRegionID = group; song.parts[2].parentRegionID = group;
        song.markers = std::vector<jaras::TimelineMarker>{{uuid(), "Verse", 5, 0}, {uuid(), "Chorus", 9, 0}};
        for (auto &marker : *song.markers) marker.section = true;
        song.markers->push_back({uuid(), "Tempo", 4.2, 0});
        song.markers->back().section = true; song.markers->back().tempoBPM = 125;
        jaras::TransportState audible; audible.playing = true; audible.position = 3.8;
        audible.regionId = second; // Scheduling may already be in another region.
        audible.queuedSectionMarkerId = song.markers->at(1).id; audible.sectionQueueStartedAt = 5.3;
        const auto *part = partsPresentation::region(song, audible);
        require(part && part->id == first, "Parts selected the future core region instead of the audible child");
        require(partsPresentation::trigger(song, *part, audible) == 9,
                "PDC countdown targeted a boundary that had already been rendered when the jump was armed");
        audible.sectionQueueStartedAt = 3.8;
        require(partsPresentation::trigger(song, *part, audible) == 5, "Tempo marker changed the audible section boundary");
        audible.position = 11; audible.ignoreNextRegionId = first; audible.ignoreNextEnd = 13;
        part = partsPresentation::region(song, audible);
        require(part && part->id == first && partsPresentation::end(*part, audible) == 13,
                "Ignore Next lost its audible owner or tail end");
        audible.ignoreNextRegionId = second; audible.ignoreNextEnd = 18; audible.position = 8;
        part = partsPresentation::region(song, audible);
        require(part && part->id == first && partsPresentation::end(*part, audible) == 10,
                "Future Ignore Next state changed the preceding audible region end");
        audible.paused = true; audible.playing = false;
        require(!partsPresentation::trigger(song, *part, audible), "Paused presentation retained a running countdown");
    });
    test("Parts playback and countdown follow the actual queued jump boundary", [] {
        const auto require = [](bool okay, const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        Session session; session.inspection = true;
        jaras::Project project; project.id = uuid(); project.name = "Parts";
        jaras::Song song; song.id = uuid(); song.name = "Song"; song.duration = 12; song.bpm = 120;
        const auto region = uuid(), verse = uuid(), chorus = uuid(), bridge = uuid();
        song.parts = {{region, "Song", 0, 12}};
        song.markers = std::vector<jaras::TimelineMarker>{
            {verse, "Verse", 2, 0}, {chorus, "Chorus", 5, 0}, {bridge, "Bridge", 9, 0}};
        for (auto &marker : *song.markers) marker.section = true;
        // An ordinary cue must not shorten a section's progress or countdown.
        song.markers->push_back({uuid(), "Lighting cue", 4.5, 0});
        project.songs = {song}; session.core.loadProject(project);
        PartsPanel panel(session, [](String error) { throw std::runtime_error(utf8(error)); });
        panel.setSize(720, 180);
        auto pad = [&](int index) {
            panel.refresh();
            return list(get(get(panel.diagnostics(), "current"), "pads"))[index];
        };
        auto fraction = [&](int index, double expected) {
            require(std::abs((double)get(pad(index), "progress") - expected) < 1e-6,
                    "Parts bar fraction disagrees with the transport boundary");
        };
        session.core.execute({jaras::CommandKind::selectRegion, region});
        session.core.execute({jaras::CommandKind::play}); session.core.advance(3);
        fraction(1, 1. / 3.);
        session.core.execute({jaras::CommandKind::queueSection, bridge});
        require((bool)get(pad(3), "queued"), "Destination was not armed"); fraction(3, 1);
        session.core.advance(1); fraction(3, .5); fraction(1, 2. / 3.);
        session.core.advance(1.25);
        require(std::abs(session.transport().position - 9.25) < 1e-6,
                "Queued jump lost the remaining portion of the playback tick");
        require(!(bool)get(pad(3), "queued") && (bool)get(pad(3), "active"),
                "Countdown did not turn into playback progress at the destination");
        fraction(3, .25 / 3.);
        session.core.execute({jaras::CommandKind::queueSection, verse}); fraction(1, 1);
        session.core.advance(1.375); fraction(1, .5);
        session.core.execute({jaras::CommandKind::cancelSection}); fraction(1, 0);
        session.core.execute({jaras::CommandKind::pause}); fraction(3, 0);
    });
}
} // namespace catlive
