#include "ProjectionSelection.h"
#include "Projection.h"
#include <shobjidl.h>
#include "../../Core/Tracks/ItemFade.hpp"
namespace catlive {
namespace {
void markProjectionFullscreen(Component &component, bool fullscreen) {
    const auto *peer = component.getPeer();
    if (!peer) return;
    const auto hwnd = static_cast<HWND>(peer->getNativeHandle());
    if (fullscreen) {
        // The Shell does not treat an owned tool window as an independent
        // fullscreen presentation. Restore workspace ownership on exit.
        SetWindowLongPtrW(hwnd, GWLP_HWNDPARENT, 0);
        RemovePropW(hwnd, L"NonRudeHWND");
    }
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ITaskbarList2 *taskbar = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&taskbar)))) {
        if (SUCCEEDED(taskbar->HrInit())) taskbar->MarkFullscreenWindow(hwnd, fullscreen ? TRUE : FALSE);
        taskbar->Release();
    }
    if (SUCCEEDED(initialized)) CoUninitialize();
}
}

void Projection::refreshVideoAppearance() {
    if(videoSurface)InvalidateRect(videoSurface,nullptr,FALSE);
    repaint();
}
Projection::Projection(Session &value, Appearance &settings, String target, StageState *state)
    : session(value), appearance(settings), role(std::move(target)), stage(state),
      profile(role == "teleprompt2" ? 2 : 1) {
    addAndMakeVisible(textView);
    addAndMakeVisible(status);

    addAndMakeVisible(fontUp);
    addAndMakeVisible(fontDown);
    textView.setReadOnly(true);
    textView.setMultiLine(true);
    textView.setScrollbarsShown(true);
    textView.setFont(theme::font(textSize, true));
    textView.setColour(TextEditor::backgroundColourId, Colours::black);
    textView.setColour(TextEditor::outlineColourId, Colours::transparentBlack);
    setWantsKeyboardFocus(true);
    textView.addMouseListener(this, true);
    fontUp.setVisible(role != "video" && !stage);
    fontDown.setVisible(role != "video" && !stage);
    status.setVisible(!stage && role != "video");
    textView.setVisible(!stage);
    fontUp.onClick = [this] {
        textSize = jlimit(14.f, 120.f, textSize + 4);
        textView.setFont(theme::font(textSize, true));
    };
    fontDown.onClick = [this] {
        textSize = jlimit(14.f, 120.f, textSize - 4);
        textView.setFont(theme::font(textSize, true));
    };
    startTimerHz(role == "video" ? 60 : 20);
}
Projection::~Projection() {
    stopTimer();
    if(videoSurface && IsWindow(videoSurface))DestroyWindow(videoSurface);
}
void Projection::resized() {
    auto content = mediaBounds();
    updateVideoSurface();
    textView.setBounds(content.reduced(22));
    status.setBounds(12, 3, getWidth() - 180, 25);
    fontUp.setBounds(getWidth() - 110, 3, 45, 26);
    fontDown.setBounds(getWidth() - 58, 3, 45, 26);
}
void Projection::paint(Graphics &g) {
    g.fillAll(Colours::black);
    if (image.isValid()) {
        g.setOpacity(mediaOpacity);
        const auto bounds = mediaBounds();
        const bool stretch = stage && flag(stage->settings(profile), "mediaStretch");
        g.drawImageWithin(image, bounds.getX(), bounds.getY(), bounds.getWidth(),
                          bounds.getHeight(),
                          stretch ? RectanglePlacement::stretchToFit : RectanglePlacement::centred);
    }
}
void Projection::updateVideoFrame(double source,bool playing,double rate) {
    if(videoFile==File())return;
    updateVideoSurface();
    const auto bounds=mediaBounds();
    vshook_video::DecodedFrame frame;
    const auto path=utf8(videoFile.getFullPathName());
    if(!videoDecoder.frameAt(path,clipID,source,playing,rate,
                             std::max(1,bounds.getWidth()),std::max(1,bounds.getHeight()),frame) ||
       !frame.pixels || frame.sequence==videoSequence)return;
    if(frame.width<=0||frame.height<=0||frame.stride<frame.width*4)return;
    videoSequence=frame.sequence;
    videoFrame=std::move(frame);
    if(videoSurface)InvalidateRect(videoSurface,nullptr,FALSE);
}
LRESULT CALLBACK Projection::videoSurfaceProc(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    auto *self=reinterpret_cast<Projection*>(GetWindowLongPtrW(window,GWLP_USERDATA));
    if(message==WM_NCCREATE) {
        auto *create=reinterpret_cast<CREATESTRUCTW*>(lp);
        SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        return TRUE;
    }
    if(message==WM_ERASEBKGND)return 1;
    if(message==WM_LBUTTONDBLCLK && self) {
        self->toggleFullScreen();return 0;
    }
    if(message==WM_RBUTTONDBLCLK && self && self->role=="video") {
        if(auto *parent=self->findParentComponentOfClass<DocumentWindow>())
            parent->closeButtonPressed();
        return 0;
    }
    if(message==WM_PAINT) {
        PAINTSTRUCT paint{};
        if(HDC dc=BeginPaint(window,&paint)) {
            if(self)self->paintVideoSurface(dc);
            EndPaint(window,&paint);
        }
        return 0;
    }
    return DefWindowProcW(window,message,wp,lp);
}
void Projection::paintVideoSurface(HDC dc) {
    RECT area{};GetClientRect(videoSurface,&area);
    const int width=area.right-area.left,height=area.bottom-area.top;
    if(!videoFrame.pixels||width<=0||height<=0) {
        FillRect(dc,&area,static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));return;
    }
    const bool stretch=role=="video"?(bool)appearance.value("jaras.video.stretch", false):stage&&flag(stage->settings(profile),"mediaStretch");
    int x=0,y=0,w=width,h=height;
    if(!stretch) {
        const double fit=std::min(double(width)/videoFrame.width,double(height)/videoFrame.height);
        w=std::max(1,int(std::lround(videoFrame.width*fit)));
        h=std::max(1,int(std::lround(videoFrame.height*fit)));
        x=(width-w)/2;y=(height-h)/2;
        if(y>0) {RECT top{0,0,width,y},bottom{0,y+h,width,height};
            FillRect(dc,&top,static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
            FillRect(dc,&bottom,static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));}
        if(x>0) {RECT left{0,y,x,y+h},right{x+w,y,width,y+h};
            FillRect(dc,&left,static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
            FillRect(dc,&right,static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));}
    }
    BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth=videoFrame.width;
    info.bmiHeader.biHeight=-videoFrame.height;
    info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;
    info.bmiHeader.biCompression=BI_RGB;
    const std::uint8_t *pixels=videoFrame.pixels;
    if(role=="video" && (bool)appearance.value("jaras.video.grayscale", false)) {
        const size_t bytes=(size_t)videoFrame.stride*(size_t)videoFrame.height;
        if(grayscaleSequence!=videoFrame.sequence || grayscalePixels.size()!=bytes) {
            grayscalePixels.resize(bytes);
            for(int row=0;row<videoFrame.height;++row) {
                const auto *source=videoFrame.pixels+(size_t)row*videoFrame.stride;
                auto *target=grayscalePixels.data()+(size_t)row*videoFrame.stride;
                for(int column=0;column<videoFrame.width;++column) {
                    const auto *rgb=source+column*4;
                    auto *gray=target+column*4;
                    const auto brightness=(std::uint8_t)((29u*rgb[0]+150u*rgb[1]+77u*rgb[2]+128u)>>8);
                    gray[0]=gray[1]=gray[2]=brightness;gray[3]=rgb[3];
                }
            }
            grayscaleSequence=videoFrame.sequence;
        }
        pixels=grayscalePixels.data();
    }
    const int mode=SetStretchBltMode(dc,COLORONCOLOR);
    StretchDIBits(dc,x,y,w,h,0,0,videoFrame.width,videoFrame.height,
                  pixels,&info,DIB_RGB_COLORS,SRCCOPY);
    if(mode)SetStretchBltMode(dc,mode);
    if(mediaOpacity<.999f) {
        auto mask=CreateCompatibleDC(dc);
        auto bitmap=CreateCompatibleBitmap(dc,1,1);
        auto previous=SelectObject(mask,bitmap);
        RECT pixel{0,0,1,1};FillRect(mask,&pixel,static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
        BLENDFUNCTION blend{AC_SRC_OVER,0,static_cast<BYTE>(std::lround(255*(1-mediaOpacity))),0};
        AlphaBlend(dc,x,y,w,h,mask,0,0,1,1,blend);
        SelectObject(mask,previous);DeleteObject(bitmap);DeleteDC(mask);
    }
}
void Projection::updateVideoSurface() {
    if(videoFile==File()) {
        if(videoSurface)ShowWindow(videoSurface,SW_HIDE);
        return;
    }
    auto *peer=getPeer();if(!peer)return;
    HWND parent=static_cast<HWND>(peer->getNativeHandle());if(!parent)return;
    if(videoSurface && (!IsWindow(videoSurface) || GetParent(videoSurface)!=parent)) {
        if(IsWindow(videoSurface))DestroyWindow(videoSurface);
        videoSurface=nullptr;
    }
    if(!videoSurface) {
        static const bool registered=[] {
            WNDCLASSW type{};type.lpfnWndProc=&Projection::videoSurfaceProc;
            type.style=CS_DBLCLKS;
            type.hInstance=GetModuleHandleW(nullptr);
            type.lpszClassName=L"CatLiveNativeVideoSurface";
            type.hCursor=LoadCursorW(nullptr,MAKEINTRESOURCEW(32512));
            return RegisterClassW(&type)!=0 || GetLastError()==ERROR_CLASS_ALREADY_EXISTS;
        }();
        if(!registered)return;
        videoSurface=CreateWindowExW(0,L"CatLiveNativeVideoSurface",L"",WS_CHILD|WS_VISIBLE,
                                    0,0,1,1,parent,nullptr,GetModuleHandleW(nullptr),this);
    }
    if(!videoSurface)return;
    auto bounds=mediaBounds();
    POINT point{bounds.getX(),bounds.getY()};
    auto screen=localPointToGlobal(juce::Point<int>(point.x,point.y));
    point={static_cast<LONG>(std::lround(screen.x)),static_cast<LONG>(std::lround(screen.y))};
    ScreenToClient(parent,&point);
    RECT current{};GetWindowRect(videoSurface,&current);
    POINT topLeft{current.left,current.top};ScreenToClient(parent,&topLeft);
    if(!IsWindowVisible(videoSurface)||topLeft.x!=point.x||topLeft.y!=point.y||
       current.right-current.left!=bounds.getWidth()||current.bottom-current.top!=bounds.getHeight())
        SetWindowPos(videoSurface,HWND_TOP,point.x,point.y,bounds.getWidth(),bounds.getHeight(),
                     SWP_NOACTIVATE|SWP_SHOWWINDOW);
}
juce::Rectangle<int> Projection::mediaBounds() const {
    if (role == "video") return getLocalBounds();
    if (!stage)
        return getLocalBounds().withTrimmedTop(34);
    return getLocalBounds().reduced(8).withTrimmedTop(
        flag(stage->settings(profile), "hideTransport") ? 0 : 108);
}
void Projection::paintOverChildren(Graphics &g) {
    if (stage)
        paintStage(g);
}
void Projection::toggleFullScreen() {
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        if (presenting) {
            presenting = false;
            markProjectionFullscreen(*window, false);
            window->setAlwaysOnTop(windowedOnTop);
            window->setTitleBarHeight(windowedTitleHeight);
            window->setBounds(windowedBounds);
            if (windowedMaximised) window->setFullScreen(true);
        } else {
            const auto *display = Desktop::getInstance().getDisplays().getDisplayForRect(window->getBounds());
            if (!display) return;
            const auto screen = display->totalArea;
            windowedBounds = window->getBounds();
            windowedTitleHeight = window->getTitleBarHeight();
            windowedOnTop = window->isAlwaysOnTop();
            windowedMaximised = window->isFullScreen();
            if (windowedMaximised) window->setFullScreen(false);
            presenting = true;
            // Preserve the native peer and decoded video surface across the
            // transition. Changing resize/shadow/button flags recreates the HWND.
            window->setTitleBarHeight(0);
            window->setAlwaysOnTop(false);
            window->setBounds(screen);
        }
        for (auto *button : {window->getCloseButton(), window->getMinimiseButton(), window->getMaximiseButton()})
            if (button) button->setVisible(!presenting);
        if (auto *peer = window->getPeer()) peer->performAnyPendingRepaintsNow();
        window->toFront(true);
        grabKeyboardFocus();
        if (presenting) markProjectionFullscreen(*window, true);
    }
}
bool Projection::keyPressed(const KeyPress &key) {
    if (key == KeyPress::escapeKey && presenting) {
        toggleFullScreen(); return true;
    }
    return false;
}
void Projection::mouseDown(const MouseEvent &e) {
    grabKeyboardFocus();
    if (!e.mods.isPopupMenu()) return;
    // Projection windows have no context menu on macOS. Their controls live
    // on the Video/TP buttons in the workspace.
}
void Projection::mouseDoubleClick(const MouseEvent &e) {
    if (!e.mods.isPopupMenu()) toggleFullScreen();
    else if(role=="video")if(auto *window=findParentComponentOfClass<DocumentWindow>())window->closeButtonPressed();
}
void Projection::timerCallback() {
    if (stage) {
        resized();
        repaint();
    }
    const jaras::AudioClip *clip = nullptr;
    const auto transport = session.presentationTransport();
    const auto at = transport.playing || transport.paused ? transport.position : transport.editPosition;
    if (auto *song = session.song()) clip = firstProjectionItem(*song,at,role);
    if (!clip) {
        if(videoFrame.pixels||videoFile.existsAsFile()) {
            videoFrame={};videoFile={};videoSequence=0;grayscaleSequence=0;grayscalePixels.clear();videoDecoder.reset();updateVideoSurface();repaint();
        }
        textView.setVisible(false);
        if (image.isValid()) {
            image = {};
            repaint();
        }
        clipID.clear();
        lyrics.clear();
        status.setText(role == "video" ? "Video"
                                       : String::fromUTF8("Teleprompter · nenhum item neste ponto"),
                       dontSendNotification);
        return;
    }
    const auto opacity = (float)jaras::itemFadeGain(*clip, at);
    if (opacity != mediaOpacity) { mediaOpacity = opacity; if(videoSurface)InvalidateRect(videoSurface,nullptr,FALSE);repaint(); }
    if (clip->id != clipID || (clip->text && text(*clip->text) != lyrics)) {
        clipID = clip->id;
        itemStart = clip->startTime;
        itemDuration = clip->duration;
        loaded = false;
        videoFrame={};videoFile={};videoSequence=0;grayscaleSequence=0;grayscalePixels.clear();videoDecoder.reset();updateVideoSurface();
        image = {};
        if (clip->text) {
            lyrics = text(*clip->text);
            textView.setText(lyrics, false);
            textView.moveCaretToTop(false);
            textView.setVisible(!stage);
        } else if (clip->audioFile) {
            lyrics.clear();
            textView.setVisible(false);
            try {
                auto file =
                    ProjectCodec::resolveMedia(session.mediaDirectory, clip->audioFile->path);
                if (file.hasFileExtension("png;jpg;jpeg;bmp;gif")) {
                    image = ImageFileFormat::loadFrom(file);
                    if (!image.isValid())
                        throw std::runtime_error("Unable to decode image.");
                } else {
                    videoFile=file;
                    loaded = true;
                    updateVideoSurface();
                }
            } catch (const std::exception &e) {
                status.setText(String::fromUTF8(e.what()), dontSendNotification);
            }
        }
        repaint();
    }
    itemStart = clip->startTime;
    itemDuration = clip->duration;
    if (loaded) {
        double source = clip->sourceOffset + (at - clip->startTime) * clip->playbackRate;
        updateVideoFrame(source,transport.playing,clip->playbackRate);
    }
    status.setText(text(clip->name) + "  " + clockText(at, true), dontSendNotification);
}

} // namespace catlive
#include "ProjectionStage.h"
