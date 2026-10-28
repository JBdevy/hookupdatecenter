#pragma once
// Native Windows controls. No JUCE drawing, widgets or mouse dispatch in here.
#include <windows.h>
#include <windowsx.h>
#include <d2d1.h>
#include <dwrite_3.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <functional>
#include <memory>
#include <string>
#include <stdexcept>
#include <vector>
namespace catlive::native {
class TransportButtons final {
    template<class T> using Ptr = Microsoft::WRL::ComPtr<T>;
  public:
    struct State {
        RECT rect{};
        float scale = 1, dimming = 0, fontSize = 9;
        bool active = false, enabled = true, visible = true, blocked = false;
        unsigned background = 0xff252525, foreground = 0xffffffff, activeBackground = 0xff6cbd4b, surface = 0xff1d1d1d;
        unsigned accent = 0;
        // `tooltip` is retained as the native accessibility/window description;
        // CatLive does not create hover tooltip windows.
        std::wstring text, icon, tooltip;
        bool operator==(const State &b) const {
            return EqualRect(&rect,&b.rect) && scale==b.scale && dimming==b.dimming && fontSize==b.fontSize && blocked==b.blocked && active==b.active && enabled==b.enabled && visible==b.visible && background==b.background && foreground==b.foreground && activeBackground==b.activeBackground && surface==b.surface && accent==b.accent && text==b.text && icon==b.icon && tooltip==b.tooltip;
        }
    };
    using Click = std::function<void(bool)>;
    explicit TransportButtons(const std::wstring &fontFile) {
        check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, factory.GetAddressOf()));
        auto stroke=D2D1::StrokeStyleProperties();
        stroke.startCap=stroke.endCap=stroke.dashCap=D2D1_CAP_STYLE_ROUND;
        stroke.lineJoin=D2D1_LINE_JOIN_ROUND;
        check(factory->CreateStrokeStyle(stroke,nullptr,0,&iconStroke));
        check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,__uuidof(IDWriteFactory3),reinterpret_cast<IUnknown**>(write.GetAddressOf())));
        Ptr<IDWriteFontFaceReference> face;
        Ptr<IDWriteFontSetBuilder> builder;
        Ptr<IDWriteFontSet> set;
        check(write->CreateFontFaceReference(fontFile.c_str(),nullptr,0,DWRITE_FONT_SIMULATIONS_NONE,&face));
        check(write->CreateFontSetBuilder(&builder)); check(builder->AddFontFaceReference(face.Get()));
        check(builder->CreateFontSet(&set)); check(write->CreateFontCollectionFromFontSet(set.Get(),&fonts));
        // A legacy font collection exposes this bundled face as "Inter
        // SemiBold". Asking for "Inter" can silently fall back to a system font.
        Ptr<IDWriteFontFamily> family;Ptr<IDWriteLocalizedStrings> names;
        check(fonts->GetFontFamily(0,&family));check(family->GetFamilyNames(&names));
        UINT32 length=0;check(names->GetStringLength(0,&length));
        std::wstring familyName(length+1,L'\0');check(names->GetString(0,familyName.data(),length+1));
        familyName.resize(length);
        check(write->CreateTextFormat(familyName.c_str(),fonts.Get(),DWRITE_FONT_WEIGHT_SEMI_BOLD,DWRITE_FONT_STYLE_NORMAL,DWRITE_FONT_STRETCH_NORMAL,9.f,L"pt-BR",&format));
        format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    ~TransportButtons() { buttons.clear(); }
    void update(size_t index, HWND parent, const State &state, Click click) {
        while(buttons.size()<=index) buttons.push_back(std::make_unique<Button>(*this));
        auto &button=*buttons[index]; button.click=std::move(click);
        if(button.window && (!IsWindow(button.window)||GetParent(button.window)!=parent)) button.destroy();
        if(!button.window && parent) {
            static const bool registered=[] { WNDCLASSW c{};c.lpfnWndProc=proc;c.hInstance=GetModuleHandleW(nullptr);c.lpszClassName=L"CatLiveTransportButton";c.hCursor=LoadCursorW(nullptr,MAKEINTRESOURCEW(32512));return RegisterClassW(&c)!=0||GetLastError()==ERROR_CLASS_ALREADY_EXISTS;}();
            if(!registered) throw std::runtime_error("Não foi possível registrar os controles do transporte.");
            button.window=CreateWindowExW(0,L"CatLiveTransportButton",L"",WS_CHILD|WS_CLIPSIBLINGS,0,0,1,1,parent,nullptr,GetModuleHandleW(nullptr),&button);
            if(!button.window) throw std::runtime_error("Não foi possível criar os controles do transporte.");
        }
        if(!button.window) return;
        if(!(button.state==state)) {
            const bool resize=!EqualRect(&button.state.rect,&state.rect);
            button.state=state;
            if(resize) {
                SetWindowPos(button.window,HWND_TOP,state.rect.left,state.rect.top,state.rect.right-state.rect.left,state.rect.bottom-state.rect.top,SWP_NOACTIVATE);
                button.target.Reset();
            }
            ShowWindow(button.window,state.visible?SW_SHOWNOACTIVATE:SW_HIDE);
            EnableWindow(button.window,state.enabled && !state.blocked);
            SetWindowTextW(button.window,state.tooltip.c_str());
            InvalidateRect(button.window,nullptr,FALSE);
        }
    }
    void hide() { for(auto &b:buttons) { if(b->window) ShowWindow(b->window,SW_HIDE);b->state.visible=false; } }
  private:
    static void check(HRESULT result) { if(FAILED(result)) throw std::runtime_error("Não foi possível inicializar o desenho nativo do transporte."); }
    struct Button {
        explicit Button(TransportButtons &v):owner(v){}
        ~Button(){destroy();}
        void destroy(){target.Reset();if(window&&IsWindow(window))DestroyWindow(window);window=nullptr;}
        TransportButtons &owner; HWND window=nullptr; State state; Click click;
        bool pressed=false,hover=false; Ptr<ID2D1HwndRenderTarget> target;
    };
    Ptr<ID2D1Factory> factory;
    Ptr<IDWriteFactory3> write;
    Ptr<IDWriteFontCollection1> fonts;
    Ptr<IDWriteTextFormat> format;
    Ptr<ID2D1StrokeStyle> iconStroke;
    std::vector<std::unique_ptr<Button>> buttons;
    static LRESULT CALLBACK proc(HWND h,UINT m,WPARAM w,LPARAM l) {
        auto *b=reinterpret_cast<Button*>(GetWindowLongPtrW(h,GWLP_USERDATA));
        if(m==WM_NCCREATE){b=static_cast<Button*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);b->window=h;SetWindowLongPtrW(h,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(b));}
        if(!b)return DefWindowProcW(h,m,w,l);
        switch(m){
        case WM_ERASEBKGND:return 1;
        case WM_PAINT:{PAINTSTRUCT ps{};BeginPaint(h,&ps);b->owner.paint(*b);EndPaint(h,&ps);return 0;}
        case WM_MOUSEMOVE:if(!b->hover){b->hover=true;TRACKMOUSEEVENT t{sizeof(t),TME_LEAVE,h,0};TrackMouseEvent(&t);InvalidateRect(h,nullptr,FALSE);}return 0;
        case WM_MOUSELEAVE:b->hover=false;InvalidateRect(h,nullptr,FALSE);return 0;
        case WM_LBUTTONDOWN:if(b->state.enabled&&!b->state.blocked){SetFocus(GetParent(h));b->pressed=true;SetCapture(h);InvalidateRect(h,nullptr,FALSE);}return 0;
        case WM_LBUTTONUP:{const bool was=b->pressed;b->pressed=false;if(GetCapture()==h)ReleaseCapture();InvalidateRect(h,nullptr,FALSE);RECT r{};GetClientRect(h,&r);POINT p{GET_X_LPARAM(l),GET_Y_LPARAM(l)};auto action=b->click;if(was&&PtInRect(&r,p)&&action&&b->state.enabled&&!b->state.blocked)action(false);return 0;}
        case WM_CAPTURECHANGED:b->pressed=false;InvalidateRect(h,nullptr,FALSE);return 0;
        case WM_RBUTTONUP:{auto action=b->click;if(action&&b->state.enabled&&!b->state.blocked)action(true);return 0;}
        case WM_NCDESTROY:SetWindowLongPtrW(h,GWLP_USERDATA,0);b->window=nullptr;return DefWindowProcW(h,m,w,l);
        default:return DefWindowProcW(h,m,w,l);
        }
        return DefWindowProcW(h,m,w,l);
    }
    static D2D1_COLOR_F colour(unsigned argb) { return D2D1::ColorF(((argb>>16)&255)/255.f,((argb>>8)&255)/255.f,(argb&255)/255.f,((argb>>24)&255)/255.f); }
    void paint(Button &b) {
        RECT r{};GetClientRect(b.window,&r);
        const auto &s=b.state;const float scale=std::max(.1f,s.scale);
        if(!b.target) {
            auto properties=D2D1::RenderTargetProperties();properties.dpiX=properties.dpiY=96.f*scale;
            if(FAILED(factory->CreateHwndRenderTarget(properties,D2D1::HwndRenderTargetProperties(b.window,D2D1::SizeU(r.right,r.bottom)),&b.target)))return;
        }
        auto *t=b.target.Get();t->SetDpi(96.f*scale,96.f*scale);t->BeginDraw();t->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);t->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
        t->Clear(colour(s.surface));
        const float width=r.right/scale,height=r.bottom/scale;
        auto bg=colour(s.active?s.activeBackground:s.background);
        if(s.accent){bg=colour(s.accent);bg.a=s.active?1.f:b.pressed?.7f:.45f;}
        if(!s.enabled&&!s.accent)bg.a*=.35f;
        Ptr<ID2D1SolidColorBrush> brush;t->CreateSolidColorBrush(bg,&brush);if(!brush){t->EndDraw();return;}
        const auto bounds=D2D1::RoundedRect(D2D1::RectF(.5f,.5f,width-.5f,height-.5f),6,6);
        t->FillRoundedRectangle(bounds,brush.Get());
        auto fg=colour(s.foreground);if(!s.enabled&&!s.accent)fg.a*=.35f;brush->SetColor(fg);
        const bool text=!s.text.empty();float iconSize=s.icon.empty()?0.f:12.f,textWidth=0;
        const float gap=iconSize>0 && text?3.f:0.f;
        Ptr<IDWriteTextLayout> layout;
        if(text) {
            const float available=std::max(1.f,width-iconSize-gap-4.f);
            write->CreateTextLayout(s.text.c_str(),(UINT32)s.text.size(),format.Get(),available,height,&layout);
            if(layout) {
                const DWRITE_TEXT_RANGE range{0,(UINT32)s.text.size()};
                layout->SetFontSize(s.fontSize,range);
                DWRITE_TEXT_METRICS metrics{};layout->GetMetrics(&metrics);
                if(metrics.width>available) {
                    // Rerasterize at the final device-pixel em size; never
                    // horizontally scale a cached bitmap or glyph outline.
                    const float size=std::max(8.f/scale,std::floor(s.fontSize*scale*available/metrics.width)/scale);
                    layout->SetFontSize(size,range);layout->GetMetrics(&metrics);
                }
                textWidth=metrics.width;
            }
        }
        const float x=text?(width-iconSize-gap-textWidth)*.5f:(width-iconSize)*.5f,y=(height-iconSize)*.5f;
        // Rasterize vectors at their final display size. Align straight strokes
        // to device pixels so small icons do not turn into two faint pixel rows.
        const float iconScale=iconSize>0?iconSize/12.f:1.f;
        const float pixels=scale*iconScale;
        const float strokePixels=std::max(1.f,std::round(1.1f*pixels));
        const float stroke=strokePixels/pixels;
        const auto snapX=[&](float v){return (std::round((x+v*iconScale)*scale-strokePixels*.5f)+strokePixels*.5f)/pixels-x/iconScale;};
        const auto snapY=[&](float v){return (std::round((y+v*iconScale)*scale-strokePixels*.5f)+strokePixels*.5f)/pixels-y/iconScale;};
        t->SetTransform(D2D1::Matrix3x2F::Scale(iconScale,iconScale)*D2D1::Matrix3x2F::Translation(x,y));
        auto rect=[&](float a,float c,float d,float e){t->FillRectangle(D2D1::RectF(a,c,d,e),brush.Get());};
        auto line=[&](float a,float c,float d,float e){
            if(a==d)a=d=snapX(a);
            if(c==e)c=e=snapY(c);
            t->DrawLine(D2D1::Point2F(a,c),D2D1::Point2F(d,e),brush.Get(),stroke,iconStroke.Get());
        };
        if(s.icon==L"play"){
            Ptr<ID2D1PathGeometry> path;factory->CreatePathGeometry(&path);Ptr<ID2D1GeometrySink> sink;if(path&&SUCCEEDED(path->Open(&sink))){sink->BeginFigure(D2D1::Point2F(2,1),D2D1_FIGURE_BEGIN_FILLED);sink->AddLine(D2D1::Point2F(11,6));sink->AddLine(D2D1::Point2F(2,11));sink->EndFigure(D2D1_FIGURE_END_CLOSED);sink->Close();t->FillGeometry(path.Get(),brush.Get());}
        }else if(s.icon==L"pause"){rect(2,1,4.5f,11);rect(7.5f,1,10,11);}
        else if(s.icon==L"stopall")rect(1.5f,1.5f,10.5f,10.5f);
        else if(s.icon==L"record") {
            const auto circle = D2D1::Ellipse(D2D1::Point2F(6,6),5,5);
            if (s.active) {
                t->FillEllipse(circle,brush.Get());
                brush->SetColor(bg); rect(3.8f,3.8f,8.2f,8.2f); brush->SetColor(fg);
            } else {
                t->DrawEllipse(circle,brush.Get(),stroke,iconStroke.Get());
                t->FillEllipse(D2D1::Ellipse(D2D1::Point2F(6,6),2.6f,2.6f),brush.Get());
            }
        }
        else if(s.icon==L"loop"){
            Ptr<ID2D1PathGeometry> path;factory->CreatePathGeometry(&path);Ptr<ID2D1GeometrySink> sink;
            if(path&&SUCCEEDED(path->Open(&sink))){
                sink->BeginFigure(D2D1::Point2F(1,7),D2D1_FIGURE_BEGIN_HOLLOW);
                sink->AddLine(D2D1::Point2F(1,5));
                sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F(1,3),D2D1::Point2F(2,2.5f),D2D1::Point2F(4,2.5f)));
                sink->AddLine(D2D1::Point2F(10,2.5f));sink->EndFigure(D2D1_FIGURE_END_OPEN);
                sink->BeginFigure(D2D1::Point2F(11,5),D2D1_FIGURE_BEGIN_HOLLOW);
                sink->AddLine(D2D1::Point2F(11,7));
                sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F(11,9),D2D1::Point2F(10,9.5f),D2D1::Point2F(8,9.5f)));
                sink->AddLine(D2D1::Point2F(2,9.5f));sink->EndFigure(D2D1_FIGURE_END_OPEN);sink->Close();
                t->DrawGeometry(path.Get(),brush.Get(),stroke,iconStroke.Get());
            }
            line(8,0.5f,10,2.5f);line(8,4.5f,10,2.5f);line(4,7.5f,2,9.5f);line(4,11.5f,2,9.5f);
        }
        else if(s.icon==L"metronome") {
            line(4,1,1,11); line(1,11,11,11); line(11,11,8,1); line(8,1,4,1);
            line(3,8.5f,9,8.5f); line(6,9,9.5f,.5f);
            t->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(7.4f,2,10.2f,4.2f),.5f,.5f),brush.Get());
        }
        else if(s.icon==L"teleprompter") {
            t->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(1,1,11,10),1,1),brush.Get(),stroke,iconStroke.Get());
            line(3,4,9,4);line(3,6,8,6);line(4,12,8,12);line(6,10,6,12);
        } else if(s.icon==L"notice") {
            t->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(1,1,11,9),2,2),brush.Get(),stroke,iconStroke.Get());
            line(3,9,3,12);line(3,12,6,9);line(3,4,9,4);line(3,6,8,6);
        } else if(s.icon==L"video") {
            t->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(0,2,8,10),1,1),brush.Get(),stroke,iconStroke.Get());
            line(8,4,12,2);line(12,2,12,10);line(12,10,8,8);
        } else if(s.icon==L"save") {
            t->DrawRectangle(D2D1::RectF(1,1,11,11),brush.Get(),stroke,iconStroke.Get());
            line(3,1,3,5);line(3,5,9,5);line(9,5,9,1);line(3,11,3,8);line(3,8,9,8);line(9,8,9,11);
        } else if(s.icon==L"check") {line(1,6,5,10);line(5,10,11,2);}
        t->SetTransform(D2D1::Matrix3x2F::Identity());
        if(layout)t->DrawTextLayout(D2D1::Point2F(x+iconSize+gap,0),layout.Get(),brush.Get(),D2D1_DRAW_TEXT_OPTIONS_CLIP);
        if(s.dimming>0){brush->SetColor(D2D1::ColorF(0,0,0,s.dimming));t->FillRectangle(D2D1::RectF(0,0,width,height),brush.Get());}
        if(t->EndDraw()==D2DERR_RECREATE_TARGET)b.target.Reset();
    }
};
}
