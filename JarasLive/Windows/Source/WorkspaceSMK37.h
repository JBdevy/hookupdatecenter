// Included after Workspace and Setlist implementations.
namespace catlive {
void Workspace::performSMK37(int pad) {
    if(!projectReady||loginPanel||browserVisible||!actions.learning.isEmpty()||session.busy)return;
    auto say=[&](String value,unsigned rgb=0xeeeeee){smk37->feedback(value,rgb);};
    if(pad==0){session.toggleRecording();if(!session.audio.isRecording())say("REC DESATIVADO",0xff4040);}
    else if(pad==2){performAction("togglePreview",1,0);say(stage.preview?"PREVIEW ATIVADO":"PREVIEW DESATIVADO",0x55cfff);}
    else if(pad==3||pad==4){tracksViewport.setViewPosition(tracksViewport.getViewPositionX(),std::max(0,tracksViewport.getViewPositionY()+(pad==3?-72:72)));say(pad==3?"TRACK MIXER ACIMA":"TRACK MIXER ABAIXO");}
    else if(pad==5||pad==6||pad==13||pad==14){
        const bool queued=pad==5||pad==6;const int direction=pad==5||pad==13?-1:1;
        PartsPanel *panel=nullptr;
        if(partsLeft->isShowing()&&partsSidebar->isShowing())panel=queued?partsLeft.get():partsSidebar.get();
        else if(partsLeft->isShowing())panel=partsLeft.get();else if(partsSidebar->isShowing())panel=partsSidebar.get();
        if(panel)if(auto marker=panel->navigate(queued,direction)){auto rows=panel->smkList(queued);smk37->navigation(queued?3:2,rows.first,rows.second);setlist->repaint();}
    }else if(pad==7){performAction("toggleAuto",1,0);say(session.project().regionSetlist.value_or(jaras::RegionSetlist{}).autoAdvance?"AUTO ATIVO":"AUTO DESATIVADO",0xe67e22);}
    else if(pad==8){session.command(session.transport().playing||session.transport().paused?jaras::CommandKind::stop:jaras::CommandKind::play);say(session.transport().playing?"PLAY":"STOP",session.transport().playing?0x2ecc71:0xff4040);}
    else if(pad==9){session.command(jaras::CommandKind::pause);if(!session.transport().paused)say(session.transport().playing?"PLAY":"STOP");}
    else if(pad==10){session.command(jaras::CommandKind::toggleLoop);if(!session.transport().loop.enabled&&!session.transport().multiLoop)say("LOOP DESATIVADO");}
    else if(pad==11||pad==12){setlist->stepSelection(pad==11?-1:1);auto rows=setlist->smkList();smk37->navigation(1,rows.first,rows.second);}
    else if(pad==15){if(session.smkPart)session.command(jaras::CommandKind::queueSection,*session.smkPart);else setlist->activateSelection();}
    updateSMK37();
}
void Workspace::updateSMK37() {
    if(!smk37)return;smk37->poll();
    if(!projectReady||!vinhetasPanel)return;
    const auto lists=session.project().regionSetlist.value_or(jaras::RegionSetlist{});
    String playlist="All regions";for(const auto &list:lists.playlists)if(lists.selectedId==list.id && session.song() && list.songId==session.song()->id){playlist=text(list.name);break;}
    smk37->playlist(playlist);
    smk37->library(vinhetasPanel->remoteSnapshot(true));
    smk37->fadeoutProgress(session.transportFadeoutActive(),session.transportFadeoutRemaining(),session.transportFadeoutDuration());
    const auto t=session.presentationTransport();const auto *song=session.song();const auto *region=session.core.sectionPlaybackRegion();
    smk37->playback(t.position,region?region->startTime:0,region?region->endTime:song?song->duration:0);
    String label=region?text(region->name):String();unsigned colour=region?region->color.value_or(0xffb347):0xffb347;
    const bool looping=t.loop.enabled||(t.multiLoop&&t.multiLoop->gates&&!t.multiLoop->released);
    const bool total=t.multiLoop&&region&&t.multiLoop->id==region->id&&region->totalLoop.value_or(false);
    const auto start=t.loop.enabled?t.loop.start:t.multiLoop?std::optional<double>(t.multiLoop->start):std::nullopt;
    if(!total&&start&&song&&song->markers){const jaras::TimelineMarker *best=nullptr;for(const auto &m:*song->markers)if(m.section.value_or(false)&&m.position>=(region?region->startTime:0)&&m.position<=*start+.000001&&(!best||m.position>best->position))best=&m;if(best){label=text(best->name);colour=best->color;}}
    smk37->transport(t.paused,session.audio.isRecording(),looping,session.project().regionSetlist.value_or(jaras::RegionSetlist{}).autoAdvance,stage.preview,t.playing,t.queuedRegionId.has_value(),label,colour);
}
}
