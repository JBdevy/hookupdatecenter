#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${1:-}" <<'PY'
import json, os, pathlib, plistlib, shutil, subprocess, sys, tempfile, time
# iOS 16 treats pointer clicks as direct touches unless the production bundle
# explicitly opts in. Newer simulators default to YES and can hide this omission.
production_info = plistlib.loads(pathlib.Path('Apple/Info-iPad.plist').read_bytes())
if production_info.get('UIApplicationSupportsIndirectInputEvents') is not True:
    raise SystemExit('iPad Info.plist must enable UIApplicationSupportsIndirectInputEvents for iPadOS 16 mouse/trackpad support.')
def command(*args):
    return subprocess.check_output(args, text=True).strip()
devices = [device for group in json.loads(command('xcrun','simctl','list','devices','available','-j'))['devices'].values() for device in group]
requested = sys.argv[1]
device = next((d for d in devices if d['udid'] == requested), None) if requested else next((d for d in devices if 'iPad' in d['name'] and d['state'] == 'Booted'), None)
if device is None and not requested: device = next((d for d in devices if 'iPad' in d['name']), None)
if device is None: raise SystemExit('An available iPad simulator is required.')
udid = device['udid']; booted_here = device['state'] != 'Booted'
bundle = 'com.catlive.tests.itemheader'
folder = pathlib.Path(tempfile.mkdtemp(prefix='catlive-ipad-header-'))
installed = False
try:
    source = pathlib.Path('Apple/Shared/GridSelectionInput.swift').read_text()
    geometry = source[source.index('struct GridSelectionItem {'):source.index('/// Immutable item metadata')]
    remote = pathlib.Path('Apple/Shared/DAWRemoteView.swift').read_text()
    mix = remote[remote.index('private struct IpadNativeItemMix:'):remote.index('private struct IpadNativeItemMove:')].replace('private struct','struct',1)
    start = remote.index('    private func cancelItemMix()')
    end = remote.index('    private func timelineRow(', start)
    handler = remote[start:end].replace('private func ', 'func ')
    fixture = pathlib.Path('Tests/Apple/IpadItemHeaderFixture.swift').read_text().replace('// MIX_MODEL', mix).replace('    // MIX_HANDLER',handler)
    (folder/'HeaderGeometry.swift').write_text('import SwiftUI\nimport UIKit\n' + geometry)
    (folder/'HeaderFixture.swift').write_text(fixture)
    workspace = pathlib.Path('Apple/Shared/IpadStandaloneWorkspace.swift').read_text()
    resize = workspace[workspace.index('/// A control excludes resizing'):workspace.index('struct IpadTrackSelectionSurface:')]
    (folder/'ResizeControl.swift').write_text('import SwiftUI\nimport UIKit\n' + resize)
    app = folder / 'HeaderProbe.app'; app.mkdir()
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle, 'CFBundleName':'HeaderProbe', 'CFBundleExecutable':'HeaderProbe',
        'CFBundleVersion':'1', 'CFBundleShortVersionString':'1.0', 'CFBundlePackageType':'APPL',
        'LSRequiresIPhoneOS':True, 'MinimumOSVersion':'16.0', 'UIDeviceFamily':[2],
        'UIApplicationSupportsIndirectInputEvents':production_info['UIApplicationSupportsIndirectInputEvents'],
        'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False}, 'UILaunchScreen':{}}))
    sources = ['Application/Controls/ControlInput.swift', 'Application/Controls/HardwareKeyboardInput.swift',
               'Apple/Shared/IpadHardwareKeyboard.swift', 'Apple/Shared/IpadTimelinePointer.swift',
               'Application/Project/ItemFadeCurve.swift', 'Application/Project/TimelinePointerSelection.swift',
               'Apple/Shared/IpadItemHeader.swift', str(folder/'HeaderGeometry.swift'), str(folder/'ResizeControl.swift'), str(folder/'HeaderFixture.swift')]
    subprocess.run(['swiftc','-swift-version','5','-target',os.uname().machine+'-apple-ios16.0-simulator',
                    '-sdk',command('xcrun','--sdk','iphonesimulator','--show-sdk-path'),'-parse-as-library',
                    *sources,'-o',str(app/'HeaderProbe')], check=True)
    if booted_here:
        subprocess.run(['xcrun','simctl','boot',udid], check=True)
        subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'], check=True)
    subprocess.run(['xcrun','simctl','terminate',udid,bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun','simctl','install',udid,str(app)], check=True); installed = True
    container = pathlib.Path(command('xcrun','simctl','get_app_container',udid,bundle,'data'))
    result = container/'Documents/result.txt'; result.unlink(missing_ok=True)
    subprocess.run(['xcrun','simctl','launch',udid,bundle], check=True)
    deadline = time.monotonic()+45
    while not result.exists() and time.monotonic()<deadline: time.sleep(.2)
    if not result.exists(): raise SystemExit('UIKit header fixture timed out before completing.')
    output = result.read_text(); print(output)
    if not output.startswith('IPAD_ITEM_HEADER_UIKIT_'): raise SystemExit(1)
finally:
    if installed: subprocess.run(['xcrun','simctl','uninstall',udid,bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if booted_here: subprocess.run(['xcrun','simctl','shutdown',udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(folder)
PY
