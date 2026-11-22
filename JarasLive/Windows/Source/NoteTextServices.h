#pragma once
#include <BinaryData.h>
#include <d2d1.h>
#include <dwrite.h>
#include <icu.h>
#include <imm.h>
#include <richedit.h>
#include <textserv.h>
#include <wrl/client.h>

namespace catlive {
// RichEdit's GDI layout can resolve the bundled process-private font. Use
// DirectWrite for the emoji at the positions reported by that same layout.
class NoteTextServices final : public ITextHost {
  public:
    static const wchar_t *defaultFace() {
        static const auto registered = [] {
            DWORD count = 0;
            return AddFontMemResourceEx(const_cast<char *>(BinaryData::InterRegular_ttf),
                                        BinaryData::InterRegular_ttfSize, nullptr, &count);
        }();
        return registered ? L"Inter" : L"Segoe UI";
    }

    explicit NoteTextServices(HWND window) : window(window) {
        format.cbSize = sizeof(format);
        format.dwMask = CFM_FACE | CFM_COLOR | CFM_SIZE | CFM_CHARSET;
        format.yHeight = 225;
        format.crTextColor = RGB(255, 255, 255);
        format.bCharSet = DEFAULT_CHARSET;
        wcscpy_s(format.szFaceName, defaultFace());
        paragraph.cbSize = sizeof(paragraph);
        paragraph.dwMask = PFM_ALIGNMENT;
        paragraph.wAlignment = PFA_LEFT;
    }

    ~NoteTextServices() {
        if (active) services->OnTxInPlaceDeactivate();
        services.Reset();
        releaseSurface();
    }

    bool initialize(HMODULE module) {
        const auto create = reinterpret_cast<decltype(&CreateTextServices)>(GetProcAddress(module, "CreateTextServices"));
        const auto serviceID = reinterpret_cast<const IID *>(GetProcAddress(module, "IID_ITextServices2"));
        hostID = reinterpret_cast<const IID *>(GetProcAddress(module, "IID_ITextHost"));
        if (!create || !serviceID || !hostID || !createTarget()) return false;
        Microsoft::WRL::ComPtr<IUnknown> object;
        if (FAILED(create(nullptr, this, object.GetAddressOf())) ||
            FAILED(object->QueryInterface(*serviceID, reinterpret_cast<void **>(services.GetAddressOf()))))
            return false;
        RECT rect{};
        GetClientRect(window, &rect);
        active = SUCCEEDED(services->OnTxInPlaceActivate(&rect));
        if (!active) return false;
        return true;
    }

    void setBackground(COLORREF color) {
        frameDirty = true;
        background = color;
        InvalidateRect(window, nullptr, FALSE);
    }

