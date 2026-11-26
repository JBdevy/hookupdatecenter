#pragma once
#include "StageContent.h"
namespace catlive {
void Projection::paintStage(Graphics &g) {
    const auto settings = stage->settings(profile);
    const auto notices = stage->preferences.value("jaras.notices.appearance", object());
    const bool preview = stage->preview && flag(settings, "previewEnabled", true) &&
                         !flag(settings, "ignorePreview");
    const bool showingNotice =
        !preview && stage->noticeActive() && flag(notices, profile == 1 ? "window1" : "window2", true);
    const bool clear = !preview && flag(settings, "clearMode");
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
    if (showingNotice) {
        auto area = getLocalBounds().toFloat();
        const float size =
            (float)(jlimit(24., 72., getWidth() * .078) * num(notices, "scale", 100) / 100.);
        auto family = str(notices, "font", "Arial");
        if (family == "Menlo")
            family = "Consolas";
        const Font font(FontOptions(family, size, Font::plain).withPointHeight(size));
        const auto message = stage->noticeText(notices);
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
        if (flag(settings, "windowBorderEnabled", true)) {
            g.setColour(border("borderColor", "rgbWindowBorderEnabled"));
            g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.7f), 5, 1.4f);
        }
        return;
    }
    const auto content = StageContent::make(session,*stage,profile).payload;
    const bool loopActive = flag(content, "loopActive");
    if (preview)
        g.fillAll(Colours::black);
    if (loopActive) {
        const auto bar = box.removeFromBottom(24);
        g.setColour(Colour(0xffffff00));
        g.fillRect(bar);
        g.setColour(Colours::black);
        g.setFont(Font(FontOptions(14.f, Font::bold)));
        g.drawFittedText(str(content, "loopLabel", "Loop ativo"), bar.toNearestInt(), Justification::centred, 1);
        box.removeFromBottom(3);
    }
    auto label = [&](String value, juce::Rectangle<float> area, String family, float size,
                     Colour ink, Justification alignment = Justification::centred, int lines = 1) {
        if(value.startsWith(ItemTextColors::prefix())) {
            ItemTextColors::draw(g,value,area,StageState::font(settings,family,size),ink,alignment,display);return;
        }
        g.setFont(StageState::font(settings, family, size));
        g.setColour(ink);
        g.drawFittedText(display(value), area.toNearestInt(), alignment, lines, .3f);
    };
    auto *song = session.song();
    if (!clear && !flag(settings, "hideTransport")) {
        const auto position = str(settings, "clockPosition", "center-top");
        const bool timerEnabled = flag(settings,"clockEnabled",true);
        const bool top = !timerEnabled || position.endsWith("top");
        const bool localEnabled=flag(settings,"localClockEnabled",true);
        const bool paired=timerEnabled&&localEnabled&&!position.startsWith("center");
        const float size=std::max(getHeight()>getWidth()?15.f:18.f,
            std::min((box.getWidth()-16)/11,getHeight()/8.f)*(float)num(settings,"clockScale",100)/100);
        const float localSize=paired?size:std::max(10.f,std::min(24.f,getHeight()/28.f)*(float)num(settings,"localClockScale",100)/100);
        const float clockHeight=timerEnabled?size+(paired?10:18):localSize+10;
        if(timerEnabled||localEnabled) {
            auto row=top?box.removeFromTop(clockHeight+6):box.removeFromBottom(clockHeight+6);
            const float timerWidth=paired?(row.getWidth()-8)/2:std::min(row.getWidth(),size*7.2f+36);
            const float timerX=!localEnabled?row.getCentreX()-timerWidth/2:position.startsWith("left")?row.getX():position.startsWith("right")?row.getRight()-timerWidth:row.getCentreX()-timerWidth/2;
            if(timerEnabled) {
                juce::Rectangle<float> clock{timerX,row.getY(),timerWidth,clockHeight};
                if(flag(settings,"clockBorderEnabled",true)){g.setColour(border("clockBorderColor","rgbClockBorderEnabled"));g.drawRoundedRectangle(clock,5,2);}
                label(stage->timeText(true),clock.reduced(10,5),"fontFamily",size,color(stage->seconds()<0?"clockExpiredColor":"clockColor"));
            }
            if(localEnabled) {
                const bool left=paired?position.startsWith("right"):str(settings,"localClockPosition","right")=="left";
                const float available=timerEnabled&&!paired?std::max(0.f,(row.getWidth()-timerWidth)/2-8):row.getWidth();
                const float width=paired?timerWidth:std::min(available,localSize*5.4f+10);
                juce::Rectangle<float> local{!timerEnabled?row.getCentreX()-width/2:left?row.getX():row.getRight()-width,row.getY(),width,paired?clockHeight:localSize+10};
                if(flag(settings,"localClockBorderEnabled",true)){g.setColour(color("localClockBorderColor"));g.drawRoundedRectangle(local,5,1);}
                label(Time::getCurrentTime().formatted("%H:%M:%S"),local.reduced(5),"fontFamily",localSize,color("localClockColor"));
            }
        }
        auto title = [&](String value, String key, float base) {
            if (preview || value.isEmpty() || !flag(settings, Identifier(key + "Enabled")))
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
        const auto chords=str(content,"chordsStyled",str(content,"chords"));
        if (!preview && flag(settings, "chordsEnabled", true) && chords.isNotEmpty()) {
            const float size = (float)num(settings, "chordScale", 50);
            auto area = str(settings, "chordPosition", "top") == "bottom"
                            ? box.removeFromBottom(size * 1.5f)
                            : box.removeFromTop(size * 1.5f);
            float textWidth=1;
            const auto chordFont=StageState::font(settings,"chordFontFamily",size);
            for(const auto &line:StringArray::fromLines(display(ItemTextColors::plain(chords))))
                textWidth=std::max(textWidth,GlyphArrangement::getStringWidth(chordFont,line));
            area=area.withSizeKeepingCentre(std::min(area.getWidth(),textWidth+12),area.getHeight());
            g.setColour(border("chordColor", "rgbChordBorderEnabled"));
            g.drawRoundedRectangle(area, 5, 1);
            label(chords, area.reduced(5), "chordFontFamily", size, color("chordColor"),
                  Justification::centred, 2);
        }
        if (!preview && !loopActive && flag(settings, "progressEnabled")) {
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
    const auto drawLyrics = [&](juce::Rectangle<float> fullBox, bool allowHorizontal) {
        if (str(content, "text").isEmpty()) return;
        const auto columns=ItemTextColors::columns(str(content,"textStyled",str(content,"text")));
        for(int index=0;index<columns.size();++index) {
            auto lyricsBox = fullBox;
            if(columns.size()==2) {
                if(allowHorizontal && getWidth()>=getHeight()) { const float width=(fullBox.getWidth()-8)/2;lyricsBox={fullBox.getX()+index*(width+8),fullBox.getY(),width,fullBox.getHeight()}; }
                else { const float height=(fullBox.getHeight()-8)/2;lyricsBox={fullBox.getX(),fullBox.getY()+index*(height+8),fullBox.getWidth(),height}; }
            }
            if (flag(settings, "textBoxEnabled", true)) {
                g.setColour(border("textBoxColor", "rgbTextBoxBorderEnabled"));
                g.drawRoundedRectangle(lyricsBox, 5, 1);
            }
            auto align = str(settings, "textAlignment", "center");
            const auto text = display(ItemTextColors::plain(columns[index]));
            const auto lines = StringArray::fromLines(text);
            const auto baseFont = StageState::font(settings,"fontFamily",100.f);
            float longest = 1;
            for (const auto &line : lines) longest = std::max(longest,GlyphArrangement::getStringWidth(baseFont,line));
            const auto textArea = lyricsBox.reduced(6);
            const float fit = std::max(.01f,std::min(std::max(1.f,textArea.getWidth()) / longest,
                std::max(1.f,textArea.getHeight()) / (std::max(1,lines.size()) * baseFont.getHeight() * 1.2f)));
            label(columns[index], textArea, "fontFamily",
                  (float)(100 * fit * num(settings, "textScale", 100) / 100.),
                  color("textColor"),
                  align == "left"    ? Justification::centredLeft
                  : align == "right" ? Justification::centredRight
                                     : Justification::centred,
                  std::max(1,lines.size()));
        }
    };

    if (preview && song && !clear) {
        if (flag(settings, "previewLyricsEnabled")) {
            if (getWidth() >= getHeight()) {
                drawLyrics(box.removeFromLeft(std::max(0.f, (box.getWidth() - 8.f) * .5f)), false);
                box.removeFromLeft(8.f);
            } else {
                drawLyrics(box.removeFromTop(std::max(0.f, (box.getHeight() - 8.f) * .5f)), false);
                box.removeFromTop(8.f);
            }
        }
        const auto blocks=list(get(content,"blocks"));
        const int columns=std::max(1,std::min(2,blocks.size())),gridRows=std::max(1,(std::min(4,blocks.size())+columns-1)/columns);
        const float width=std::max(1.f,(box.getWidth()-12-(columns-1)*8)/columns);
        const float available=std::max(1.f,box.getHeight()-12-(gridRows-1)*8);
        const auto rowTime = [&](const var &value, bool heading) {
            const auto seconds = num(value, "duration");
            return seconds > 0 && flag(settings, heading ? "previewBlockDurationEnabled" : "previewSongDurationEnabled", true)
                ? clockText(std::ceil(seconds)) : String();
        };
        const auto previewFont = [&](float size) {
            return StageState::font(settings, "previewFontFamily", size).withPointHeight(size);
        };
        const std::array<float, 4> scales{
            (float)num(settings, "previewScale", 100),
            (float)num(settings, "previewRegionDurationScale", 100),
            (float)num(settings, "previewBlockScale", 100),
            (float)num(settings, "previewBlockDurationScale", 100)
        };
        const auto rowSizes = [&](float size, bool heading, bool scaled) {
            const int index = heading ? 2 : 0;
            return std::pair{std::max(1.f, size * (scaled ? scales[index] : 100.f) / 100.f),
                             std::max(1.f, size * (scaled ? scales[index + 1] : 100.f) / 100.f)};
        };
        const auto textHeight = [&](const var &value, bool heading, float size, bool scaled) {
            const auto [nameSize, timeSize] = rowSizes(size, heading, scaled);
            const auto time = rowTime(value, heading);
            const auto timeWidth = time.isEmpty() ? 0.f : GlyphArrangement::getStringWidth(previewFont(timeSize), time) + 5.f;
            GlyphArrangement glyphs;
            glyphs.addJustifiedText(previewFont(nameSize), display(str(value, "name")), 0, 0,
                                    std::max(1.f, width - 18.f - timeWidth), Justification::left);
            const auto nameHeight = jlimit(nameSize * 1.2f, nameSize * 2.4f, glyphs.getBoundingBox(0, -1, true).getHeight());
            return std::ceil(std::max(nameHeight, time.isEmpty() ? 0.f : timeSize * 1.2f)) + 2.f;
        };
        struct PreviewLayout { float font; std::array<float,2> heights; };
        String cacheKey = String(width) + ":" + String(available) + ":" + str(settings, "previewFontFamily");
        for (float scale : scales) cacheKey += ":" + String(scale);
        for (const auto &block : blocks) {
            cacheKey += "\nBLOCK:" + display(str(block, "name")) + " " + rowTime(block, true);
            for (const auto &row : list(get(block, "songs")))
                cacheKey += "\n" + display(str(row, "name")) + " " + rowTime(row, false);
        }
        static std::map<String, PreviewLayout> layouts;
        PreviewLayout layout;
        if (auto at = layouts.find(cacheKey); at != layouts.end()) layout = at->second;
        else {
            const auto heights = [&](float size, bool scaled) {
                std::array<float, 2> rows{16, gridRows > 1 ? 16.f : 0.f};
                for (int i = 0; i < std::min(4, blocks.size()); ++i) {
                    const auto &block = blocks[i];
                    float used = str(block, "name").isEmpty() ? 16 : textHeight(block, true, size, scaled) + 30;
                    for (const auto &row : list(get(block, "songs"))) used += textHeight(row, false, size, scaled) + 8;
                    rows[i / columns] = std::max(rows[i / columns], used);
                }
                return rows;
            };
            float low = 1, high = 96;
            for (int n = 0; n < 12; ++n) {
                const float mid = (low + high) / 2;
                const auto rows = heights(mid, false);
                if (rows[0] + rows[1] <= available) low = mid;
                else high = mid;
            }
            layout.font = std::max(1.f, std::floor(low * 2) / 2);
            layout.heights = heights(layout.font, true);
            const float total = std::max(1.f, layout.heights[0] + layout.heights[1]);
            for (auto &height : layout.heights) height = available * height / total;
            if (layouts.size() > 256) layouts.clear();
            layouts[cacheKey] = layout;
        }
        for(int i=0;i<std::min(4,blocks.size());++i) {
            const auto &block=blocks[i];const auto songs=list(get(block,"songs"));
            const bool heading=str(block,"name").isNotEmpty();
            auto frame=juce::Rectangle<float>(box.getX()+6+(i%columns)*(width+8),box.getY()+6+(i/columns)*(layout.heights[0]+8),width,layout.heights[i/columns]);
            // The stroke is centred on its path. Keep it inside the cell and
            // outside the text clip so fractional row heights cannot cut it off.
            g.setColour(Colour(0xff000000|(uint32)(int64)get(block,"color")).withAlpha(.7f));
            g.drawRoundedRectangle(frame.reduced(.5f),6,1);
            auto body=frame.reduced(6);
            Graphics::ScopedSaveState cellClip(g);g.reduceClipRegion(body.getSmallestIntegerContainer());
            auto row=[&](const var &value,bool title){
                const auto [nameSize, timeSize] = rowSizes(layout.font, title, true);
                const auto area = body.removeFromTop(textHeight(value, title, layout.font, true) + 4);
                body.removeFromTop(4);
                const bool played=!title&&flag(value,"liveExecuted");
                const bool active=!title&&flag(value,"playing"),waiting=!title&&flag(value,"queued");
                const auto ink=played?Colour(0xffff4040):active||waiting?Colours::white:Colour(0xff000000|(uint32)(int64)(title?get(value,"nameColor",0x69ed91):get(value,"color")));
                auto textArea=area;
                if(active||waiting){
                    g.setColour(Colour(active?0xff701818:0xff665000));g.fillRect(area);
                    g.setColour(Colour(active?0xffff4040:0xffffdf40));
                    g.fillRect(juce::Rectangle<float>(area.getX(),area.getBottom()-3,area.getWidth()*(float)jlimit(0.,1.,num(value,"playbackProgress")),3));
                    textArea=textArea.reduced(3,0).withTrimmedBottom(4);
                }
                const auto time = rowTime(value, title);
                auto nameArea = textArea;
                auto timeArea = nameArea.removeFromRight(time.isEmpty() ? 0.f : std::min(nameArea.getWidth() * .6f,
                    GlyphArrangement::getStringWidth(previewFont(timeSize), time) + 1.f));
                if (!time.isEmpty()) nameArea.removeFromRight(5.f);
                const auto drawText = [&](const String &text, auto bounds, float size, Justification alignment, int lines) {
                    if (text.isEmpty() || bounds.isEmpty()) return;
                    GlyphArrangement glyphs;
                    glyphs.addFittedText(previewFont(size), text, bounds.getX(), bounds.getY(),
                                        bounds.getWidth(), bounds.getHeight(), alignment, lines, 1.f);
                    g.setColour(ink);
                    glyphs.draw(g);
                    if (!played) return;
                    for (int first = 0; first < glyphs.getNumGlyphs();) {
                        int end = first + 1;
                        const auto baseline = glyphs.getGlyph(first).getBaselineY();
                        while (end < glyphs.getNumGlyphs() && std::abs(glyphs.getGlyph(end).getBaselineY() - baseline) < .5f) ++end;
                        const auto line = glyphs.getBoundingBox(first, end - first, false);
                        g.fillRect(juce::Rectangle<float>(line.getX(), line.getCentreY(), line.getWidth(),
                            std::max(1.f, size / 18)).getIntersection(bounds));
                        first = end;
                    }
                };
                drawText(display(str(value, "name")), nameArea, nameSize, Justification::centredLeft, 2);
                drawText(time, timeArea, timeSize, Justification::centredRight, 1);
                if(!title&&flag(settings,"previewUnderlineEnabled",true)){g.setColour(ink);g.drawHorizontalLine((int)textArea.getBottom()-2,textArea.getX(),textArea.getRight());}
            };
            if(heading){row(block,true);g.setColour(Colour(0xff000000|(uint32)(int64)get(block,"color")).withAlpha(.85f));g.fillRect(body.removeFromTop(2));body.removeFromTop(6);}
            for(const auto &value:songs)row(value,false);
        }
    } else if (!clear) {
        drawLyrics(box, true);
    }

    if (!clear && flag(settings, "windowBorderEnabled", true)) {
        g.setColour(border("borderColor", "rgbWindowBorderEnabled"));
        g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.7f), 5, 1.4f);
    }

}
} // namespace catlive
