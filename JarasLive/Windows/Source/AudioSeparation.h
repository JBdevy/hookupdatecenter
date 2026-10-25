#pragma once
#include "AudioExport.h"
#include "ProjectCodec.h"
#include "TrackTree.h"
namespace catlive::audioSeparation {
inline String outputName(const String &stem,const String &original) {
    auto base=original.trim();
    if(File(base).hasFileExtension("wav;wave;aif;aiff;aifc;mp3;m4a;aac;flac;ogg;oga;opus;caf;alac;wma"))base=base.upToLastOccurrenceOf(".",false,false);
    return stem+" - "+(base.isEmpty()?String("Item"):base);
}
inline bool eligible(const jaras::Track &track,const jaras::AudioClip &clip) {
    const auto file=clip.audioFile?clip.audioFile:track.audioFile;
    return jaras::fixedTrackName(track.role).empty() && !clip.midi && !clip.text && !clip.timecode && file && clip.duration>0 &&
        File(text(file->path)).hasFileExtension("wav;wave;aif;aiff;aifc;mp3;m4a;aac;flac;ogg;oga;opus;caf;alac;wma");
}
inline std::optional<std::string> withoutRealtimeSeparation(std::optional<std::string> source) {
    if(!source)return source;auto value=JSON::parse(text(*source));if(!value.isObject())return source;
    Array<var> inserted;for(const auto &item:list(get(value,"inserted")))if(item.toString()!="CatStemSeparation 5")inserted.add(item);
    put(value,"inserted",inserted);put(value,"stemSeparatorEnabled",false);value.getDynamicObject()->removeProperty("stemMix");
    return utf8(JSON::toString(value,true));
}
inline String fingerprint(const jaras::AudioClip &clip) {
    jaras::Project p;p.id="separation-fingerprint";p.name="Fingerprint";
    jaras::Song s;s.id="song";s.name="Song";s.duration=std::max(1.,clip.startTime+clip.duration);
    jaras::Track t;t.id="track";t.name="Track";t.clips={clip};s.tracks={t};p.songs={s};
    const auto songs=list(get(ProjectCodec::encode(p),"songs"));
    const auto tracks=list(get(songs[0],"tracks"));
    return JSON::toString(list(get(tracks[0],"clips"))[0],true);
}
inline void commit(jaras::Project &project,const ID &songID,const ID &trackID,
                   const jaras::AudioClip &original,const std::vector<jaras::Track> &stems) {
    if(stems.size()!=5)throw std::runtime_error("A separação não retornou os cinco instrumentos.");
    auto next=project;
    for(auto &song:next.songs)if(song.id==songID) {
        for(size_t row=0;row<song.tracks.size();++row)if(song.tracks[row].id==trackID) {
            for(auto &clip:song.tracks[row].clips)if(clip.id==original.id) {
                if(fingerprint(clip)!=fingerprint(original))throw std::runtime_error("O item original mudou durante a separação.");
                std::set<ID> ids;
                for(const auto &stem:stems) {
                    if(!ids.insert(stem.id).second||stem.clips.size()!=1||stem.clips[0].startTime!=original.startTime||stem.clips[0].duration!=original.duration)
                        throw std::runtime_error("As pistas separadas têm identificação ou posição inválida.");
                }
                clip.muted=true;
                clip.separatedStemTracks.clear();for(const auto &stem:stems)clip.separatedStemTracks.push_back(stem.id);
                std::set<ID> descendants{trackID};size_t at=row+1;
                while(at<song.tracks.size()&&song.tracks[at].parentTrackID&&descendants.count(*song.tracks[at].parentTrackID)) { descendants.insert(song.tracks[at].id);++at; }
                song.tracks.insert(song.tracks.begin()+ptrdiff_t(at),stems.begin(),stems.end());
                jaras::validate(next);project=std::move(next);return;
            }
        }
    }
    throw std::runtime_error("O projeto ou o item original não está mais disponível.");
}
struct Result { std::vector<jaras::Track> tracks;std::vector<File> files; };
inline Result render(const jaras::Project &project,const jaras::Song &song,const jaras::Track &track,
                     const jaras::AudioClip &clip,const File &directory,std::atomic<bool> &cancel,
                     const std::function<void(double,String)> &progress) {
    if(!eligible(track,clip))throw std::runtime_error("Selecione apenas um item de áudio.");
    const auto runtime=File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("StemSeparationRuntime");
    const auto python=runtime.getChildFile("python/python.exe"),worker=runtime.getChildFile("separate.py"),model=runtime.getChildFile("5c90dfd2-34c22ccb.th");
    if(!python.existsAsFile()||!worker.existsAsFile()||!model.existsAsFile())throw std::runtime_error("O motor de separação não está incluído nesta instalação do CatLive.");
    const auto needed=clip.duration*44100*2*4*6+16*1024*1024;
    const auto free=directory.getBytesFreeOnVolume();
    if(free>=0&&double(free)<needed)throw std::runtime_error("Espaço insuficiente no disco para separar o áudio.");
    const auto temporary=directory.getChildFile(".catlive-separation-"+text(uuid()));
    if(temporary.createDirectory().failed())throw std::runtime_error("Não foi possível preparar a separação.");
    Result result;
    auto cleanup=[&]{temporary.deleteRecursively();};
    try {
        auto source=song;auto neutral=track;neutral.role.id="other";neutral.clips={clip};neutral.clips[0].muted=false;neutral.clips[0].fxJSON=withoutRealtimeSeparation(neutral.clips[0].fxJSON);
        neutral.fxJSON.reset();neutral.automationJSON.reset();neutral.parentTrackID.reset();neutral.routing.reset();neutral.stereoLinkPartner.reset();
        neutral.volume=1;neutral.pan=0;neutral.mute=false;neutral.solo=false;neutral.phaseInverted=false;neutral.patch=jaras::OutputPatch{0,2};neutral.outputs.reset();neutral.secondaryPatch.reset();
        source.tracks={neutral};for(auto &part:source.parts)part.pitchSemitones=0;
        auto neutralProject=project;neutralProject.masterFXJSON.reset();neutralProject.masterAutomationJSON.reset();neutralProject.masterVolume=1;neutralProject.masterPan=0;neutralProject.masterMute=false;neutralProject.masterSolo=false;neutralProject.masterMono=false;
        ExportRequest request;request.directory=temporary;request.encodings[0].rate=44100;request.encodings[0].floatingPoint=true;request.encodings[0].bits=32;request.encodings[0].channels=2;
        request.jobs.push_back({"input.wav",clip.startTime,clip.startTime+clip.duration,track.id,{}});
        audioExport::render(neutralProject,source,directory,request,cancel,[&](double fraction){progress(fraction*.08,String::fromUTF8("Preparando o áudio…"));});
        ChildProcess process;
        StringArray arguments{python.getFullPathName(),"-I","-B",worker.getFullPathName(),"--input",temporary.getChildFile("input.wav").getFullPathName(),"--output",temporary.getFullPathName(),"--model",model.getFullPathName()};
        if(!process.start(arguments))throw std::runtime_error("Não foi possível iniciar a separação de áudio.");
        while(process.isRunning()) {
            if(cancel.load()){process.kill();throw std::runtime_error("Separação cancelada.");}
            const auto status=JSON::parse(temporary.getChildFile("progress.json"));
            if(status.isObject())progress(.08+jlimit(0.,1.,num(status,"fraction"))*.82,get(status,"message").toString());
            Thread::sleep(100);
        }
        if(cancel.load())throw std::runtime_error("Separação cancelada.");
        if(process.getExitCode()!=0) {
            auto detail=temporary.getChildFile("error.txt").loadFileAsString().substring(0,600);
            throw std::runtime_error(utf8(detail.isEmpty()?String::fromUTF8("Falha ao separar o áudio."):detail));
        }
        const auto stems=directory.getChildFile("Stems");if(stems.createDirectory().failed())throw std::runtime_error("Não foi possível criar a pasta Stems.");
        const StringArray names{"Vocal","Drum","Bass","Guitar","Other"};const char *roles[]={"backingVocal","drums","bass","guitar","other"};const unsigned colors[]={0xb68af4,0x69ed91,0x8e70ca,0x45ba91,0xaaa0c7};
        AudioFormatManager formats;registerAudioFormats(formats);
        for(int index=0;index<5;++index) {
            if(cancel.load())throw std::runtime_error("Separação cancelada.");
            const auto generated=temporary.getChildFile(names[index]+".wav");std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(generated));
            if(!reader||reader->sampleRate!=44100||reader->numChannels!=2||std::abs(double(reader->lengthInSamples)/44100-clip.duration)>.01)throw std::runtime_error("O áudio separado tem duração ou formato incorreto.");
            reader.reset();const auto label=outputName(names[index],text(clip.name));auto name=File::createLegalFileName(label).substring(0,120);
            const auto destination=stems.getNonexistentChildFile(name,".wav");
            if(!generated.moveFileTo(destination))throw std::runtime_error("Não foi possível salvar o áudio separado.");result.files.push_back(destination);
            jaras::AudioClip output;output.id=uuid();output.name=utf8(label);output.startTime=clip.startTime;output.duration=clip.duration;output.audioFile=jaras::AudioFile{utf8("Stems/"+destination.getFileName()),{}};output.regionOwnerID=clip.regionOwnerID;output.renderedTempo=true;
            jaras::Track stem;stem.id=uuid();stem.name=utf8(label);stem.role.id=roles[index];stem.color=colors[index];stem.clips={output};stem.parentTrackID=track.parentTrackID;stem.volume=track.volume;stem.pan=track.pan;stem.fxJSON=withoutRealtimeSeparation(track.fxJSON);stem.mute=track.mute;stem.solo=track.solo;stem.patch=track.patch;stem.secondaryPatch=track.secondaryPatch;stem.outputs=track.outputs;stem.phaseInverted=track.phaseInverted;
            result.tracks.push_back(std::move(stem));progress(.9+index*.02,String::fromUTF8("Preparando ")+names[index]);
        }
        cleanup();return result;
    }catch(...){cleanup();for(const auto &file:result.files)file.deleteFile();throw;}
}
}
