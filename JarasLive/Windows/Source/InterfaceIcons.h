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
        p.addRoundedRectangle(2, 4, 20, 16, 2);
        for (int x : {7, 12, 17})
            line((float)x, 4, (float)x, 20);
        p.addRectangle(5, 4, 4, 9);
        p.addRectangle(10, 4, 4, 9);
        p.addRectangle(15, 4, 4, 9);
    } else if (name == "railSections") {
        p.addRoundedRectangle(2, 12, 8, 9, 1);
        p.addRoundedRectangle(14, 12, 8, 9, 1);
        line(2, 5, 10, 5);
        line(14, 5, 22, 5);
        line(2, 8, 10, 8);
        line(14, 8, 22, 8);
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
        line(6, 6, 20, 6);
        line(17, 3, 20, 6);
        line(20, 6, 17, 9);
        line(20, 6, 20, 13);
        line(18, 18, 4, 18);
        line(7, 15, 4, 18);
        line(4, 18, 7, 21);
        line(4, 18, 4, 11);
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
