#pragma once
#include "StageContent.h"
namespace catlive {
void Projection::paintStage(Graphics &g) {
    const auto settings = stage->settings(profile);
    const auto content = StageContent::make(session,*stage,profile).payload;
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
    auto *song = session.song();
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
        title(str(content,"song"), "songName", getHeight() / 18.f);
        title(str(content,"queued"), "queueName", getHeight() / 22.f);
        const auto chords=str(content,"chords");
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
            const double progress=num(content,"progress");
            auto area = str(settings, "progressPosition", "bottom") == "top"
                            ? box.removeFromTop(7)
                            : box.removeFromBottom(7);
            g.setColour(color("progressColor").withAlpha(.18f));
            g.fillRoundedRectangle(area, 3);
            if (progress > 0) {
                g.setColour(color("progressColor"));
                g.fillRoundedRectangle(
                    area.withWidth(area.getWidth() *
                                   (float)progress),
                    3);
            }
        }
    }
    if (preview && song && !clear) {
        const auto blocks=list(get(content,"blocks"));
        const int columns=std::max(1,std::min(4,blocks.size()));
        int rows=1;for(const auto &block:blocks)rows=std::max(rows,list(get(block,"songs")).size()+(str(block,"name").isNotEmpty()?1:0));
        const float width=(box.getWidth()-12-(columns-1)*8)/columns;
        const float font=std::max(9.f,std::min((width-20)/13,(box.getHeight()-20)/rows/1.1f)*(float)num(settings,"previewScale",100)/100);
        for(int i=0;i<blocks.size();++i) {
            const auto &block=blocks[i];const auto songs=list(get(block,"songs"));
            const bool heading=str(block,"name").isNotEmpty();
            auto frame=juce::Rectangle<float>(box.getX()+6+i*(width+8),box.getY()+6,width,(songs.size()+(heading?1:0))*(font*1.2f+3)+12);
            g.setColour(Colour(0xff000000|(uint32)(int64)get(block,"color")).withAlpha(.7f));g.drawRoundedRectangle(frame,6,1);
            auto body=frame.reduced(6);
            auto row=[&](const var &value,bool title){
                auto text=str(value,"name");if(flag(settings,title?"previewBlockDurationEnabled":"previewSongDurationEnabled",true)&&num(value,"duration")>0)text+=String::fromUTF8(" • ")+clockText(std::ceil(num(value,"duration")));
                const auto area=body.removeFromTop(font*1.2f+3);
                const auto ink=Colour(0xff000000|(uint32)(int64)get(value,"color"));
                label(text,area,"previewFontFamily",title?font*1.05f:font,ink,Justification::centredLeft,2);
                if(!title&&flag(settings,"previewUnderlineEnabled",true)){g.setColour(ink);g.drawHorizontalLine((int)area.getBottom()-2,area.getX(),area.getRight());}
            };
            if(heading)row(block,true);for(const auto &value:songs)row(value,false);
        }
    } else if (!clear && str(content,"text").isNotEmpty()) {
        if (flag(settings, "textBoxEnabled", true)) {
            g.setColour(border("textBoxColor", "rgbTextBoxBorderEnabled"));
            g.drawRoundedRectangle(box, 5, 1);
        }
        auto align = str(settings, "textAlignment", "center");
        label(str(content,"text"), box.reduced(12), "fontFamily",
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
