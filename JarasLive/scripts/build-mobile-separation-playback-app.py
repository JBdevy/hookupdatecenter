#!/usr/bin/env python3
"""Build an isolated physical-iPad audio regression app; never install/launch it.

The output is unsigned. Sign it with a development profile for
com.hookdeveloper.catlive.audioprobe before installing on a test device.
Pass --model <CatStemHTDemucs6.mlmodelc> to enable the optional real Core ML run.
Read Documents/result.txt after launch; a successful run ends with PASS.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), default="iphoneos")
    parser.add_argument("--model", type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = options.output.resolve()
    model = options.model.resolve() if options.model else None
    os.chdir(root)
    output.mkdir(parents=True, exist_ok=True)
    app = output / "AudioProbe.app"
    app.mkdir(exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", options.sdk, "--show-sdk-path"], text=True).strip()
    target = "arm64-apple-ios16.0" + ("-simulator" if options.sdk == "iphonesimulator" else "")
    common = ["-target", target, "-isysroot", sdk]
    bridge_dependencies = list(Path("Apple/Bridge").glob("*.h")) + list(Path("Apple/Bridge").glob("*.inc"))
    source_paths = sorted(Path("Core/ThirdParty/Lame").glob("*.c")) + [Path(path) for path in (
        "Apple/Bridge/JarasRecording.mm", "Apple/Bridge/JarasCoreBridge.mm", "Core/Project/Models.cpp",
        "Core/Transport/Engine.cpp", "Core/Import/TrackTaxonomy.cpp", "Apple/Bridge/JarasEffects.mm",
        "Apple/Bridge/JarasStemSeparator.mm", "Apple/Bridge/JarasVST3.mm", "Apple/Bridge/JarasSoundFont.mm",
        "Apple/Bridge/JarasTimecode.mm")]
    objects = []
    for source in source_paths:
        obj = output / (source.stem + ".o")
        objects.append(str(obj))
        dependencies = [source] + (bridge_dependencies if source.suffix == ".mm" else [])
        if obj.exists() and obj.stat().st_mtime > max(path.stat().st_mtime for path in dependencies):
            continue
        args = ["clang" if source.suffix == ".c" else "clang++", *common, "-O1",
                "-DHAVE_CONFIG_H", "-ICore/ThirdParty/Lame"]
        if source.suffix != ".c":
            args += ["-std=c++17"]
        if source.suffix == ".mm":
            args += ["-fobjc-arc"]
        subprocess.run([*args, "-c", str(source), "-o", str(obj)], check=True)
    # Use the same production playback/export source set as the desktop audio
    # integration test; compile it for iOS with the real hardware driver.
    line = next(line for line in Path("scripts/test-offline-export.sh").read_text().splitlines()
                if line.startswith("swiftc "))
    sources = re.findall(r'(?:Application|Apple)/[^\s"$]+\.swift', line)
    sources += ["Application/Project/StemSeparation.swift", "Tests/Apple/MobileSeparationPlaybackApp.swift"]
    subprocess.run(["swiftc", "-swift-version", "5", "-target", target, "-sdk", sdk, "-parse-as-library",
                    "-import-objc-header", "Apple/Bridge/JarasLive-Bridging-Header.h", *sources, *objects,
                    "-framework", "Accelerate", "-framework", "CoreML", "-lc++", "-o", str(app / "AudioProbe")], check=True)
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.hookdeveloper.catlive.audioprobe", "CFBundleName": "CatLive Audio Probe",
        "CFBundleExecutable": "AudioProbe", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "CFBundlePackageType": "APPL", "LSRequiresIPhoneOS": True, "MinimumOSVersion": "16.0",
        "UIDeviceFamily": [2], "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UILaunchScreen": {}, "NSMicrophoneUsageDescription": "Test CatLive playback after separation.",
        "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True}))
    if model:
        if not model.is_dir() or model.suffix != ".mlmodelc":
            parser.error("--model must point to a compiled .mlmodelc directory")
        shutil.copytree(model, app / "CatStemHTDemucs6.mlmodelc", dirs_exist_ok=True)
    print(f"AUDIO_PROBE_APP={app}")


if __name__ == "__main__":
    main()
