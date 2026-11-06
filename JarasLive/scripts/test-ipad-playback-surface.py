#!/usr/bin/env python3
"""Exercise the production iPad scroll/needle compositor on a booted simulator."""
from pathlib import Path
import plistlib, subprocess, sys, tempfile, time
root = Path(__file__).resolve().parent.parent
simulator = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='catlive-ipad-playback-') as temporary:
    directory = Path(temporary)
    app = directory / 'PlaybackFixture.app'
    app.mkdir()
    source = (root / 'Apple/Shared/IpadStandaloneWorkspace.swift').read_text()
    viewport = source[source.index('struct IpadTimelineViewport:'):source.index('/// Translation is measured from mouse-down')]
    surface = source[source.index('@MainActor final class IpadTimelinePlaybackControl {'):source.rindex('#endif')]
    models = (root / 'Application/Project/ProjectModels.swift').read_text()
    transport = models[models.index('public struct QueueState:'):models.index('public struct PlaybackItemStartIndex')]
    multi = (root / 'Application/Project/MultiLoop.swift').read_text()
    start = multi.index('public struct MultiLoopPlayback:')
    multi = multi[start:multi.index('\n}', start) + 2]
    presentation = (root / 'Application/Transport/TimelinePlaybackPresentation.swift').read_text().split('/// Song names and explicit tempo metadata')[0]
    headers = (root / 'Apple/Shared/IpadItemHeader.swift').read_text()
    headers = headers[headers.index('final class IpadItemHeaderViewport:'):headers.index('enum IpadItemMixParameter')]
    tests = (root / 'Tests/Apple/IpadTimelinePlaybackTests.swift').read_text()
    swift = directory / 'Fixture.swift'
    swift.write_text('import UIKit\nimport SwiftUI\nimport Combine\npublic struct MultiLoopTrack: Codable, Equatable, Sendable {}\n' + '\n'.join([transport, multi, presentation, viewport, headers, surface, tests]))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-sdk', sdk, '-target',
        'arm64-apple-ios16.0-simulator', str(swift), '-o', str(app / 'PlaybackFixture')], check=True)
    with (app / 'Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleIdentifier': 'com.catlive.tests.playback-surface', 'CFBundleName': 'PlaybackFixture',
            'CFBundleExecutable': 'PlaybackFixture', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1', 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [2],
            'UILaunchScreen': {}, 'UIRequiresFullScreen': True, 'LSRequiresIPhoneOS': True,
            'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}, f)
    subprocess.run(['xcrun', 'simctl', 'install', simulator, str(app)], check=True)
    try:
        container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', simulator,
            'com.catlive.tests.playback-surface', 'data'], text=True).strip())
        result = container / 'Documents/result.txt'
        result.unlink(missing_ok=True)
        subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', simulator,
            'com.catlive.tests.playback-surface'], check=True)
        deadline = time.monotonic() + 45
        while not result.exists() and time.monotonic() < deadline: time.sleep(0.2)
        output = result.read_text() if result.exists() else 'Fixture did not complete.'
        print(output)
        assert output.startswith('IPAD_PLAYBACK_RETAINED_CONTENT_DISPLAY_CLOCK_STOP_SUBPLAY_AND_MANUAL_NAVIGATION_OK')
    finally:
        subprocess.run(['xcrun', 'simctl', 'uninstall', simulator, 'com.catlive.tests.playback-surface'], check=False)
