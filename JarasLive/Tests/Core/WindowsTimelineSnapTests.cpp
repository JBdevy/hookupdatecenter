#include "../../Windows/Source/TimelineSnapping.h"
#include <iostream>

using namespace catlive::timelineGrid;
namespace {
int failures = 0;
void check(double actual, double expected, const char *label) {
    if (std::abs(actual - expected) > 1e-8) {
        std::cerr << label << ": got " << actual << ", expected " << expected << '\n';
        ++failures;
    }
}
jaras::AudioClip item(const char *id, double start, double duration) {
    jaras::AudioClip clip; clip.id = id; clip.startTime = start; clip.duration = duration;
    return clip;
}
std::vector<std::pair<jaras::ID,double>> edges(const jaras::Song &song) {
    std::vector<std::pair<jaras::ID,double>> result;
    for (const auto &track : song.tracks) for (const auto &clip : track.clips) {
        result.emplace_back(clip.id, clip.startTime);
        result.emplace_back(clip.id, clip.startTime + clip.duration);
    }
    std::sort(result.begin(), result.end(), [](const auto &a, const auto &b) {
        return a.second == b.second ? a.first < b.first : a.second < b.second;
    });
    return result;
}
}
int main() {
    jaras::Song song; song.bpm = 120; song.duration = 10000;
    song.timeSettings = jaras::ProjectTimeSettings{}; song.timeSettings->divisions = 0;
    jaras::Track track; track.id = "track"; track.clips = {item("moving",100,50)};
    song.tracks = {track};
    jaras::TransportState transport; transport.editPosition = transport.position = 100;
    const std::set<jaras::ID> selected{"moving"};
    auto index = edges(song);
    for (double scale : {.01, .05, .3, 1., 10., 100.}) {
        const double drop = 100 + 30 / scale;
        check(snapSelection(drop,song,scale,transport,false,&selected),drop,"distant drop cannot return to origin");
        check(snapSelection(drop,song,scale,transport,false,&selected,&index),drop,"cached distant drop cannot return to origin");
        check(snapSelection(drop,song,scale,transport,true,&selected,&index),drop,"Shift remains free");
    }
    song.tracks[0].clips = {item("first",100,20),item("second",160,20),item("other",1000,50)};
    index = edges(song);
    transport.editPosition = transport.position = 5000;
    const std::set<jaras::ID> multi{"first","second"};
    for (double scale : {.05,.3,1.,100.}) {
        for (const auto *cache : {static_cast<const decltype(index)*>(nullptr), static_cast<const decltype(index)*>(&index)}) {
            check(snapSelection(1000-7/scale,song,scale,transport,false,&multi,cache),1000,"nearby other item attracts");
            check(snapSelection(1000-9/scale,song,scale,transport,false,&multi,cache),1000-9/scale,"outside eight pixels stays free");
        }
    }
    check(snapSelection(163,song,1,transport,false,&multi,&index),163,"entire moving selection excluded");
    song.tracks.clear(); song.timeSettings->divisions = 4;
    check(snapSelection(1.12,song,60,transport,false),1,"nearby grid attracts");
    check(snapSelection(1.24,song,60,transport,false),1.24,"distant grid does not force drop");
    check(snapCursor(1.24,song,60,false),1,"cursor click keeps division quantization");
    for (double scale : {.05,.3,1.,100.}) {
        transport.editPosition = transport.position = 1000;
        check(snapSelection(1000+7/scale,song,scale,transport,false),1000,"nearby edit cursor remains magnetic");
    }
    jaras::Part region; region.id = "region"; region.startTime = 3.13; region.endTime = 7.17;
    song.parts = {region};
    jaras::TimelineMarker marker; marker.id = "marker"; marker.position = 9.23;
    song.markers = std::vector<jaras::TimelineMarker>{marker};
    transport.editPosition = transport.position = 5000;
    for (double scale : {20.,100.,1000.}) for (double target : {3.13,7.17,9.23})
        check(snapSelection(target+.001,song,scale,transport,false),target,"nearby region and marker preserved");
    if (failures) { std::cerr << failures << " snapping failures\n"; return 1; }
    std::cout << "WINDOWS_ITEM_SNAP_DISTANT_DROP_RADIUS_SELECTION_INDEX_SHIFT_CURSOR_PARITY_OK\n";
}
