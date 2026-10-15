#pragma once
namespace catlive {
void Projection::paintStage(Graphics &g) {
    const auto settings = stage->settings(profile);
    const auto notices = stage->preferences.value("jaras.notices.appearance", object());
    const bool showingNotice =
        stage->noticeActive() && flag(notices, profile == 1 ? "window1" : "window2", true);
    const bool clear = flag(settings, "clearMode");
    auto box = getLocalBounds().toFloat().reduced(7);
    const auto rgb = Colour::fromHSV((float)std::fmod(StageState::now() / 6, 1.), 1.f, 1.f, 1.f);
    auto color = [&](String key, uint32 fallback = 0xffffff) {
        return StageState::colour(settings, key, fallback);
    };
    auto border = [&](String key, String animated) {
        return flag(settings, Identifier(animated)) ? rgb : color(key);
    };
    auto display = [&](String value) {
        const auto mode = str(settings, "textCase");
        return mode == "uppercase"   ? unicodeCase(value)
               : mode == "lowercase" ? unicodeCase(value, false)
                                     : value;
    };
    const bool preview = stage->preview && flag(settings, "previewEnabled", true) &&
                         !flag(settings, "ignorePreview");
    if (preview || (showingNotice && flag(notices, "cleanDisplay", true)))
        g.fillAll(Colours::black);
    auto label = [&](String value, juce::Rectangle<float> area, String family, float size,
                     Colour ink, Justification alignment = Justification::centred, int lines = 1) {
        g.setFont(StageState::font(settings, family, size));
        g.setColour(ink);
        g.drawFittedText(display(value), area.toNearestInt(), alignment, lines, .3f);
    };
    const auto &transport = session.transport();
    auto *song = session.song();
    const jaras::Part *current = nullptr, *queued = nullptr;
    if (song)
        for (const auto &part : song->parts) {
            if (transport.regionId && *transport.regionId == part.id)
                current = &part;
            if (transport.queuedRegionId && *transport.queuedRegionId == part.id)
                queued = &part;
        }
    if (!clear && !flag(settings, "hideTransport") &&
        !(showingNotice && flag(notices, "cleanDisplay", true))) {
        const auto position = str(settings, "clockPosition", "center-top");
        const bool top = position.endsWith("top");
        const float size =
            (float)jlimit(16., 76., getHeight() / 8. * num(settings, "clockScale", 100) / 100.);
        const float clockHeight = size * 1.3f;
        if (flag(settings, "clockEnabled", true) || flag(settings, "localClockEnabled", true)) {
            auto row =
                top ? box.removeFromTop(clockHeight + 6) : box.removeFromBottom(clockHeight + 6);
            if (flag(settings, "clockEnabled", true)) {
                const float width = std::min(row.getWidth(), size * 6.1f);
                const float x = position.startsWith("left")    ? row.getX()
                                : position.startsWith("right") ? row.getRight() - width
                                                               : row.getCentreX() - width / 2;
                juce::Rectangle<float> clock{x, row.getY(), width, clockHeight};
                if (flag(settings, "clockBorderEnabled", true)) {
                    g.setColour(border("clockBorderColor", "rgbClockBorderEnabled"));
                    g.drawRoundedRectangle(clock, 5, 2);
                }
                label(stage->timeText(true), clock.reduced(5), "fontFamily", size,
                      color(stage->seconds() < 0 ? "clockExpiredColor" : "clockColor"));
            }
            if (flag(settings, "localClockEnabled", true)) {
                const float localSize = (float)jlimit(
                    12., 42., getHeight() / 18. * num(settings, "localClockScale", 100) / 100.);
                const float width = std::min(row.getWidth() / 3, localSize * 5.4f);
                const bool left = str(settings, "localClockPosition", "right") == "left";
                juce::Rectangle<float> local{left ? row.getX() : row.getRight() - width, row.getY(),
                                             width, localSize * 1.4f};
                if (flag(settings, "localClockBorderEnabled", true)) {
                    g.setColour(color("localClockBorderColor"));
                    g.drawRoundedRectangle(local, 4, 1);
                }
                label(Time::getCurrentTime().formatted("%H:%M:%S"), local, "fontFamily", localSize,
                      color("localClockColor"));
            }
        }
        auto title = [&](String value, String key, float base) {
            if (value.isEmpty() || !flag(settings, Identifier(key + "Enabled")))
                return;
            const float size = (float)jlimit(
                10., 90., base * num(settings, Identifier(key + "Scale"), 100) / 100.);
            auto area = str(settings, Identifier(key + "Position"), "top") == "bottom"
                            ? box.removeFromBottom(size * 1.4f)
                            : box.removeFromTop(size * 1.4f);
            label(value, area, key + "FontFamily", size, color(key + "Color"));
        };
        title(current ? text(current->name)
              : song  ? text(song->name)
                      : String(),
              "songName", getHeight() / 18.f);
        title(queued ? text(queued->name) : String(), "queueName", getHeight() / 22.f);
        String chords;
        double chordStart = 0, chordDuration = 0;
        if (song)
            for (const auto &track : song->tracks)
                if (track.role.id == "chords" && !track.mute)
                    for (const auto &clip : track.clips)
                        if (clip.text && !clip.muted && transport.position >= clip.startTime &&
                            transport.position < clip.startTime + clip.duration) {
                            chords = text(*clip.text);
                            chordStart = clip.startTime;
                            chordDuration = clip.duration;
                            break;
                        }
        if (!preview && flag(settings, "chordsEnabled", true) && chords.isNotEmpty()) {
            const float size = (float)num(settings, "chordScale", 50);
            auto area = str(settings, "chordPosition", "top") == "bottom"
                            ? box.removeFromBottom(size * 1.5f)
                            : box.removeFromTop(size * 1.5f);
            g.setColour(border("chordColor", "rgbChordBorderEnabled"));
            g.drawRoundedRectangle(area, 5, 1);
            label(chords, area.reduced(5), "chordFontFamily", size, color("chordColor"),
                  Justification::centred, 2);
        }
        if (flag(settings, "progressEnabled")) {
            const bool chord = str(settings, "progressMode") == "chords";
            const double duration = chord ? chordDuration : itemDuration,
                         start = chord ? chordStart : itemStart;
            auto area = str(settings, "progressPosition", "bottom") == "top"
                            ? box.removeFromTop(7)
                            : box.removeFromBottom(7);
            g.setColour(color("progressColor").withAlpha(.18f));
            g.fillRoundedRectangle(area, 3);
            if (duration > 0) {
                g.setColour(color("progressColor"));
                g.fillRoundedRectangle(
                    area.withWidth(area.getWidth() *
                                   (float)jlimit(0., 1., (transport.position - start) / duration)),
                    3);
            }
        }
    }
    if (preview && song && !clear) {
        std::vector<const jaras::Part *> parts;
        if (const auto &setlist = session.project().regionSetlist; setlist && setlist->selectedId) {
            for (const auto &playlist : setlist->playlists)
                if (playlist.id == *setlist->selectedId)
                    for (const auto &id : playlist.regionIds)
                        for (const auto &p : song->parts)
                            if (p.id == id)
                                parts.push_back(&p);
        } else
            for (const auto &p : song->parts)
                parts.push_back(&p);
        const int columns = (int)parts.size() > 16 ? 2 : 1;
        const int count = std::max(1, ((int)parts.size() + columns - 1) / columns);
        const float height = std::min(48.f, box.getHeight() / count);
        const float font =
            (float)jlimit(9., 34., height * .65 * num(settings, "previewScale", 100) / 100.);
        for (size_t i = 0; i < parts.size(); ++i) {
            const auto *part = parts[i];
            juce::Rectangle<float> area{box.getX() + (i / count) * (box.getWidth() / columns),
                                        box.getY() + (i % count) * height,
                                        box.getWidth() / columns - 10, height};
            auto value = text(part->name);
            if (flag(settings, "previewSongDurationEnabled", true))
                value += String::fromUTF8(" • ") + clockText(part->endTime - part->startTime);
            const auto ink = part == current  ? color("highlightColor")
                             : part == queued ? color("queueNameColor")
                                              : color("textColor");
            label(value, area, "previewFontFamily", font, ink, Justification::centredLeft);
            if (flag(settings, "previewUnderlineEnabled", true)) {
                g.setColour(ink.withAlpha(.5f));
                g.drawHorizontalLine((int)area.getBottom() - 2, area.getX(), area.getRight());
            }
        }
    } else if (!clear && lyrics.isNotEmpty()) {
        if (flag(settings, "textBoxEnabled", true)) {
            g.setColour(border("textBoxColor", "rgbTextBoxBorderEnabled"));
            g.drawRoundedRectangle(box, 5, 1);
        }
        auto align = str(settings, "textAlignment", "center");
        label(lyrics, box.reduced(12), "fontFamily",
              (float)(getHeight() / 9. * num(settings, "textScale", 100) / 100.),
              color("textColor"),
              align == "left"    ? Justification::centredLeft
              : align == "right" ? Justification::centredRight
                                 : Justification::centred,
              20);
    }
    if (!clear && flag(settings, "windowBorderEnabled", true)) {
        g.setColour(border("borderColor", "rgbWindowBorderEnabled"));
        g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.7f), 5, 1.4f);
    }
    if (showingNotice) {
        auto area = getLocalBounds().toFloat();
        const float size =
            (float)(jlimit(24., 72., getWidth() * .078) * num(notices, "scale", 100) / 100.);
        auto family = str(notices, "font", "Arial");
        if (family == "Menlo")
            family = "Consolas";
        const Font font(FontOptions(family, size, Font::plain).withPointHeight(size));
        const auto message = stage->noticeText(notices);
        if (!flag(notices, "cleanDisplay", true)) {
            float height = 0;
            if (stage->noticeImage.isValid()) {
                height = (area.getWidth() - 48) * stage->noticeImage.getHeight() /
                         std::max(1, stage->noticeImage.getWidth());
            } else {
                AttributedString attributed(message);
                attributed.setFont(font);
                TextLayout layout;
                layout.createLayout(attributed, std::max(1.f, area.getWidth() - 48));
                height = layout.getHeight();
            }
            area.setHeight(std::min(area.getHeight(), height + 48));
        }
        const double elapsed = std::max(0., StageState::now() - stage->noticeSent);
        const bool flash = elapsed < 1.05 && ((int)(elapsed / .175) % 2) == 0;
        g.setColour(
            StageState::colour(notices, flash ? "flash" : "background", flash ? 0xffdc52 : 0));
        g.fillRect(area);
        const auto inner = area.reduced(24).toNearestInt();
        if (stage->noticeImage.isValid())
            g.drawImageWithin(stage->noticeImage, inner.getX(), inner.getY(), inner.getWidth(),
                              inner.getHeight(), RectanglePlacement::centred);
        else {
            g.setFont(font);
            g.setColour(StageState::colour(notices, "text", 0xffffff));
            g.drawFittedText(message, inner, Justification::centred, 20, .3f);
        }
    }
}
} // namespace catlive
