#include "ProjectCodec.h"
#include <algorithm>
#include <chrono>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
using catlive::native::ProjectCodec;
using catlive::native::json;
namespace {
void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
template <typename F> void rejects(F &&work, const char *message) {
    bool rejected = false;
    try { work(); } catch (const std::exception &) { rejected = true; }
    expect(rejected, message);
}
std::string id(int number) {
    char result[37];
    std::snprintf(result, sizeof(result), "00000000-0000-4000-8000-%012d", number);
    return result;
}
jaras::Project fixture() {
    jaras::Project p;
    p.id = id(1); p.name = "São João — 演奏 🎵";
    p.createdAt = p.updatedAt = "2026-10-16T21:03:11Z";
    p.masterColor = 0x69ed91; p.masterPhaseInverted = true;
    p.masterVolume = .8123456789012345; p.masterPan = -.21234567890123456;
    p.masterMute = true; p.masterSolo = true; p.masterMono = true;
    p.masterPatch = jaras::OutputPatch{1,2}; p.masterSecondaryPatch = jaras::OutputPatch{3,2};
    p.masterOutputs = std::vector<jaras::OutputPatch>{{1,2},{3,2}};
    p.masterFXJSON = R"({"inserted":["EQ"],"externalState":{"library":"Órgão","bytes":"abc"},"gain":0.12345678901234566})";
    p.masterAutomationJSON = R"({"volume":[{"time":0.12345678901234566,"value":0.7}]})";
    jaras::Song song; song.id=id(2); song.name="Show"; song.duration=100; song.bpm=123.45678901234567;
    song.beatsPerBar=7; song.beatUnit=8; song.regionOwnershipInitialized=true; song.regionOwnershipVersion=2;
    song.timeSettings=jaras::ProjectTimeSettings{8,jaras::ProjectTimebase::relative,true,false};
    jaras::Track track; track.id=id(3); track.name="Piano"; track.role.id="keys";
    track.volume=.73; track.pan=-.2; track.mute=true; track.solo=true; track.output=3;
    track.color=0x123456; track.phaseInverted=true; track.heightScale=1.25;
    track.midiInput=2; track.midiChannel=16; track.inputMonitoring=true;
    track.recordingChannels=2; track.recordingFormat="wav32"; track.inputPatch=jaras::OutputPatch{1,2};
    track.patch=jaras::OutputPatch{0,2}; track.secondaryPatch=jaras::OutputPatch{3,2};
    track.outputs=std::vector<jaras::OutputPatch>{{0,2},{3,2}};
    track.audioFile=jaras::AudioFile{"Stems/Órgão.wav", "hash"};
    track.automationJSON=R"({"pan":[{"time":1,"value":-0.12345678901234566}]})";
    track.fxJSON=p.masterFXJSON;
    track.routing=jaras::TrackRouting{};
    jaras::AudioClip clip; clip.id=id(4); clip.name="Take"; clip.startTime=10; clip.duration=8;
    clip.sourceOffset=.12345678901234566; clip.playbackRate=1.1234567890123457; clip.muted=true;
    clip.audioFile=jaras::AudioFile{"Stems/Órgão.wav", "hash"}; clip.gain=.7123456789012345;
    clip.pan=.2; clip.phaseInverted=true; clip.normalizationGain=1.1;
    clip.fadeIn=.25; clip.fadeOut=.5; clip.fadeInCurve=-.3; clip.fadeInSCurve=.4;
    clip.fadeOutCurve=.7; clip.fadeOutSCurve=-.8; clip.channelMode=3;
    clip.loopStart=0; clip.loopLength=2; clip.recordingLane=1; clip.fxBypassed=true;
    clip.frozenMIDI=true; clip.renderedTiming=true; clip.renderedTempo=true;
    clip.pitchSemitones=3; clip.tempoBasePlaybackRate=.75; clip.regionOwnerID=id(5);
    clip.separatedStemTracks={id(3)}; clip.waveform={.1,.5,.9}; clip.waveformChannels={{.1,.2},{.3,.4}};
    clip.fxJSON=R"({"inserted":["EQ"],"bands":[{"gain":-0.12345678901234566}]})";
    clip.automationJSON=track.automationJSON; track.clips.push_back(clip);
    jaras::AudioClip midi; midi.id=id(6); midi.name="MIDI"; midi.startTime=20; midi.duration=8;
    midi.midi.emplace(); midi.midi->sourceBPM=87.12345678901235; midi.midi->division=32;
    midi.midi->mode="swing"; midi.midi->swing=.73; midi.midi->notes={{id(7),.1,.23456789012345678,64,119,9}};
    midi.fadeIn=.2; midi.fadeOut=.4; track.clips.push_back(midi);
    song.tracks.push_back(track);
    jaras::Track timecode; timecode.id=id(8); timecode.role.id="timecode"; timecode.name="Timecode";
    timecode.timecode=jaras::TimecodeSettings{"ltc",29.97,123,true,3}; timecode.importedTimecodeItems=true;
    jaras::AudioClip tc; tc.id=id(9); tc.name="TC"; tc.startTime=0; tc.duration=30;
    tc.timecode=timecode.timecode; tc.timecodeStartOffset=-.5; tc.timecodeEndOffset=1.25;
    timecode.clips.push_back(tc); song.tracks.push_back(timecode);
    jaras::Track click; click.id=id(10); click.role.id="generatedClick"; click.name="Click";
    click.clickSound=jaras::AudioFile{"Stems/Click.wav", "clickhash"}; song.tracks.push_back(click);
    jaras::Track text; text.id=id(11); text.role.id="teleprompt"; text.name="Teleprompter 1";
    jaras::AudioClip lyric; lyric.id=id(12); lyric.name="Letra"; lyric.duration=20;
    lyric.text="Coração\n演奏"; text.clips.push_back(lyric); song.tracks.push_back(text);
    jaras::Part region; region.id=id(5); region.name="Música"; region.startTime=0; region.endTime=40; region.color=0x654321; region.uppercaseName=true;
    region.pitchSemitones=-2; region.totalLoop=true; region.pitchTrackIDs=std::vector<jaras::ID>{id(3)};
    region.pitchGroupIDs=std::vector<jaras::ID>{};
    jaras::MultiLoop loop; loop.id=id(13); loop.name="Loop"; loop.marker1=id(14); loop.marker2=id(15);
    loop.fadeSeconds=2.5; loop.enabled=true; loop.mixerEnabled=false; loop.tracks={{id(3),.6,true,false,true}};
    region.multiLoops.push_back(loop); song.parts.push_back(region);
    jaras::Part child; child.id=id(16); child.name="Filho"; child.startTime=10; child.endTime=20; child.parentRegionID=id(5); song.parts.push_back(child);
    jaras::TimelineMarker marker; marker.id=id(14); marker.name="Tempo"; marker.position=2; marker.color=0x123456; marker.tempoBPM=121.23456789012345;
    marker.tempoBeats=7; marker.tempoUnit=8; marker.tempoReferenceBPM=120;
    marker.tempoTimebase="relative"; marker.section=true; marker.loopSection=false; marker.regionOwnerID=id(5);
    jaras::TimelineMarker end; end.id=id(15); end.name="Fim"; end.position=30; end.color=0xabcdef; end.sourceRegionID=id(16); end.unifiedRegionID=id(5);
    song.markers=std::vector<jaras::TimelineMarker>{marker,end};
    p.songs.push_back(song); p.savedCursor=jaras::SavedProjectCursor{id(2),12.123456789012345};
    p.setlists={{id(17),"Lista",{id(2)}}};
    jaras::RegionSetlist rs; rs.autoAdvance=true; rs.autoUntilBlockEnd=true;
    rs.stopAtRegionEnd=true; rs.prepareWithoutPlayback=true; rs.automaticSubplay=true; rs.automaticSubplaySeconds=3.25;
    rs.liveEnabled=true; rs.playedLiveRegionIDs=std::vector<jaras::ID>{id(5)};
    rs.playlists={{id(18),"Repertório",id(2),{id(5),id(16)}}}; rs.selectedId=id(18);
    rs.blocks=std::vector<jaras::SetlistBlock>{{id(19),id(2),id(18),"Bloco",0x123456,id(5),true}};
    p.regionSetlist=rs;
    jaras::validate(p);
    return p;
}
}
int main(int argc, char **argv) {
    try {
        if (argc == 4 && std::string(argv[1]) == "--roundtrip-json") {
            std::ifstream in(std::filesystem::u8path(argv[2]));
            expect(in.is_open(), "Cannot read JSON fixture");
            json value; in >> value;
            const auto first = ProjectCodec::encode(ProjectCodec::decode(value),value);
            const auto second = ProjectCodec::encode(ProjectCodec::decode(first),first);
            expect(first == second,"Real project JSON is not stable");
            std::ofstream out(std::filesystem::u8path(argv[3])); out << second.dump();
            expect(bool(out),"Cannot write roundtrip evidence");
            std::cout << "REAL_PROJECT_JSON_ROUNDTRIP_OK\n"; return 0;
        }
        if (argc == 4 && (std::string(argv[1]) == "--roundtrip-project" || std::string(argv[1]) == "--decode-project")) {
            const auto original = ProjectCodec::read(std::filesystem::u8path(argv[2]));
            const auto output = ProjectCodec::encode(ProjectCodec::decode(original),original);
            if (std::string(argv[1]) == "--roundtrip-project")
                ProjectCodec::write(std::filesystem::u8path(argv[3]), output);
            else { std::ofstream file(std::filesystem::u8path(argv[3])); file << output.dump(); expect(bool(file),"Cannot write decoded JSON"); }
            std::cout << "PROJECT_FILE_ROUNDTRIP_OK\n"; return 0;
        }
        int passed=0;
        auto test=[&](const char *name,const std::function<void()> &work) {
            work(); ++passed; std::cout << "PASS " << name << '\n';
        };
        const auto model=fixture();
        const auto encoded=ProjectCodec::encode(model);
        test("all populated document fields survive model roundtrip",[&]{
            const auto decoded=ProjectCodec::decode(json::parse(encoded.dump()));
            expect(ProjectCodec::encode(decoded)==encoded,"Document/model roundtrip changed");
            expect(decoded.songs[0].tracks[0].clips[0].sourceOffset==model.songs[0].tracks[0].clips[0].sourceOffset,"Double precision lost");
            expect(decoded.songs[0].tracks[0].clips[1].midi->notes[0].length==model.songs[0].tracks[0].clips[1].midi->notes[0].length,"MIDI precision lost");
            expect(json::parse(*decoded.masterFXJSON)==json::parse(*model.masterFXJSON),"External plugin state lost");
            expect(decoded.songs[0].tracks[1].clips[0].timecodeEndOffset==1.25,"Timecode span lost");
            expect(decoded.songs[0].tracks[2].clickSound->path=="Stems/Click.wav","Click sound lost");
            expect(decoded.songs[0].tracks[3].clips[0].text=="Coração\n演奏","Unicode text lost");
        });
        test("unknown object fields survive ID based merge and edits",[&]{
            auto original=encoded;
            const json extension={{"version",9},{"list",json::array({nullptr,false,0,"símbolo"})}};
            for (const auto *pointer:{"","/songs/0","/songs/0/tracks/0","/songs/0/tracks/0/clips/0","/songs/0/tracks/0/clips/1/midi","/songs/0/tracks/0/clips/1/midi/grid","/songs/0/tracks/0/clips/1/midi/notes/0","/songs/0/parts/0","/songs/0/parts/0/multiLoops/0","/songs/0/parts/0/multiLoops/0/tracks/0","/songs/0/markers/0","/setlists/0","/regionSetlist","/regionSetlist/playlists/0","/regionSetlist/blocks/0"})
                original[json::json_pointer(pointer)]["futureExtension"]=extension;
            auto edited=ProjectCodec::decode(original); edited.name="Editado"; edited.songs[0].tracks[0].clips[0].gain=.8;
            auto output=ProjectCodec::encode(edited,original);
            auto expected=original;expected["name"]="Editado";expected["songs"][0]["tracks"][0]["clips"][0]["gain"]=.8;
            expect(output==expected,"Unknown field lost or edit failed");
        });
        test("absent default values stay absent and explicit edits persist",[&]{
            auto original=encoded;
            for (auto key:{"masterVolume","masterPan","masterMute","masterSolo","masterMono"})original.erase(key);
            auto &song=original["songs"][0];song.erase("beatsPerBar");song.erase("beatUnit");
            auto &clip=song["tracks"][0]["clips"][0];clip.erase("playbackRate");clip.erase("muted");
            original["regionSetlist"].erase("autoUntilBlockEnd");
            expect(ProjectCodec::encode(ProjectCodec::decode(original),original)==original,"Absent defaults materialized");
            auto edited=ProjectCodec::decode(original);edited.masterMono=true;edited.songs[0].tracks[0].clips[0].muted=true;
            auto result=ProjectCodec::encode(edited,original);
            expect(result["masterMono"]==true&&result["songs"][0]["tracks"][0]["clips"][0]["muted"]==true,"Default edit was discarded");
        });
        test("null routing slots and empty optional arrays retain their distinction",[&]{
            auto result=ProjectCodec::encode(ProjectCodec::decode(encoded));
            expect(result["songs"][0]["tracks"][0]["routing"]["receives"][0].is_null(),"Routing null lost");
            expect(result["songs"][0]["parts"][0]["pitchGroupIDs"].is_array(),"Empty optional array lost");
        });
        test("removed modeled FX and curves are removed from preserved original",[&]{
            auto edited=ProjectCodec::decode(encoded);edited.masterFXJSON.reset();edited.songs[0].tracks[0].fxJSON.reset();
            auto &clip=edited.songs[0].tracks[0].clips[0];clip.fxJSON.reset();clip.fadeInCurve.reset();clip.fadeOutSCurve.reset();
            auto output=ProjectCodec::encode(edited,encoded);
            expect(!output.contains("masterFX")&&!output["songs"][0]["tracks"][0].contains("fx"),"FX persisted after deletion");
            const auto &c=output["songs"][0]["tracks"][0]["clips"][0];
            expect(!c.contains("fx")&&!c.contains("fadeInCurve")&&!c.contains("fadeOutSCurve"),"Item state persisted after deletion");
        });
        test("cleared optional fields do not revive from preserved original",[&]{
            auto edited=ProjectCodec::decode(encoded);
            edited.masterPhaseInverted.reset(); edited.masterColor.reset(); edited.masterOutputs.reset(); edited.savedCursor.reset();
            auto &song=edited.songs[0]; song.timeSettings.reset();
            auto &track=song.tracks[0]; track.color.reset(); track.heightScale.reset(); track.phaseInverted.reset();
            auto &clip=track.clips[0]; clip.gain.reset(); clip.pan.reset(); clip.phaseInverted.reset();
            clip.fadeIn.reset(); clip.fadeOut.reset();
            // Moving an item outside all regions clears its established owner.
            // A save must not reacquire its old region from the source JSON.
            clip.startTime=50; clip.regionOwnerID.reset();
            song.tracks[3].clips[0].text.reset();
            song.parts[0].color.reset(); song.parts[0].uppercaseName.reset(); song.parts[1].parentRegionID.reset();
            auto &marker=(*song.markers)[0]; marker.tempoBPM.reset(); marker.section.reset(); marker.loopSection.reset();
            marker.tempoBeats.reset(); marker.tempoUnit.reset(); marker.tempoTimebase.reset(); marker.tempoReferenceBPM.reset();
            const auto output=ProjectCodec::encode(edited,encoded);
            for(const auto *key:{"masterPhaseInverted","masterColor","masterOutputs","savedCursor"})
                expect(!output.contains(key),"Cleared master optional survived");
            const auto &rs=output["songs"][0]; const auto &rt=rs["tracks"][0]; const auto &rc=rt["clips"][0];
            expect(!rs.contains("timeSettings"),"Cleared song time settings survived");
            for(const auto *key:{"color","heightScale","phaseInverted"}) expect(!rt.contains(key),"Cleared track optional survived");
            for(const auto *key:{"gain","pan","phaseInverted","fadeIn","fadeOut","regionOwnerID"})
                expect(!rc.contains(key),"Cleared item optional survived");
            expect(!rs["tracks"][3]["clips"][0].contains("text"),"Cleared text survived");
            expect(!rs["parts"][0].contains("color")&&!rs["parts"][0].contains("uppercaseName")&&!rs["parts"][1].contains("parentRegionID"),"Cleared region optional survived");
            for(const auto *key:{"tempoBPM","section","loopSection"}) expect(!rs["markers"][0].contains(key),"Cleared marker optional survived");
            const auto reloaded=ProjectCodec::decode(output);
            expect(!reloaded.songs[0].tracks[0].clips[0].regionOwnerID,"Reload restored previous music ownership");
            expect(!jaras::regionOwns(reloaded.songs[0],id(5),reloaded.songs[0].tracks[0].clips[0].regionOwnerID),"Detached item belongs to old music again");
            song.markers.reset(); for(auto &part:song.parts) part.multiLoops.clear();
            expect(!ProjectCodec::encode(edited,encoded)["songs"][0].contains("markers"),"Removed marker collection survived");
        });
        test("legacy UUID migration touches only document identities and references",[&]{
            auto original=encoded;
            const auto compact=[](std::string value){value.erase(std::remove(value.begin(),value.end(),'-'),value.end());return value;};
            // Every UUID in this fixture belongs to the known document schema.
            std::function<void(json&)> shorten=[&](json &value){
                if(value.is_object()||value.is_array()){for(auto &child:value)shorten(child);}
                else if(value.is_string())for(int i=1;i<=19;++i)if(value==id(i)){value=compact(id(i));break;}
            };
            shorten(original);
            auto expected=encoded;
            const auto legacy=compact(id(3));
            const json opaque={{"id",legacy},{"reference",legacy},{legacy,legacy+"-timecode"}};
            original["futureExtension"]=expected["futureExtension"]=opaque;
            original["songs"][0]["tracks"][0]["futureExtension"]=expected["songs"][0]["tracks"][0]["futureExtension"]=opaque;
            original["songs"][0]["tracks"][0]["stereoLink"]={{"partner",compact(id(8))},{"original",{{"routing",{{"receives",json::array({compact(id(10)),nullptr})},{"transmitters",json::array({compact(id(11))})}}}}}};
            expected["songs"][0]["tracks"][0]["stereoLink"]={{"partner",id(8)},{"original",{{"routing",{{"receives",json::array({id(10),nullptr})},{"transmitters",json::array({id(11)})}}}}}};
            original["resolume"]={{"withMarkers",{{"region:"+compact(id(5)),"2:4"},{"marker:"+compact(id(14)),"2:5"}}},{"futureExtension",opaque}};
            expected["resolume"]={{"withMarkers",{{"region:"+id(5),"2:4"},{"marker:"+id(14),"2:5"}}},{"futureExtension",opaque}};
            original["windowsLighting"]={{"assignments",{{"region:"+compact(id(5)),4}}},{"starts",{{compact(id(2)),opaque}}}};
            expected["windowsLighting"]={{"assignments",{{"region:"+id(5),4}}},{"starts",{{id(2),opaque}}}};
            const auto result=ProjectCodec::canonicalIDs(original);
            expect(result==expected,"Domain UUID was missed or opaque field was rewritten");
            expect(ProjectCodec::canonicalIDs(result)==result,"UUID migration is not idempotent");
            const std::string hexadecimal="abcdef0123456789abcdef0123456789";
            auto legacyTC=json{{"id",hexadecimal},{"songs",json::array({{{"tracks",json::array({{{"id",hexadecimal+"-timecode"}}})}}})}};
            auto migrated=ProjectCodec::canonicalIDs(legacyTC);
            expect(migrated["id"]=="ABCDEF01-2345-6789-ABCD-EF0123456789","Hexadecimal UUID not canonicalized");
            expect(migrated["songs"][0]["tracks"][0]["id"]=="2BCDEF01-2345-6789-ABCD-EF0123456789","Legacy timecode ID not canonicalized");
        });
        test("FX migration keeps insertion automation and opaque plugin state coherent",[&]{
            const std::string native="abcdef0123456789abcdef0123456789",band="0123456789abcdef0123456789abcdef",external="fedcba9876543210fedcba9876543210";
            const std::string nativeID="ABCDEF01-2345-6789-ABCD-EF0123456789",bandID="01234567-89AB-CDEF-0123-456789ABCDEF";
            const json opaque={{"id",native},{"classID",external},{band,native},{"nested",{{"id",band}}}};
            const json plugin={{"id",external},{"name","Kontakt"},{"classID",native},{"path","Kontakt.vst3"},{"componentState",native},{"controllerState",external},{"futureVendorState",opaque}};
            const json fx={{"inserted",json::array({"External:"+external,"Native:"+native})},{"externalPlugins",json::array({plugin})},
                {"bands",json::array({{{"id",band},{"futureExtension",opaque}}})},
                {"instances",json::array({{{"id",native},{"kind","EQ"},{"settings",{{"inserted",json::array({"EQ"})},{"bands",json::array({{{"id",band}}})},{"futureExtension",opaque}}}}})}};
            const json automation={{"envelopes",json::array({{{"id",native},{"target",{{"kind","nativeFX"},{"native",{{"effect","Native:"+native},{"band",band}}}}},{"points",json::array({{{"id",band},{"time",0},{"value",.5}}})}},
                {{"id",band},{"target",{{"kind","externalFX"},{"plugin",external},{"parameter",1}}},{"futureExtension",opaque}}})}};
            auto original=encoded;
            original["masterFX"]=fx; original["masterAutomation"]=automation;
            for(auto pointer:{"/songs/0/tracks/0","/songs/0/tracks/0/clips/0"}){
                original[json::json_pointer(pointer)]["fx"]=fx; original[json::json_pointer(pointer)]["automation"]=automation;
            }
            const auto result=ProjectCodec::encode(ProjectCodec::decode(original),original);
            for(auto pointer:{"/masterFX","/songs/0/tracks/0/fx","/songs/0/tracks/0/clips/0/fx"}){
                const auto &value=result[json::json_pointer(pointer)];
                expect(value["externalPlugins"][0]==plugin,"Opaque VST3 IDs/state changed");
                expect(value["inserted"][0]=="External:"+external,"External insertion detached");
                expect(value["instances"][0]["id"]==nativeID&&value["inserted"][1]=="Native:"+nativeID,"Native insertion detached");
                expect(value["bands"][0]["id"]==bandID&&value["instances"][0]["settings"]["bands"][0]["id"]==bandID,"EQ bands not normalized");
                expect(value["bands"][0]["futureExtension"]==opaque&&value["instances"][0]["settings"]["futureExtension"]==opaque,"Native opaque extensions changed");
            }
            for(auto pointer:{"/masterAutomation","/songs/0/tracks/0/automation","/songs/0/tracks/0/clips/0/automation"}){
                const auto &values=result[json::json_pointer(pointer)]["envelopes"];
                expect(values[0]["id"]==nativeID&&values[0]["points"][0]["id"]==bandID,"Envelope IDs not normalized");
                expect(values[0]["target"]["native"]["effect"]=="Native:"+nativeID&&values[0]["target"]["native"]["band"]==bandID,"Native automation detached");
                expect(values[1]["target"]["plugin"]==external&&values[1]["futureExtension"]==opaque,"External automation or opaque state changed");
            }
            expect(ProjectCodec::encode(ProjectCodec::decode(result),result)==result,"FX document changed on next save");
        });
        test("model validation rejects unsupported versions and corrupt values",[&]{
            auto invalid=encoded;invalid["projectFormatVersion"]=2;rejects([&]{ProjectCodec::decode(invalid);},"Unsupported version accepted");
            invalid=encoded;invalid["songs"][0]["tracks"][0]["clips"][0]["duration"]=-1;rejects([&]{ProjectCodec::decode(invalid);},"Invalid clip accepted");
            invalid=encoded;invalid["songs"][0]["tracks"][0]["clips"][0]["audioFile"]["path"]="../secret";rejects([&]{ProjectCodec::decode(invalid);},"Path traversal accepted");
            rejects([&]{ProjectCodec::decode(json::array());},"Root array accepted");
        });
        const auto root=std::filesystem::temp_directory_path()/std::filesystem::u8path("catlive-native-codec-"+std::to_string(std::chrono::high_resolution_clock::now().time_since_epoch().count()));
        struct Cleanup { std::filesystem::path root; ~Cleanup(){std::error_code error;std::filesystem::remove_all(root,error);} } cleanup{root};
        std::filesystem::create_directories(root/"Stems");
        test("plaintext document read preserves Unicode and model state",[&]{
            const auto file=root/"plain.json";std::ofstream(file,std::ios::binary)<<encoded.dump();
            expect(ProjectCodec::read(file)==encoded,"Plaintext read changed data");
            expect(ProjectCodec::unseal(std::vector<std::uint8_t>{'{','}'})=="{}","Legacy plaintext rejected");
            rejects([&]{ProjectCodec::unseal({1,2,3});},"Unknown document accepted");
        });
        test("media path resolution stays in project and keeps UTF8 paths",[&]{
            const auto media=root/std::filesystem::u8path("Stems/Órgão.wav");std::ofstream(media)<<"fixture";
            expect(ProjectCodec::resolveMedia(root,"Stems/Órgão.wav")==media,"Unicode media not resolved");
            expect(ProjectCodec::resolveMedia(root,"Stems\\Órgão.wav")==media,"Legacy slash not normalized");
            for(const auto &path:{"../other.wav","Stems/../../other.wav","C:/other.wav","/other.wav","."})
                rejects([&]{ProjectCodec::resolveMedia(root,path,false);},"Unsafe media path accepted");
        });
#ifdef _WIN32
        test("AES GCM document encryption is authenticated with fresh nonces",[&]{
            const auto plain=encoded.dump();const auto one=ProjectCodec::seal(plain),two=ProjectCodec::seal(plain);
            expect(one!=two,"Encryption reused nonce");expect(ProjectCodec::unseal(one)==plain,"GCM roundtrip failed");
            auto bad=one;bad.back()^=1;rejects([&]{ProjectCodec::unseal(bad);},"GCM authentication ignored");
            bad.resize(20);rejects([&]{ProjectCodec::unseal(bad);},"Truncated ciphertext accepted");
        });
        test("atomic encrypted save reopens and protects sibling projects",[&]{
            const auto file=root/"project.jl";ProjectCodec::write(file,encoded);expect(ProjectCodec::read(file)==encoded,"Saved document changed");
            auto changed=encoded;changed["name"]="Atualizado";ProjectCodec::write(file,changed);expect(ProjectCodec::read(file)==changed,"Atomic replacement failed");
            rejects([&]{ProjectCodec::write(root/"sibling.jl",encoded);},"Sibling project allowed");
            expect(ProjectCodec::read(file)==changed&&!std::filesystem::exists(root/"sibling.jl"),"Failed write damaged original");
        });
#endif
        std::cout<<"PROJECT_CODEC_TESTS_PASSED="<<passed<<'\n';return 0;
    }catch(const std::exception &error){std::cerr<<"FAIL "<<error.what()<<'\n';return 1;}
}
