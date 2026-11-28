#include "../../Core/Songs/RegionTempoAdjustment.hpp"
#define DR_WAV_IMPLEMENTATION
#include "../../Core/Audio/RegionTempoRender.hpp"
#include <cassert>
#include <chrono>
#include <filesystem>
#include <iostream>
using jaras::regionTempo::Plan;
int main() {
    jaras::Song s; s.id="music";s.duration=20;s.bpm=120;
    s.parts={{"a","A",2,6},{"b","B",9,14}};
    jaras::TimelineMarker m;m.id="tempo-1";m.position=2;m.tempoBPM=90.5;m.tempoPlaybackRate=1;
    auto n=m;n.id="tempo-2";n.position=4;n.tempoBPM=150;
    try{Plan absent(s,s.parts[0],120);return 1;}catch(const std::invalid_argument& e){assert(std::string(e.what()).find("Nenhum")!=std::string::npos);}
    s.markers={{m}};try{Plan same(s,s.parts[0],120);return 2;}catch(const std::invalid_argument& e){assert(std::string(e.what()).find("dois")!=std::string::npos);}
    s.markers->push_back(n);
    auto named=m;named.id="cue";named.tempoBPM.reset();named.position=5;s.markers->push_back(named);
    jaras::Track t;t.id="t";
    jaras::AudioClip inside;inside.id="clip";inside.startTime=2;inside.duration=4;
    auto later=inside;later.id="later";later.startTime=10;t.clips={inside,later};s.tracks={t};
    Plan plan(s,s.parts[0],120);
    const double after=2+2*(90.5+150)/120;
    assert(std::abs(plan.time.position(6)-after)<1e-10);
    jaras::Project project;project.songs={s};
    auto& song=project.songs.front();
    plan.apply(project,song,song.parts[0],[]{return std::string("restore");});
    assert(std::abs(song.parts[1].startTime-song.parts[0].endTime-3)<1e-10);
    assert(std::abs(song.tracks[0].clips[1].startTime-song.parts[1].startTime-1)<1e-10);
    assert(*jaras::tempoPlayback::active(song,3)->tempoBPM==120);
    assert(*jaras::tempoPlayback::active(song,7)->tempoBPM==150);
    auto integer=s;integer.markers->at(0).tempoBPM=90;Plan integerPlan(integer,integer.parts[0],110);
    assert(integerPlan.edges.size()==3);
    {
        auto clickSong=s;
        clickSong.parts.front().endTime=50;
        clickSong.markers->at(0).tempoBPM=119.5;
        clickSong.markers->at(1).tempoBPM=121.5;
        Plan measured(clickSong,clickSong.parts.front(),127.5);
        std::vector<double> pulses;
        for(int i=0;i<64;++i) {
            if(i==21)continue; // a missing quarter note must keep its place
            pulses.push_back(2.2+.5*i+(.015*(i%3-1)));
        }
        auto clock=measured.time;
        measured.alignToClick(pulses);
        const double first=measured.time.position(pulses.front());
        for(size_t i=0;i<pulses.size();++i) {
            const double expected=first+(i+(i>=21?1:0))*60./127.5;
            assert(std::abs(measured.time.position(pulses[i])-expected)<1e-8);
            assert(std::abs(measured.time.inverse(expected)-pulses[i])<1e-8);
        }
        assert(std::abs(first-clock.position(pulses.front()))<1e-9);
        assert(std::abs(measured.time.position(53)-measured.time.position(50)-3)<1e-9);
        Plan noClick(clickSong,clickSong.parts.front(),127.5);
        noClick.alignToClick({2.1,2.35,2.6,2.85,3.1}); // subdivisions alone are ambiguous
        assert(noClick.edges.size()==3);
    }
    auto dir=std::filesystem::temp_directory_path()/("catlive-fixed-tempo-qa-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(dir);struct Cleanup{std::filesystem::path path;~Cleanup(){std::filesystem::remove_all(path);}} cleanup{dir};
    auto input=dir/"original.wav",output=dir/"adjusted.wav";const int sr=48000;
    drwav_data_format f{drwav_container_riff,DR_WAVE_FORMAT_IEEE_FLOAT,2,sr,32};drwav wave;assert(drwav_init_file_write(&wave,input.string().c_str(),&f,nullptr));
    std::vector<float> pcm(2*4*sr);
    for(int i=0;i<4*sr;++i){pcm[2*i]=.4f*std::sin(i*2*3.141592653589793*440/sr);pcm[2*i+1]=.17f*std::sin(i*2*3.141592653589793*220/sr);}
    assert(drwav_write_pcm_frames(&wave,4*sr,pcm.data())==4*sr);drwav_uninit(&wave);
    std::vector<catlive::regionTempo::Anchor> anchors;for(auto e:plan.edges)anchors.push_back({e-2,plan.time.position(e)-2});
    double last=-1;catlive::regionTempo::render(input,output,anchors,[&](double p){assert(p>=last);last=p;return true;});assert(last==1);
    assert(drwav_init_file(&wave,output.string().c_str(),nullptr));assert(wave.totalPCMFrameCount==static_cast<drwav_uint64>(std::llround((after-2)*sr)));
    pcm.resize(wave.totalPCMFrameCount*2);drwav_read_pcm_frames_f32(&wave,wave.totalPCMFrameCount,pcm.data());drwav_uninit(&wave);
    for(double time:{.3,2.4})for(int c=0;c<2;++c){int index=int(time*sr),cross=0;for(int i=index;i<index+sr/4;++i)if(pcm[2*i+c]<=0 && pcm[2*i+2+c]>0)++cross;assert(std::abs(cross-(c?55:110))<=2);}
    bool cancelled=false;try{catlive::regionTempo::render(input,dir/"cancel.wav",anchors,[](double p){return p<.2;});}catch(const std::runtime_error&){cancelled=true;}
    assert(cancelled && !std::filesystem::exists(dir/"cancel.wav") && std::filesystem::exists(input));
    std::cout<<"ADJUST_BPM_INTEGER_FRACTIONAL_MARKERS_STEREO_FREQUENCY_FRAMES_GAPS_CANCEL_OK\n";
}
