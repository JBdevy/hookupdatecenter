#pragma once
#include "NativePluginShortcuts.h"
namespace catlive {
// The plug-in keeps its own HWND and pixel dimensions. The enclosing HWND clips
// it to the FX manager; scrolling never stretches or rasterizes the editor.
class ExternalEffectEditor final : public Component, private AsyncUpdater, private ScrollBar::Listener {
    std::shared_ptr<native::vst3::Processor> processor;
    HWNDComponent host;
    HWND canvas{};
    std::unique_ptr<native::vst3::Editor> editor;
    std::unique_ptr<NativePluginShortcuts> shortcuts;
    ScrollBar horizontal{false}, vertical{true};
    std::function<bool(const KeyPress &)> key;
    std::function<void(bool)> keyState;
    std::function<void(int,int)> preferredSizeChanged;
    Point<int> lastPreferredSize;
    String failure;
    int width = 740, height = 560;
    bool attempted = false;
    void handleAsyncUpdate() override {
        if (!isShowing() || !getPeer()) return;
        if (attempted) { reportPreferredSize(); return; }
        attempted = true;
        try {
            auto parent = static_cast<HWND>(getPeer()->getNativeHandle());
            auto hwnd = CreateWindowExW(0,L"STATIC",L"CatLive FX editor",WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS,
                                       0,0,1,1,parent,nullptr,GetModuleHandleW(nullptr),nullptr);
            if (!hwnd) throw std::runtime_error("Could not create the plug-in editor host.");
            host.setHWND(hwnd);
            canvas = CreateWindowExW(0,L"STATIC",L"CatLive plug-in",WS_CHILD|WS_VISIBLE|WS_CLIPCHILDREN,
                                     0,0,width,height,hwnd,nullptr,GetModuleHandleW(nullptr),nullptr);
            if (!canvas) throw std::runtime_error("Could not create the plug-in editor view.");
            shortcuts = std::make_unique<NativePluginShortcuts>(canvas,key,keyState);
            editor = processor->openEditor(canvas,[this](int w,int h){width=w;height=h;resized();});
            width=editor->width();height=editor->height();resized();
            reportPreferredSize();
        } catch (const std::exception &e) {
            failure=String::fromUTF8(e.what());shortcuts.reset();editor.reset();host.setHWND(nullptr);canvas=nullptr;repaint();
        }
    }
    void reportPreferredSize() {
        if (!editor || !preferredSizeChanged || getWidth() <= 0) return;
        const auto *peer=getPeer();
        const auto pixels=peer->getAreaCoveredBy(*this).toFloat()*peer->getPlatformScaleFactor();
        const double scale=pixels.getWidth()/getWidth();
        if(scale<=0)return;
        const Point<int> size((int)std::ceil(width/scale),(int)std::ceil(height/scale));
        if(size==lastPreferredSize)return;
        lastPreferredSize=size;preferredSizeChanged(size.x,size.y);
    }
    void scrollBarMoved(ScrollBar *,double) override { positionEditor(); }
    void positionEditor() {
        if(canvas)SetWindowPos(canvas,nullptr,-roundToInt(horizontal.getCurrentRangeStart()),
            -roundToInt(vertical.getCurrentRangeStart()),width,height,SWP_NOACTIVATE|SWP_NOZORDER);
    }
public:
    ExternalEffectEditor(std::shared_ptr<native::vst3::Processor> plugin,
                         std::function<bool(const KeyPress &)> shortcut,std::function<void(bool)> changed,
                         std::function<void(int,int)> preferredSize = {})
        :processor(std::move(plugin)),key(std::move(shortcut)),keyState(std::move(changed)),preferredSizeChanged(std::move(preferredSize)) {
        setComponentID("embeddedExternalEditor");
        addAndMakeVisible(host);addChildComponent(horizontal);addChildComponent(vertical);
        horizontal.addListener(this);vertical.addListener(this);
    }
    ~ExternalEffectEditor() override {
        cancelPendingUpdate();shortcuts.reset();editor.reset();host.setHWND(nullptr);
    }
    bool uses(const std::shared_ptr<native::vst3::Processor> &plugin)const{return processor==plugin;}
    void parentHierarchyChanged() override {triggerAsyncUpdate();}
    void visibilityChanged() override {triggerAsyncUpdate();}
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        if(failure.isNotEmpty()){g.setColour(theme::secondary);g.setFont(theme::font(12));g.drawFittedText(failure,getLocalBounds().reduced(20),Justification::centred,4);}
    }
    void resized() override {
        auto area=getLocalBounds();
        auto *peer=getPeer();
        const auto pixels=peer?peer->getAreaCoveredBy(*this).toFloat()*peer->getPlatformScaleFactor():area.toFloat();
        const double scale=getWidth()>0?pixels.getWidth()/getWidth():1.;
        bool h=width>pixels.getWidth(),v=height>pixels.getHeight();
        if(v&&width>pixels.getWidth()-12*scale)h=true;
        if(h&&height>pixels.getHeight()-12*scale)v=true;
        horizontal.setVisible(h);vertical.setVisible(v);
        if(h)horizontal.setBounds(area.removeFromBottom(12).withTrimmedRight(v?12:0));
        if(v)vertical.setBounds(area.removeFromRight(12));
        host.setBounds(area);host.updateHWNDBounds();
        RECT client{};if(host.getHWND())GetClientRect(static_cast<HWND>(host.getHWND()),&client);
        horizontal.setRangeLimits(0,width,dontSendNotification);vertical.setRangeLimits(0,height,dontSendNotification);
        horizontal.setCurrentRange(h?horizontal.getCurrentRangeStart():0,std::max(1L,client.right),dontSendNotification);
        vertical.setCurrentRange(v?vertical.getCurrentRangeStart():0,std::max(1L,client.bottom),dontSendNotification);
        positionEditor();triggerAsyncUpdate();
    }
};
}
