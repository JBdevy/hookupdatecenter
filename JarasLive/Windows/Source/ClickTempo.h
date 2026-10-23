#pragma once
#include "WaveformCache.h"
#include "../../Core/Songs/TempoEditMap.hpp"
namespace catlive::clickTempo {
inline void require(bool ok, const std::string &message) { if (!ok) throw std::runtime_error(message); }
struct Transient { double position = 0, peak = 1; std::vector<double> shape; };
struct Section { double position, bpm; };
inline double median(std::vector<double> values) {
    std::sort(values.begin(),values.end()); const auto n=values.size();
    return n%2 ? values[n/2] : (values[n/2-1]+values[n/2])*.5;
}
inline std::optional<int> meter(const std::vector<Transient> &input, const std::atomic<bool> *cancel = nullptr) {
    std::vector<Transient> pulses;
    for(const auto &p:input)if(std::isfinite(p.peak)&&p.peak>0&&std::all_of(p.shape.begin(),p.shape.end(),[](double v){return std::isfinite(v);}))pulses.push_back(p);
    if(pulses.size()<6)return {};
    size_t dimensions=pulses.front().shape.size();for(const auto &p:pulses)dimensions=std::min(dimensions,p.shape.size());
    std::vector<std::vector<double>> features;
    for(const auto &p:pulses){std::vector<double> f{std::log2(std::max(.000001,p.peak))};f.insert(f.end(),p.shape.begin(),p.shape.begin()+dimensions);features.push_back(std::move(f));}
    const auto distance=[](const auto &a,const auto &b){double sum=0;for(size_t d=0;d<a.size();++d)sum+=(a[d]-b[d])*(a[d]-b[d]);return std::sqrt(sum);};
    for(size_t period=2;period<=12&&pulses.size()>=period*3;++period)for(size_t phase=0;phase<period;++phase){
        if (cancel && cancel->load()) return {};
        std::vector<double>a(dimensions+1),b(dimensions+1);int na=0,nb=0;
        for(size_t i=0;i<features.size();++i){auto &sum=i%period==phase?a:b;if(i%period==phase)++na;else ++nb;for(size_t d=0;d<=dimensions;++d)sum[d]+=features[i][d];}
        for(auto &v:a)v/=na;for(auto &v:b)v/=nb;
        const double contrast=distance(a,b);if(contrast<.2)continue;
        const double tolerance=std::max(.08,contrast*.35);int goodA=0,goodB=0;
        for(size_t i=0;i<features.size();++i)if(i%period==phase)goodA+=distance(features[i],a)<=tolerance;else goodB+=distance(features[i],b)<=tolerance;
        if((double)goodA/na>=.9&&(double)goodB/nb>=.9)return (int)period;
    }
    return {};
}
// Port of Application/Project/ClickTempoDetector.swift: keep measured attack
// positions, missing-beat distances, ramps and short changes, including meter.
inline std::vector<Section> sections(std::vector<double> input,int beatsPerBar=4,const std::atomic<bool>*cancel=nullptr) {
    input.erase(std::remove_if(input.begin(),input.end(),[](double value){return !std::isfinite(value)||value<0;}),input.end());
    std::sort(input.begin(),input.end());std::vector<double> times;
    for(double t:input)if(std::isfinite(t)&&t>=0&&(times.empty()||t-times.back()>.000001))times.push_back(t);
    if(times.size()<4)return {};
    if(times.size()>=10){
        const size_t tail=times.size()-1;std::vector<double> recent;
        for(size_t i=tail-8;i<tail;++i)recent.push_back(times[i]-times[i-1]);
        std::sort(recent.begin(),recent.end());const double period=(recent[3]+recent[4])*.5,gap=times[tail]-times[tail-1],distance=gap/period;
        if(std::count_if(recent.begin(),recent.end(),[&](double v){return std::abs(v-period)<=period*.04;})>=7&&distance>1.5&&std::abs(gap-std::round(distance)*period)>std::max(.030,period*.05))times.pop_back();
    }
    std::vector<double> intervals,beats{0},changes;
    for(size_t i=1;i<times.size();++i)intervals.push_back(times[i]-times[i-1]);
    for(size_t i=0;i<intervals.size();++i){
        std::vector<double> nearby(intervals.begin()+std::max(0,(int)i-3),intervals.begin()+std::min(intervals.size(),i+4));
        std::sort(nearby.begin(),nearby.end());const double m=nearby[nearby.size()/2],multiple=m>0?std::round(intervals[i]/m):1;
        const bool missing=multiple>=2&&multiple<=4&&std::abs(intervals[i]-multiple*m)<std::max(.012,m*.03);
        beats.push_back(beats.back()+(missing?multiple:1));if(i)changes.push_back(std::abs(intervals[i]-intervals[i-1]));
    }
    std::sort(changes.begin(),changes.end());const double tolerance=std::min(.020,std::max(.008,changes[changes.size()/2]*2));
    const auto integerTempo=[&](int first,int last,double anchored)->std::optional<double>{
        const int count=last-first+1,half=(count-1)/2;std::vector<double> slopes;
        for(int lag:std::set<int>{std::max(1,half-1),std::max(1,half),std::max(1,half+1),std::max(1,beatsPerBar)})
            if(lag<count)for(int i=first;i<=last-lag;++i)slopes.push_back((times[i+lag]-times[i])/(beats[i+lag]-beats[i]));
        if(slopes.empty())return {};
        const double period=median(slopes),bpm=std::round(60/period);if(bpm<60||bpm>300)return {};
        std::vector<double> deviations;for(double v:slopes)deviations.push_back(std::abs(v-period));
        const double uncertainty=std::max(2./44100/std::max(1.,beats[last]-beats[first]),3*median(deviations)/std::sqrt((double)count));
        if(std::abs(60/period-bpm)>.01&&std::abs(period-60/bpm)>uncertainty)return {};
        if(beatsPerBar>0&&beatsPerBar<count-2){std::vector<double> differences;
            for(int i=first;i<=last-beatsPerBar;++i)differences.push_back(std::abs(times[i+beatsPerBar]-times[i]-(beats[i+beatsPerBar]-beats[i])*60/bpm));
            if(median(differences)<=.002)anchored=std::max(anchored,.030);
        }
        for(int i=first;i<=last;++i)if(std::abs(times[i]-times[first]-(beats[i]-beats[first])*60/bpm)>anchored)return {};
        return bpm;
    };
    std::vector<std::pair<int,int>> pending{{0,(int)times.size()-1}};std::vector<Section> pieces;
    while(!pending.empty()){
        if(cancel&&cancel->load())return {};
        const auto span=pending.back();pending.pop_back();const int first=span.first,last=span.second;
        const double period=(times[last]-times[first])/(beats[last]-beats[first]);const auto integer=integerTempo(first,last,tolerance);
        double maximum=0;int split=first;
        for(int i=first+1;i<last;++i){double e=std::abs(times[i]-times[first]-(beats[i]-beats[first])*period);if(e>maximum){maximum=e;split=i;}}
        if(!integer&&maximum>tolerance){pending.push_back({split,last});pending.push_back({first,split});continue;}
        const double bpm=integer.value_or(60/period);if(std::isfinite(bpm)&&bpm>=60&&bpm<=300)pieces.push_back({times[first],bpm});
    }
    std::vector<Section> result;
    for(size_t index=0;index<pieces.size();){
        if (cancel && cancel->load()) return {};
        const int first=(int)(std::lower_bound(times.begin(),times.end(),pieces[index].position)-times.begin());
        size_t lastSection=index;auto chosen=pieces[index];
        while(lastSection+1<pieces.size()){
            if (cancel && cancel->load()) return {};
            const int last=lastSection+2<pieces.size()?(int)(std::lower_bound(times.begin(),times.end(),pieces[lastSection+2].position)-times.begin()):(int)times.size()-1;
            const double bpm=60*(beats[last]-beats[first])/(times[last]-times[first]);
            auto fits=[&](double value){if(value<60||value>300)return false;for(int i=first;i<=last;++i)if(std::abs(times[i]-times[first]-(beats[i]-beats[first])*60/value)>.020)return false;return true;};
            if(!fits(bpm))break;const auto integer=integerTempo(first,last,.020);chosen.bpm=integer&&fits(*integer)?*integer:bpm;++lastSection;
        }
        result.push_back(chosen);index=lastSection+1;
    }
    return result;
}
// MP3 readers may seek to a neighbouring compressed frame. Decode forwards
// and retain two PCM blocks so overlapping attack/timbre windows stay exact.
class SequentialPCM final {
  public:
    explicit SequentialPCM(AudioFormatReader &source) : reader(source), cache((int)source.numChannels, block * 2) {}
    bool read(AudioBuffer<float> &destination, int64 first, int count, const std::atomic<bool> *cancel) {
        if (first < begin || count > block || first + count > reader.lengthInSamples) return false;
        while (first + count > end) {
            if (cancel && cancel->load()) return false;
            if (end - begin == block * 2) {
                for (int c = 0; c < cache.getNumChannels(); ++c)
                    cache.copyFrom(c, 0, cache, c, block, block);
                begin += block;
            }
            const auto amount = (int)std::min<int64>(block, reader.lengthInSamples - end);
            if (amount <= 0 || !reader.read(&cache, (int)(end - begin), amount, end, true, true)) return false;
            end += amount;
        }
        if (first < begin) return false;
        for (int c = 0; c < destination.getNumChannels(); ++c)
            destination.copyFrom(c, 0, cache, c, (int)(first - begin), count);
        return true;
    }
  private:
    static constexpr int block = 65536;
    AudioFormatReader &reader;
    AudioBuffer<float> cache;
    int64 begin = 0, end = 0;
};
inline std::vector<Transient> transients(const File &file,const std::atomic<bool> *cancel=nullptr) {
    AudioFormatManager formats;registerAudioFormats(formats);std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
    require(reader!=nullptr,"Could not read Click audio: "+utf8(file.getFileName()));
    auto peaks=WaveformCache::forAnalysis(file,*reader,cancel);require(peaks!=nullptr,"Could not analyse Click audio");
    double maximum=0;std::vector<double> values(peaks->levels[0].count);
    for(size_t i=0;i<values.size();++i)for(int c=0;c<peaks->sourceChannels;++c){const auto p=peaks->at(0,c,i);values[i]=std::max(values[i],(double)std::max(std::abs(WaveformCache::decode(p.low)),std::abs(WaveformCache::decode(p.high))));maximum=std::max(maximum,values[i]);}
    if(maximum<=.00001)return {};
    reader.reset(formats.createReaderFor(file));
    require(reader!=nullptr,"Could not reopen Click audio");
    SequentialPCM sequential(*reader);
    const double threshold=maximum*.04;bool armed=true;double previous=-1e30;std::vector<Transient> result;
    const int capacity=512+(int)std::ceil(reader->sampleRate*.03);AudioBuffer<float> pcm((int)reader->numChannels,capacity);
    for(size_t i=0;i<values.size();++i){
        if(cancel&&cancel->load())return {};
        if(values[i]<threshold*.3)armed=true;if(!armed||values[i]<threshold)continue;armed=false;
        const int64 first=std::max<int64>(0,((int64)i-1)*256);if(first/reader->sampleRate-previous<.08)continue;
        const int count=(int)std::min<int64>(capacity,reader->lengthInSamples-first);
        require(sequential.read(pcm,first,count,cancel),"Could not read Click attack");
        float peak=0;for(int c=0;c<pcm.getNumChannels();++c)peak=std::max(peak,pcm.getMagnitude(c,0,count));
        const double attack=std::max(.00001,peak*.2);int offset=-1;
        for(int n=0;n<count&&offset<0;++n)for(int c=0;c<pcm.getNumChannels();++c)if(std::abs(pcm.getSample(c,n))>=attack){offset=n;break;}
        if(offset<0)continue;
        const int64 onset=first+offset;previous=onset/reader->sampleRate;const int detail=(int)std::min<int64>(reader->lengthInSamples-onset,(int)(reader->sampleRate*.03));
        if(detail<=0)continue;require(sequential.read(pcm,onset,detail,cancel),"Could not read Click timbre");
        Transient pulse; pulse.position=previous;pulse.peak=0;
        for(int c=0;c<pcm.getNumChannels();++c){double p=0,energy=0,early=0,last=0;int crossings=0;
            for(int n=0;n<detail;++n){double value=pcm.getSample(c,n);p=std::max(p,std::abs(value));energy+=value*value;if(n<detail/3)early+=value*value;if(value*last<0)++crossings;last=value;}
            if(p>pulse.peak){pulse.peak=p;pulse.shape={(double)crossings/detail*reader->sampleRate/4000,std::sqrt(energy/detail)/std::max(p,.000001),early/std::max(energy,.000000001)};}
        }
        result.push_back(std::move(pulse));
    }
    return result;
}
inline std::vector<Section> markerSections(std::vector<Section> input,int beatsPerBar,int beatUnit,double end) {
    const auto rounded=[](double bpm){return std::abs(bpm-std::round(bpm))<=.25?std::round(bpm):bpm;};
    input.erase(std::remove_if(input.begin(),input.end(),[&](const auto& s){return !std::isfinite(s.position)||!std::isfinite(s.bpm)||s.bpm<60||s.bpm>300||s.position>=end;}),input.end());
    std::sort(input.begin(),input.end(),[](const auto&a,const auto&b){return a.position<b.position;});
    if(input.empty())return {};
    std::vector<Section> result{{input.front().position,rounded(input.front().bpm)}};
    for(size_t i=1;i<input.size();++i) {
        const auto previous=result.back();
        if(std::abs(rounded(input[i].bpm)-previous.bpm)<.01)continue;
        const double bars=2.*std::max(1,beatsPerBar)*4/std::max(1,beatUnit)*60/previous.bpm;
        const double position=std::max(input[i].position,previous.position+bars);
        if(position>=end)break;
        while(i+1<input.size() && input[i+1].position<=position)++i;
        const double bpm=rounded(input[i].bpm);
        if(std::abs(bpm-previous.bpm)>=.01)result.push_back({position,bpm});
    }
    return result;
}
inline std::vector<jaras::TimelineMarker> markers(const jaras::Song &song,const jaras::Part &sourceRegion,
        const std::function<std::vector<Transient>(const jaras::AudioFile&)> &source,const std::atomic<bool>*cancel=nullptr) {
    auto region=sourceRegion;region.endTime=jaras::TempoEditMap::tempoEditEnd(song,region);
    std::vector<Transient> pulses;
    for(const auto &track:song.tracks)if(track.role.id=="click"||text(track.name).trim().equalsIgnoreCase("click"))
        for(const auto &clip:track.clips)if(clip.startTime<region.endTime&&clip.startTime+clip.duration>region.startTime){
            if(region.parentRegionID&&clip.startTime<region.startTime)continue;
            const auto &file=clip.audioFile?clip.audioFile:track.audioFile;if(!file)continue;
            for(auto pulse:source(*file)){
                const double position=clip.startTime+(pulse.position-clip.sourceOffset)/std::max(.001,clip.playbackRate);
                if(position>=std::max(clip.startTime,region.startTime)&&position<std::min(clip.startTime+clip.duration,region.endTime)){pulse.position=position;pulses.push_back(std::move(pulse));}
            }
        }
    std::sort(pulses.begin(),pulses.end(),[](const auto &a,const auto &b){return a.position<b.position;});std::vector<Transient> unique;
    for(const auto &p:pulses)if(unique.empty()||p.position-unique.back().position>.08)unique.push_back(p);
    std::vector<double> positions;for(const auto &p:unique)positions.push_back(p.position);
    const auto signature=meter(unique,cancel);
    const auto spans=markerSections(sections(positions,signature.value_or(song.beatsPerBar),cancel),signature.value_or(song.beatsPerBar),signature?4:song.beatUnit,region.endTime);std::vector<jaras::TimelineMarker> result;
    for(size_t i=0;i<spans.size();++i){const auto &span=spans[i];const double end=i+1<spans.size()?spans[i+1].position:region.endTime;
        std::vector<Transient> local;for(const auto &p:unique)if(p.position>=span.position&&p.position<end)local.push_back(p);
        const auto signature=meter(local,cancel);jaras::TimelineMarker m;m.id=uuid();m.name="TEMPO";m.position=span.position;m.color=0x999999;m.tempoBPM=span.bpm;m.tempoBeats=signature.value_or(song.beatsPerBar);m.tempoUnit=signature?4:song.beatUnit;m.tempoTimebase="global";m.tempoReferenceBPM=span.bpm;result.push_back(m);
    }
    if(!result.empty()&&result.front().position>region.startTime){auto m=result.front();m.id=uuid();m.position=region.startTime;result.insert(result.begin(),m);}
    return result;
}
// Only analysis inputs belong in this signature: moving the edit cursor,
// selecting a track or adjusting a fader must not invalidate background work.
inline std::string inputSignature(const jaras::Song &song, const std::set<ID> &regions) {
    MemoryOutputStream out;
    out.writeString(text(song.id)); out.writeDouble(song.bpm); out.writeInt(song.beatsPerBar); out.writeInt(song.beatUnit);
    for (const auto &part : song.parts) if (regions.count(part.id)) {
        out.writeString(text(part.id)); out.writeDouble(part.startTime); out.writeDouble(part.endTime);
        out.writeString(text(part.parentRegionID.value_or("")));
    }
    for (const auto &track : song.tracks)
        if (track.role.id == "click" || text(track.name).trim().equalsIgnoreCase("click")) {
            out.writeString(text(track.id));
            for (const auto &clip : track.clips) {
                out.writeString(text(clip.id)); out.writeDouble(clip.startTime); out.writeDouble(clip.duration);
                out.writeDouble(clip.sourceOffset); out.writeDouble(clip.playbackRate);
                out.writeDouble(clip.loopStart.value_or(0)); out.writeDouble(clip.loopLength.value_or(0));
                const auto &file = clip.audioFile ? clip.audioFile : track.audioFile;
                out.writeString(file ? text(file->path) : String());
                out.writeString(file ? text(file->sha256.value_or("")) : String());
            }
        }
    // A manual tempo edit while analysing wins over the pending result.
    if (song.markers) for (const auto &marker : *song.markers) if (marker.tempoBPM) {
        out.writeString(text(marker.id)); out.writeDouble(marker.position); out.writeDouble(*marker.tempoBPM);
        out.writeInt(marker.tempoBeats.value_or(song.beatsPerBar)); out.writeInt(marker.tempoUnit.value_or(song.beatUnit));
        out.writeDouble(marker.tempoReferenceBPM.value_or(0)); out.writeString(text(marker.tempoTimebase.value_or("")));
    }
    return std::string(static_cast<const char *>(out.getData()), out.getDataSize());
}
inline void insert(jaras::Song &song,const jaras::Part &region,const std::vector<jaras::TimelineMarker> &detected) {
    if(!song.markers)song.markers.emplace();
    song.markers->erase(std::remove_if(song.markers->begin(),song.markers->end(),[&](const auto &m){return m.tempoBPM&&m.position>=region.startTime&&m.position<jaras::TempoEditMap::tempoEditEnd(song,region);}),song.markers->end());
    for(auto m:detected){auto at=std::find_if(song.markers->begin(),song.markers->end(),[&](const auto &other){return other.tempoBPM&&std::abs(other.position-m.position)<.000001;});
        m.regionOwnerID=jaras::regionOwnerAt(song,m.position);
        if(at!=song.markers->end()){m.id=at->id;if(at->position==m.position)m.regionOwnerID=at->regionOwnerID;*at=m;}else song.markers->push_back(m);
    }
    if(std::any_of(song.markers->begin(),song.markers->end(),[](const auto &m){return m.tempoBPM.has_value();}) && std::none_of(song.markers->begin(),song.markers->end(),[](const auto &m){return m.tempoBPM&&m.position<=0;})){
        jaras::TimelineMarker initial;initial.id=uuid();initial.name="TEMPO";initial.position=0;initial.color=0x999999;initial.regionOwnerID=jaras::regionOwnerAt(song,0);initial.tempoBPM=120;initial.tempoReferenceBPM=120;initial.tempoBeats=4;initial.tempoUnit=4;initial.tempoTimebase="global";song.markers->push_back(initial);
    }
}
}
