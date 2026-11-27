#pragma once
#include "Common.h"
#include "MeterRepaint.h"
#include "../../Core/Audio/MeterState.hpp"
namespace catlive::meterDisplay {
using PeakHold = audio::PeakHold;
inline constexpr int vuColumnWidth = 68, vuStripHeight = 38;
enum class VUStyle { amber = 1, purple = 2 };
class ClassicVU final : public Component {
    static constexpr std::array<int, 11> marks{-20,-10,-7,-5,-3,-2,-1,0,1,2,3};
    static Point<float> point(float value, float radius) {
        const auto amplitude = std::pow(10.f, value / 20.f);
        const auto fraction = jlimit(0.f, 1.f, (amplitude - .1f) / (std::pow(10.f, .15f) - .1f));
        const auto angle = degreesToRadians(-55.f + 110.f * fraction);
        return {48.f + radius * std::sin(angle), 41.f - radius * std::cos(angle)};
    }
    Image face;
    static constexpr float dialWidth = 96.f, dialHeight = 45.f;
    VUStyle style = VUStyle::purple;
    audio::AnalogVU pointer;
    double lastRefresh = 0;
    float level = -20;
    void buildFace(int pixelWidth, int pixelHeight) {
        face = Image(Image::ARGB, pixelWidth, pixelHeight, true);
        Graphics g(face);
        g.addTransform(AffineTransform::scale(pixelWidth / dialWidth, pixelHeight / dialHeight));
        const juce::Rectangle<float> box{.5f,.5f,95,44};
        const bool amber = style == VUStyle::amber;
        g.setGradientFill(ColourGradient(Colour(amber ? 0xffffde87 : 0xff512d72),0,0,
                                         Colour(amber ? 0xffe3a644 : 0xff241632),0,45,false));
        g.fillRoundedRectangle(box,5);
        g.setColour(Colour(amber ? 0xff9b6934 : 0xff80659a)); g.drawRoundedRectangle(box,5,1);
        g.setFont(theme::semiboldFont(8.5f));
        for (const auto mark : marks) {
            g.setColour(amber ? Colour(mark > 0 ? 0xffa52519 : 0xff332318) : theme::green);
            const auto a=point(float(mark),26), b=point(float(mark),31);
            g.drawLine(Line<float>(a,b), mark == 0 ? 1.2f : .75f);
            if (mark == -20 || mark == -10 || mark == -5 || mark == 0 || mark == 3) {
                const auto anchor=point(float(mark),38);
                g.drawText((mark>0 ? "+" : "") + String(mark), juce::Rectangle<float>(18,9).withCentre(anchor), Justification::centred);
            }
        }
        g.setColour(Colour(amber ? 0xff332318 : 0xffd0b3eb));
        g.setFont(theme::semiboldFont(9));
        g.drawText("VU", 39, 24, 18, 10, Justification::centred);
    }
public:
    ClassicVU() {
        setInterceptsMouseClicks(false,false);
        setComponentID("classicVUMeter");
        setTitle("VU Meter");
    }
    void setStyle(VUStyle next) {
        if (style == next) return;
        style = next;
        face = {};
        repaint();
    }
    void refresh(float input) {
        if (!isShowing()) return;
        const auto now=Time::getMillisecondCounterHiRes() / 1000.;
        const auto elapsed=lastRefresh == 0 ? 1. / 30 : now - lastRefresh;
        lastRefresh=now;
        const auto next=pointer.update(input, elapsed);
        if (next != level) { level=next;repaint(); }
    }
    void paint(Graphics &g) override {
        if (getLocalBounds().isEmpty()) return;
        const auto scale = std::min(getWidth() / dialWidth, getHeight() / dialHeight);
        const auto dpi = g.getInternalContext().getPhysicalPixelScaleFactor();
        const auto pixelWidth = std::max(1, roundToInt(dialWidth * scale * dpi));
        const auto pixelHeight = std::max(1, roundToInt(dialHeight * scale * dpi));
        // Cache the dial at its displayed pixel size. Only the needle changes on meter ticks.
        if (!face.isValid() || face.getWidth() != pixelWidth || face.getHeight() != pixelHeight)
            buildFace(pixelWidth, pixelHeight);
        const auto dial = getLocalBounds().toFloat().withSizeKeepingCentre(dialWidth * scale, dialHeight * scale);
        g.drawImage(face, dial);
        g.addTransform(AffineTransform::scale(scale).translated(dial.getX(), dial.getY()));
        g.setColour(Colour(style == VUStyle::amber ? 0xff261a12 : 0xfff2e9ff));
        g.drawLine(Line<float>({48,41},point(level,32)),1.15f);
        g.fillEllipse(46,39,4,4);
    }
};
inline bool visibleInViewport(const Component& component) {
    if (!component.isShowing()) return false;
    auto bounds = component.getLocalBounds();
    for (auto* child = &component; auto* parent = child->getParentComponent(); child = parent) {
        bounds = parent->getLocalArea(child, bounds).getIntersection(parent->getLocalBounds());
        if (bounds.isEmpty()) return false;
    }
    return !bounds.isEmpty();
}
class PeakReadout final : public Component {
    std::function<float()> read;
    std::function<void()> clear;
    std::function<Colour()> colour;
    float shown=-1;
    static float displayDB(float amplitude) {
        const auto rounded = std::round(20.f * std::log10(amplitude) * 100.f) / 100.f;
        if (amplitude == 1.f) return 0.f;
        return amplitude < 1.f ? std::min(-.01f, rounded) : std::max(.01f, rounded);
    }
public:
    // The owning mixer polls visible meters together. One timer per peak
    // multiplied the idle workload by every track, including offscreen rows.
    void refresh(){
        if (!visibleInViewport(*this)) return;
        const auto amplitude=read();
        const auto value=amplitude>0 && std::isfinite(amplitude)
            ? displayDB(amplitude) : -1000.f;
        if(value!=shown){shown=value;repaint();}
    }
    PeakReadout(std::function<float()> get,std::function<void()> reset,std::function<Colour()> foreground=[] {return Colours::white;})
        :read(std::move(get)),clear(std::move(reset)),colour(std::move(foreground)){
        setComponentID("peakReadout");setTitle("Reset peak");
    }
    bool hitTest(int x, int y) override {
        const auto amplitude=read();
        if(amplitude<=0)return false;
        const auto db=displayDB(amplitude);
        const auto value=(db>=0?"+":"")+String(db,2);
        const auto field=getLocalBounds().toFloat().withSizeKeepingCentre(
            std::min((float)getWidth(),GlyphArrangement::getStringWidth(theme::semiboldFont(8),value)+4.f),
            std::min(12.f,(float)getHeight()));
        return field.contains((float)x,(float)y);
    }
    void paint(Graphics &g)override{
        const auto amplitude=read();if(amplitude<=0)return;
        const auto db=displayDB(amplitude);
        const auto text=(db>=0?"+":"")+String(db,2);
        const auto font=theme::semiboldFont(8);g.setFont(font);
        const auto field=getLocalBounds().toFloat().withSizeKeepingCentre(std::min((float)getWidth(),GlyphArrangement::getStringWidth(font,text)+4.f),std::min(12.f,(float)getHeight()));
        if(db>0){g.setColour(Colours::black);g.fillRoundedRectangle(field,2);}
        g.setColour(db>0?Colours::red:colour());
        g.drawText(text,field,Justification::centred,false);
    }
    void mouseDown(const MouseEvent &e)override{if(e.mods.isLeftButtonDown()){clear();repaint();}}
};
// Match TrackMeterLevel: immediate attack, no hold, 40 dB/s fall.
// The independent numeric peak is retained by PeakHold.
inline float envelope(float previous, float input, double elapsed) noexcept {
    input = std::isfinite(input) ? std::max(0.f, input) : 0.f;
    const auto level = std::max(input, previous * (float)std::pow(10., -40. * std::max(0., elapsed) / 20.));
    return level < .001f ? 0.f : level;
}
inline constexpr float railThickness = 14.f;
inline constexpr float yellowTransitionStart = fractionForDB(-20.f), yellowTransitionEnd = fractionForDB(-17.f);
inline const Colour signalGreen{0xff239653}, railBorder{0xff2d3236}, linkedRail{0xff8158a7};
inline void rail(Graphics &g, juce::Rectangle<float> bounds, const std::array<float, 2>& levels,
                 bool vertical, bool fixedUpperSpan = false, bool linked = false) {
    if (bounds.isEmpty()) return;
    Path outline;
    const float radius = std::min(3.f, std::min(bounds.getWidth(), bounds.getHeight()) / 2);
    outline.addRoundedRectangle(bounds, radius);
    g.setColour(linked ? linkedRail : theme::faderRail);
    g.fillPath(outline);
    Graphics::ScopedSaveState saved(g);
    g.reduceClipRegion(outline);
    const auto start = vertical ? Point<float>(bounds.getCentreX(), bounds.getBottom())
                                : Point<float>(bounds.getX(), bounds.getCentreY());
    const auto end = vertical ? Point<float>(bounds.getCentreX(), bounds.getY())
                              : Point<float>(bounds.getRight(), bounds.getCentreY());
    const Colour red(0xfff44336);
    ColourGradient gradient(signalGreen, start, theme::yellow, end, false);
    const auto dbPosition = [&](float db) {
        return fixedUpperSpan ? (float)horizontalTrackFraction(db, bounds.getWidth()) : fractionForDB(db);
    };
    gradient.addColour(dbPosition(-20.f), signalGreen);
    gradient.addColour(dbPosition(-17.f), theme::yellow);
    for (int channel = 0; channel < 2; ++channel) {
        const auto amplitude = levels[(size_t)channel];
        const auto amount = amplitude > 0.f && std::isfinite(amplitude) ? dbPosition(20.f * std::log10(amplitude)) : 0.f;
        const auto gap = std::min(1.f, vertical ? bounds.getWidth() : bounds.getHeight());
        const auto thickness = ((vertical ? bounds.getWidth() : bounds.getHeight()) - gap) / 2;
        const auto fill = vertical
            ? bounds.withX(bounds.getX() + channel * (thickness + gap)).withWidth(thickness)
                .withTop(bounds.getBottom() - bounds.getHeight() * amount)
            : bounds.withY(bounds.getY() + channel * (thickness + gap)).withHeight(thickness)
                .withWidth(bounds.getWidth() * amount);
        g.setGradientFill(gradient);
        g.fillRect(fill);
        if (levels[(size_t)channel] > 1.f) {
            g.setColour(red);
            const auto threshold = dbPosition(0.f);
            g.fillRect(vertical ? fill.withBottom(bounds.getBottom() - bounds.getHeight() * threshold)
                                : fill.withLeft(bounds.getX() + bounds.getWidth() * threshold));
        }
    }
    g.setColour(railBorder);
    g.drawRoundedRectangle(bounds.reduced(.375f), std::max(0.f, radius - .375f), .75f);
}
inline void gainReduction(Graphics &g, juce::Rectangle<float> bounds, float db) {
    if (db < 0.f || bounds.isEmpty()) return;
    g.setColour(theme::faderRail);
    g.fillRoundedRectangle(bounds, 1.f);
    if (db <= 0.f) return;
    g.setColour(Colour(0xfff44336));
    const float fraction = std::min(1.f, db / 24.f);
    const auto fill = bounds.getHeight() > bounds.getWidth() ? bounds.withHeight(bounds.getHeight() * fraction)
        : bounds.withLeft(bounds.getRight() - bounds.getWidth() * fraction);
    g.fillRoundedRectangle(fill, 1.f);
}
inline void faderThumb(Graphics &g, Point<float> centre, bool vertical) {
    const float width = vertical ? 18.f : 11.f;
    const float height = vertical ? 11.f : 18.f;
    const juce::Rectangle<float> face(centre.x - width / 2, centre.y - height / 2, width, height);
    constexpr float outlineWidth = .85f;
    constexpr Point<float> points[]{
        {-.35f, -.5f}, {.35f, -.5f}, {.5f, -.39f}, {.29f, 0.f}, {.5f, .39f},
        {.35f, .5f}, {-.35f, .5f}, {-.5f, .39f}, {-.29f, 0.f}, {-.5f, -.39f}
    };
    const auto position = [&](Point<float> point) {
        return Point<float>{centre.x + (vertical ? -point.y : point.x) * (width - outlineWidth),
                            centre.y + (vertical ? point.x : point.y) * (height - outlineWidth)};
    };
    Path shape;
    shape.startNewSubPath(position(points[0]));
    for (size_t i = 1; i < std::size(points); ++i) shape.lineTo(position(points[i]));
    shape.closeSubPath();
    g.setGradientFill(ColourGradient(Colour(0xff513553), centre.x, face.getY(),
                                    Colour(0xff402346), centre.x, face.getBottom(), false));
    g.fillPath(shape);
    g.setColour(Colour(0xff9565a0));
    g.strokePath(shape, PathStrokeType(outlineWidth, PathStrokeType::curved));
    g.setColour(Colour(0xfffff9ff));
    g.fillRect(face.withSizeKeepingCentre(vertical ? 9.f : 1.5f, vertical ? 1.5f : 9.f));
}
inline void compactRail(Graphics &g, juce::Rectangle<float> bounds, const std::array<float, 2>& levels) {
    rail(g, bounds.withSizeKeepingCentre(std::min(8.f, bounds.getWidth()), std::min(20.f, bounds.getHeight())),
         levels, true);
}
inline void bar(Graphics &g, juce::Rectangle<float> bounds, float amplitude) {
    if (bounds.isEmpty()) return;
    // Give both narrow channels equal physical widths at fractional UI/DPI scales.
    const float scale=g.getInternalContext().getPhysicalPixelScaleFactor();
    if(scale>0) bounds={std::round(bounds.getX()*scale)/scale,std::round(bounds.getY()*scale)/scale,
        std::max(1.f,std::round(bounds.getWidth()*scale))/scale,std::max(1.f,std::round(bounds.getHeight()*scale))/scale};
    g.setColour(Colours::black.withAlpha(.55f));
    g.fillRect(bounds);
    const float level = fraction(amplitude);
    if (level <= 0) return;
    ColourGradient gradient(signalGreen, bounds.getX(), bounds.getBottom(),
                            theme::yellow, bounds.getX(), bounds.getY(), false);
    gradient.addColour(yellowTransitionStart, signalGreen);
    gradient.addColour(yellowTransitionEnd, theme::yellow);
    g.setGradientFill(gradient);
    g.fillRect(bounds.withTop(bounds.getBottom() - bounds.getHeight() * level));
    if (amplitude > 1.f) {
        g.setColour(Colour(0xfff44336));
        g.fillRect(bounds.withTop(bounds.getBottom() - bounds.getHeight() * level)
                         .withBottom(bounds.getBottom() - bounds.getHeight() * fractionForDB(0.f)));
    }
}
}
