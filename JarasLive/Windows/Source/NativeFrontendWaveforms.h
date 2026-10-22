#pragma once
#include "Session.h"
#include "WaveformCache.h"
#include <deque>

namespace catlive {
namespace nativeWaveforms {
// The source mapping is the same as WaveformRenderer: sourceOffset and
// playbackRate precede looping; a non-repeating prefix is retained.
template<class Query>
std::pair<float,float> range(const jaras::AudioClip &clip, double localStart, double localEnd, Query query) {
    const double rate=std::max(.001,clip.playbackRate), loop=clip.loopLength.value_or(0), loopStart=clip.loopStart.value_or(0);
    double first=clip.sourceOffset+std::max(0.,localStart)*rate;
    const double last=clip.sourceOffset+std::max(0.,localEnd)*rate;
    float low=0,high=0;bool any=false;
    auto add=[&](double start,double end) {
        if(end<=start)return;const auto value=query(start,end);
        if(!any){low=value.first;high=value.second;any=true;}else{low=std::min(low,value.first);high=std::max(high,value.second);}
    };
    if(loop<=0){add(first,last);return {low,high};}
    if(first<loopStart){add(first,std::min(last,loopStart));first=loopStart;}
    if(last<=first)return {low,high};
    if(last-first>=loop){add(loopStart,loopStart+loop);return {low,high};}
    const double source=loopStart+std::fmod(first-loopStart,loop), count=last-first;
    const double prefix=std::min(count,loopStart+loop-source);
    add(source,source+prefix);if(prefix<count)add(loopStart,loopStart+count-prefix);
    return {low,high};
}
inline int channel(int mode,int channel,int sourceChannels) {
    return mode==1?0:mode==2?std::min(1,sourceChannels-1):mode==3&&sourceChannels>1?sourceChannels:
        mode==4&&sourceChannels>1&&channel<2?1-channel:channel;
}
}

// Message-thread request facade; all filesystem/cache/PCM work stays on a
// bounded worker. Each accepted request replies once unless its owner closes.
class NativeFrontendWaveforms final {
public:
    using Reply=std::function<void(var,String)>;
    explicit NativeFrontendWaveforms(Session &session):state(std::make_shared<State>()) {state->session=&session;}
    ~NativeFrontendWaveforms(){invalidate();state->alive.store(false);}
    void invalidate() {
        for(auto &entry:state->requests)entry.second->cancelled.store(true);
        state->sourceCancellation->store(true);
        state->sourceCancellation=std::make_shared<std::atomic<bool>>(false);
        state->requests.clear();++state->generation;
    }
    void request(const var &payload,Reply reply) {
        auto &session=*state->session;
        const auto project=str(payload,"projectID"), clipID=str(payload,"clipID");
        const auto revision=(int64)get(payload,"revision",(int64)-1);
        const double start=num(payload,"start",std::numeric_limits<double>::quiet_NaN()), end=num(payload,"end",std::numeric_limits<double>::quiet_NaN());
        const double requestedWidth=num(payload,"pixelWidth");
        if(project!=text(session.project().id)||revision<0||(uint64)revision!=session.revision){reply({},"Stale waveform project or revision.");return;}
        if(!std::isfinite(start)||!std::isfinite(end)||!std::isfinite(end-start)||end<=start||!std::isfinite(requestedWidth)||requestedWidth<1||requestedWidth>16384||clipID.isEmpty()){
            reply({},"Invalid waveform viewport.");return;
        }
        const jaras::AudioClip *found=nullptr;std::optional<jaras::AudioFile> media;
        if(const auto *song=session.song())for(const auto &track:song->tracks)for(const auto &clip:track.clips)if(clip.id==utf8(clipID)){
            found=&clip;media=clip.audioFile?clip.audioFile:track.audioFile;break;
        }
        if(!found||!media||found->text||(found->midi&&!found->frozenMIDI.value_or(false))){reply({},"Item has no audio waveform source.");return;}
        if(session.busy){reply({},"Project is loading.");return;}
        Request job;job.clip=waveformClip(*found);job.project=project;job.clipID=clipID;job.revision=(uint64)revision;
        job.start=std::max(start,found->startTime);job.end=std::min(end,found->startTime+found->duration);job.secondsPerColumn=(end-start)/requestedWidth;
        if(job.end<=job.start){reply({},"Waveform viewport is outside the item.");return;}
        try {job.file=ProjectCodec::resolveMedia(session.mediaDirectory,media->path,false);}catch(const std::exception &error){reply({},String::fromUTF8(error.what()));return;}
        if(state->project!=project){invalidate();state->project=project;}
        auto old=state->requests.find(clipID);if(old!=state->requests.end())old->second->cancelled.store(true);
        if(state->pending.load()>=48){reply({},"Waveform queue is busy; retry the visible viewport.");return;}
        auto token=std::make_shared<Token>();state->requests[clipID]=token;job.generation=state->generation;
        job.sourceCancellation=state->sourceCancellation;
        const auto shared=state;shared->pending.fetch_add(1);
        workers().addJob([shared,token,job=std::move(job),reply=std::move(reply)]() mutable {
            var result;String error;
            try {
                if(!shared->alive.load()||token->cancelled.load())error="Waveform request superseded.";
                else result=render(*shared,job,*token);
            }catch(const std::exception &failure){error=String::fromUTF8(failure.what());}
            shared->pending.fetch_sub(1);
            MessageManager::callAsync([shared,token,job=std::move(job),result=std::move(result),error=std::move(error),reply=std::move(reply)]() mutable {
                if(!shared->alive.load())return;
                const auto current=shared->requests.find(job.clipID);
                const bool superseded=token->cancelled.load()||shared->generation!=job.generation||current==shared->requests.end()||current->second!=token;
                if(current!=shared->requests.end()&&current->second==token)shared->requests.erase(current);
                auto &session=*shared->session;
                if(superseded||text(session.project().id)!=job.project||session.revision!=job.revision){reply({},"Waveform request superseded.");return;}
                reply(std::move(result),std::move(error));
            });
        });
    }
private:
    struct Token {std::atomic<bool> cancelled{false};};
    struct Request {jaras::AudioClip clip;File file;String project,clipID;uint64 revision=0,generation=0;double start=0,end=0,secondsPerColumn=0;std::shared_ptr<std::atomic<bool>> sourceCancellation;};
    struct Source {std::shared_ptr<const WaveformCache::Data> data;uint64 used=0;};
    struct Page {std::shared_ptr<const WaveformCache::Detail> data;uint64 used=0;};
    struct State {
        Session *session=nullptr;std::atomic<bool> alive{true};std::atomic<unsigned> pending{0};
        // Message-thread ownership; workers only read Request snapshots/tokens.
        String project;uint64 generation=0;std::map<String,std::shared_ptr<Token>> requests;
        std::shared_ptr<std::atomic<bool>> sourceCancellation=std::make_shared<std::atomic<bool>>(false);
        // Only the shared serial worker touches immutable-source/detail caches.
        std::map<String,Source> sources;std::map<String,Page> pages;uint64 clock=0;
    };
    std::shared_ptr<State> state;
    static jaras::AudioClip waveformClip(const jaras::AudioClip &source) {
        // No embedded peaks, MIDI notes or plugin blobs are copied on the UI
        // thread just to draw a visible piece of this item.
        jaras::AudioClip clip;clip.id=source.id;clip.startTime=source.startTime;clip.duration=source.duration;
        clip.sourceOffset=source.sourceOffset;clip.playbackRate=source.playbackRate;
        clip.loopStart=source.loopStart;clip.loopLength=source.loopLength;clip.channelMode=source.channelMode;
        clip.gain=source.gain;clip.normalizationGain=source.normalizationGain;clip.phaseInverted=source.phaseInverted;
        clip.fadeIn=source.fadeIn;clip.fadeOut=source.fadeOut;clip.fadeInCurve=source.fadeInCurve;clip.fadeOutCurve=source.fadeOutCurve;
        clip.fadeInSCurve=source.fadeInSCurve;clip.fadeOutSCurve=source.fadeOutSCurve;return clip;
    }
    static ThreadPool &workers(){static ThreadPool pool(1);return pool;}
    static void check(const State &state,const Token &token){if(!state.alive.load()||token.cancelled.load())throw std::runtime_error("Waveform request superseded.");}
    static void trim(State &state) {
        size_t mapped=0;for(const auto &s:state.sources)mapped+=s.second.data->mappedBytes()+s.second.data->owned.getSize();
        while(state.sources.size()>24||mapped>128*1024*1024){auto oldest=state.sources.begin();for(auto i=state.sources.begin();i!=state.sources.end();++i)if(i->second.used<oldest->second.used)oldest=i;mapped-=oldest->second.data->mappedBytes()+oldest->second.data->owned.getSize();state.sources.erase(oldest);}
        size_t bytes=0;for(const auto &p:state.pages)bytes+=size_t(p.second.data->samples.getNumChannels())*size_t(p.second.data->samples.getNumSamples())*sizeof(float);
        while(state.pages.size()>32||bytes>64*1024*1024){auto oldest=state.pages.begin();for(auto i=state.pages.begin();i!=state.pages.end();++i)if(i->second.used<oldest->second.used)oldest=i;bytes-=size_t(oldest->second.data->samples.getNumChannels())*size_t(oldest->second.data->samples.getNumSamples())*sizeof(float);state.pages.erase(oldest);}
    }
    static var render(State &state,const Request &request,Token &token) {
        check(state,token);const auto file=existingMediaPath(request.file);
        if(!file.existsAsFile())throw std::runtime_error("Audio file not found.");
        const auto size=file.getSize(),modified=file.getLastModificationTime().toMilliseconds();
        const String identity=file.getFullPathName()+":"+String(size)+":"+String(modified);
        AudioFormatManager formats;registerAudioFormats(formats);std::unique_ptr<AudioFormatReader> reader;
        auto open=[&]() -> AudioFormatReader& {
            if(!reader)reader.reset(formats.createReaderFor(file));
            if(!reader)throw std::runtime_error("Cannot decode the audio waveform.");return *reader;
        };
        std::shared_ptr<const WaveformCache::Data> data;
        auto cached=state.sources.find(identity);
        if(cached!=state.sources.end()){cached->second.used=++state.clock;data=cached->second.data;}
        else {
            data=WaveformCache::cachedMetadata(file);
            // Panning or editing gain can supersede this viewport while the
            // first source analysis is still running. Finish that reusable
            // work for the next viewport; only project close/load cancels it.
            if(!data)data=WaveformCache::forAnalysis(file,open(),request.sourceCancellation.get());
            if(!state.alive.load()||request.sourceCancellation->load())throw std::runtime_error("Waveform request superseded.");
            if(!data)throw std::runtime_error("Cannot read the audio waveform.");
            state.sources[identity]={data,++state.clock};trim(state);
        }
        check(state,token);
        auto page=[&](int64 frame)->std::shared_ptr<const WaveformCache::Detail> {
            const int64 first=frame/WaveformCache::Detail::pageFrames*WaveformCache::Detail::pageFrames;
            const auto key=identity+":"+String(first);auto found=state.pages.find(key);
            if(found!=state.pages.end()){found->second.used=++state.clock;return found->second.data;}
            check(state,token);auto &decoder=open();
            if(decoder.lengthInSamples!=data->frames||decoder.sampleRate!=data->sampleRate)throw std::runtime_error("Audio file changed; request the waveform again.");
            auto result=std::make_shared<WaveformCache::Detail>();result->start=first;
            const int count=int(std::min(WaveformCache::Detail::pageFrames,data->frames-first));result->samples.setSize(data->storedChannels,count);
            if(!decoder.read(&result->samples,0,count,first,true,true))throw std::runtime_error("Cannot decode waveform detail.");
            if(data->storedChannels>data->sourceChannels){result->samples.clear(data->sourceChannels,0,count);for(int c=0;c<data->sourceChannels;++c)result->samples.addFrom(data->sourceChannels,0,result->samples,c,0,count,1.f/data->sourceChannels);}
            state.pages[key]={result,++state.clock};trim(state);return result;
        };
        bool usedPCM=false,usedPeaks=false;
        auto rawRange=[&](int channel,double start,double end)->std::pair<float,float> {
            if(end<=0||start>=data->duration||end<=start)return {};
            const bool includesSilence=start<0||end>data->duration;
            const int64 a=std::max<int64>(0,(int64)std::floor(std::max(0.,start)*data->sampleRate+1.e-7));
            const int64 b=std::min(data->frames,(int64)std::ceil(std::min(data->duration,end)*data->sampleRate-1.e-7));
            if(b<=a)return {};
            if(b-a>=256){usedPeaks=true;auto p=data->rangeFrames(channel,a,b);if(includesSilence){p.first=std::min(0.f,p.first);p.second=std::max(0.f,p.second);}return p;}
            usedPCM=true;float low=includesSilence?0.f:std::numeric_limits<float>::max(),high=includesSilence?0.f:std::numeric_limits<float>::lowest();
            auto samples=page(a);
            for(int64 n=a;n<b;++n){if(n>=samples->start+samples->samples.getNumSamples())samples=page(n);const float v=samples->sample(channel,n);if(std::isfinite(v)){low=std::min(low,v);high=std::max(high,v);}}
            return low<=high?std::pair<float,float>{low,high}:std::pair<float,float>{};
        };
        const auto &clip=request.clip;const int mode=clip.channelMode.value_or(0);
        const int channels=(mode==0||mode==4)?data->sourceChannels:1;
        const int budget=std::min(4096,32768/std::max(1,channels));
        // Anchor source columns independently of the viewport. Fractional pans
        // must not repartition attacks or make their apparent height flicker.
        const double anchor=clip.startTime-clip.sourceOffset/std::max(.001,clip.playbackRate);
        double step=request.secondsPerColumn;
        auto count=[&]{return std::ceil((request.end-anchor)/step)-std::floor((request.start-anchor)/step);};
        while(count()>budget)step*=std::max(1.01,std::ceil(count()/budget));
        const double columnStart=anchor+std::floor((request.start-anchor)/step)*step;
        const int width=std::max(1,std::min(budget,(int)count()));
        auto lows=std::vector<std::vector<float>>(static_cast<size_t>(channels),std::vector<float>(static_cast<size_t>(width)));
        auto highs=lows;
        for(int x=0;x<width;++x){
            if((x&63)==0)check(state,token);
            const double a=std::max(0.,columnStart+x*step-clip.startTime);
            const double b=std::min(clip.duration,columnStart+(x+1)*step-clip.startTime);
            for(int c=0;c<channels;++c){
                const int source=nativeWaveforms::channel(mode,c,data->sourceChannels);
                const auto values=nativeWaveforms::range(clip,a,b,[&](double from,double to){return rawRange(source,from,to);});
                lows[size_t(c)][size_t(x)]=values.first;highs[size_t(c)][size_t(x)]=values.second;
            }
        }
        Array<var> output;
        for(int c=0;c<channels;++c){
            Array<var> low,high;low.ensureStorageAllocated(width);high.ensureStorageAllocated(width);
            for(int x=0;x<width;++x){low.add(lows[size_t(c)][size_t(x)]);high.add(highs[size_t(c)][size_t(x)]);}
            auto channel=object();put(channel,"min",low);put(channel,"max",high);output.add(channel);
        }
        check(state,token);
        auto result=object();put(result,"projectID",request.project);put(result,"revision",(int64)request.revision);put(result,"clipID",request.clipID);
        put(result,"start",request.start);put(result,"end",request.end);put(result,"pixelWidth",width);put(result,"channels",output);put(result,"columnStart",columnStart);put(result,"columnDuration",step);
        put(result,"sampleRate",data->sampleRate);put(result,"sourceChannels",data->sourceChannels);put(result,"quality",usedPCM?(usedPeaks?"mixed":"pcm"):"peaks");
        put(result,"clipStart",clip.startTime);put(result,"clipEnd",clip.startTime+clip.duration);put(result,"gain",clip.gain.value_or(1));put(result,"normalizationGain",clip.normalizationGain.value_or(1));put(result,"phaseInverted",clip.phaseInverted.value_or(false));put(result,"channelMode",mode);
        put(result,"sourceOffset",clip.sourceOffset);put(result,"playbackRate",clip.playbackRate);put(result,"loopStart",clip.loopStart.value_or(0));put(result,"loopLength",clip.loopLength.value_or(0));
        put(result,"fadeIn",clip.fadeIn.value_or(0));put(result,"fadeOut",clip.fadeOut.value_or(0));put(result,"fadeInCurve",clip.fadeInCurve.value_or(0));put(result,"fadeOutCurve",clip.fadeOutCurve.value_or(0));put(result,"fadeInSCurve",clip.fadeInSCurve.value_or(1));put(result,"fadeOutSCurve",clip.fadeOutSCurve.value_or(1));
        return result;
    }
};
}
