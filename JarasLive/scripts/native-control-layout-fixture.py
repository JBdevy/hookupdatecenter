# Extract real control markup; stub only commands and unopened editors.
from pathlib import Path
import sys
script=Path('scripts/test-native-control-pulses.sh').read_text();generator=script.split("<<'PYTEST'\n",1)[1].split('\nPYTEST\n',1)[0]
output = Path(sys.argv[1]) / 'main.swift'
sys.argv=['generator',str(output)];exec(generator)
p=output;prefix=p.read_text().split('\nMainActor.assumeIsolated {',1)[0]
main = Path('Apple/Shared/MainView.swift').read_text()
prefix += main[main.index('enum SidebarWidthLimits {'):main.index('private struct WorkspaceProjectIdentity:')]
prefix = prefix.replace('@MainActor final class ShowProjectPresentation:', 'final class ShowProjectPresentation:')
song=Path('Apple/Shared/SongListView.swift').read_text();a=song.index('private struct RegionStopButton:');stop=song[a:song.index('\n#if os(macOS)',a)].replace('private struct RegionStopButton:','struct RegionStopButton:')
legacy=stop.replace('RegionStopButton:','LegacyRegionStopButton:').replace('JarasBlink(','BaselineJarasBlink(')
a=song.index('            HStack(spacing: 3) {',song.index('let playbackEnd'));end=song.index('}.padding(.horizontal, 8).padding(.bottom, 6)',a)+len('}.padding(.horizontal, 8).padding(.bottom, 6)');header=song[a:end]
def matched(s,a,left,right):
 d=1;i=a+1
 while d:
  if s[i]==left:d+=1
  if s[i]==right:d-=1
  i+=1
 return i
# Remove behavior-only modifiers and replace callbacks, retaining production
# controls, labels, spacing, framing, padding, disabled states and alignment.
for token in ['.popover(','.immediateRightClick {','.background(PlaylistPopoverSpaceReader']:
 while token in header:
  a=header.index(token)
  if '(' in token:
   o=header.index('(',a);end=matched(header,o,'(',')')
   while end<len(header) and header[end].isspace():end+=1
   if token.startswith('.popover') and header[end]=='{':end=matched(header,end,'{','}')
  else:
   o=header.index('{',a);end=matched(header,o,'{','}')
  header=header[:a]+header[end:]
start=0
while True:
 try:a=header.index('Button {',start)
 except ValueError:break
 o=header.index('{',a);end=matched(header,o,'{','}');header=header[:o]+'{}'+header[end:];start=o+2
header=header.replace('RegionStopButton(active: setlist.stopsAtRegionEnd) { show.toggleRegionStop() }','RegionStopButton(active: active) {}.background(PulseSizingProbe(name: "stop"))')
for label,name in [('Choose playlist','choose'),('Create playlist','create'),('Search songs (Tab)','search'),('Queue the next song automatically','auto'),('Add a setlist block','blocks')]:
 header=header.replace('.jarasHelp("'+label+'")','.jarasHelp("'+label+'").background(PulseSizingProbe(name: "'+name+'"))')
base='''
struct GeometryPlaylist { let name = "EVENTO" }
struct GeometrySetlist { var autoAdvance = true }
'''
for typename,body in [('NativeHeaderFixture',header),('LegacyHeaderFixture',header.replace('RegionStopButton(','LegacyRegionStopButton('))]:
 base+='''
struct '''+typename+''': View {
 let active: Bool
 let width: CGFloat
 let playlist: GeometryPlaylist? = GeometryPlaylist()
 let setlist = GeometrySetlist()
 let query = ""
 var body: some View {
  VStack(alignment: .leading,spacing:0) {
'''+body+'''.background(PulseSizingProbe(name:"header"))
   Text("FIRST ROW").frame(height:32).background(PulseSizingProbe(name:"first"))
   Spacer(minLength:0)
  }.frame(width:width,height:650,alignment:.topLeading)
 }
}
'''
p.write_text(prefix+'\n'+stop+'\n'+legacy+'\n'+base+'\n'+Path('Tests/Apple/NativeControlLayoutSupport.swift').read_text())

def until(src,begin,end):
 a=src.index(begin);return src[a:src.index(end,a)]
def balanced(src,a):
 d=1;i=a+1
 while d:
  if src[i]=='{':d+=1
  if src[i]=='}':d-=1
  i+=1
 return i
transport=Path('Apple/Shared/TransportView.swift').read_text()
parts=[]
metronome = until(transport,'private struct MetronomeControl:','#if os(macOS)\nprivate struct NativeMetronomePulse<')
a = metronome.index('    var body: some View {'); b = metronome.index('    private var control:', a)
metronome = metronome[:a] + '    var body: some View { control }\n' + metronome[b:]
parts.append(metronome.replace('MetronomeControl:', 'LegacyMetronomeControl:'))

parts.append(until(transport,'private struct ProjectSaveButton:','enum TransportControlMetrics'))
parts.append(until(transport,'private struct ProjectSaveButton:','private struct JarasSavePulse:')
    .replace('ProjectSaveButton:', 'LegacyProjectSaveButton:').replace('JarasSavePulse(', 'BaselineJarasSavePulse('))
