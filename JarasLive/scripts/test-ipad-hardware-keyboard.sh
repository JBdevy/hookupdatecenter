#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${1:-}" <<'PY'
import json, os, pathlib, plistlib, shutil, subprocess, sys, tempfile, time
def command(*args):
    return subprocess.check_output(args, text=True).strip()
devices = [device for group in json.loads(command('xcrun','simctl','list','devices','available','-j'))['devices'].values() for device in group]
requested = sys.argv[1]
device = next((d for d in devices if d['udid'] == requested), None) if requested else next((d for d in devices if 'iPad' in d['name'] and d['state'] == 'Booted'), None)
if device is None and not requested: device = next((d for d in devices if 'iPad' in d['name']), None)
if device is None: raise SystemExit('An available iPad simulator is required.')
udid = device['udid']; booted_here = device['state'] != 'Booted'
bundle = 'com.catlive.tests.hardwarekeyboard'
folder = pathlib.Path(tempfile.mkdtemp(prefix='catlive-ipad-keyboard-'))
installed = False
try:
    mappings = pathlib.Path('Apple/Shared/ControlMappings.swift').read_text()
    start = mappings.index('    @discardableResult func handleHardwareKey(')
    handler = mappings[start:mappings.index('    #if os(macOS)', start)]
    probe = folder/'ActionsProbe.swift'
    probe.write_text(pathlib.Path('Tests/Apple/HardwareKeyboardActionsTests.swift').read_text().replace('    // PRODUCTION_HANDLER', handler))
    subprocess.run(['swiftc','-swift-version','5','-parse-as-library',
                    'Application/Controls/ControlInput.swift','Application/Controls/HardwareKeyboardInput.swift',
                    'Application/Controls/DAWActions.swift',str(probe),'-o',str(folder/'ActionsProbe')], check=True)
    subprocess.run([str(folder/'ActionsProbe')], check=True)
    app = folder / 'KeyboardProbe.app'; app.mkdir()
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle, 'CFBundleName':'KeyboardProbe', 'CFBundleExecutable':'KeyboardProbe',
        'CFBundleVersion':'1', 'CFBundleShortVersionString':'1.0', 'CFBundlePackageType':'APPL',
        'LSRequiresIPhoneOS':True, 'MinimumOSVersion':'16.0', 'UIDeviceFamily':[2],
        'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False}, 'UILaunchScreen':{}}))
    sources = ['Application/Controls/ControlInput.swift', 'Application/Controls/HardwareKeyboardInput.swift',
               'Apple/Shared/IpadHardwareKeyboard.swift', 'Tests/Apple/IpadHardwareKeyboardFixture.swift']
    subprocess.run(['swiftc','-swift-version','5','-target',os.uname().machine+'-apple-ios16.0-simulator',
                    '-sdk',command('xcrun','--sdk','iphonesimulator','--show-sdk-path'),'-parse-as-library',
                    *sources,'-o',str(app/'KeyboardProbe')], check=True)
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
    if not result.exists(): raise SystemExit('UIKit keyboard fixture timed out before completing.')
    output = result.read_text(); print(output)
    if not output.startswith('IPAD_HARDWARE_KEYBOARD_UIKIT_'): raise SystemExit(1)
finally:
    if installed: subprocess.run(['xcrun','simctl','uninstall',udid,bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if booted_here: subprocess.run(['xcrun','simctl','shutdown',udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(folder)
PY
