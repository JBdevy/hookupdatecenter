#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Import/TrackTaxonomy.hpp"
#include <iostream>
#include <stdexcept>
using namespace jaras;
static void expect(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
int main() {
    Project p; p.id="project"; p.name="Show"; p.songs={{"one","One",10,120,{{"track","Click",{"click"}}},{}},{"two","Two",20,100,{},{}},{"three","Three",30,90,{},{}}};
    p.setlists={{"setlist","Setlist",{"one","two","three"}}};
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
    e.execute({CommandKind::toggleLoop}); e.advance(35); expect(e.transport().playing && e.transport().position==5,"loop wraps");
    e.finishCurrentSong(true); e.advance(40); expect(!e.transport().playing && e.transport().position==30,"revocation waits for boundary even with loop");
    e.execute({CommandKind::volume,"track",0.3}); expect(e.project().songs[0].tracks[0].volume==0.3,"mixer volume");
    e.execute({CommandKind::mute,"track"}); expect(e.project().songs[0].tracks[0].mute,"mute");
    TrackTaxonomy taxonomy; expect(taxonomy.classify("MÉTRÔNOMO.wav").id=="click","accents and case"); expect(taxonomy.classify("Sanfona L.wav").id=="accordion","role independent of channel suffix"); expect(taxonomy.classify("clickbait.wav").id=="other","word boundaries"); taxonomy.addAlias("violao",{"acousticGuitar"}); expect(taxonomy.classify("Violão.wav").id=="acousticGuitar","extensible taxonomy");
    p.songs[0].tracks[0].audioFile=AudioFile{"../private.wav",{}}; bool rejected=false; try { validate(p); } catch(...) { rejected=true; } expect(rejected,"portable paths");
    std::cout << "JARAS_CORE_OK\n";
}
