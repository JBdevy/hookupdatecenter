#!/usr/bin/env python3
"""Build the branded Installer.app product archive before signing/notarization."""

import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def build_package(app: Path, destination: Path, version: str) -> None:
    if not re.fullmatch(r"[0-9]+\.[0-9]{2}", version):
        raise ValueError("Use a public version X.XX, such as 1.04")
    app = app.resolve(strict=True)
    if not (app / "Contents/Info.plist").is_file():
        raise ValueError("The payload must be a built CatLive.app bundle")
    destination = destination.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="catlive-installer-") as temporary:
        stage = Path(temporary)
        component = stage / "CatLive-Application.pkg"
        distribution = stage / "Distribution.xml"
        resources = stage / "Resources"
        payload = stage / "Payload"
        components = stage / "Components.plist"
        resources.mkdir()
        shutil.copy2(root / "Installer/Assets/mac-background.png", resources)
        # A component package can otherwise discover an old copy of the app in
        # Downloads and update it there. Pin upgrades to /Applications as well.
        # Keep independent inodes. pkgbuild can give a hard-linked resource's
        # AppleDouble metadata the same archive identity as its file; extracting
        # that package then leaves spurious ._* resources and breaks the seal.
        shutil.copytree(app, payload / app.name, symlinks=True, copy_function=shutil.copy2)
        subprocess.run(["/usr/bin/pkgbuild", "--analyze", "--root", str(payload), str(components)], check=True)
        bundles = plistlib.loads(components.read_bytes())
        def pin_locations(entries: list) -> None:
            for entry in entries:
                entry["BundleIsRelocatable"] = False
                pin_locations(entry.get("ChildBundles", []))
        pin_locations(bundles)
        components.write_bytes(plistlib.dumps(bundles))
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        subprocess.run([
            "/usr/bin/pkgbuild", "--root", str(payload), "--component-plist", str(components),
            "--identifier", info["CFBundleIdentifier"], "--version", str(info["CFBundleVersion"]),
            "--install-location", "/Applications",
            "--compression", "latest", "--min-os-version", "12.0", str(component),
        ], check=True)
        subprocess.run([
            "/usr/bin/productbuild", "--synthesize", "--package", str(component), str(distribution),
        ], check=True)
        tree = ET.parse(distribution)
        document = tree.getroot()
        document.insert(0, ET.Element("title"))
        document.find("title").text = f"CatLive {version}"
        options = document.find("options")
        if options is None:
            options = ET.SubElement(document, "options")
        options.set("customize", "never")
        options.set("require-scripts", "false")
        options.set("hostArchitectures", "arm64,x86_64")
        options.set("rootVolumeOnly", "true")
        ET.SubElement(document, "background", {"file": "mac-background.png", "alignment": "bottomleft", "scaling": "none"})
        ET.SubElement(document, "background-darkAqua", {"file": "mac-background.png", "alignment": "bottomleft", "scaling": "none"})
        # rootVolumeOnly selects the boot volume automatically. Adding a
        # <domains> element makes Installer show a redundant scope-selection
        # page, even when localSystem is its only enabled choice.
        domains = document.find("domains")
        if domains is not None:
            document.remove(domains)
        tree.write(distribution, encoding="utf-8", xml_declaration=True)
        subprocess.run([
            "/usr/bin/productbuild", "--distribution", str(distribution),
            "--package-path", str(stage), "--resources", str(resources), str(destination),
        ], check=True)
    print(f"Branded CatLive {version} installer: {destination}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--version", required=True)
    arguments = parser.parse_args()
    build_package(arguments.app, arguments.output, arguments.version)
