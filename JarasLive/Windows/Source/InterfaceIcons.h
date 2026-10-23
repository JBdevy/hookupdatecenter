#pragma once
#include "Common.h"
namespace catlive {
// Small line icons drawn at logical resolution; no platform symbol-font dependency.
inline bool drawInterfaceIcon(Graphics &g, const String &name, juce::Rectangle<float> bounds) {
    Path p;
    bool fill = false;
    auto line = [&](float x1, float y1, float x2, float y2) {
        p.startNewSubPath(x1, y1);
        p.lineTo(x2, y2);
    };
    if (name == "chevron.left" || name == "chevron.right") {
        const float a = name == "chevron.left" ? 15.f : 9.f;
        const float b = 24.f - a;
        p.startNewSubPath(a, 5); p.lineTo(b, 12); p.lineTo(a, 19);
        p.applyTransform(AffineTransform::fromTargetPoints(0, 0, bounds.getX(), bounds.getY(), 24, 0, bounds.getRight(), bounds.getY(), 0, 24, bounds.getX(), bounds.getBottom()));
        g.strokePath(p, PathStrokeType(1.8f, PathStrokeType::curved, PathStrokeType::rounded));
        return true;
    }
    if (name == "record.circle") {
        // Match the compact macOS SF Symbol: outer ring and solid centre.
        const auto ring = bounds.withSizeKeepingCentre(11.f, 11.f);
        g.drawEllipse(ring, 1.15f);
        g.fillEllipse(bounds.withSizeKeepingCentre(5.f, 5.f));
        return true;
    }
    if (name == "mono") {
        const auto cx = bounds.getCentreX(), cy = bounds.getCentreY();
        g.drawEllipse(cx - 9, cy - 5.5f, 11, 11, 1.3f);
        g.drawEllipse(cx - 2, cy - 5.5f, 11, 11, 1.3f);
        return true;
    }
    if (name == "folder" || name == "folderOpen") {
        p.startNewSubPath(2, 7);
        p.lineTo(2, 4);
        p.lineTo(10, 4);
        p.lineTo(13, 7);
        p.lineTo(22, 7);
        p.lineTo(22, 20);
        p.lineTo(2, 20);
        p.closeSubPath();
        if (name == "folderOpen") {
            line(3, 10, 21, 10);
        }
    } else if (name == "lock" || name == "unlock") {
        p.addRoundedRectangle(5, 11, 14, 11, 2);
        p.startNewSubPath(8, 11); p.lineTo(8, 7);
        if (name == "lock") { p.cubicTo(8, 1, 16, 1, 16, 7); p.lineTo(16, 11); }
        else { p.cubicTo(8, 1, 17, 1, 17, 7); }
        line(12, 15, 12, 18);
    } else if (name == "itemTimebase") {
        line(3, 5, 3, 19); line(21, 5, 21, 19);
        line(6, 12, 18, 12);
        line(6, 12, 10, 8); line(6, 12, 10, 16);
        line(18, 12, 14, 8); line(18, 12, 14, 16);
    } else if (name == "magnet") {
        p.startNewSubPath(4,3); p.lineTo(4,13); p.cubicTo(4,25,20,25,20,13);
        p.lineTo(20,3); p.lineTo(15,3); p.lineTo(15,13); p.cubicTo(15,18,9,18,9,13);
        p.lineTo(9,3); p.closeSubPath(); line(4,8,9,8); line(15,8,20,8);
    } else if (name == "visibility") {
        p.startNewSubPath(2,12);p.cubicTo(7,3,17,3,22,12);p.cubicTo(17,21,7,21,2,12);p.closeSubPath();
        p.addEllipse(8.5f,8.5f,7,7);
    } else if (name == "menu") {
        for (int y : {6, 12, 18})
            line(3, (float)y, 21, (float)y);
    } else if (name == "mixer" || name == "railMixer") {
        for (int i = 0; i < 3; ++i) {
            float y = 5.f + i * 7, x = i == 1 ? 15.f : 8.f;
            line(3, y, x - 3, y);
            line(x + 3, y, 21, y);
            p.addRoundedRectangle(x - 3, y - 2, 6, 4, 1);
        }
        if (name == "railMixer")
            p.applyTransform(AffineTransform::rotation(MathConstants<float>::halfPi, 12, 12));
    } else if (name == "undo" || name == "redo") {
        p.startNewSubPath(5, 9);
        p.lineTo(14, 9);
        p.cubicTo(23, 9, 23, 20, 14, 20);
        line(5, 9, 10, 4);
        line(5, 9, 10, 14);
        if (name == "redo")
            p.applyTransform(AffineTransform::scale(-1, 1).translated(24, 0));
    } else if (name == "keyboard") {
        p.addRoundedRectangle(1, 5, 22, 14, 2);
        for (int row = 0; row < 2; ++row)
            for (int column = 0; column < 6; ++column)
                p.addRectangle(4.f + column * 3, 8.f + row * 3, 1, 1);
        line(6, 16, 18, 16);
    } else if (name == "railKeyboard" || name == "piano") {
        // Filled piano keys with transparent black-key slots, matching
        // the compact pianokeys symbol used by the Mac sidebar.
        p.setUsingNonZeroWinding(false);
        p.addRoundedRectangle(1, 1, 22, 22, 2.6f);
        for (float x : {6.5f, 12.f, 17.5f}) {
            p.startNewSubPath(x - 1.55f, 1); p.lineTo(x + 1.55f, 1);
            p.lineTo(x + 1.55f, 12.9f);
            p.quadraticTo(x + 1.55f, 14.1f, x + .45f, 14.1f);
            p.lineTo(x + .45f, 23); p.lineTo(x - .45f, 23);
            p.lineTo(x - .45f, 14.1f);
            p.quadraticTo(x - 1.55f, 14.1f, x - 1.55f, 12.9f);
            p.closeSubPath();
        }
        fill = true;
    } else if (name == "railParts") {
        line(3,6,21,6);
        line(3,12,16,12);
        line(3,18,11,18);
    } else if (name == "settings" || name == "railSettings") {
        for (int i = 0; i < 16; ++i) {
            const float a = (float)i * MathConstants<float>::twoPi / 16;
            const float radius = (i % 2) == 0 ? 10.f : 7.5f;
            const float x = 12 + std::cos(a) * radius, y = 12 + std::sin(a) * radius;
            if (i == 0)
                p.startNewSubPath(x, y);
            else
                p.lineTo(x, y);
        }
        p.closeSubPath();
        p.addEllipse(8, 8, 8, 8);
    } else if (name == "grid") {
        for (int y = 3; y <= 17; y += 7)
            for (int x = 3; x <= 17; x += 7)
                p.addRoundedRectangle((float)x, (float)y, 4, 4, 1);
    } else if (name == "metronome") {
        p.startNewSubPath(5, 21);
        p.lineTo(9, 3);
        p.lineTo(15, 3);
        p.lineTo(19, 21);
        p.closeSubPath();
        line(7, 18, 17, 18);
        line(12, 18, 4, 7);
        p.addRectangle(3, 6, 4, 4);
    } else if (name == "record") {
        p.addEllipse(3, 3, 18, 18);
        p.addEllipse(8, 8, 8, 8);
    } else if (name == "waveform") {
        for (int i = 0; i < 7; ++i) {
            float h = (i == 3 ? 18.f : i == 2 || i == 4 ? 12.f : 6.f);
            line(3.f + i * 3, 12 - h / 2, 3.f + i * 3, 12 + h / 2);
        }
    } else if (name == "setlist") {
        for (int y : {5, 12, 19}) {
            p.addEllipse(2, (float)y - 1, 2, 2);
            line(7, (float)y, 22, (float)y);
        }
    } else if (name == "speaker") {
        p.startNewSubPath(3, 9);
        p.lineTo(7, 9);
        p.lineTo(12, 4);
        p.lineTo(12, 20);
        p.lineTo(7, 15);
        p.lineTo(3, 15);
        p.closeSubPath();
        p.startNewSubPath(16, 7);
        p.quadraticTo(21, 12, 16, 17);
        p.startNewSubPath(19, 3);
        p.quadraticTo(26, 12, 19, 21);
    } else if (name == "account") {
        p.addEllipse(2, 2, 20, 20);
        p.addEllipse(8, 5, 8, 8);
        p.startNewSubPath(5, 19);
        p.quadraticTo(12, 9, 19, 19);
    } else if (name == "mappings") {
        p.addRoundedRectangle(2, 3, 20, 7, 3);
        p.addRoundedRectangle(2, 14, 20, 7, 3);
        p.addEllipse(4, 5, 3, 3);
        p.addEllipse(17, 16, 3, 3);
    } else if (name == "plugins") {
        p.startNewSubPath(2, 7);
        p.lineTo(9, 7);
        p.cubicTo(4, 0, 20, 0, 15, 7);
        p.lineTo(22, 7);
        p.lineTo(22, 13);
        p.cubicTo(15, 9, 15, 23, 22, 19);
        p.lineTo(22, 23);
        p.lineTo(2, 23);
        p.closeSubPath();
    } else if (name == "notice") {
        p.addRoundedRectangle(2, 3, 20, 14, 3);
        line(6, 17, 5, 22);
        line(5, 22, 11, 17);
        line(6, 8, 18, 8);
        line(6, 12, 14, 12);
    } else if (name == "clock") {
        p.addEllipse(2, 2, 20, 20);
        line(12, 5, 12, 12);
        line(12, 12, 7, 12);
    } else if (name == "search") {
        p.addEllipse(3, 3, 12, 12);
        line(13, 13, 21, 21);
    } else if (name == "close") {
        line(5, 5, 19, 19);
        line(19, 5, 5, 19);
    } else if (name == "play") {
        p.addTriangle(6, 3, 21, 12, 6, 21);
        fill = true;
    } else if (name == "teleprompter") {
        line(3, 4, 21, 4);
        line(3, 9, 21, 9);
        line(3, 14, 16, 14);
        line(3, 19, 12, 19);
    } else if (name == "remote") {
        p.addEllipse(2, 2, 20, 20);
        p.addEllipse(7, 2, 10, 20);
        line(2, 12, 22, 12);
        line(4, 6, 20, 6);
        line(4, 18, 20, 18);
    } else if (name == "check") {
        line(4, 12, 10, 18);
        line(10, 18, 20, 5);
    } else if (name == "save") {
        line(3, 10, 3, 21);
        line(3, 21, 21, 21);
        line(21, 21, 21, 10);
        line(12, 2, 12, 15);
        line(7, 10, 12, 15);
        line(12, 15, 17, 10);
    } else if (name == "pause") {
        p.addRectangle(6, 5, 4, 14);
        p.addRectangle(14, 5, 4, 14);
        fill = true;
    } else if (name == "stopall") {
        p.addRoundedRectangle(5, 5, 14, 14, 1);
        fill = true;
    } else if (name == "loop") {
        p.startNewSubPath(2,14);p.lineTo(2,10);p.cubicTo(2,6,4,5,8,5);p.lineTo(20,5);
        p.startNewSubPath(22,10);p.lineTo(22,14);p.cubicTo(22,18,20,19,16,19);p.lineTo(4,19);
        line(16,1,20,5);line(16,9,20,5);line(8,15,4,19);line(8,23,4,19);
    } else if (name == "video") {
        p.addRoundedRectangle(2, 5, 14, 14, 2);
        p.startNewSubPath(16, 9);
        p.lineTo(22, 6);
        p.lineTo(22, 18);
        p.lineTo(16, 15);
    } else
        return false;
    const float side = std::min(bounds.getWidth(), bounds.getHeight());
    p.applyTransform(AffineTransform::scale(side / 24).translated(bounds.getCentreX() - side / 2,
                                                                  bounds.getCentreY() - side / 2));
    if (fill)
        g.fillPath(p);
    else
        g.strokePath(p, PathStrokeType(1.35f, PathStrokeType::curved, PathStrokeType::rounded));
    return true;
}
} // namespace catlive
