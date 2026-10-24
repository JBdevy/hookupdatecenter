const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'Windows/Source/StageContent.h'), 'utf8');
function slice(a, b) {
  const start = source.indexOf(a), end = source.indexOf(b, start);
  if (start < 0 || end < 0) throw Error('Production preview section missing');
  return source.slice(start, end);
}
const cpp = `
#include "Core/Project/Models.hpp"
#include <algorithm>
#include <cassert>
#include <functional>
#include <iostream>
#include <map>
#include <set>
using ID=jaras::ID;
template<class T> T jlimit(T low,T high,T value){return std::clamp(value,low,high);}
struct SessionFixture{const jaras::Project &value;const jaras::Project &project()const{return value;}};
struct Preview {std::vector<ID> rows,sources;std::vector<std::vector<ID>> anchors;std::set<ID> marks;std::optional<ID> active,queued;double countdown=0;};
Preview inspect(const jaras::Project &project,const jaras::TransportState &transport){
  SessionFixture session{project};const auto *song=&project.songs[0];const jaras::Part *current=nullptr;
  for(const auto &part:song->parts)if(transport.position>=part.startTime&&transport.position<part.endTime&&(!current||part.endTime-part.startTime<current->endTime-current->startTime))current=&part;
  ${slice('            std::vector<std::pair<ID,const jaras::Part*>> roots;', '            auto block=')}
  ${slice('            std::set<ID> played;', '            for(const auto &entry:regions){\n                const auto *part=entry.second;')}
  Preview result;
  for(const auto &row:regions){result.rows.push_back(row.first);result.sources.push_back(row.second->id);result.anchors.push_back(row.anchors);}
  result.marks=played;result.active=playingEntry;result.queued=queuedEntry;result.countdown=queueProgress;return result;
}
int main(){
 const ID parent="00000000-0000-0000-0000-000000000001",first="00000000-0000-0000-0000-000000000002",second="00000000-0000-0000-0000-000000000003",copy="00000000-0000-0000-0000-000000000004";
 jaras::Project project;jaras::Song song;song.id="00000000-0000-0000-0000-000000000010";song.duration=200;
 jaras::Part group;group.id=parent;group.name="Hidden wrapper";group.endTime=200;
 jaras::Part one;one.id=first;one.startTime=0;one.endTime=100;one.parentRegionID=parent;
 auto two=one;two.id=second;two.startTime=100;two.endTime=200;
 song.parts={group,two,one};project.songs={song};project.regionSetlist.emplace();
 auto &setlist=*project.regionSetlist;setlist.playedLiveRegionIDs=std::vector<ID>{first};
 jaras::TransportState transport;transport.playing=true;transport.regionId=parent;transport.position=25;
 auto preview=inspect(project,transport);
 assert(preview.rows==std::vector<ID>({first,second}));assert(preview.marks.empty());assert(preview.active==first);assert(!preview.queued);
 assert(preview.anchors[0]==std::vector<ID>({parent,first}));
 setlist.liveEnabled=true;preview=inspect(project,transport);assert(preview.marks.count(first)&&!preview.marks.count(second)&&!preview.marks.count(parent));
 jaras::RegionPlaylist playlist;playlist.id="00000000-0000-0000-0000-000000000020";playlist.songId=song.id;playlist.regionIds={parent,copy};playlist.duplicates=std::vector<jaras::RegionPlaylistDuplicate>{{copy,parent}};
 setlist.playlists={playlist};setlist.selectedId=playlist.id;
 transport.playlistEntryId=copy;transport.queuedRegionId=parent;transport.queuedPlaylistEntryId=parent;transport.queueStartedAt=0;
 preview=inspect(project,transport);assert(preview.rows.size()==4&&std::set<ID>(preview.rows.begin(),preview.rows.end()).size()==4);
 assert(preview.active==preview.rows[2]);assert(preview.queued==preview.rows[0]);assert(preview.countdown==.875);
 transport.queuedPlaylistEntryId=copy;preview=inspect(project,transport);assert(preview.queued==preview.rows[2]);
 setlist.liveEnabled=false;assert(inspect(project,transport).marks.empty());
 setlist.liveEnabled=true;setlist.playedLiveRegionIDs=std::vector<ID>{};assert(inspect(project,transport).marks.empty());
 std::cout<<"WINDOWS_PREVIEW_ROWS_OK: drawer-only rows, Live gate/reset, distinct copies and countdown\\n";
}
`;
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'catlive-preview-rows-'));
try {
 const file=path.join(directory,'test.cpp'),exe=path.join(directory,process.platform==='win32'?'test.exe':'test');fs.writeFileSync(file,cpp);
 const win=process.platform==='win32';
 const result=spawnSync(win?'cl.exe':process.env.CXX||'c++',win?['/nologo','/std:c++17','/EHsc','/utf-8','/I'+root,'/Fe:'+exe,file]:['-std=c++17','-Wall','-Wextra','-I',root,file,'-o',exe],{cwd:directory,encoding:'utf8'});
 process.stdout.write(result.stdout||'');process.stderr.write(result.stderr||'');if(result.error||result.status!==0)throw result.error||Error('compile failed');
 const run=spawnSync(exe,[],{encoding:'utf8'});process.stdout.write(run.stdout||'');process.stderr.write(run.stderr||'');if(run.error||run.status!==0)throw run.error||Error('preview fixture failed');
}finally{fs.rmSync(directory,{recursive:true,force:true});}
