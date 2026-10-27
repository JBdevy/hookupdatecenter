#pragma once
#include "StageContent.h"
namespace catlive {
void Projection::paintStage(Graphics &g) {
    const auto settings = stage->settings(profile);
    const auto content = StageContent::make(session,*stage,profile).payload;
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
    if (preview || (showingNotice && flag(notices, "cleanDisplay", true)))
        g.fillAll(Colours::black);
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
    if (!clear && !flag(settings, "hideTransport") &&
        !(showingNotice && flag(notices, "cleanDisplay", true))) {
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
        if (!preview && flag(settings, "progressEnabled")) {
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
        const int columns=std::max(1,std::min(2,blocks.size())),gridRows=std::max(1,(std::min(4,blocks.size())+columns-1)/columns);
        const float width=std::max(1.f,(box.getWidth()-12-(columns-1)*8)/columns);
        const float available=std::max(1.f,box.getHeight()-12-(gridRows-1)*8);
        const auto rowText=[&](const var &value,bool title){
            auto text=str(value,"name");if(flag(settings,title?"previewBlockDurationEnabled":"previewSongDurationEnabled",true)&&num(value,"duration")>0)text+=String::fromUTF8(" • ")+clockText(std::ceil(num(value,"duration")));
            return display(text);
        };
        const auto textHeight=[&](const String &text,float size){
            GlyphArrangement glyphs;glyphs.addJustifiedText(StageState::font(settings,"previewFontFamily",size),text,0,0,std::max(1.f,width-18),Justification::left);
            return std::ceil(std::min(size*2.4f,std::max(size*1.2f,glyphs.getBoundingBox(0,-1,true).getHeight())))+2;
        };
        struct PreviewLayout { float font; std::array<float,2> heights; };
        String cacheKey=String(width)+":"+String(available)+":"+str(settings,"previewFontFamily");
        for(int i=0;i<std::min(4,blocks.size());++i){cacheKey+="\nBLOCK:"+rowText(blocks[i],true);for(const auto &value:list(get(blocks[i],"songs")))cacheKey+="\n"+rowText(value,false);}
        static std::map<String,PreviewLayout> layouts;
        PreviewLayout layout;
        if(auto at=layouts.find(cacheKey);at!=layouts.end())layout=at->second;
        else {
            const auto heights=[&](float size){
                std::array<float,2> rows{16,gridRows>1?16.f:0.f};
                for(int i=0;i<std::min(4,blocks.size());++i){
                    const auto &block=blocks[i];float used=str(block,"name").isEmpty()?16:textHeight(rowText(block,true),size)+30;
                    for(const auto &value:list(get(block,"songs")))used+=textHeight(rowText(value,false),size)+8;
                    rows[i/columns]=std::max(rows[i/columns],used);
                }
                return rows;
            };
            float low=1,high=96;
            for(int n=0;n<12;++n){const float mid=(low+high)/2;const auto rows=heights(mid);if(rows[0]+rows[1]<=available)low=mid;else high=mid;}
            layout.font=std::max(1.f,std::floor(low*2)/2);layout.heights=heights(layout.font);
            const float total=std::max(1.f,layout.heights[0]+layout.heights[1]);
            for(auto &height:layout.heights)height=available*height/total;
            if(layouts.size()>256)layouts.clear();layouts[cacheKey]=layout;
        }
        const float font=std::max(1.f,layout.font*(float)num(settings,"previewScale",100)/100);
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
                auto text=str(value,"name");if(flag(settings,title?"previewBlockDurationEnabled":"previewSongDurationEnabled",true)&&num(value,"duration")>0)text+=String::fromUTF8(" • ")+clockText(std::ceil(num(value,"duration")));
                const auto area=body.removeFromTop(textHeight(display(text),font)+4);
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
                const auto rowFont=StageState::font(settings,"previewFontFamily",font);
                GlyphArrangement glyphs;
                glyphs.addFittedText(rowFont,display(text),textArea.getX(),textArea.getY(),textArea.getWidth(),textArea.getHeight(),Justification::centredLeft,2,1.f);
                g.setColour(ink);glyphs.draw(g);
                if(played){
                    // Strike each fitted line, including long names that wrap.
                    for(int first=0;first<glyphs.getNumGlyphs();){
                        int end=first+1;const auto baseline=glyphs.getGlyph(first).getBaselineY();
                        while(end<glyphs.getNumGlyphs()&&std::abs(glyphs.getGlyph(end).getBaselineY()-baseline)<.5f)++end;
                        const auto bounds=glyphs.getBoundingBox(first,end-first,false);
                        g.fillRect(juce::Rectangle<float>(bounds.getX(),bounds.getCentreY(),bounds.getWidth(),std::max(1.f,font/18)).getIntersection(textArea));
                        first=end;
                    }
                }
                if(!title&&flag(settings,"previewUnderlineEnabled",true)){g.setColour(ink);g.drawHorizontalLine((int)textArea.getBottom()-2,textArea.getX(),textArea.getRight());}
            };
            if(heading){row(block,true);g.setColour(Colour(0xff000000|(uint32)(int64)get(block,"color")).withAlpha(.85f));g.fillRect(body.removeFromTop(2));body.removeFromTop(6);}
            for(const auto &value:songs)row(value,false);
        }
    } else if (!clear && str(content,"text").isNotEmpty()) {
        if (flag(settings, "textBoxEnabled", true)) {
            g.setColour(border("textBoxColor", "rgbTextBoxBorderEnabled"));
            g.drawRoundedRectangle(box, 5, 1);
        }
        auto align = str(settings, "textAlignment", "center");
        const auto text = display(str(content,"text"));
        const auto lines = StringArray::fromLines(text);
        const auto baseFont = StageState::font(settings,"fontFamily",100.f);
        float longest = 1;
        for (const auto &line : lines) longest = std::max(longest,GlyphArrangement::getStringWidth(baseFont,line));
        const auto textArea = box.reduced(6);
        const float fit = std::max(.01f,std::min(std::max(1.f,textArea.getWidth()) / longest,
            std::max(1.f,textArea.getHeight()) / (std::max(1,lines.size()) * baseFont.getHeight() * 1.2f)));
        label(str(content,"textStyled",str(content,"text")), textArea, "fontFamily",
              (float)(100 * fit * num(settings, "textScale", 100) / 100.),
              color("textColor"),
              align == "left"    ? Justification::centredLeft
              : align == "right" ? Justification::centredRight
                                 : Justification::centred,
              std::max(1,lines.size()));
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
