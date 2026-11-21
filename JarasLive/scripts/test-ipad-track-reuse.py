#!/usr/bin/env python3
"""Exercise the native row pool and rebind real faders and meters on a booted iPad simulator."""
from pathlib import Path
import plistlib, subprocess, sys, tempfile, time
root = Path(__file__).resolve().parent.parent
simulator = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='catlive-ipad-track-reuse-') as temporary:
    directory = Path(temporary)
    app = directory / 'TrackReuseFixture.app'
    app.mkdir()
    workspace = (root / 'Apple/Shared/IpadStandaloneWorkspace.swift').read_text()
    remote = (root / 'Apple/Shared/DAWRemoteView.swift').read_text()
    index = (root / 'Apple/Shared/TimelineVisibleClipIndex.swift').read_text()
    declarations = workspace[workspace.index('struct IpadRecycledTrackRows<Row:'):workspace.index('@MainActor final class IpadTimelinePlaybackControl')]
    audio = (root / 'Apple/Shared/StemAudioPlayback.swift').read_text()
    meter_style = audio[audio.index('enum MixerMeterStyle {'):audio.index('struct MixerFaderMeter:')]
    meters = remote[remote.index('private final class IpadStereoMeterLayers'):remote.index('@MainActor private struct NativeRemoteProjectsView')]
    sliders = remote[remote.index('struct RemoteNativeSlider:'):remote.index('private func remoteDecibelText(')]
    mixer = (root / 'Apple/Shared/TrackMixerRow.swift').read_text()
    thumb = mixer[mixer.index('enum MixerFaderThumbStyle {'):mixer.index('private struct TrackVolumeFader:')]
    theme = (root / 'Apple/Shared/Theme.swift').read_text()
    display = '; '.join(line.strip() for line in theme.splitlines() if 'static let displayHex:' in line or 'static let lightDarkBackgroundHex:' in line)
    color = 'extension JarasTheme { ' + display + '; static let display = Color(hex: displayHex) }\n'
    color += theme[theme.index('extension Color {'):theme.index('struct ProjectSaveIcon:')]
    swift = directory / 'Fixture.swift'
    swift.write_text((root / 'Tests/Apple/IpadTrackReuseFixture.swift').read_text() + '\n' + declarations + '\n' + meter_style + '\n' + meters + '\n' + index + '\n' + sliders + '\n' + thumb + '\n' + color)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-sdk', sdk, '-target',
        'arm64-apple-ios16.0-simulator', str(swift), '-o', str(app / 'TrackReuseFixture')], check=True)
    with (app / 'Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleIdentifier': 'com.catlive.tests.track-reuse', 'CFBundleName': 'TrackReuseFixture',
            'CFBundleExecutable': 'TrackReuseFixture', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1', 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [2],
            'UILaunchScreen': {}, 'UIRequiresFullScreen': True, 'LSRequiresIPhoneOS': True,
            'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}, f)
    subprocess.run(['xcrun', 'simctl', 'install', simulator, str(app)], check=True)
    try:
        container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', simulator,
            'com.catlive.tests.track-reuse', 'data'], text=True).strip())
        result = container / 'Documents/result.txt'
        result.unlink(missing_ok=True)
        subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', simulator,
            'com.catlive.tests.track-reuse'], check=True)
        deadline = time.monotonic() + 45
        while not result.exists() and time.monotonic() < deadline: time.sleep(0.2)
        output = result.read_text() if result.exists() else 'Fixture did not complete.'
        print(output)
        assert output.startswith('PASS:')
    finally:
        subprocess.run(['xcrun', 'simctl', 'uninstall', simulator, 'com.catlive.tests.track-reuse'], check=False)
