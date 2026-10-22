#pragma once
#include "Common.h"
#include "../../Core/Tracks/ItemFade.hpp"
namespace catlive {
// ProjectModels.TrackLanes: simultaneous items occupy distinct visual lanes.
struct ItemLanes {
    std::map<ID, int> lanes;
    struct Placement { int lane = 0, count = 1; };
    std::map<ID, Placement> placements;
    int count = 1;
    static std::vector<const jaras::AudioClip*> references(const jaras::Track &track) {
        std::vector<const jaras::AudioClip*> result;result.reserve(track.clips.size());
        for(const auto &clip:track.clips)result.push_back(&clip);return result;
    }
    explicit ItemLanes(const jaras::Track &track):ItemLanes(references(track)) {}
    explicit ItemLanes(std::vector<const jaras::AudioClip*> ordered) {
        std::vector<const jaras::AudioClip *> placed, takes;
        const auto chronological = [](const auto *a, const auto *b) {
            return a->startTime != b->startTime ? a->startTime < b->startTime : a->id < b->id;
        };
        std::sort(ordered.begin(), ordered.end(), chronological);
        std::vector<double> ends;
        for (const auto *clip : ordered) {
            if (clip->recordingLane) { takes.push_back(clip); continue; }
            auto at = std::find_if(ends.begin(), ends.end(), [&](double end) { return end <= clip->startTime + 1e-9; });
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
                if (other->startTime < clip->startTime + clip->duration - 1e-9 && other->startTime + other->duration > clip->startTime + 1e-9)
                    lane = std::max(lane, lanes.at(other->id) + 1);
            lanes[clip->id] = lane; placed.push_back(clip); count = std::max(count, lane + 1);
        }
        // Only items connected by a real temporal overlap share vertical space.
        // An isolated clip fills the row even if other songs have multiple takes.
        for (size_t first=0; first<ordered.size();) {
            size_t last=first+1;
            double end=ordered[first]->startTime+ordered[first]->duration;
            while(last<ordered.size() && ordered[last]->startTime<end-1e-9) {
                end=std::max(end,ordered[last]->startTime+ordered[last]->duration);++last;
            }
            std::set<int> used;
            for(size_t i=first;i<last;++i)used.insert(lanes.at(ordered[i]->id));
            std::map<int,int> compact;int next=0;for(int lane:used)compact.emplace(lane,next++);
            for(size_t i=first;i<last;++i)placements.emplace(ordered[i]->id,Placement{compact.at(lanes.at(ordered[i]->id)),(int)used.size()});
            first=last;
        }
    }
    int lane(const ID &id) const { const auto at = lanes.find(id); return at == lanes.end() ? 0 : at->second; }
    Placement placement(const ID &id) const { const auto at=placements.find(id);return at==placements.end()?Placement{}:at->second; }
    struct Geometry { float top, height; };
    Geometry geometry(const ID &id, float bodyHeight, bool recording = false) const {
        const auto p=recording?Placement{lane(id),count}:placement(id);
        const float height=bodyHeight/std::max(1,p.count);
        return {p.lane*height,height};
    }
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
        if (!editable) return;
        if (width < 26.7f) { titleLeft = visible.getRight(); return; }
        float next = x;
        auto append = [&](juce::Rectangle<float>& target, float w, float gap = 1.f) {
            if (next + w + 2 > visible.getRight()) return false;
            target = {next,y,w,std::min(17.f,bounds.getHeight())};
            next += w + gap; titleLeft = next;
            return true;
        };
        const auto readoutFont = theme::semiboldFont(9);
        const auto labelWidth = [&](const String& label) { return std::ceil(GlyphArrangement::getStringWidth(readoutFont,label)) + 2.f; };
        const float gainWidth = labelWidth(gainText(clip.gain.value_or(1)));
        const float panWidth = labelWidth(panText(clip.pan.value_or(0)));
        const float nameWidth = std::max(24.f, std::ceil(GlyphArrangement::getStringWidth(readoutFont, text(clip.name)))) + 3.f;
        const float gainThreshold = 4.6f + 23.1f + nameWidth + 19.5f + .5f + gainWidth + 1.f;
        const float fxThreshold = gainThreshold + ((!midi || clip.fxJSON) ? 27.f : 0.f);
        const float phaseThreshold = fxThreshold + (!midi ? 20.5f : 0.f);
        const float panThreshold = phaseThreshold + (!midi ? 19.5f + .5f + panWidth + 1.f : 0.f);
        if (width >= gainThreshold) {
            append(gainRect,19.5f,.5f);
            append(gainLabel,gainWidth);
        } else if (width >= 2.6f + 23.1f + nameWidth + 19.5f + 1.f) {
            append(gainRect,19.5f);
        }
        if (!append(muteRect,22.1f)) return;
        if (width < fxThreshold) return;
        if ((!midi || clip.fxJSON) && !append(fxRect,26)) return;
        if (!midi) {
            if (width < phaseThreshold || !append(phaseRect,19.5f)) return;
            if (width < panThreshold || !append(panRect,19.5f,.5f)) return;
            append(panLabel,labelWidth(panText(clip.pan.value_or(0))));
        }
    }
    int resizeSide(Point<float> point) const {
        if (point.y < item.getY() || point.y >= item.getBottom()) return 0;
        const float tolerance = std::min(10.f, std::max(2.f, item.getWidth() / 2));
        const float left = std::abs(point.x - item.getX()), right = std::abs(point.x - item.getRight());
        return std::min(left, right) <= tolerance ? (left <= right ? -1 : 1) : 0;
    }
    static const MouseCursor &fadeCursor(bool left) {
        static const auto make = [](bool in) {
            Image image(Image::ARGB, 32, 32, true); Graphics g(image);
            Path curve; curve.startNewSubPath(6, in ? 26.f : 6.f);
            curve.cubicTo(14, in ? 26.f : 6.f, 16, in ? 6.f : 26.f, 26, in ? 6.f : 26.f);
            g.setColour(Colours::black); g.strokePath(curve, PathStrokeType(6, PathStrokeType::curved, PathStrokeType::rounded));
            g.setColour(Colours::white); g.strokePath(curve, PathStrokeType(3, PathStrokeType::curved, PathStrokeType::rounded));
            return MouseCursor(image, 8, 8, 2.f);
        };
        static const auto fadeIn = make(true), fadeOut = make(false);
        return left ? fadeIn : fadeOut;
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
        const auto left = fadeRect(clip,true), right = fadeRect(clip,false);
        const bool in = !left.isEmpty() && left.expanded(2).getIntersection(item.withTrimmedTop(17)).contains(p);
        const bool out = !right.isEmpty() && right.expanded(2).getIntersection(item.withTrimmedTop(17)).contains(p);
        if (in && out) return std::abs(p.x-left.getCentreX()) <= std::abs(p.x-right.getCentreX()) ? fadeIn : fadeOut;
        if (in) return fadeIn;
        if (out) return fadeOut;
        return none;
    }
    void draw(Graphics &g, const jaras::AudioClip &clip) const {
        g.saveState(); g.reduceClipRegion(visible.getSmallestIntegerContainer());
        auto button = [&](juce::Rectangle<float> r, String caption, bool active, bool bypass = false) {
            if (r.isEmpty()) return;
            g.setColour(bypass ? Colour(0xffff453a) : Colours::white.withAlpha(.10f)); g.fillRect(r);
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
