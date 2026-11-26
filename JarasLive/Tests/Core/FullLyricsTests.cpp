#include "../../Core/Project/FullLyrics.hpp"
#include <cassert>
#include <iostream>
int main() {
    using namespace jaras;
    assert((fullLyrics::stanzas("A\n\nB\n \n\t\nC\r\nD") == std::vector<std::string>{"A\n\nB", "C\nD"}));
    Song song; Part root; root.id="root";root.name="Unified";root.startTime=10;root.endTime=100;
    Part a; a.id="a";a.parentRegionID=root.id;a.startTime=10;a.endTime=50;
    Part b; b.id="b";b.parentRegionID=root.id;b.startTime=50;b.endTime=100;
    song.parts={root,b,a};
    auto range=fullLyrics::range(song,73);
    assert(range.region=="b" && range.start==50 && range.end==100);
    int id=0;auto items=fullLyrics::items(range,"One\n\n\nTwo\n\n\nThree",[&]{return std::to_string(++id);});
    assert(items.size()==3 && items.front().startTime==50 && items.back().startTime+items.back().duration==100);
    assert(items[1].startTime==items[0].startTime+items[0].duration);
    bool rejected=false;try{fullLyrics::items(range,"No\n\nseparation",[]{return "x";});}catch(...){rejected=true;}
    assert(rejected);
    std::cout<<"FULL_LYRICS_TWO_BLANK_LINES_UNIFIED_SONG_AND_EQUAL_DURATION_OK\n";
}