    void resized() {
        frameDirty = true;
        if (active) services->OnTxPropertyBitsChange(TXTBIT_CLIENTRECTCHANGE, TXTBIT_CLIENTRECTCHANGE);
        InvalidateRect(window, nullptr, FALSE);
    }
    static constexpr UINT_PTR caretTimer = 0xca71;
    void refreshCaret(bool focused) {
        frameDirty = true;
        caretLit = focused;
        KillTimer(window, caretTimer);
        const auto interval = GetCaretBlinkTime();
        if (focused && interval != 0 && interval != INFINITE) SetTimer(window, caretTimer, interval, nullptr);
        InvalidateRect(window, nullptr, FALSE);
    }
    void blinkCaret() {
        caretLit = !caretLit;
        if (lastCaret.right > lastCaret.left) InvalidateRect(window, &lastCaret, FALSE);
    }
    void drawCaret(HDC dc) {
        if (GetFocus() != window) return;
        CHARRANGE selection{};
        POINTL position{};
        LRESULT result = 0;
        if (!send(EM_EXGETSEL, 0, reinterpret_cast<LPARAM>(&selection), result) ||
            selection.cpMin != selection.cpMax || selection.cpMin < 0 ||
            !send(EM_POSFROMCHAR, reinterpret_cast<WPARAM>(&position), selection.cpMin, result)) return;
        RECT frame{};
        GetClientRect(window, &frame);
        const auto dpi = std::max(96u, GetDpiForWindow(window));
        const LONG height = caretHeight > 0 ? caretHeight : MulDiv(18, dpi, 96);
        const RECT caret{position.x, position.y, position.x + std::max(1, MulDiv(1, dpi, 96)), position.y + height};
        if (IntersectRect(&lastCaret, &frame, &caret) && caretLit) {
            static const auto brush = CreateSolidBrush(RGB(theme::green.getRed(), theme::green.getGreen(), theme::green.getBlue()));
            if (brush) FillRect(dc, &lastCaret, brush);
        }
    }
    void updateGlyphs() {
        if (glyphsDirty) {
            glyphsDirty = false;
            keycaps.clear();
            emoji.clear();
            GETTEXTLENGTHEX request{GTL_PRECISE | GTL_NUMCHARS, 1200};
            LRESULT length = 0;
            if (!send(EM_GETTEXTLENGTHEX, reinterpret_cast<WPARAM>(&request), 0, length) || length <= 0) return;
            std::wstring text(size_t(length) + 1, L'\0');
            GETTEXTEX options{DWORD(text.size() * sizeof(wchar_t)), GT_RAWTEXT, 1200, nullptr, nullptr};
            LRESULT read = 0;
            if (!send(EM_GETTEXTEX, reinterpret_cast<WPARAM>(&options), reinterpret_cast<LPARAM>(text.data()), read) || read <= 0) return;
            UErrorCode error = U_ZERO_ERROR;
            const auto *units = reinterpret_cast<const UChar *>(text.data());
            std::unique_ptr<UBreakIterator, decltype(&ubrk_close)> breaks(ubrk_open(UBRK_CHARACTER, nullptr, units, int32_t(read), &error), ubrk_close);
            if (U_SUCCESS(error) && breaks) {
                for (int32_t first = ubrk_first(breaks.get()), end = ubrk_next(breaks.get()); end != UBRK_DONE;
                     first = end, end = ubrk_next(breaks.get())) {
                    const std::wstring_view cluster(text.data() + first, size_t(end - first));
                    if (cluster.find(L'\u20e3') != cluster.npos || cluster.find(L'\ufe0e') != cluster.npos) continue;
                    int32_t cursor = first;
                    UChar32 codePoint;
                    U16_NEXT(units, cursor, end, codePoint);
                    if (u_hasBinaryProperty(codePoint, UCHAR_EMOJI_PRESENTATION) ||
                        (u_hasBinaryProperty(codePoint, UCHAR_EMOJI) && cluster.find(L'\ufe0f') != cluster.npos))
                        emoji.push_back({first, end, std::wstring(cluster)});
                }
            }
            for (LONG first = 0; first + 1 < read; ++first) {
                const auto glyph = text[size_t(first)];
                if (!((glyph >= L'0' && glyph <= L'9') || glyph == L'#' || glyph == L'*')) continue;
                LONG after = first + 1;
                if (text[size_t(after)] == L'\ufe0f') ++after;
                if (after < read && text[size_t(after)] == L'\u20e3') {
                    LONG next = after + 1;
                    while (next < read && (text[size_t(next)] == L' ' || text[size_t(next)] == L'\t')) ++next;
                    const bool endOfLine = next == read || text[size_t(next)] == L'\r' || text[size_t(next)] == L'\n';
                    keycaps.push_back({first, after + 1, next, endOfLine, glyph});
                    first = after;
                }
            }
        }
    }
    void invalidateGlyphs() { glyphsDirty = true; frameDirty = true; InvalidateRect(window, nullptr, FALSE); }

    bool send(UINT message, WPARAM w, LPARAM l, LRESULT &result) const {
        return active && services->TxSendMessage(message, w, l, &result) == S_OK;
    }

    void paint(HDC destination) {
        RECT bounds{};
        GetClientRect(window, &bounds);
        if (bounds.right <= 0 || bounds.bottom <= 0) return;
        if (!prepareSurface(destination, bounds.right, bounds.bottom)) return;
        if (frameDirty) {
            frameDirty = false;
            renderFrame(surfaceDC, bounds);
        }
        BitBlt(destination, 0, 0, bounds.right, bounds.bottom, surfaceDC, 0, 0, SRCCOPY);
    }

