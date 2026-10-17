#pragma once
#include "PartsPanel.h"

namespace catlive {
template <typename Register>
void addPartsPanelTests(Register &&test) {
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
