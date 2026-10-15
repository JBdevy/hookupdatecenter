#pragma once
#include "Appearance.h"
namespace catlive {
// Mac FooterPianoKeyboard: all 88 notes always fit, no computer-key mappings.
class FooterKeyboard final : public Component, private Timer, private MidiKeyboardState::Listener {
  public:
    FooterKeyboard(MidiKeyboardState &state, Appearance &appearance) : state(state), appearance(appearance) {
        for (int n=21;n<=108;++n) if (!black(n)) whites.push_back(n);
        state.addListener(this); startTimerHz(30); setWantsKeyboardFocus(false);
    }
    ~FooterKeyboard() { release(); state.removeListener(this); }
    void visibilityChanged() override { if (!isShowing()) release(); }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        for (bool dark : {false,true}) for(int n=21;n<=108;++n) if(black(n)==dark) {
            auto r=keyRect(n).reduced(.5f,0);
            const bool active=state.isNoteOnForChannels(0xffff,n) || held==n;
            g.setColour(active ? appearance.colour(dark?"jaras.keyboard.blackColor":"jaras.keyboard.whiteColor",0x54ff93) : dark?Colour(0xff141414):Colour(0xffe3e3e3));
            g.fillRoundedRectangle(r,2);
            if(n==21 || n%12==0) { g.setColour(Colours::black); g.setFont(theme::mediumFont(9));
                g.drawText(n==21?String("A-1"):"C"+String(n/12-2), r.withTop(r.getBottom()-21), Justification::centred); }
        }
    }
    void mouseDown(const MouseEvent &e) override { if(!e.mods.isPopupMenu()) press(at(e.position)); }
    void mouseDrag(const MouseEvent &e) override { if(!e.mods.isPopupMenu()) press(at(e.position)); }
    void mouseUp(const MouseEvent &) override { release(); }
    juce::Rectangle<float> keyRect(int n) const {
        const auto bounds=getLocalBounds().toFloat().reduced(6,4);
        const float width=bounds.getWidth()/(float)whites.size();
        auto i=std::lower_bound(whites.begin(),whites.end(),n)-whites.begin();
        return black(n)?juce::Rectangle<float>(bounds.getX()+i*width-width*.3f,bounds.getY(),width*.6f,bounds.getHeight()*.63f):juce::Rectangle<float>(bounds.getX()+i*width,bounds.getY(),width,bounds.getHeight());
    }
  private:
    MidiKeyboardState &state; Appearance &appearance; std::vector<int> whites; int held=-1; std::atomic<bool> changed{true};
    static bool black(int n) { const int v=n%12; return v==1||v==3||v==6||v==8||v==10; }
    int at(Point<float> p) const { if(!getLocalBounds().toFloat().contains(p)) return -1; for(bool dark:{true,false}) for(int n=21;n<=108;++n) if(black(n)==dark&&keyRect(n).contains(p)) return n; return -1; }
    void release() { if(held>=0) state.noteOff(1,held,0); held=-1; repaint(); }
    void press(int n) { if(n==held) return; release(); if(n>=0){held=n;state.noteOn(1,n,.8f);} repaint(); }
    void handleNoteOn(MidiKeyboardState *,int,int,float) override {changed=true;}
    void handleNoteOff(MidiKeyboardState *,int,int,float) override {changed=true;}
    void timerCallback() override {if(held>=0 && !Process::isForegroundProcess()) release(); if(changed.exchange(false)) repaint();}
};
}
