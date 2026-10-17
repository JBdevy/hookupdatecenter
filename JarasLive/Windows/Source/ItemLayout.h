#pragma once
#include "Common.h"
#include "../../Core/Tracks/ItemFade.hpp"
namespace catlive {
// ProjectModels.TrackLanes: simultaneous items occupy distinct visual lanes.
struct ItemLanes {
    std::map<ID, int> lanes;
    int count = 1;
    explicit ItemLanes(const jaras::Track &track) {
        std::vector<const jaras::AudioClip *> ordered, placed, takes;
        for (const auto &clip : track.clips) ordered.push_back(&clip);
        const auto chronological = [](const auto *a, const auto *b) {
            return a->startTime != b->startTime ? a->startTime < b->startTime : a->id < b->id;
        };
        std::sort(ordered.begin(), ordered.end(), chronological);
        std::vector<double> ends;
        for (const auto *clip : ordered) {
            if (clip->recordingLane) { takes.push_back(clip); continue; }
            auto at = std::find_if(ends.begin(), ends.end(), [&](double end) { return end <= clip->startTime; });
            const int lane = (int)(at - ends.begin());
            if (at == ends.end()) ends.push_back(clip->startTime + clip->duration);
            else *at = clip->startTime + clip->duration;
            lanes[clip->id] = lane; placed.push_back(clip); count = std::max(count, lane + 1);
        }
        std::sort(takes.begin(), takes.end(), [&](const auto *a, const auto *b) {
            return a->recordingLane != b->recordingLane ? a->recordingLane < b->recordingLane : chronological(a,b);
        });
        for (const auto *clip : takes) {
            int lane = 0;
            for (const auto *other : placed)
                if (other->startTime < clip->startTime + clip->duration && other->startTime + other->duration > clip->startTime)
                    lane = std::max(lane, lanes.at(other->id) + 1);
            lanes[clip->id] = lane; placed.push_back(clip); count = std::max(count, lane + 1);
        }
    }
    int lane(const ID &id) const { const auto at = lanes.find(id); return at == lanes.end() ? 0 : at->second; }
};
// ClipRepetitionBoundaries: show visible source repeats, skipping subpixel seams.
inline std::vector<float> itemLoopSeams(const jaras::AudioClip &clip, juce::Rectangle<float> bounds, float viewportWidth, double scale) {
    std::vector<float> result;
    const double length=clip.loopLength.value_or(0),rate=clip.playbackRate;
    if(length<=0 || rate<=0 || scale<=0 || !std::isfinite(length)) return result;
    const double interval=length/rate,offset=clip.sourceOffset-clip.loopStart.value_or(0);
    const double phase=std::fmod(std::fmod(offset,length)+length,length),origin=(length-phase)/rate;
    const double lower=std::max(1e-6,(-bounds.getX()-4)/scale),upper=std::min(clip.duration-1e-6,(viewportWidth-bounds.getX()+4)/scale);
    const double skip=std::max(1.,std::ceil(10/scale/interval)),step=interval*skip;
    double position=origin+std::ceil(std::max(0.,std::ceil((lower-origin)/interval))/skip)*step;
    for(;position<=upper;) {
        result.push_back(bounds.getX()+(float)(position*scale));
        const double next=position+step;if(next<=position) break;position=next;
    }
    return result;
}
inline Path itemOutline(const jaras::AudioClip &clip, juce::Rectangle<float> r, float viewportWidth, double scale) {
    Path path;
    const float radius=r.getWidth()<20 ? 0 : 3;
    const auto seams=itemLoopSeams(clip,r,viewportWidth,scale);
    if(seams.empty()) {path.addRoundedRectangle(r,radius);return path;}
    const float left=r.getX(),right=r.getRight(),top=r.getY(),bottom=r.getBottom(),depth=std::min(5.f,r.getHeight()/3);
    path.startNewSubPath(left+radius,top);path.lineTo(right-radius,top);path.quadraticTo(right,top,right,top+radius);
    path.lineTo(right,bottom-radius);path.quadraticTo(right,bottom,right-radius,bottom);
    for(auto at=seams.rbegin();at!=seams.rend();++at) if(*at>left+radius && *at<right-radius) {
        path.lineTo(std::min(right-radius,*at+4),bottom);path.lineTo(*at,bottom-depth);path.lineTo(std::max(left+radius,*at-4),bottom);
    }
    path.lineTo(left+radius,bottom);path.quadraticTo(left,bottom,left,bottom-radius);path.lineTo(left,top+radius);path.quadraticTo(left,top,left+radius,top);path.closeSubPath();return path;
}
// GridSelectionItem geometry is shared by drawing and hit testing.
struct ItemHeader {
    enum Control { none, mute, fx, phase, pan, gain, fadeIn, fadeOut, fadeInCurve, fadeInSCurve, fadeOutCurve, fadeOutSCurve };
    juce::Rectangle<float> item, visible, muteRect, fxRect, phaseRect, panRect, panLabel, gainRect, gainLabel;
    float titleLeft = 0;
    bool editable = false, midi = false;
    ItemHeader(juce::Rectangle<float> bounds, float viewportWidth, const jaras::Track &track, const jaras::AudioClip &clip)
        : item(bounds), editable(jaras::fixedTrackName(track.role).empty() || (clip.audioFile && clip.audioFile->path.rfind("Videos/",0)==0)), midi(bool(clip.midi)) {
        visible = bounds.getIntersection({0, bounds.getY(), viewportWidth, std::min(17.f,bounds.getHeight())});
        const float x = visible.getX() + 2.6f, y = bounds.getY(), width = visible.getWidth();
        titleLeft = visible.getX() + 6;
        if (!editable || width<27.3f) return;
        if (width >= 27.3f) muteRect = {x,y,22.1f,17};
        if ((!midi || clip.fxJSON) && width >= 53.3f) fxRect = {x+23.4f,y,26,17};
        if (!midi && width >= 74.1f) phaseRect = {x+50.7f,y,19.5f,17};
        if (!midi && width >= 96.2f) panRect = {x+71.5f,y,19.5f,17};
        if (!panRect.isEmpty() && visible.getRight()-panRect.getRight() >= 42.6f) panLabel = {panRect.getRight()+.5f,y,40,17};
        const float offset = midi ? 50.7f : 132.f;
        if (width >= offset + (midi ? 23.4f : 24.7f)) gainRect = {x+offset,y,19.5f,17};
        const float labelWidth = std::max(32.f, std::ceil(gainText(clip.gain.value_or(1)).length()*4.75f)+6);
        if (!gainRect.isEmpty() && visible.getRight()-gainRect.getRight() >= labelWidth+3.9f) gainLabel = {gainRect.getRight()+.5f,y,labelWidth,17};
        for (auto r : {muteRect,fxRect,phaseRect,panRect,panLabel,gainRect,gainLabel}) if (!r.isEmpty()) titleLeft = r.getRight()+1;
    }
    int resizeSide(Point<float> point) const {
        if (point.y < item.getY() || point.y >= item.getBottom()) return 0;
        const float tolerance = std::min(10.f, std::max(2.f, item.getWidth() / 2));
        const float left = std::abs(point.x - item.getX()), right = std::abs(point.x - item.getRight());
        return std::min(left, right) <= tolerance ? (left <= right ? -1 : 1) : 0;
    }
    static String gainText(double value) { return value <= 0 ? String::fromUTF8("−∞ dB") : (value >= 1 ? "+" : "") + String(20*std::log10(value),1)+" dB"; }
    static String panText(double value) { return std::abs(value)<.005 ? "Center" : String(value<0 ? "L-" : "R-")+String(roundToInt(std::abs(value)*100))+"%"; }
    juce::Rectangle<float> fadeRect(const jaras::AudioClip &clip, bool left) const {
        if (!editable || clip.duration<=0 || item.getWidth()<20 || item.getHeight()<25) return {};
        const float x = left ? item.getX() + item.getWidth()*(float)(jlimit(0.,clip.duration,clip.fadeIn.value_or(0))/clip.duration)
                             : item.getRight() - item.getWidth()*(float)(jlimit(0.,clip.duration,clip.fadeOut.value_or(0))/clip.duration);
        return {jlimit(item.getX(),item.getRight()-7,x-3.5f),item.getY()+18,7,7};
    }
    static bool isShape(Control control) { return control >= fadeInCurve && control <= fadeOutSCurve; }
    static bool shapeIn(Control control) { return control == fadeInCurve || control == fadeInSCurve; }
    static bool shapeS(Control control) { return control == fadeInSCurve || control == fadeOutSCurve; }
    static std::optional<double> &shapeValue(jaras::AudioClip &clip, Control control) {
        if (control == fadeInCurve) return clip.fadeInCurve;
        if (control == fadeInSCurve) return clip.fadeInSCurve;
        if (control == fadeOutCurve) return clip.fadeOutCurve;
        return clip.fadeOutSCurve;
    }
    juce::Rectangle<float> shapeRect(const jaras::AudioClip &clip, bool left, bool s) const {
        const double amount = jlimit(0., clip.duration, (left ? clip.fadeIn : clip.fadeOut).value_or(0));
        const float width = item.getWidth() * (float)(amount / std::max(.000001, clip.duration));
        const float top = item.getY() + 18, height = item.getBottom() - 2 - top;
        if (!editable || width < 26 || height < 24) return {};
        const jaras::FadeCurve curve((left ? clip.fadeInCurve : clip.fadeOutCurve).value_or(0),
                                     (left ? clip.fadeInSCurve : clip.fadeOutSCurve).value_or(1));
        const double level = s ? .25 : .75;
        double low = 0, high = 1;
        for (int i = 0; i < 24; ++i) { const auto middle = (low + high) / 2; if (curve.value(middle) < level) low = middle; else high = middle; }
        const float x = (float)((low + high) / 2) * width;
        return {(left ? item.getX() + x : item.getRight() - x) - 3, top + (float)(1 - level) * height - 3, 6, 6};
    }
    Control hit(Point<float> p, const jaras::AudioClip &clip) const {
        if (muteRect.contains(p)) return mute;
        if (fxRect.contains(p)) return fx;
        if (phaseRect.contains(p)) return phase;
        if (panRect.contains(p)) return pan;
        if (gainRect.contains(p)) return gain;
        for (const auto control : {fadeInCurve, fadeInSCurve, fadeOutCurve, fadeOutSCurve}) {
            const auto r = shapeRect(clip, shapeIn(control), shapeS(control));
            if (!r.isEmpty() && r.expanded(3).contains(p)) return control;
        }
        if (fadeRect(clip,true).contains(p)) return fadeIn;
        if (fadeRect(clip,false).contains(p)) return fadeOut;
        return none;
    }
    void draw(Graphics &g, const jaras::AudioClip &clip) const {
        g.saveState(); g.reduceClipRegion(visible.getSmallestIntegerContainer());
        auto button = [&](juce::Rectangle<float> r, String caption, bool active, bool bypass = false) {
            if (r.isEmpty()) return;
            g.setColour(bypass ? Colour(0xffff453a) : Colours::black.withAlpha(.28f)); g.fillRect(r);
            g.setColour(active ? Colour(0xff33ff8c) : Colours::white); g.setFont(theme::semiboldFont(9)); g.drawText(caption,r,Justification::centred);
        };
        button(muteRect,"M",false,clip.muted);
        const bool hasFX = clip.fxJSON && !list(get(JSON::parse(text(*clip.fxJSON)),"inserted")).isEmpty();
        button(fxRect,"FX",hasFX && !clip.fxBypassed.value_or(false),clip.fxBypassed.value_or(false));
        if (!phaseRect.isEmpty()) {
            g.setColour(clip.phaseInverted.value_or(false) ? Colours::yellow : Colours::black.withAlpha(.28f)); g.fillRect(phaseRect);
            g.setColour(clip.phaseInverted.value_or(false) ? Colours::black : Colours::white);
            auto centre=phaseRect.getCentre(); g.drawEllipse(centre.x-4.55f,centre.y-4.55f,9.1f,9.1f,1.2f);
            g.drawLine(centre.x-5.85f,centre.y+5.85f,centre.x+5.85f,centre.y-5.85f,1.2f);
        }
        auto knob = [&](juce::Rectangle<float> r, double position) {
            if (r.isEmpty()) return;
            const auto c=r.getCentre(); g.setColour(Colours::black); g.fillEllipse(c.x-5.85f,c.y-5.85f,11.7f,11.7f);
            g.setColour(Colours::white); g.drawEllipse(c.x-5.85f,c.y-5.85f,11.7f,11.7f,1.5f);
            const float angle=(float)((135+jlimit(0.,1.,position)*270)*MathConstants<double>::pi/180);
            g.setColour(Colour(0xff33ff8c)); g.drawLine(c.x,c.y,c.x+std::cos(angle)*4.55f,c.y+std::sin(angle)*4.55f,2);
        };
        knob(panRect,(clip.pan.value_or(0)+1)/2);
        knob(gainRect,(20*std::log10(std::max(.000001,clip.gain.value_or(1)))+60)/84);
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(9));
        g.drawText(panText(clip.pan.value_or(0)),panLabel,Justification::centredLeft);
        g.drawText(gainText(clip.gain.value_or(1)),gainLabel,Justification::centredLeft);
        g.restoreState();
    }
    void drawFades(Graphics &g, const jaras::AudioClip &clip) const {
        if (!editable || clip.duration<=0) return;
        g.saveState(); g.reduceClipRegion(item.getSmallestIntegerContainer());
        const float top=item.getY()+18, bottom=item.getBottom()-2;
        for (bool left : {true,false}) {
            const double amount=jlimit(0.,clip.duration,(left ? clip.fadeIn : clip.fadeOut).value_or(0));
            if (amount>0 && bottom>top) {
                const float width=item.getWidth()*(float)(amount/clip.duration), x1=left ? item.getX() : item.getRight()-width, x2=x1+width;
                const jaras::FadeCurve shape((left ? clip.fadeInCurve : clip.fadeOutCurve).value_or(0), (left ? clip.fadeInSCurve : clip.fadeOutSCurve).value_or(1));
                const int steps = jlimit(16, 128, (int)std::ceil(std::min(128.f, width)));
                Path curve;
                for (int i = 0; i <= steps; ++i) {
                    const double t = (double)i / steps;
                    const float x = x1 + (float)t * width, y = bottom - (float)shape.value(left ? t : 1-t) * (bottom-top);
                    if (i == 0) curve.startNewSubPath(x,y); else curve.lineTo(x,y);
                }
                Path shade(curve); shade.lineTo(x2,top); shade.lineTo(x1,top); shade.closeSubPath();
                g.setColour(Colours::black.withAlpha(.25f)); g.fillPath(shade);
                g.setColour(Colours::white.withAlpha(.95f)); g.strokePath(curve,PathStrokeType(1));
            }
            for (bool s : {false, true}) {
                const auto r = shapeRect(clip,left,s); if (r.isEmpty()) continue;
                g.setColour(Colours::black.withAlpha(.8f)); g.fillEllipse(r);
                g.setColour(Colours::white.withAlpha(.95f)); g.drawEllipse(r,1);
            }
            const auto r=fadeRect(clip,left); if (r.isEmpty()) continue;
            Path grip; grip.addTriangle(left?r.getX():r.getRight(),r.getY(),left?r.getRight():r.getX(),r.getY(),left?r.getX():r.getRight(),r.getBottom());
            g.setColour(Colours::white.withAlpha(.85f)); g.fillPath(grip);
        }
        g.restoreState();
    }
};
}