    void renderFrame(HDC dc, const RECT &bounds) {
        updateGlyphs();
        const RECTL textBounds{bounds.left, bounds.top, bounds.right, bounds.bottom};
        // RichEdit's GDI layout knows the registered Inter font and supplies
        // the caret coordinates. Compose color emoji over those same pixels.
        SetDCBrushColor(dc, background);
        FillRect(dc, &bounds, static_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
        services->TxDraw(DVASPECT_CONTENT, 0, nullptr, nullptr, dc, nullptr,
            const_cast<RECTL *>(&textBounds), nullptr, nullptr, nullptr, 0, TXTVIEW_ACTIVE);
        if (emoji.empty() && keycaps.empty()) return;
        if ((!target && !createTarget()) || FAILED(target->BindDC(dc, &bounds))) return;

        GdiFlush();
        const auto size = D2D1::SizeU(UINT32(bounds.right), UINT32(bounds.bottom));
        if (!textFrame) {
            const auto properties = D2D1::BitmapProperties(target->GetPixelFormat(), 96, 96);
            if (FAILED(target->CreateBitmap(size, properties, textFrame.GetAddressOf()))) return;
        }
        if (FAILED(textFrame->CopyFromMemory(nullptr, surfacePixels, size.width * 4))) return;
        target->BeginDraw();
        target->DrawBitmap(textFrame.Get());
        drawEmoji(bounds);
        drawKeycaps(bounds);
        if (FAILED(target->EndDraw())) {
            textFrame.Reset();
            keycapBitmaps = {};
            target.Reset();
            frameDirty = true;
            InvalidateRect(window, nullptr, FALSE);
        }
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id != __uuidof(IUnknown) && (!hostID || id != *hostID)) return E_NOINTERFACE;
        *out = static_cast<ITextHost *>(this);
        AddRef();
        return S_OK;
    }
    // The editor owns the host and releases its text service before destroying it.
    ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    // RichEdit can draw immediately during typing and IME composition. Keep
    // these GDI operations off the window; WM_PAINT presents the composed frame.
    HDC TxGetDC() override {
        const auto screen = GetDC(window);
        const auto dc = CreateCompatibleDC(screen);
        if (screen) ReleaseDC(window, screen);
        return dc;
    }
    INT TxReleaseDC(HDC dc) override { return DeleteDC(dc); }
    BOOL TxShowScrollBar(INT bar, BOOL show) override { return ShowScrollBar(window, bar, show); }
    BOOL TxEnableScrollBar(INT bar, INT arrows) override { return EnableScrollBar(window, bar, arrows); }
    BOOL TxSetScrollRange(INT bar, LONG first, INT last, BOOL redraw) override {
        return SetScrollRange(window, bar, first, last, redraw);
    }
    BOOL TxSetScrollPos(INT bar, INT position, BOOL redraw) override {
        SetScrollPos(window, bar, position, redraw);
        return TRUE;
    }
    void TxInvalidateRect(LPCRECT rect, BOOL) override { frameDirty = true; InvalidateRect(window, rect, FALSE); }
    void TxViewChange(BOOL) override { frameDirty = true; InvalidateRect(window, nullptr, FALSE); }
    BOOL TxCreateCaret(HBITMAP bitmap, INT width, INT height) override {
        caretHeight = height;
        return CreateCaret(window, bitmap, width, height);
    }
    BOOL TxShowCaret(BOOL) override { return TRUE; }
    BOOL TxSetCaretPos(INT x, INT y) override { return SetCaretPos(x, y); }
    BOOL TxSetTimer(UINT id, UINT timeout) override { return SetTimer(window, id, timeout, nullptr) != 0; }
    void TxKillTimer(UINT id) override { KillTimer(window, id); }
    void TxScrollWindowEx(INT, INT, LPCRECT, LPCRECT, HRGN, LPRECT, UINT) override {
        frameDirty = true;
        InvalidateRect(window, nullptr, FALSE);
    }
    void TxSetCapture(BOOL capture) override {
        if (capture) SetCapture(window);
        else if (GetCapture() == window) ReleaseCapture();
    }
    void TxSetFocus() override { if (GetFocus() != window) SetFocus(window); }
    void TxSetCursor(HCURSOR cursor, BOOL) override { SetCursor(cursor); }
    BOOL TxScreenToClient(LPPOINT point) override { return ScreenToClient(window, point); }
    BOOL TxClientToScreen(LPPOINT point) override { return ClientToScreen(window, point); }
    HRESULT TxActivate(LONG *oldState) override { if (oldState) *oldState = 0; return S_OK; }
    HRESULT TxDeactivate(LONG) override { return S_OK; }
    HRESULT TxGetClientRect(LPRECT rect) override { return GetClientRect(window, rect) ? S_OK : E_FAIL; }
    HRESULT TxGetViewInset(LPRECT rect) override {
        constexpr LONG inset = 9 * 2540 / 96;
        *rect = {inset, inset, inset, inset};
        return S_OK;
    }
    HRESULT TxGetCharFormat(const CHARFORMATW **out) override { *out = &format; return S_OK; }
    HRESULT TxGetParaFormat(const PARAFORMAT **out) override { *out = &paragraph; return S_OK; }
    COLORREF TxGetSysColor(int index) override {
        if (index == COLOR_WINDOW) return background;
        if (index == COLOR_WINDOWTEXT) return format.crTextColor;
        return GetSysColor(index);
    }
    HRESULT TxGetBackStyle(TXTBACKSTYLE *out) override { *out = TXTBACK_OPAQUE; return S_OK; }
    HRESULT TxGetMaxLength(DWORD *out) override { *out = 0x7fffffff; return S_OK; }
    HRESULT TxGetScrollBars(DWORD *out) override { *out = WS_VSCROLL | ES_AUTOVSCROLL; return S_OK; }
    HRESULT TxGetPasswordChar(TCHAR *out) override { *out = 0; return S_FALSE; }
    HRESULT TxGetAcceleratorPos(LONG *out) override { *out = -1; return S_OK; }
    HRESULT TxGetExtent(LPSIZEL out) override {
        RECT rect{};
        GetClientRect(window, &rect);
        const auto dpi = std::max(96u, GetDpiForWindow(window));
        *out = {MulDiv(rect.right, 2540, dpi), MulDiv(rect.bottom, 2540, dpi)};
        return S_OK;
    }
    HRESULT OnTxCharFormatChange(const CHARFORMATW *) override { return S_OK; }
    HRESULT OnTxParaFormatChange(const PARAFORMAT *) override { return S_OK; }
    HRESULT TxGetPropertyBits(DWORD mask, DWORD *out) override {
        *out = mask & (TXTBIT_RICHTEXT |
            TXTBIT_MULTILINE | TXTBIT_WORDWRAP | TXTBIT_USECURRENTBKG);
        return S_OK;
    }
    HRESULT TxNotify(DWORD event, void *) override {
        if (event == EN_CHANGE) {
            invalidateGlyphs();
            SendMessageW(GetParent(window), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(window), EN_CHANGE), reinterpret_cast<LPARAM>(window));
        }
        return S_OK;
    }
    HIMC TxImmGetContext() override { return ImmGetContext(window); }
    void TxImmReleaseContext(HIMC context) override { ImmReleaseContext(window, context); }
    HRESULT TxGetSelectionBarWidth(LONG *out) override { *out = 0; return S_OK; }

