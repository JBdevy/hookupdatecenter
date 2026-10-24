#pragma once
#include "ProjectReduction.h"
#include "PortablePackage.h"
namespace catlive::projectReductionTests {
template<class Test,class Fixture> void run(const File &directory,Test &&test,Fixture fixture){
 test("Reduction splits by region, keeps only chosen tracks and preserves actual gain",[&]{
    const auto root=directory.getNonexistentChildFile("reduction","");root.createDirectory();
    auto p=fixture();auto &song=p.songs[0];song.tracks.clear();song.parts.clear();song.markers.reset();song.duration=4;
    p.masterFXJSON.reset();p.masterAutomationJSON.reset();p.masterVolume=.7;p.masterPan=0;p.masterMute=false;p.masterSolo=false;
    for(int i=0;i<3;++i){
        String name="input"+String(i)+".wav";auto stream=root.getChildFile(name).createOutputStream();WavAudioFormat wav;
        std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.release(),48000,2,24,{},0));
        recordingCaptureTests::require(writer!=nullptr,"Cannot write fixture");AudioBuffer<float> pcm(2,192000);
        for(int ch=0;ch<2;++ch)FloatVectorOperations::fill(pcm.getWritePointer(ch),.1f,pcm.getNumSamples());
        writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples());writer.reset();
        jaras::Track t;t.id=uuid();t.name=utf8(name);t.volume=i==0?.5:1;t.role.id="other";
        jaras::AudioClip c;c.id=uuid();c.name="source";c.duration=4.000000000002;c.audioFile=jaras::AudioFile{utf8(name),{}};t.clips={c};song.tracks.push_back(t);
    }
    for(int i=0;i<2;++i){jaras::Part r;r.id=uuid();r.name="Music"+std::to_string(i+1);r.startTime=i*2;r.endTime=(i+1)*2;song.parts.push_back(r);}
    projectReduction::Group g;g.name="Mix";g.sources={song.tracks[0].id,song.tracks[1].id};std::atomic<bool> cancel{false};
    const auto target=root.getChildFile("Reduced/Reduced.jl");std::vector<projectReduction::Progress> events;
    projectReduction::write(p,{g},root,target,cancel,[&](const projectReduction::Progress &event){events.push_back(event);});
    recordingCaptureTests::require(!events.empty()&&events.front().fraction==0&&events.back().fraction==1,"Progress endpoints incorrect");
    for(size_t i=1;i<events.size();++i)recordingCaptureTests::require(events[i].fraction>=events[i-1].fraction,"Progress moved backwards");
    for(size_t i=0;i+1<events.size();++i)recordingCaptureTests::require(events[i].fraction<1,"Progress finished before project save");
    for(const String name:{String("Music1"),String("Music2")})recordingCaptureTests::require(std::any_of(events.begin(),events.end(),[&](const auto &e){return e.message.contains("Mix")&&e.message.contains(name);}),"Progress missing region name");
    auto reduced=ProjectCodec::decode(ProjectCodec::read(target));
    recordingCaptureTests::require(reduced.songs[0].tracks.size()==1,"Unselected track survived");
    const auto &clips=reduced.songs[0].tracks[0].clips;
    recordingCaptureTests::require(clips.size()==2&&clips[0].startTime==0&&clips[1].startTime==2&&clips[0].duration==2,"Regions were joined horizontally");
    recordingCaptureTests::require(reduced.masterVolume==p.masterVolume&&reduced.projectSyncID!=p.projectSyncID,"Master or new project identity changed incorrectly");
    AudioFormatManager formats;formats.registerBasicFormats();
    for(const auto &c:clips){std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(target.getParentDirectory().getChildFile(text(c.audioFile->path))));
        recordingCaptureTests::require(reader&&reader->lengthInSamples==96000,"Render duration changed");AudioBuffer<float> pcm(2,512);reader->read(&pcm,0,512,12000,true,true);
        recordingCaptureTests::require(std::abs(pcm.getSample(0,100)-.15f)<.001f,"Combined gain differs from actual PCM");}
    const auto size=projectReduction::estimate(p,{g},root);
    recordingCaptureTests::require(size.frames==192000&&size.files==2&&size.copiedBytes==0,"Size estimate does not match region outputs");
    recordingCaptureTests::require(size.bytes("WAV")==size.bytes("AIFF")&&size.bytes("WAV")>size.bytes("MP3"),"Format size estimates are incorrect");
    for(const String encoding:{String("WAV"),String("AIFF"),String("MP3")}){
      for(double rate:{44100.,48000.})for(int quality:(encoding=="MP3"?std::vector<int>{128,320}:std::vector<int>{16,24,32})){
        const int bits=encoding=="MP3"?32:quality,bitrate=encoding=="MP3"?quality:320;
        const auto formatTarget=root.getChildFile(encoding+String(rate)+"-"+String(quality)+"/Test.jl");
        projectReduction::write(p,{g},root,formatTarget,cancel,[](const projectReduction::Progress &){},encoding,std::nullopt,bits,rate,bitrate);
        const auto formatted=ProjectCodec::decode(ProjectCodec::read(formatTarget));
        double bytes=(double)formatTarget.getSize();
        for(const auto &clip:formatted.songs[0].tracks[0].clips){
            const auto file=formatTarget.getParentDirectory().getChildFile(text(clip.audioFile->path));bytes+=file.getSize();
            recordingCaptureTests::require(file.hasFileExtension(encoding.toLowerCase()),"Selected format not applied");
            std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
            recordingCaptureTests::require(reader&&std::abs(reader->lengthInSamples/reader->sampleRate-2)<.1,"Encoded file unreadable or duration incorrect");
            recordingCaptureTests::require(reader->sampleRate==rate,"Sample rate ignored");
            if(encoding!="MP3")recordingCaptureTests::require(reader->bitsPerSample==bits&&reader->usesFloatingPointData==(bits==32),"PCM depth or floating point selection ignored");
        }
        recordingCaptureTests::require(bytes<=size.bytes(encoding,bits,rate,bitrate)*1.05,"Project preview underestimated encoded files");
    }
    }
    const auto fullDisk=root.getChildFile("FullDisk/FullDisk.jl");bool noSpace=false,renderStarted=false;
    try{projectReduction::write(p,{g},root,fullDisk,cancel,[&](const projectReduction::Progress &event){if(event.message.contains("Renderizando"))renderStarted=true;},"WAV",0);}
    catch(const std::exception &error){noSpace=String::fromUTF8(error.what()).contains(String::fromUTF8("Espaço insuficiente"));}
    recordingCaptureTests::require(noSpace&&!renderStarted&&!fullDisk.getParentDirectory().exists(),"Insufficient disk space was not caught before rendering");
    auto nested=p;jaras::Track outer;outer.id=uuid();outer.name="Outer";outer.role.id="other";outer.volume=.5;
    jaras::Track inner;inner.id=uuid();inner.name="Inner";inner.role.id="other";inner.volume=.5;inner.parentTrackID=outer.id;
    for(auto &t:nested.songs[0].tracks)t.parentTrackID=inner.id;
    nested.songs[0].tracks.insert(nested.songs[0].tracks.begin(),inner);nested.songs[0].tracks.insert(nested.songs[0].tracks.begin(),outer);
    for(bool single:{false,true}){
        auto selected=g;if(single)selected.sources={song.tracks[0].id};
        const auto flatTarget=root.getChildFile(single?"FlatSingle/FlatSingle.jl":"FlatMix/FlatMix.jl");
        projectReduction::write(nested,{selected},root,flatTarget,cancel,[](const projectReduction::Progress &){});
        const auto flat=ProjectCodec::decode(ProjectCodec::read(flatTarget));
        recordingCaptureTests::require(flat.songs[0].tracks.size()==1&&!flat.songs[0].tracks[0].parentTrackID,"Original groups leaked into reduced project");
        const auto &destination=flat.songs[0].tracks[0];
        std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(flatTarget.getParentDirectory().getChildFile(text(destination.clips[0].audioFile->path))));
        AudioBuffer<float> pcm(2,512);reader->read(&pcm,0,512,12000,true,true);
        recordingCaptureTests::require(std::abs(pcm.getSample(0,100)-(single?.05f:.15f)*.25f)<.001f,"Ancestor group gain lost or doubled");
    }
    auto boosted=p;boosted.songs[0].tracks[0].volume=8;boosted.songs[0].tracks[1].volume=8;
    for(const String encoding:{String("WAV"),String("AIFF")}){
    const auto boostTarget=root.getChildFile("Float-"+encoding+"/Float.jl");projectReduction::write(boosted,{g},root,boostTarget,cancel,[](const projectReduction::Progress &){},encoding);
    const auto boost=ProjectCodec::decode(ProjectCodec::read(boostTarget));
    std::unique_ptr<AudioFormatReader> floatReader(formats.createReaderFor(boostTarget.getParentDirectory().getChildFile(text(boost.songs[0].tracks[0].clips[0].audioFile->path))));
    AudioBuffer<float> loud(2,512);floatReader->read(&loud,0,512,12000,true,true);
    recordingCaptureTests::require(floatReader->usesFloatingPointData&&std::abs(loud.getSample(0,100)-1.6f)<.001f,"Reduction clipped floating point headroom");
    }
        bool rejected=false;try{projectReduction::write(p,{g},root,target,cancel,[](const projectReduction::Progress &){});}catch(...){rejected=true;}
    recordingCaptureTests::require(rejected&&target.existsAsFile(),"Existing project was not protected");
    cancel=true;const auto cancelled=root.getChildFile("Cancelled/Cancelled.jl");try{projectReduction::write(p,{g},root,cancelled,cancel,[](const projectReduction::Progress &){});}catch(...){}
    recordingCaptureTests::require(!cancelled.getParentDirectory().exists()&&p.songs[0].tracks.size()==3,"Cancellation changed original or left partial copy");
 });
 test("Reduction iPad filter removes individual video and timecode items",[&]{
    auto p=fixture();auto &t=p.songs[0].tracks[0];t.clips.clear();t.audioFile.reset();
    jaras::AudioClip audio;audio.id=uuid();audio.duration=1;audio.audioFile=jaras::AudioFile{"Stems/audio.wav",{}};t.clips.push_back(audio);
    auto video=audio;video.id=uuid();video.audioFile=jaras::AudioFile{"Videos/video.mp4",{}};t.clips.push_back(video);
    auto filtered=ProjectCodec::decode(portablePackage::iPadCopy(ProjectCodec::encode(p)));
    recordingCaptureTests::require(filtered.songs[0].tracks[0].clips.size()==1&&filtered.songs[0].tracks[0].clips[0].id==audio.id,"iPad export removed mixed track audio");
 });
}
}
