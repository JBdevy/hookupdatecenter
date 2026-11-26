#pragma once
#include "ItemTextColors.h"
#include "Localization.h"
#include "NoteTextServices.h"
#include "TextItemPanel.h"
#include <commctrl.h>
#include <richedit.h>
#include <richole.h>
#include <tom.h>
#include <wrl/client.h>

namespace catlive {
// Keep editing, glyph fallback, hit testing and caret movement in the same
// Windows control. The Library still stores its portable colored text runs.
class LibraryNoteEditor final : public Component, private AsyncUpdater {
  public:
    LibraryNoteEditor(String text, std::function<void(String)> save, bool focus = true, bool writable = true)
        : initial(std::move(text)), changed(std::move(save)), focusOnAttach(focus), editable(writable) {
        setComponentID("library-note-editor");
        addAndMakeVisible(host);
    }

    ~LibraryNoteEditor() override {
        cancelPendingUpdate();
        const auto container = static_cast<HWND>(host.getHWND());
        host.setHWND(nullptr);
        if (IsWindow(container)) DestroyWindow(container);
    }

    void parentHierarchyChanged() override { triggerAsyncUpdate(); }
    void visibilityChanged() override { triggerAsyncUpdate(); }
    void resized() override {
        host.setBounds(getLocalBounds());
        if (fallback) fallback->setBounds(getLocalBounds());
        if (editor) {
            host.updateHWNDBounds();
            fitEditor();
            syncAppearance();
        }
    }
    void syncAppearance() {
        if (!editor) return;
        const auto background = asColorRef(theme::display.getARGB());
        if (background != currentBackground) {
            currentBackground = background;
            if (textServices) textServices->setBackground(background);
            SendMessageW(editor, EM_SETBKGNDCOLOR, FALSE, background);
        }
        const bool blocked = isCurrentlyBlockedByAnotherModalComponent();
        if (host.isVisible() == blocked) host.setVisible(!blocked);
    }
    HWND nativeEditor() const { return editor; }

  private:
    String initial;
    std::function<void(String)> changed;
    const bool focusOnAttach;
    const bool editable;
    HWNDComponent host;
    HWND editor = nullptr;
    std::unique_ptr<NoteTextServices> textServices;
    COLORREF currentBackground = CLR_INVALID;
    std::unique_ptr<TextItemPanel> fallback;

    static COLORREF asColorRef(uint32 rgb) { return RGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
    static uint32 asRGB(COLORREF color) { return (uint32(GetRValue(color)) << 16) | (uint32(GetGValue(color)) << 8) | GetBValue(color); }

    void handleAsyncUpdate() override {
        if (editor || fallback || !isShowing() || !getPeer()) return;
        static const auto richEdit = LoadLibraryExW(L"Msftedit.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (richEdit) {
            const auto parent = static_cast<HWND>(getPeer()->getNativeHandle());
            const auto instance = GetModuleHandleW(nullptr);
            const auto container = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                0, 0, 1, 1, parent, nullptr, instance, nullptr);
            if (container) {
                const DWORD childStyle = WS_CHILD | WS_VISIBLE | WS_VSCROLL | (editable ? WS_TABSTOP : 0);
                editor = CreateWindowExW(0, L"STATIC", L"Notes", childStyle | SS_NOTIFY,
                    0, 0, 1, 1, container, nullptr, instance, nullptr);
                if (editor) {
                    auto services = std::make_unique<NoteTextServices>(editor);
                    if (services->initialize(richEdit)) textServices = std::move(services);
                    else { DestroyWindow(editor); editor = nullptr; }
                }
                if (!editor) editor = CreateWindowExW(0, MSFTEDIT_CLASS, L"Notes",
                    childStyle | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | ES_NOHIDESEL,
                    0, 0, 1, 1, container, nullptr, instance, nullptr);
                if (editor) {
                    SetWindowSubclass(container, containerMessages, reinterpret_cast<UINT_PTR>(this), 0);
                    SetWindowSubclass(editor, editorMessages, reinterpret_cast<UINT_PTR>(this), 0);
                    loadText();
                    if (editable) SendMessageW(editor, EM_SETEVENTMASK, 0, ENM_CHANGE);
                    else SendMessageW(editor, EM_SETREADONLY, TRUE, 0);
                    host.setHWND(container);
                    resized();
                    if (editable && focusOnAttach && !isCurrentlyBlockedByAnotherModalComponent()) ::SetFocus(editor);
                    return;
                }
                DestroyWindow(container);
            }
        }
        fallback = std::make_unique<TextItemPanel>(initial, changed, true, false, editable, editable, focusOnAttach);
        addAndMakeVisible(*fallback);
        resized();
    }

