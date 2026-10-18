#!/usr/bin/env python3
"""Compare current Mac/Windows imports of identical DAW source documents."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])

def canonical(project):
    song = project['songs'][0]
    tracks, parts, markers = song['tracks'], song['parts'], song.get('markers') or []
    ids = {}
    for i, track in enumerate(tracks): ids[track['id'].lower()] = f'track:{i}'
    for part in parts: ids[part['id'].lower()] = f"part:{part['startTime']:.9f}:{part['endTime']:.9f}:{part['name']}"
    for marker in markers: ids[marker['id'].lower()] = f"marker:{marker['position']:.9f}:{bool(marker.get('tempoBPM'))}"
    def ref(value): return ids.get(str(value).lower(), value)
    def chosen(value, defaults): return {key: value.get(key, default) for key, default in defaults.items()}
    def clip(value):
        result = chosen(value, dict(name='', startTime=0, duration=0, sourceOffset=0, playbackRate=1, pitchSemitones=0, gain=1, pan=0, muted=False, phaseInverted=False, fadeIn=0, fadeOut=0, loopStart=None, loopLength=None, text=None))
        if value.get('midi'):
            result['midi'] = dict(sourceBPM=value['midi'].get('sourceBPM',120), notes=[chosen(n,dict(start=0,length=1,pitch=60,velocity=100,channel=1)) for n in value['midi']['notes']])
        return result
    def loop(value):
        result = chosen(value,dict(name='',fadeSeconds=3,enabled=False,mixerEnabled=False))
        result.update(marker1=ref(value['marker1']),marker2=ref(value['marker2']))
        result['tracks'] = [dict(chosen(t,dict(gain=1,mute=False,solo=False,autoFader=False)),id=ref(t['id'])) for t in value.get('tracks',[])]
        return result
    def part(value):
        result = chosen(value,dict(name='',startTime=0,endTime=0,color=None,pitchSemitones=0))
        result['parentRegionID'] = ref(value.get('parentRegionID'))
        for key in ['pitchTrackIDs','pitchGroupIDs']: result[key] = [ref(i) for i in value[key]] if value.get(key) is not None else None
        result['multiLoops'] = [loop(l) for l in value.get('multiLoops') or []]
        return result
    def marker(value):
        result = chosen(value,dict(name='',position=0,color=0,section=False,loopSection=False,tempoBPM=None,tempoBeats=None,tempoUnit=None,tempoTimebase=None,tempoReferenceBPM=None))
        for key in ['unifiedRegionID','sourceRegionID']: result[key]=ref(value.get(key))
        return result
    result = chosen(song,dict(bpm=120,beatsPerBar=4,beatUnit=4,duration=1))
    result['tracks'] = [dict(chosen(t,dict(name='',color=None,volume=1,pan=0,mute=False,solo=False,phaseInverted=False)),role=t['role'],parentTrackID=ref(t.get('parentTrackID')),clips=[clip(c) for c in t['clips']]) for t in tracks]
    result['parts'] = sorted([part(p) for p in parts],key=lambda p:(p['startTime'],-p['endTime'],p['name']))
    result['markers'] = sorted([marker(m) for m in markers],key=lambda m:(m['position'],m['tempoBPM'] is not None,m['name']))
    setlist=project.get('regionSetlist') or {}
    lists=setlist.get('playlists',[])
    pids={p['id'].lower():i for i,p in enumerate(lists)}
    result['playlists']=[dict(name=p['name'],regionIds=[ref(r) for r in p['regionIds']]) for p in lists]
    result['selectedPlaylist']=pids.get(str(setlist.get('selectedId')).lower())
    result['blocks']=[dict(name=b['name'],color=b['color'],symbol=b.get('symbol',True),before=ref(b.get('beforeRegionId')),playlist=pids.get(str(b.get('playlistId')).lower())) for b in setlist.get('blocks') or []]
    return result

def differences(a,b,at=''):
    if isinstance(a,dict) and isinstance(b,dict):
        for key in a.keys()|b.keys():
            if key not in a or key not in b: yield at+'/'+key, a.get(key), b.get(key)
            else: yield from differences(a[key],b[key],at+'/'+key)
    elif isinstance(a,list) and isinstance(b,list):
        if len(a)!=len(b): yield at+'/length',len(a),len(b)
        for i,(x,y) in enumerate(zip(a,b)): yield from differences(x,y,at+'/'+str(i))
    elif isinstance(a,(float,int)) and isinstance(b,(float,int)):
        if abs(a-b)>1e-6: yield at,a,b
    elif a!=b: yield at,a,b

failures=[]; count=0
for case in json.loads((root/'parity-cases.json').read_text()):
    if not case['success']: continue
    count+=1
    mac=canonical(json.loads((root/'mac-results'/f"{case['name']}.json").read_text()))
    windows=canonical(case['project'])
    for at,a,b in differences(mac,windows): failures.append(f"{case['name']}{at}: Mac={a!r}; Windows={b!r}")
if failures: raise SystemExit('\n'.join(failures))
print(f'{count} identical source projects match Mac/Windows: tracks, items, pitch, markers, regions, playlists, blocks and multiloops.')