  private:
    HDC surfaceDC = nullptr;
    HBITMAP surfaceBitmap = nullptr;
    HGDIOBJ originalBitmap = nullptr;
    void *surfacePixels = nullptr;
    Microsoft::WRL::ComPtr<ID2D1Bitmap> textFrame;
    SIZE surfaceSize{};
    bool frameDirty = true;
    void releaseSurface() {
        textFrame.Reset();
        surfacePixels = nullptr;
        if (surfaceDC && originalBitmap) SelectObject(surfaceDC, originalBitmap);
        if (surfaceBitmap) DeleteObject(surfaceBitmap);
        if (surfaceDC) DeleteDC(surfaceDC);
        surfaceDC = nullptr; surfaceBitmap = nullptr; originalBitmap = nullptr;
    }
    bool prepareSurface(HDC reference, LONG width, LONG height) {
        if (surfaceDC && width == surfaceSize.cx && height == surfaceSize.cy) return true;
        releaseSurface();
        surfaceDC = CreateCompatibleDC(reference);
        BITMAPINFO info{};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        surfaceBitmap = CreateDIBSection(reference, &info, DIB_RGB_COLORS, &surfacePixels, nullptr, 0);
        if (!surfaceDC || !surfaceBitmap) { releaseSurface(); return false; }
        originalBitmap = SelectObject(surfaceDC, surfaceBitmap);
        surfaceSize = {width, height};
        frameDirty = true;
        return true;
    }
    HWND window;
    const IID *hostID = nullptr;
    CHARFORMATW format{};
    PARAFORMAT paragraph{};
    COLORREF background = RGB(32, 32, 32);
    bool active = false;
    bool caretLit = false;
    LONG caretHeight = 0;
    RECT lastCaret{};
    struct Keycap { LONG first, end, next; bool endOfLine; wchar_t glyph; };
    struct Emoji { LONG first, end; std::wstring text; };
    std::vector<Keycap> keycaps;
    std::vector<Emoji> emoji;
    bool glyphsDirty = true;
    Microsoft::WRL::ComPtr<ITextServices2> services;
    Microsoft::WRL::ComPtr<ID2D1DCRenderTarget> target;

