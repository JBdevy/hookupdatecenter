#!/usr/bin/env python3
"""Export the Mac track-icon vector paths to the Windows renderer (run on macOS)."""
from pathlib import Path
import json
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
destination = root / "Windows/Source/TrackInstrumentIcons.h"
source = (root / "Apple/Shared/TrackInstrumentIcons.swift").read_text().split("struct TrackInstrumentPickerModal: View")[0]
exporter = '\nimport Foundation\nvar icons: [[String: Any]] = []\nfor icon in TrackInstrumentIcon.allCases {\n var commands: [String] = []\n func n(_ p: CGPoint) -> String { "\\(Double(p.x)), \\(Double(p.y))" }\n TrackInstrumentIconView.drawing(icon).forEach { element in\n  switch element {\n  case .move(to: let p): commands.append("p.startNewSubPath(\\(n(p)));")\n  case .line(to: let p): commands.append("p.lineTo(\\(n(p)));")\n  case .quadCurve(to: let p, control: let c): commands.append("p.quadraticTo(\\(n(c)), \\(n(p)));")\n  case .curve(to: let p, control1: let c1, control2: let c2): commands.append("p.cubicTo(\\(n(c1)), \\(n(c2)), \\(n(p)));")\n  case .closeSubpath: commands.append("p.closeSubPath();")\n  }\n }\n icons.append(["id":icon.rawValue,"title":icon.title,"lettering":icon.lettering ?? "","commands":commands])\n}\nprint(String(data: try JSONSerialization.data(withJSONObject: icons), encoding:.utf8)!)\n'
with tempfile.TemporaryDirectory(prefix="catlive-icons-") as directory:
    swift = Path(directory) / "Export.swift"
    swift.write_text(source + exporter)
    icons = json.loads(subprocess.check_output(["swift", str(swift)], text=True))
s='''#pragma once
#include "Common.h"\n#include "../../Core/Project/Models.hpp"
// Vector geometry exported from Apple/Shared/TrackInstrumentIcons.swift.
// Coordinates and stable project identifiers are identical on both desktops.
namespace catlive::trackIcons {
struct Icon { const char *id, *title, *lettering; Path path; };
inline const std::vector<Icon> &catalog() {
    static const auto icons = [] {
        std::vector<Icon> result;
'''
for i in icons:
 s+='        { Path p;\n'+'\n'.join('          '+c for c in i['commands'])+'\n'
 s+='          result.push_back({'+','.join(json.dumps(i[k],ensure_ascii=False) for k in ['id','title','lettering'])+',std::move(p)}); }\n'
s+='''        return result;
    }();
    return icons;
}
inline const Icon *find(const std::optional<std::string> &id) {
    if (id) for (const auto &icon : catalog()) if (*id == icon.id) return &icon;
    return nullptr;
}
inline bool visible(const jaras::Song *song) {
    return song && std::any_of(song->tracks.begin(), song->tracks.end(), [](const auto &t) { return find(t.instrumentIcon) != nullptr; });
}
inline void draw(Graphics &g, const Icon &icon, juce::Rectangle<float> bounds) {
    if (bounds.isEmpty()) return;
    g.setColour(Colours::white);
    if (*icon.lettering) {
        const String label(icon.lettering);
        g.setFont(theme::font(label.length() <= 3 ? 22.f : 12.f, true));
        g.drawFittedText(label,bounds.toNearestInt(),Justification::centred,1,.5f);
    } else {
        const float scale=std::min(bounds.getWidth(),bounds.getHeight())/64.f;
        g.strokePath(icon.path,PathStrokeType(2.2f,PathStrokeType::curved,PathStrokeType::rounded),
            AffineTransform::scale(scale).translated(bounds.getCentreX()-32*scale,bounds.getCentreY()-32*scale));
    }
}
}
'''
destination.write_text(s)