    void fitEditor() {
        RECT frame{};
        GetClientRect(static_cast<HWND>(host.getHWND()), &frame);
        MoveWindow(editor, 0, 0, frame.right, frame.bottom, TRUE);
        if (textServices) return;
        const auto inset = MulDiv(9, GetDpiForWindow(editor), 96);
        InflateRect(&frame, -inset, -inset);
        if (frame.right > frame.left && frame.bottom > frame.top)
            SendMessageW(editor, EM_SETRECT, 0, reinterpret_cast<LPARAM>(&frame));
    }

    void loadText() {
        SendMessageW(editor, WM_SETTEXT, 0, reinterpret_cast<LPARAM>(L""));
        SendMessageW(editor, EM_SETTEXTMODE, TM_RICHTEXT | TM_MULTILEVELUNDO, 0);
        SendMessageW(editor, EM_EXLIMITTEXT, 0, 0x7fffffff);
        CHARFORMAT2W font{};
        font.cbSize = sizeof(font);
        font.dwMask = CFM_FACE | CFM_SIZE | CFM_COLOR;
        font.yHeight = 225;
        font.crTextColor = RGB(255, 255, 255);
        wcscpy_s(font.szFaceName, NoteTextServices::defaultFace());
        SendMessageW(editor, EM_SETCHARFORMAT, SCF_DEFAULT, reinterpret_cast<LPARAM>(&font));
        for (const auto &run : ItemTextColors::runs(initial)) {
            setSelectionColor(run.color.value_or(0xffffff));
            const auto string = run.text.replace("\r\n", "\n").replace("\n", "\r");
            SendMessageW(editor, EM_REPLACESEL, FALSE, reinterpret_cast<LPARAM>(string.toWideCharPointer()));
        }
        setSelectionColor(0xffffff);
        SendMessageW(editor, EM_EMPTYUNDOBUFFER, 0, 0);
    }

    void setSelectionColor(uint32 rgb) {
        CHARFORMAT2W format{};
        format.cbSize = sizeof(format);
        format.dwMask = CFM_COLOR;
        format.crTextColor = asColorRef(rgb);
        SendMessageW(editor, EM_SETCHARFORMAT, SCF_SELECTION, reinterpret_cast<LPARAM>(&format));
    }

    String encodedText() const {
        GETTEXTLENGTHEX lengthRequest{GTL_PRECISE | GTL_NUMCHARS, 1200};
        const auto length = SendMessageW(editor, EM_GETTEXTLENGTHEX, reinterpret_cast<WPARAM>(&lengthRequest), 0);
        if (length <= 0) return {};
        std::wstring text(size_t(length) + 1, L'\0');
        GETTEXTEX request{DWORD(text.size() * sizeof(wchar_t)), GT_RAWTEXT, 1200, nullptr, nullptr};
        text.resize(size_t(SendMessageW(editor, EM_GETTEXTEX, reinterpret_cast<WPARAM>(&request), reinterpret_cast<LPARAM>(text.data()))));
        const auto asString = [](const std::wstring &part) { return String(part.c_str()).replace("\r", "\n"); };
        using Microsoft::WRL::ComPtr;
        ComPtr<IRichEditOle> ole;
        ComPtr<ITextDocument> document;
        ComPtr<ITextRange> range;
        if (!SendMessageW(editor, EM_GETOLEINTERFACE, 0, reinterpret_cast<LPARAM>(ole.GetAddressOf())) ||
            FAILED(ole.As(&document)) || FAILED(document->Range(0, 0, range.GetAddressOf()))) return asString(text);
        std::vector<ItemTextColors::Run> runs;
        const auto end = LONG(text.size());
        for (LONG pos = 0; pos < end;) {
            LONG next = pos;
            LONG color = tomAutoColor;
            ComPtr<ITextFont> font;
            range->SetRange(pos, pos);
            range->MoveEnd(tomCharFormat, 1, nullptr);
            range->GetEnd(&next);
            if (next <= pos) next = end;
            next = std::min(next, end);
            if (SUCCEEDED(range->GetFont(font.GetAddressOf()))) font->GetForeColor(&color);
            const auto rgb = color == tomAutoColor || color == tomUndefined ? 0xffffff : asRGB(color);
            const std::optional<uint32> value = rgb == 0xffffff ? std::nullopt : std::optional<uint32>(rgb);
            const auto part = asString(text.substr(size_t(pos), size_t(next - pos)));
            if (!runs.empty() && runs.back().color == value) runs.back().text += part;
            else runs.push_back({part, value});
            pos = next;
        }
        return ItemTextColors::encode(runs);
    }

