#pragma once
#include "TrackDuplication.h"
namespace catlive::trackDuplicationTests {
inline void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
inline var findTrack(const var &document, const ID &identity) {
    for (auto song : list(get(document, "songs"))) for (auto track : list(get(song, "tracks")))
        if (utf8(str(track, "id")) == identity) return track;
    throw std::runtime_error("Duplicated track not found");
}
inline jaras::Track track(const char *name) {
    jaras::Track value; value.id = uuid(); value.name = name; value.role.id = "keys"; return value;
}
inline jaras::Project fixture() {
    jaras::Project p; p.id = uuid(); p.name = "Complete track copy";
    p.createdAt = p.updatedAt = "2026-10-16T12:00:00Z";
    jaras::Song song; song.id = uuid(); song.name = "Show"; song.duration = 120;
    auto source = track("Piano"); source.volume = .72; source.pan = -.31; source.color = 0x456789;
    source.phaseInverted = true; source.heightScale = .5; source.inputPatch = jaras::OutputPatch{4,1};
    source.recordingChannels = 1; source.recordingFormat = "wav32"; source.inputMonitoring = false;
    source.outputs = std::vector<jaras::OutputPatch>{{0,2},{3,2}};
    source.fxJSON = R"({"inserted":["EQ","Native:native","External:kontakt"],"bands":[{"id":"base-band","frequency":824,"gain":3}],"instances":[{"id":"native","kind":"EQ","settings":{"inserted":["EQ"],"bands":[{"id":"repeat-band","frequency":1300,"gain":-4}]}}],"externalPlugins":[{"id":"kontakt","classID":"00112233445566778899AABBCCDDEEFF","name":"Kontakt","path":"Kontakt.vst3","componentState":"bGlicmFyeS1zdGF0ZQ==","controllerState":"aW5zdHJ1bWVudC1lZGl0cw==","vendor":{"id":"native","reference":"kontakt"}}]})";
    source.automationJSON = R"({"mode":"latch","envelopes":[{"id":"native-envelope","target":{"kind":"nativeFX","native":{"effect":"Native:native","band":"repeat-band"}},"points":[{"id":"native-point","time":2,"value":0.7}]},{"id":"plugin-envelope","target":{"kind":"externalFX","plugin":"kontakt","parameter":12},"points":[{"id":"plugin-point","time":4,"value":0.3}]}]})";
    jaras::AudioClip item; item.id = uuid(); item.name = "MIDI"; item.startTime = 3; item.duration = 8;
    item.midi.emplace(); item.midi->notes = {{uuid(),1,2,64,110,1}};
    item.fadeIn = .3; item.fadeOut = 1.5; item.fadeInCurve = .2; item.fadeOutSCurve = -.6;
    item.gain = .6; item.pan = .2; item.fxJSON = source.fxJSON; item.automationJSON = source.automationJSON;
    source.clips = {item};
    auto other = track("Receiver"); other.routing.emplace(); other.routing->receives.push_back(source.id);
    song.tracks = {source,other};
    jaras::Part region; region.id = uuid(); region.name = "Music"; region.startTime = 0; region.endTime = 60;
    region.pitchTrackIDs = std::vector<ID>{source.id};
    jaras::MultiLoop loop; loop.id = uuid(); loop.name = "Loop"; loop.marker1 = uuid(); loop.marker2 = uuid();
    loop.tracks = {{source.id,.5,true,false,true}}; region.multiLoops = {loop}; song.parts = {region};
    jaras::TimelineMarker a,b;a.id=loop.marker1;a.name="A";a.position=2;a.color=0xffdc52;
    b.id=loop.marker2;b.name="B";b.position=10;b.color=0xffdc52;song.markers=std::vector<jaras::TimelineMarker>{a,b};
    song.tracks[0].clips[0].regionOwnerID = region.id; p.songs = {song};
    p.setlists = {{uuid(),"Show",{song.id}}}; jaras::validate(p); return p;
}
inline bool same(const var &a, const var &b) { return JSON::toString(a,true,17) == JSON::toString(b,true,17); }
template <typename Test> inline void run(Test &&test) {
    test("Complete track copy keeps FX payloads and remaps item automation identities", [] {
        const auto p = fixture(); const auto &song = p.songs[0]; const auto sourceID = song.tracks[0].id;
        auto raw = ProjectCodec::encode(p); auto source = findTrack(raw,sourceID);
        auto item = list(get(source,"clips"))[0];
        put(source,"futureTrackState",JSON::parse(R"({"id":"native","value":"kontakt"})"));
        put(item,"fadeTimelineStart",1.25); put(item,"fadeTimelineDuration",14.5); put(item,"automationSourceOffset",2.5);
        const auto before = JSON::toString(raw,true,17);
        const auto result = trackEditing::duplicateDocument(raw,song.id,{sourceID});
        expect(JSON::toString(raw,true,17)==before,"Duplication mutated original document");
        expect(result.trackIDs.size()==1,"Wrong copy count");
        const auto copied = findTrack(result.document,result.trackIDs[0]);
        const auto copiedItem = list(get(copied,"clips"))[0];
        expect(same(findTrack(result.document,sourceID),source),"Source track changed");
        expect(same(get(source,"futureTrackState"),get(copied,"futureTrackState")),"Unknown track data lost");
        for (const auto *key : {"volume","pan","color","heightScale","phaseInverted","inputPatch","outputs","recordingFormat","inputMonitoring"})
            expect(same(get(source,Identifier(key)),get(copied,Identifier(key))),"Track controls changed");
        for (const auto *key : {"startTime","duration","fadeIn","fadeOut","fadeInCurve","fadeOutSCurve","fadeTimelineStart","fadeTimelineDuration","automationSourceOffset","regionOwnerID"})
            expect(same(get(item,Identifier(key)),get(copiedItem,Identifier(key))),"Item geometry or processing changed");
        expect(str(item,"id")!=str(copiedItem,"id"),"Item identity shared");
        expect(str(list(get(get(item,"midi"),"notes"))[0],"id")!=str(list(get(get(copiedItem,"midi"),"notes"))[0],"id"),"MIDI note identity shared");
        for (const auto &owner : {copied,copiedItem}) {
            auto fx=get(owner,"fx"); auto plugin=list(get(fx,"externalPlugins"))[0]; auto instance=list(get(fx,"instances"))[0];
            expect(str(plugin,"id")!="kontakt" && str(instance,"id")!="native","Plugin instance identity shared");
            expect(str(plugin,"componentState")=="bGlicmFyeS1zdGF0ZQ=="&&str(plugin,"controllerState")=="aW5zdHJ1bWVudC1lZGl0cw==","Plugin state lost");
            expect(str(get(plugin,"vendor"),"id")=="native"&&str(get(plugin,"vendor"),"reference")=="kontakt","Opaque plugin data rewritten");
            const auto inserted=list(get(fx,"inserted"));
            expect(inserted[1].toString()=="Native:"+str(instance,"id")&&inserted[2].toString()=="External:"+str(plugin,"id"),"FX insertion detached");
            const auto envelopes=list(get(get(owner,"automation"),"envelopes"));
            const auto native=get(get(envelopes[0],"target"),"native");
            expect(str(native,"effect")==inserted[1].toString()&&str(native,"band")==str(list(get(get(instance,"settings"),"bands"))[0],"id"),"Native automation detached");
            expect(str(get(envelopes[1],"target"),"plugin")==str(plugin,"id"),"External automation detached");
            expect(str(envelopes[0],"id")!="native-envelope"&&str(list(get(envelopes[0],"points"))[0],"id")!="native-point","Envelope identity shared");
        }
        expect(str(list(get(get(copied,"fx"),"externalPlugins"))[0],"id")!=str(list(get(get(copiedItem,"fx"),"externalPlugins"))[0],"id"),"Track and item FX share identity");
        const auto decoded=ProjectCodec::decode(result.document);
        expect(decoded.songs[0].tracks[1].id==result.trackIDs[0],"Copy not directly after source");
        const auto &copy=decoded.songs[0].tracks[1];
        expect(copy.routing&&std::find(copy.routing->transmitters.begin(),copy.routing->transmitters.end(),song.tracks[1].id)!=copy.routing->transmitters.end(),"Opposite-endpoint routing missing");
        expect(decoded.songs[0].parts[0].pitchTrackIDs->back()==copy.id&&decoded.songs[0].parts[0].multiLoops[0].tracks.back().id==copy.id,"Region pitch or multiloop selection missing");
    });
    test("Complete track duplication preserves folder stereo hierarchy and selected children", [] {
        auto p=fixture(); auto &song=p.songs[0]; auto folder=track("Folder"),left=track("L"),right=track("R"),outside=track("Outside");
        left.parentTrackID=right.parentTrackID=folder.id; left.patch=right.patch=jaras::OutputPatch{-2,2};
        left.inputPatch=jaras::OutputPatch{1,1};right.inputPatch=jaras::OutputPatch{2,1};left.pan=-1;right.pan=1;
        const auto link=[&](const ID &partner,bool isLeft) {
            auto value=object();put(value,"partner",text(partner));put(value,"left",isLeft);put(value,"original",object());return utf8(JSON::toString(value,true,17));
        };
        left.stereoLinkPartner=right.id;left.stereoLinkLeft=true;left.stereoLinkJSON=link(right.id,true);
        right.stereoLinkPartner=left.id;right.stereoLinkJSON=link(left.id,false);
        song.tracks={folder,left,right,outside};song.parts.clear();song.markers.reset();
        auto result=trackEditing::duplicateDocument(ProjectCodec::encode(p),song.id,{folder.id,left.id});
        auto copied=ProjectCodec::decode(result.document).songs[0];
        expect(result.trackIDs.size()==3&&copied.tracks.size()==7,"Folder descendants duplicated more than once");
        expect(copied.tracks[3].id==result.trackIDMap.at(folder.id)&&copied.tracks[4].parentTrackID==copied.tracks[3].id&&copied.tracks[5].parentTrackID==copied.tracks[3].id,"Folder inserted outside source block or parents detached");
        expect(copied.tracks[4].stereoLinkPartner==copied.tracks[5].id&&copied.tracks[5].stereoLinkPartner==copied.tracks[4].id,"Stereo pair detached");
        result=trackEditing::duplicateDocument(ProjectCodec::encode(p),song.id,{left.id});
        copied=ProjectCodec::decode(result.document).songs[0];
        expect(result.trackIDs.size()==2&&copied.tracks[3].parentTrackID==folder.id&&copied.tracks[4].parentTrackID==folder.id,"Selected child failed to clone its linked partner in original folder");
    });
    test("Track duplication excludes unique tracks and fails atomically on ID collision", [] {
        auto p=fixture(); auto &song=p.songs[0]; song.tracks.clear();song.parts.clear();song.markers.reset();
        std::set<ID> selected;
        for (const auto *role:{"generatedClick","timecode","video","teleprompt","teleprompt2","chords"}) {
            auto value=track(role);value.role.id=role;value.name=jaras::fixedTrackName(value.role);selected.insert(value.id);song.tracks.push_back(value);
        }
        const auto raw=ProjectCodec::encode(p);const auto result=trackEditing::duplicateDocument(raw,song.id,selected);
        expect(result.trackIDs.empty()&&same(raw,result.document),"Special track was duplicated");
        p=fixture(); const auto source=p.songs[0].tracks[0].id; const auto before=ProjectCodec::encode(p);
        bool rejected=false;try{trackEditing::duplicateDocument(before,p.songs[0].id,{source},[&]{return source;});}catch(const std::exception&){rejected=true;}
        expect(rejected&&same(before,ProjectCodec::encode(p)),"Colliding ID changed the original");
    });
}
template <typename SessionType, typename Test> inline void runSession(Test &&test) {
    test("Complete track duplication is one Undo and Redo with opaque fields", [] {
        const auto p=fixture(); auto raw=ProjectCodec::encode(p);auto source=findTrack(raw,p.songs[0].tracks[0].id);
        put(source,"futureData",JSON::parse(R"({"original":"preserve"})"));
        auto originalItem=list(get(source,"clips"))[0];
        put(originalItem,"fadeTimelineStart",1.25);put(originalItem,"fadeTimelineDuration",12.5);put(originalItem,"automationSourceOffset",2.75);
        SessionType session;session.restoreSnapshot(raw);
        const auto before=session.snapshot();
        const auto added=session.duplicateTracks({p.songs[0].tracks[0].id});
        expect(added.size()==1&&session.song()->tracks.size()==3,"Session did not duplicate");
        const auto after=session.snapshot();
        expect(same(get(findTrack(after,added[0]),"futureData"),get(source,"futureData")),"Preserved document not committed");
        const auto copiedItem=list(get(findTrack(after,added[0]),"clips"))[0];
        for(const auto *key:{"fadeTimelineStart","fadeTimelineDuration","automationSourceOffset"})
            expect(same(get(copiedItem,Identifier(key)),get(originalItem,Identifier(key))),"Copied item lost unmodeled timing offset");
        session.undo();expect(same(before,session.snapshot()),"One Undo did not restore exact original");
        session.redo();expect(same(after,session.snapshot()),"Redo did not restore copied state and identities");
    });
}
} // namespace catlive::trackDuplicationTests
