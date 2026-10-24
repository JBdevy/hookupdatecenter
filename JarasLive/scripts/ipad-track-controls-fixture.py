#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,sys
p=Path(sys.argv[1]);p.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parent.parent
fixture=(root/'Tests/Apple/IpadTrackControlsFixture.swift').read_text().split('// PRODUCTION_ROW_CODE',1)
(p/'tests.swift').write_text((root/'Tests/Apple/IpadTrackControlsUITests.swift').read_text())
a=(root/'Apple/Shared/DAWRemoteView.swift').read_text();b=(root/'Apple/Shared/IpadStandaloneWorkspace.swift').read_text()
def section(text,start,end):return text[text.index(start):text.index(end,text.index(start))]
stepControls=section(a,'    private var tunerControl:','    private var timeText:')+section(a,'    private func stepTempo(','    private func smallButton(')
fixtureRoot=fixture[1].replace('// PRODUCTION_STEP_CONTROLS',stepControls)
theme=(root/'Apple/Shared/Theme.swift').read_text()
palette=section(theme,'private struct JarasNativePaletteKey:', 'extension View {') + theme[theme.index('extension Font {'):]
midiState=section((root/'Apple/Shared/StemAudioPlayback.swift').read_text(),'@MainActor final class TrackMIDIActivity:', '@MainActor final class InstrumentKeyboardState:')
midiIndicator=section((root/'Apple/Shared/TrackMixerRow.swift').read_text(),'struct TrackMIDIIndicator:', 'struct FooterMixerPanel:')
icons=section((root/'Apple/Shared/TrackInstrumentIcons.swift').read_text(),'enum TrackInstrumentIcon:', 'struct TrackInstrumentPickerModal:')
parts=[fixture[0],icons,midiState,midiIndicator,palette,section(b,'struct IpadTrackControlsBoundsKey:','/// Dragging the grip'),section(b,'struct IpadTrackReorderModifier:','struct IpadItemResizePreview'),section(b,'struct IpadTrackSelectionSurface:','struct IpadRegionHeaderGesture:'),section(a,'private struct IpadTrackAudioContextMenu:','private struct RemoteNativeMixerRow:'),section(a,'private struct RemoteNativeMixerRow:','/// Shared by the iPad master'),section(a,'private struct RemoteNativeSlider:','// Keep Cancel visibly'),section(a,'private struct RemoteNativeTrackButtonStyle:','/// Native Parts docks'),section(a,'private struct RemoteNativeTrackControlLayout {','/// Keep the presented scroll'),section(a,'enum RemoteSurface {','/// Plain SwiftUI buttons'),section(a,'private struct RemoteFullAreaButtonStyle:','private struct RemoteSurfaceButtonStyle:') if 'private struct RemoteSurfaceButtonStyle:' in a else '',section(a,'private struct RemotePeakReadout:','private struct IpadTrackAudioContextMenu:'),fixtureRoot]
# Only the full-area style is needed, up to the next declaration.
s=a[a.index('private struct RemoteFullAreaButtonStyle:'):];end=s.index('\n}\n')+3
parts.insert(-1,s[:end])
recording=(root/'Apple/Shared/TrackRecording.swift').read_text()
arming=(root/'Application/Controls/RecordingArmState.swift').read_text()
parts.insert(1,arming[arming.index('public struct RecordingArmState:'):])
parts.insert(-1,section(a,'struct IpadTapHoldTouchSurface:', 'private struct IpadTeleprompterRemoteHold:'))
parts.insert(-1,section(recording,'struct TrackRecordButton:', 'struct TransportRecordButton:'))
(p/'Fixture.swift').write_text('\n'.join(parts))
objects={}
def uid(s):return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def add(s,v):i=uid(s);objects[i]=v;return i
def arr(values):return '('+','.join(values)+')'
def q(s):return json.dumps(str(s))
targets=[];products=[];buildConfigs=[];appTarget=uid('app')
for name,source,kind in [('Fixture','Fixture.swift','application'),('ControlsTests','tests.swift','bundle.ui-testing')]:
 tid=appTarget if kind=='application' else uid(name)
 ref=add('ref'+name,f'isa=PBXFileReference;lastKnownFileType=sourcecode.swift;path={q(source)};sourceTree=SOURCE_ROOT;')
 bf=add('bf'+name,f'isa=PBXBuildFile;fileRef={ref};')
 phase=add('src'+name,f'isa=PBXSourcesBuildPhase;files=({bf});buildActionMask=2147483647;runOnlyForDeploymentPostprocessing=0;')
 prod=add('prod'+name,f'isa=PBXFileReference;explicitFileType={"wrapper.application" if kind=="application" else "wrapper.cfbundle"};path={name}{".app" if kind=="application" else ".xctest"};sourceTree=BUILT_PRODUCTS_DIR;');products.append(prod)
 settings={'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'com.catlive.tests.'+name,'SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'16.0','TARGETED_DEVICE_FAMILY':'2','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGNING_ALLOWED':'NO','SWIFT_OPTIMIZATION_LEVEL':'-Onone'}
 if kind=='application':settings.update(INFOPLIST_KEY_UILaunchScreen_Generation='YES',INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES')
 else:settings.update(TEST_TARGET_NAME='Fixture')
 configs=[]
 for config in ['Debug','Release']:
  configs.append(add(config+name,'isa=XCBuildConfiguration;name='+config+';buildSettings={'+''.join(k+'='+q(v)+';' for k,v in settings.items())+'};'))
 cl=add('cl'+name,f'isa=XCConfigurationList;buildConfigurations={arr(configs)};defaultConfigurationName=Debug;')
 deps=[]
 if kind!='application':
  proxy=add('proxy',f'isa=PBXContainerItemProxy;containerPortal={uid("project")};proxyType=1;remoteGlobalIDString={appTarget};remoteInfo=Fixture;')
  deps=[add('dependency',f'isa=PBXTargetDependency;target={appTarget};targetProxy={proxy};')]
 objects[tid]=f'isa=PBXNativeTarget;name={name};productName={name};productType="com.apple.product-type.{kind}";productReference={prod};buildConfigurationList={cl};buildPhases=({phase});dependencies={arr(deps)};buildRules=();';targets.append(tid)
refs=[uid('refFixture'),uid('refControlsTests')]
group=add('group',f'isa=PBXGroup;children={arr(refs+products)};sourceTree="<group>";')
pc=[]
for c in ['Debug','Release']:pc.append(add('project'+c,'isa=XCBuildConfiguration;name='+c+';buildSettings={};'))
cl=add('projectcl',f'isa=XCConfigurationList;buildConfigurations={arr(pc)};defaultConfigurationName=Debug;')
objects[uid('project')]=f'isa=PBXProject;attributes={{LastUpgradeCheck=2700;}};buildConfigurationList={cl};compatibilityVersion="Xcode 14.0";developmentRegion=en;knownRegions=(en,Base);mainGroup={group};projectDirPath="";projectRoot="";targets={arr(targets)};'
x=p/'Fixture.xcodeproj';x.mkdir(exist_ok=True)
(x/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion=1;classes={};objectVersion=56;objects={'+''.join(i+'={'+v+'};' for i,v in objects.items())+'};rootObject='+uid('project')+';}')
scheme=x/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
ref=lambda i,n:f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{i}" BuildableName="{n}" BlueprintName="{n.split(".")[0]}" ReferencedContainer="container:Fixture.xcodeproj"/>'
(scheme/'Fixture.xcscheme').write_text(f'''<?xml version="1.0"?><Scheme version="1.7"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES">{ref(appTarget,"Fixture.app")}</BuildActionEntry><BuildActionEntry buildForTesting="YES">{ref(uid("ControlsTests"),"ControlsTests.xctest")}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(uid("ControlsTests"),"ControlsTests.xctest")}</TestableReference></Testables></TestAction></Scheme>''')
