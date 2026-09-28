#!/usr/bin/env python3
from pathlib import Path
import hashlib, json
root=Path(__file__).resolve().parent.parent
objects={}
def uid(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def add(key,body): identifier=uid(key);objects[identifier]=body;return identifier
def q(value): return json.dumps(str(value))
def arr(values): return '('+','.join(values)+')'
files=sorted(p for folder in ['Core','Application','Apple'] for p in (root/folder).rglob('*') if p.suffix in ['.swift','.cpp','.mm','.c','.h','.hpp'])
refs={}
for p in files:
 rel=p.relative_to(root).as_posix();typ={'.c':'sourcecode.c.c','.swift':'sourcecode.swift','.cpp':'sourcecode.cpp.cpp','.mm':'sourcecode.cpp.objcpp','.h':'sourcecode.c.h','.hpp':'sourcecode.cpp.h'}[p.suffix]
 refs[rel]=add('file:'+rel,f'isa = PBXFileReference; lastKnownFileType = {typ}; path = {q(rel)}; sourceTree = SOURCE_ROOT;')
languageRefs=[]
for language in ['en','pt-BR']:
 languageRefs.append(add('language:'+language, f'isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {q(language)}; path = {q("Apple/Resources/"+language+".lproj/Localizable.strings")}; sourceTree = SOURCE_ROOT;'))
localization=add('localization',f'isa = PBXVariantGroup; children = {arr(languageRefs)}; name = Localizable.strings; sourceTree = "<group>";')
assets=add('assets','isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Apple/Assets.xcassets; sourceTree = SOURCE_ROOT;')
legalRefs=[]
for name in ['COPYING','SOURCE.txt','lame-3.100-source.tar.gz']:
 legalRefs.append(add('lame:'+name, f'isa = PBXFileReference; lastKnownFileType = file; path = {q("Core/ThirdParty/Lame/"+name)}; sourceTree = SOURCE_ROOT;'))
legalRefs.append(add("tinySoundFontLicense", 'isa = PBXFileReference; lastKnownFileType = text; path = "Core/ThirdParty/TinySoundFont/TinySoundFont-LICENSE.txt"; sourceTree = SOURCE_ROOT;'))
legalRefs.append(add("ebur128License", 'isa = PBXFileReference; lastKnownFileType = text; path = "Core/ThirdParty/EBUR128/EBUR128-LICENSE.txt"; sourceTree = SOURCE_ROOT;'))
for name in ['VST3-LICENSE.txt','VST3-SOURCE.txt']:
 legalRefs.append(add('vst3:'+name, f'isa = PBXFileReference; lastKnownFileType = text; path = {q("Core/ThirdParty/VST3/"+name)}; sourceTree = SOURCE_ROOT;'))
products=[];targets=[];attributes=[]
for platform,label,bundle in [('macosx','macOS','com.hookdeveloper.jaraslive.mac'),('iphoneos','iPadOS','com.hookdeveloper.jaraslive')]:
 key='target:'+label;tid=uid(key)
 product=add('product:'+label,f'isa = PBXFileReference; explicitFileType = wrapper.application; path = "Jaras Live.app"; sourceTree = BUILT_PRODUCTS_DIR;');products.append(product)
 builds=[]
 for rel,ref in refs.items():
  if Path(rel).suffix in ['.swift','.cpp','.mm','.c']: builds.append(add('build:'+label+rel,f'isa = PBXBuildFile; fileRef = {ref};'))
 sources=add('sources:'+label,f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(builds)}; runOnlyForDeploymentPostprocessing = 0;')
 frameworks=add('frameworks:'+label,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
 assetBuild=add('assetBuild:'+label,f'isa = PBXBuildFile; fileRef = {assets};')
 localizedBuild=add('localizedBuild:'+label,f'isa = PBXBuildFile; fileRef = {localization};')
 legalBuilds=[add('legalBuild:'+label+ref,f'isa = PBXBuildFile; fileRef = {ref};') for ref in legalRefs]
 resources=add('resources:'+label,f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {arr([localizedBuild,assetBuild]+legalBuilds)}; runOnlyForDeploymentPostprocessing = 0;')
 configs=[]
 for config in ['Debug','Release']:
  settings={'PRODUCT_NAME':'Jaras Live','PRODUCT_BUNDLE_IDENTIFIER':bundle,'SDKROOT':platform,'SWIFT_VERSION':'5.0','CLANG_CXX_LANGUAGE_STANDARD':'c++17','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SWIFT_OBJC_BRIDGING_HEADER':'Apple/Bridge/JarasLive-Bridging-Header.h','GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_KEY_CFBundleDisplayName':'Jaras Live','MARKETING_VERSION':'1.0.0','CURRENT_PROJECT_VERSION':'1','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'573QZX9H7Y','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','GCC_OPTIMIZATION_LEVEL':'0' if config=='Debug' else '3','ENABLE_USER_SCRIPT_SANDBOXING':'YES','HEADER_SEARCH_PATHS':'$(SRCROOT)/Core $(SRCROOT)/Core/ThirdParty/Lame $(SRCROOT)/Core/ThirdParty/VST3','GCC_PREPROCESSOR_DEFINITIONS':'$(inherited) HAVE_CONFIG_H=1','ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS':'NO'}
  if platform=='macosx': settings.update({'MACOSX_DEPLOYMENT_TARGET':'13.0','INFOPLIST_KEY_LSApplicationCategoryType':'public.app-category.music','ENABLE_APP_SANDBOX':'NO','GENERATE_INFOPLIST_FILE':'NO','INFOPLIST_FILE':'Apple/Info-mac.plist','COMBINE_HIDPI_IMAGES':'YES','ASSETCATALOG_COMPILER_APPICON_NAME':'JarasLiveIcon'})
  else: settings.update({'IPHONEOS_DEPLOYMENT_TARGET':'16.0','TARGETED_DEVICE_FAMILY':'2','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight','INFOPLIST_KEY_UIRequiresFullScreen':'YES'})
  configs.append(add('config:'+label+config,'isa = XCBuildConfiguration; name = '+config+'; buildSettings = {'+''.join(k+' = '+q(v)+';' for k,v in settings.items())+'};'))
 configList=add('configs:'+label,f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
 add(key,f'isa = PBXNativeTarget; buildConfigurationList = {configList}; buildPhases = {arr([sources,frameworks,resources])}; buildRules = (); dependencies = (); name = "Jaras Live {label}"; productName = "Jaras Live"; productReference = {product}; productType = "com.apple.product-type.application";')
 targets.append(tid);attributes.append(f'{tid} = {{CreatedOnToolsVersion = 16.0; DevelopmentTeam = 573QZX9H7Y; ProvisioningStyle = Automatic; }};')
productGroup=add('products',f'isa = PBXGroup; children = {arr(products)}; name = Products; sourceTree = "<group>";')
def folderGroup(folder):
 prefix=folder+'/'
 children=[]
 subfolders=sorted({str(Path(rel).parent) for rel in refs if rel.startswith(prefix) and str(Path(rel).parent)!=folder})
 direct=sorted({folder+'/'+rest[len(prefix):].split('/')[0] for rest in subfolders})
 for child in direct: children.append(folderGroup(child))
 children += [ref for rel,ref in refs.items() if str(Path(rel).parent)==folder]
 if folder=='Apple': children += [localization,assets]
 return add('group:'+folder,f'isa = PBXGroup; children = {arr(children)}; name = {q(Path(folder).name)}; sourceTree = "<group>";')
group=add('root',f'isa = PBXGroup; children = {arr([folderGroup(folder) for folder in ["Core","Application","Apple"]]+[productGroup])}; sourceTree = "<group>";')

projectConfigs=[add('project:'+c,f'isa = XCBuildConfiguration; name = {c}; buildSettings = {{}};') for c in ['Debug','Release']]
projectConfig=add('projectConfigs',f'isa = XCConfigurationList; buildConfigurations = {arr(projectConfigs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project=add('project',f'isa = PBXProject; attributes = {{LastUpgradeCheck = 1600; TargetAttributes = {{'+''.join(attributes)+f'}}; }}; buildConfigurationList = {projectConfig}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,"pt-BR",Base); mainGroup = {group}; productRefGroup = {productGroup}; projectDirPath = ""; projectRoot = ""; targets = {arr(targets)};')
dir=root/'Jaras Live.xcodeproj';dir.mkdir(exist_ok=True)
(dir/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(k+' = {'+v+'};' for k,v in objects.items())+'\n}; rootObject = '+project+'; }\n')
schemes=dir/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
for label,tid in zip(['macOS','iPadOS'],targets):
 reference=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{tid}" BuildableName="Jaras Live.app" BlueprintName="Jaras Live {label}" ReferencedContainer="container:Jaras Live.xcodeproj"/>'
 (schemes/f'Jaras Live {label}.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug"/><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(dir)