    std::array<Microsoft::WRL::ComPtr<ID2D1Bitmap>, 12> keycapBitmaps;
    ID2D1Bitmap *keycapBitmap(wchar_t glyph) {
        static constexpr std::array<const char *, 12> resources{{
            "keycap_30_png", "keycap_31_png", "keycap_32_png", "keycap_33_png", "keycap_34_png",
            "keycap_35_png", "keycap_36_png", "keycap_37_png", "keycap_38_png", "keycap_39_png",
            "keycap_23_png", "keycap_2a_png"
        }};
        const size_t index = glyph == L'#' ? 10 : glyph == L'*' ? 11 : size_t(glyph - L'0');
        auto &bitmap = keycapBitmaps[index];
        if (!bitmap) {
            int length = 0;
            const auto bytes = BinaryData::getNamedResource(resources[index], length);
            const auto image = juce::ImageCache::getFromMemory(bytes, length).convertedToFormat(juce::Image::ARGB);
            if (image.isNull()) return nullptr;
            const juce::Image::BitmapData pixels(image, juce::Image::BitmapData::readOnly);
            const auto props = D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
            target->CreateBitmap(D2D1::SizeU(image.getWidth(), image.getHeight()), pixels.data,
                                 UINT32(pixels.lineStride), props, bitmap.GetAddressOf());
        }
        return bitmap.Get();
    }

