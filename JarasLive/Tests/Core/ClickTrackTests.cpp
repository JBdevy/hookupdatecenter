#include "Transport/Engine.hpp"
#include <cassert>
#include <iostream>
using namespace jaras;
static void expect(bool condition, const char* message) { if(!condition) { std::cerr << message; std::abort(); } }
int main() {
    {
        Project p; p.id="click-project"; p.name="Generated click";
        Song song{"click-song","Song",30,120,{},{}};
        Track click; click.id="generated-click"; click.name="Click"; click.role.id="generatedClick";
        AudioClip item; item.id="click-item"; item.name="Click"; item.startTime=2; item.duration=8;
        click.clips={item}; song.tracks={click}; song.parts={{"region","Song",2,10}}; p.songs={song};
        Engine e; e.loadProject(p);
        e.execute({CommandKind::volume,click.id,0.5}); e.execute({CommandKind::mute,click.id}); e.execute({CommandKind::solo,click.id});
        expect(e.currentSong()->tracks[0].volume==0.5 && e.currentSong()->tracks[0].mute && e.currentSong()->tracks[0].solo,"Click exposes fader, mute and solo");
        e.moveRegion("region",15);
        expect(e.currentSong()->tracks[0].clips[0].startTime==15,"Generated click follows a moved region");
        auto invalid=p; auto duplicate=click; duplicate.id="duplicate-click"; duplicate.clips.clear(); invalid.songs[0].tracks.push_back(duplicate);
        bool rejected=false; try { validate(invalid); } catch (...) { rejected=true; }
        expect(rejected,"Only one generated Click track is allowed");
        invalid=p; invalid.songs[0].tracks[0].recordingFormat="wav";
        rejected=false; try { validate(invalid); } catch (...) { rejected=true; }
        expect(rejected,"Click cannot be a recording track");
        invalid=p; invalid.songs[0].tracks[0].clips[0].audioFile=AudioFile{"Stems/file.wav"};
        rejected=false; try { validate(invalid); } catch (...) { rejected=true; }
        expect(rejected,"Click items use the bundled generator instead of source audio");
    }
    std::cout << "CLICK_TRACK_CORE_OK controls, move, validation\n";
}