    void contextMenu(POINT position) {
        CHARRANGE selection{};
        SendMessageW(editor, EM_EXGETSEL, 0, reinterpret_cast<LPARAM>(&selection));
        if (position.x == -1 && position.y == -1) GetCursorPos(&position);
        const auto menu = CreatePopupMenu();
        if (!menu) return;
        const auto append = [](HMENU parent, UINT id, const String &label, bool enabled = true) {
            AppendMenuW(parent, MF_STRING | (enabled ? MF_ENABLED : MF_GRAYED), id, localization::translate(label).toWideCharPointer());
        };
        const bool hasSelection = selection.cpMin != selection.cpMax;
        append(menu, WM_UNDO, "Undo", SendMessageW(editor, EM_CANUNDO, 0, 0) != 0);
        append(menu, WM_CUT, "Cut", hasSelection);
        append(menu, WM_COPY, "Copy", hasSelection);
        append(menu, WM_PASTE, "Paste", IsClipboardFormatAvailable(CF_UNICODETEXT) != 0);
        append(menu, 1, "Select All");
        if (hasSelection) {
            const auto colors = CreatePopupMenu();
            if (colors) {
                const std::array<const char *, 8> names{"White", "Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple"};
                for (size_t index = 0; index < names.size(); ++index) append(colors, UINT(2 + index), names[index]);
                AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(colors), localization::translate("Text color").toWideCharPointer());
            }
        }
        const auto control = editor;
        const auto chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                                          position.x, position.y, 0, control, nullptr);
        DestroyMenu(menu);
        if (!IsWindow(control) || !chosen) return;
        if (chosen == 1) SendMessageW(control, EM_SETSEL, 0, -1);
        else if (chosen >= 2 && size_t(chosen - 2) < ItemTextColors::palette.size()) {
            setSelectionColor(ItemTextColors::palette[size_t(chosen - 2)]);
            changed(encodedText());
        } else SendMessageW(control, chosen, 0, 0);
    }

    static LRESULT CALLBACK containerMessages(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
        auto &self = *reinterpret_cast<LibraryNoteEditor *>(id);
        if (message == WM_COMMAND && HIWORD(w) == EN_CHANGE && reinterpret_cast<HWND>(l) == self.editor) {
            if (self.textServices) self.textServices->invalidateGlyphs();
            if (self.editable) self.changed(self.encodedText());
        }
        if (message == WM_NCDESTROY) RemoveWindowSubclass(window, containerMessages, id);
        return DefSubclassProc(window, message, w, l);
    }
    static LRESULT CALLBACK editorMessages(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
        auto &self = *reinterpret_cast<LibraryNoteEditor *>(id);
        if (!self.editable) {
            switch (message) {
                case WM_GETDLGCODE: return 0;
                case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
                case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK: case WM_LBUTTONUP:
                case WM_RBUTTONDOWN: case WM_RBUTTONUP: case WM_MOUSEMOVE: return 0;
                default: break;
            }
        }
        if (message == WM_CONTEXTMENU) {
            if (self.editable && !self.isCurrentlyBlockedByAnotherModalComponent())
                self.contextMenu({int(short(LOWORD(l))), int(short(HIWORD(l)))});
            return 0;
        }
        if (message == WM_MOUSEACTIVATE && self.isCurrentlyBlockedByAnotherModalComponent()) return MA_NOACTIVATEANDEAT;
        if (message == WM_NCDESTROY) {
            self.textServices.reset();
            self.editor = nullptr;
            RemoveWindowSubclass(window, editorMessages, id);
            return DefSubclassProc(window, message, w, l);
        }
        if (auto *services = self.textServices.get()) {
            if (message == WM_PAINT) {
                PAINTSTRUCT paint{};
                const auto dc = BeginPaint(window, &paint);
                if (dc) { services->paint(dc); services->drawCaret(dc); }
                EndPaint(window, &paint);
                return 0;
            }
            if (message == WM_PRINTCLIENT) {
                const auto dc = reinterpret_cast<HDC>(w);
                services->paint(dc); services->drawCaret(dc);
                return 0;
            }
            if (message == WM_TIMER && w == NoteTextServices::caretTimer) {
                services->blinkCaret();
                return 0;
            }
            if (message == WM_ERASEBKGND) return 1;
            if (message == WM_GETDLGCODE) return DLGC_WANTARROWS | DLGC_WANTCHARS | DLGC_WANTALLKEYS;
            if (message == WM_SIZE || message == WM_DPICHANGED_AFTERPARENT) services->resized();
            if (message == WM_LBUTTONDOWN && GetFocus() != window) ::SetFocus(window);
            LRESULT result = 0;
            const bool handled = services->send(message, w, l, result);
            if (message == WM_SETTEXT || message == EM_REPLACESEL) services->invalidateGlyphs();
            if (message == WM_SETFOCUS || message == WM_KILLFOCUS || message == WM_LBUTTONDOWN ||
                message == WM_LBUTTONUP || (message == WM_MOUSEMOVE && (w & MK_LBUTTON)) ||
                message == WM_CHAR || message == WM_KEYDOWN || message == WM_PASTE || message == EM_SETSEL) {
                services->refreshCaret(message != WM_KILLFOCUS && GetFocus() == window);
            }
            if (handled && message != WM_RBUTTONUP) return result;
        }
        return DefSubclassProc(window, message, w, l);
    }
};
}
