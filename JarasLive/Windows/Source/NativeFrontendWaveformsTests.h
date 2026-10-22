#pragma once
#include "NativeFrontendWaveforms.h"
#include "FloatingControlTests.h"
namespace catlive::frontendWaveformTests {
template<class Test,class Require>
void run(Test test,Require require,const File &directory) {
    test("Frontend waveforms map trim rate loop and channel modes using real PCM",[&] {
        const auto folder=directory.getNonexistentChildFile("frontend-waves","");folder.createDirectory();
        const auto file=folder.getChildFile("signal.wav");
        auto write=[&](float replacement) {
            AudioBuffer<float> pcm(2,96000);
            for(int n=0;n<96000;++n){const float value=replacement>0?replacement:n<48000?.1f:.8f;pcm.setSample(0,n,value);pcm.setSample(1,n,-value);}
            WavAudioFormat wav;auto stream=file.createOutputStream();require(stream!=nullptr,"Cannot create waveform fixture");stream->setPosition(0);stream->truncate();
            std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),48000,2,24,{},0));require(writer!=nullptr,"Cannot create PCM writer");stream.release();
            require(writer->writeFromAudioSampleBuffer(pcm,0,96000),"Cannot write waveform fixture");writer.reset();
        };write(0);
        Session session;session.inspection=true;session.audio.setOffline(true);session.mediaDirectory=folder;
        auto project=floatingControlTests::fixture();auto &clip=project.songs[0].tracks[0].clips.emplace_back();
        clip.id=uuid();clip.name="Signed real PCM";clip.audioFile=jaras::AudioFile{"signal.wav",{}};clip.startTime=10;clip.duration=1.5;clip.sourceOffset=.25;clip.playbackRate=2;clip.loopStart=.5;clip.loopLength=1;
        clip.gain=2;clip.normalizationGain=.5;clip.phaseInverted=true;clip.fadeIn=.1;
        session.core.loadProject(project);NativeFrontendWaveforms service(session);
        auto payload=[&](double start=10.35,double end=10.45,int width=128){auto p=object();put(p,"clipID",text(clip.id));put(p,"projectID",text(project.id));put(p,"revision",(int64)session.revision);put(p,"start",start);put(p,"end",end);put(p,"pixelWidth",width);return p;};
        auto await=[&](const var &p){bool done=false;var result;String error;service.request(p,[&](var r,String e){result=r;error=e;done=true;});for(int i=0;i<400&&!done;++i)floatingControlTests::pump();require(done,"Waveform worker did not reply");require(error.isEmpty(),utf8(error).c_str());return result;};
        auto result=await(payload());const auto channels=list(get(result,"channels"));
        require(channels.size()==2 && str(result,"quality")=="pcm","Close zoom did not return real stereo PCM");
        require(num(result,"gain")==2 && num(result,"normalizationGain")==.5 && flag(result,"phaseInverted"),"Waveform gain metadata changed");
        const auto lows=list(get(channels[0],"min")),highs=list(get(channels[0],"max")),right=list(get(channels[1],"min"));
        for(int x=0;x<highs.size();++x){
            const double a=num(result,"columnStart")+x*num(result,"columnDuration")-clip.startTime;
            const double b=a+num(result,"columnDuration");
            // A source-anchored bin lands exactly at frame 48000. Binary
            // timeline arithmetic can express that as .9999999999999964;
            // this is the .8 sample, not a real fragment of the .1 segment.
            const auto expected=nativeWaveforms::range(clip,a,b,[](double from,double to){return std::pair<float,float>{from<1-1.e-10?.1f:.8f,to<=1+1.e-10?.1f:.8f};});
            require(std::abs((double)highs[x]-expected.second)<1.e-5 && std::abs((double)lows[x]-expected.first)<1.e-5,"Viewport waveform differs from source trim/rate/loop at column "+String(x)+": "+String((double)lows[x],8)+","+String((double)highs[x],8));
            require(std::abs((double)right[x]+(double)highs[x])<1.e-5,"Raw signed PCM was rectified or gain applied twice");
        }
        // A fractional pan retains precisely the same source columns.
        const auto shifted=await(payload(10.3501,10.4501));
        require(std::abs(num(shifted,"columnDuration")-num(result,"columnDuration"))<1.e-10,"Pan changed waveform resolution");
        require(std::abs(std::remainder(num(shifted,"columnStart")-num(result,"columnStart"),num(result,"columnDuration")))<1.e-9,"Pan shifted source-anchored waveform columns");
        for(int mode:{4,3}){
            project.songs[0].tracks[0].clips[0].channelMode=mode;session.core.loadProject(project);++session.revision;
            auto mapped=await(payload());const auto values=list(get(list(get(mapped,"channels"))[0],"max"));
            require(mode==4?(double)values[0]<0:std::abs((double)values[0])<1.e-6,"Mono mix or swapped LR mapping differs from the audio source");
        }
        project.songs[0].tracks[0].clips[0].channelMode=0;session.core.loadProject(project);++session.revision;
        Thread::sleep(25);write(.4f);result=await(payload());
        for(auto value:list(get(list(get(result,"channels"))[0],"max")))require(std::abs((double)value-.4)<1.e-5,"Replacing a source file returned stale waveform PCM");
        bool staleDone=false;String staleError;service.request(payload(),[&](var,String error){staleDone=true;staleError=error;});++session.revision;
        for(int n=0;n<400&&!staleDone;++n)floatingControlTests::pump();require(staleDone&&staleError.isNotEmpty(),"Stale project revision delivered a waveform");
        int replies=0;String oldError,newError;service.request(payload(),[&](var,String error){oldError=error;++replies;});service.request(payload(),[&](var,String error){newError=error;++replies;});
        for(int n=0;n<400&&replies<2;++n)floatingControlTests::pump();require(replies==2&&oldError.isNotEmpty()&&newError.isEmpty(),"Superseded viewport did not cancel and settle both replies");
        const auto bounded=await(payload(10,11.5,16384));const auto count=num(bounded,"pixelWidth");const auto channelCount=list(get(bounded,"channels")).size();require(count<=4096&&count*channelCount<=32768,"Waveform response exceeds its bounded column budget");
    });
}
}