parts.append(until(transport,'private struct PanelCollapseButton:','private struct TempoControl:'))
parts.append(until(transport,'private struct TempoControl:','private struct ProjectSaveButton:'))
parts.append(until(transport,'private struct RepeatControl:','#if os(macOS)').replace('private struct RepeatControl:','struct RepeatControl:'))
parts.append(parts[-1].replace('RepeatControl:','LegacyRepeatControl:').replace('JarasBlink(','BaselineJarasBlink('))
parts.append('#if os(macOS)\n'+until(transport,'private struct VideoToggleButton:','struct DesktopMultiLoopBypassButton:'))
tp=Path('Apple/Shared/TeleprompterWindow.swift').read_text()
parts.append(until(tp,'struct TeleprompterToggleButton:','private struct TeleprompterProjectionView:'))
parts.append(until(tp,'struct TPNoticeButton:','private struct TPNoticeEditor:'))
timer=Path('Apple/Shared/TeleprompterTimerControl.swift').read_text();a=timer.index('/// Only this small control');parts.append(timer[a:timer.rindex('\n#endif')])
record=Path('Apple/Shared/TrackRecording.swift').read_text();parts.append(record[record.index('private struct RecordingButtonStyle:'):]);parts.append(parts[-1].replace('RecordingButtonStyle','LegacyRecordingButtonStyle').replace('TransportRecordButton:','LegacyTransportRecordButton:').replace('JarasBlink(','BaselineJarasBlink('))
theme=Path('Apple/Shared/Theme.swift').read_text();parts.append(until(theme,'struct InputValidationShake:','/// Blink only'))
rowstart=transport.index('                HStack(spacing: remainingSpacing) {');o=transport.index('{',rowstart);row=transport[rowstart:balanced(transport,o)]
# Only command side effects are stubbed; all production labels/control layout remain.
row=row.replace('transport.loop.enabled','active').replace('ProjectSaveButton(pending: show.needsSave, saving: show.saving, message: show.message) { Task { await show.save() } }','ProjectSaveButton(pending: pending, saving: false, message: "") {}')
row=row.replace('RepeatControl(active: active) { show.send(.toggleLoop) }','RepeatControl(active: active) {}')
import re
row=re.sub(r'Button \{ show.send\([^\n]*?\) \} label:', 'Button {} label:',row)
for name,token in [('playback','                    }.fixedSize(horizontal: true, vertical: false)'),('tempo','TempoControl(show: show)'),('timer','TeleprompterTimerControl()'),('tp1','TeleprompterToggleButton(show: show, directory: mediaDirectory, index: 1)'),('tp2','TeleprompterToggleButton(show: show, directory: mediaDirectory, index: 2)'),('messages','TPNoticeButton()'),('preview','TeleprompterPreviewButton()'),('video','VideoToggleButton()'),('remote','RemoteToggleButton(show: show)'),('save','ProjectSaveButton(pending: pending, saving: false, message: "") {}'),('metronome','MetronomeControl(show: show)'),('setlist','.frame(width: buttonWidth, height: TransportControlMetrics.height)')]:
 row=row.replace(token,token+'.background(PulseSizingProbe(name:"'+name+'"))',1)
s=p.read_text()
s=s.replace('struct Project { var songs: [Song] }','struct Project { var id = UUID(); var songs: [Song] }')
for typename,body in [('NativeTransportFixture',row),('LegacyTransportFixture',row.replace('RepeatControl(','LegacyRepeatControl(').replace('ProjectSaveButton(','LegacyProjectSaveButton(').replace('TransportRecordButton(','LegacyTransportRecordButton(').replace('MetronomeControl(','LegacyMetronomeControl('))]:
 parts.append('''
@MainActor struct '''+typename+''':View {
 let active:Bool;let pending:Bool;let width:CGFloat
 let show=ShowController(song:Song(id:UUID()));let transport=GeometryTransport()
 let remotePresentation=false;let mediaDirectory:URL?=nil;let setlistCollapsed=false
 let toggleSetlist:()->Void={}
 var body:some View {
  let spacing=min(6,max(3,(width-1296)/43));let playbackSpacing=max(6,spacing);let remainingSpacing=max(0,spacing/2-1);let buttonWidth=TransportControlMetrics.desktopWidth(for:width)
  HStack(spacing:spacing) {
   Color.clear.frame(width:190,height:74)
   VStack(spacing:5) {
    Color.clear.frame(height:25)
'''+body+'''
   }.frame(maxWidth:.infinity)
  }.buttonStyle(TransportButtonStyle(horizontalPadding:5+spacing/2,fontSize:11+spacing/8))
   .padding(.horizontal,8).padding(.vertical,6).frame(width:width,height:86)
   .environment(\.transportControlWidth,buttonWidth)
 }
}
''')
p.write_text(s+'\n'+'\n'.join(parts)+'\n'+Path('Tests/Apple/NativeControlLayoutTests.swift').read_text())