    void drawKeycaps(const RECT &bounds) {
        if (keycaps.empty()) return;
        Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush;
        if (FAILED(target->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), brush.GetAddressOf()))) return;
        CHARRANGE selection{};
        LRESULT result = 0;
        send(EM_EXGETSEL, 0, reinterpret_cast<LPARAM>(&selection), result);
        const auto dpi = std::max(96u, GetDpiForWindow(window));
        const LONG lineHeight = std::max(12, MulDiv(18, dpi, 96));
        for (const auto &keycap : keycaps) {
            POINTL start{}, end{};
            if (!send(EM_POSFROMCHAR, reinterpret_cast<WPARAM>(&start), keycap.first, result) ||
                !send(EM_POSFROMCHAR, reinterpret_cast<WPARAM>(&end), keycap.end, result) ||
                start.y + lineHeight < bounds.top || start.y >= bounds.bottom || start.x >= bounds.right) continue;
            auto *bitmap = keycapBitmap(keycap.glyph);
            if (!bitmap) continue;
            const LONG width = end.y == start.y && end.x > start.x ? end.x - start.x : lineHeight;
            LONG limit = start.x + width;
            if (keycap.endOfLine) {
                limit = std::min(bounds.right, limit + LONG(MulDiv(9, dpi, 96)));
            } else if (keycap.next > keycap.end) {
                POINTL next{};
                if (send(EM_POSFROMCHAR, reinterpret_cast<WPARAM>(&next), keycap.next, result) && next.y == start.y)
                    limit = std::max(limit, next.x);
            }
            const float size = float(std::min({lineHeight - 2, limit - start.x, width + LONG(MulDiv(4, dpi, 96))}));
            if (size <= 4) continue;
            const auto backdrop = selection.cpMin <= keycap.first && selection.cpMax >= keycap.end ? GetSysColor(COLOR_HIGHLIGHT) : background;
            brush->SetColor(D2D1::ColorF(GetRValue(backdrop) / 255.f, GetGValue(backdrop) / 255.f, GetBValue(backdrop) / 255.f));
            target->FillRectangle(D2D1::RectF(float(start.x), float(start.y), float(limit), float(start.y + lineHeight)), brush.Get());
            const float top = start.y + (lineHeight - size) / 2;
            target->DrawBitmap(bitmap, D2D1::RectF(float(start.x), top, start.x + size, top + size));
        }
    }

    void drawEmoji(const RECT &bounds) {
        if (emoji.empty()) return;
        using Microsoft::WRL::ComPtr;
        static const auto factory = [] {
            ComPtr<IDWriteFactory> value;
            DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                reinterpret_cast<IUnknown **>(value.GetAddressOf()));
            return value;
        }();
        const float scale = std::max(96u, GetDpiForWindow(window)) / 96.f;
        const float lineHeight = 18 * scale;
        ComPtr<IDWriteTextFormat> textFormat;
        if (!factory || FAILED(factory->CreateTextFormat(L"Segoe UI Emoji", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 15 * scale, L"en-us", textFormat.GetAddressOf()))) return;
        textFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        ComPtr<ID2D1SolidColorBrush> brush;
        if (FAILED(target->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), brush.GetAddressOf()))) return;
        CHARRANGE selection{};
        LRESULT result = 0;
        send(EM_EXGETSEL, 0, reinterpret_cast<LPARAM>(&selection), result);
        for (const auto &glyph : emoji) {
            POINTL start{}, end{};
            if (!send(EM_POSFROMCHAR, reinterpret_cast<WPARAM>(&start), glyph.first, result) ||
                !send(EM_POSFROMCHAR, reinterpret_cast<WPARAM>(&end), glyph.end, result) ||
                start.y + lineHeight < bounds.top || start.y >= bounds.bottom || start.x >= bounds.right) continue;
            const float width = end.y == start.y && end.x > start.x ? float(end.x - start.x) : lineHeight;
            ComPtr<IDWriteTextLayout> layout;
            if (FAILED(factory->CreateTextLayout(glyph.text.data(), UINT32(glyph.text.size()), textFormat.Get(),
                width, lineHeight, layout.GetAddressOf()))) continue;
            DWRITE_TEXT_METRICS metrics{};
            if (FAILED(layout->GetMetrics(&metrics)) || metrics.width <= 0) continue;
            const auto rect = D2D1::RectF(float(start.x), float(start.y), start.x + width, start.y + lineHeight);
            const auto backdrop = selection.cpMin <= glyph.first && selection.cpMax >= glyph.end ? GetSysColor(COLOR_HIGHLIGHT) : background;
            brush->SetColor(D2D1::ColorF(GetRValue(backdrop) / 255.f, GetGValue(backdrop) / 255.f, GetBValue(backdrop) / 255.f));
            target->FillRectangle(rect, brush.Get());
            brush->SetColor(D2D1::ColorF(D2D1::ColorF::White));
            target->PushAxisAlignedClip(rect, D2D1_ANTIALIAS_MODE_ALIASED);
            // A legacy fallback can allocate more or less space than the composed glyph.
            target->SetTransform(D2D1::Matrix3x2F::Scale(std::min(1.f, width / metrics.width), 1,
                                                        D2D1::Point2F(rect.left, rect.top)));
            target->DrawTextLayout(D2D1::Point2F(rect.left, rect.top), layout.Get(), brush.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            target->SetTransform(D2D1::Matrix3x2F::Identity());
            target->PopAxisAlignedClip();
        }
    }

    bool createTarget() {
        Microsoft::WRL::ComPtr<ID2D1Factory> factory;
        if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, factory.GetAddressOf()))) return false;
        const auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96, 96);
        return SUCCEEDED(factory->CreateDCRenderTarget(&props, target.GetAddressOf()));
    }
};
}
