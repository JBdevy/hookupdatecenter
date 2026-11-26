// Real Direct2D/DirectWrite regression: same Inter glyphs, DPI, geometry and
// premultiplied target as the HWND renderer. Does not create or focus a window.
#include <windows.h>
#include <d3d11.h>
#include <d2d1_1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;
static void check(HRESULT value) {
    if (FAILED(value)) throw std::runtime_error("HRESULT " + std::to_string((unsigned)value));
}
struct Image {
    unsigned width = 0, height = 0;
    std::vector<unsigned char> pixels;
    size_t coloured() const {
        size_t count = 0;
        for (size_t i = 0; i < pixels.size(); i += 4)
            if (pixels[i] != pixels[i + 1] || pixels[i + 1] != pixels[i + 2]) ++count;
        return count;
    }
    bool opaque() const {
        for (size_t i = 3; i < pixels.size(); i += 4) if (pixels[i] != 255) return false;
        return true;
    }
    void save(const std::filesystem::path& file) const {
        ComPtr<IWICImagingFactory> factory;
        check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
        ComPtr<IWICStream> stream; check(factory->CreateStream(&stream));
        check(stream->InitializeFromFilename(file.c_str(), GENERIC_WRITE));
        ComPtr<IWICBitmapEncoder> encoder; check(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder));
        check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
        ComPtr<IWICBitmapFrameEncode> frame; check(encoder->CreateNewFrame(&frame, nullptr));
        check(frame->Initialize(nullptr)); check(frame->SetSize(width, height));
        WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA; check(frame->SetPixelFormat(&format));
        check(frame->WritePixels(height, width * 4, (UINT)pixels.size(), const_cast<BYTE*>(pixels.data())));
        check(frame->Commit()); check(encoder->Commit());
    }
};
struct Renderer {
    ComPtr<ID2D1DeviceContext> context;
    ComPtr<IDWriteFontFace> face;
    std::string adapter;
    explicit Renderer(const std::filesystem::path& font) {
        ComPtr<ID3D11Device> d3d;
        check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                               nullptr, 0, D3D11_SDK_VERSION, &d3d, nullptr, nullptr));
        ComPtr<IDXGIDevice> dxgi; check(d3d.As(&dxgi));
        ComPtr<IDXGIAdapter> gpu; check(dxgi->GetAdapter(&gpu));
        DXGI_ADAPTER_DESC description{}; check(gpu->GetDesc(&description));
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, description.Description, -1, nullptr, 0, nullptr, nullptr);
        adapter.resize((size_t)bytes);
        WideCharToMultiByte(CP_UTF8, 0, description.Description, -1, adapter.data(), bytes, nullptr, nullptr);
        if (!adapter.empty()) adapter.pop_back();
        ComPtr<ID2D1Factory1> factory;
        check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, IID_PPV_ARGS(&factory)));
        ComPtr<ID2D1Device> device; check(factory->CreateDevice(dxgi.Get(), &device));
        check(device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &context));
        ComPtr<IDWriteFactory> write;
        check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(write.GetAddressOf())));
        ComPtr<IDWriteFontFile> file; check(write->CreateFontFileReference(font.c_str(), nullptr, &file));
        BOOL supported = FALSE; DWRITE_FONT_FILE_TYPE fileType; DWRITE_FONT_FACE_TYPE faceType; UINT32 faces = 0;
        check(file->Analyze(&supported, &fileType, &faceType, &faces));
        if (!supported || faces == 0) throw std::runtime_error("Bundled Inter font is not supported");
        auto* raw = file.Get();
        check(write->CreateFontFace(faceType, 1, &raw, 0, DWRITE_FONT_SIMULATIONS_NONE, &face));
    }
    Image render(D2D1_TEXT_ANTIALIAS_MODE mode, float dpi = 96, bool transparent = false, bool layer = false, bool rgb = false) {
        unsigned width = (unsigned)(800 * dpi / 96), height = (unsigned)(240 * dpi / 96);
        auto properties = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, rgb ? D2D1_ALPHA_MODE_IGNORE : D2D1_ALPHA_MODE_PREMULTIPLIED), dpi, dpi);
        ComPtr<ID2D1Bitmap1> target;
        check(context->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, &properties, &target));
        context->SetTarget(target.Get()); context->SetDpi(dpi, dpi);
        context->SetTextAntialiasMode(mode);
        context->BeginDraw();
        context->Clear(transparent ? D2D1::ColorF(0, 0.f) : D2D1::ColorF(0x202020));
        const auto parentTextMode = context->GetTextAntialiasMode();
        if (layer) {
            // Same scoping as JUCE's patched Layer::push/pop: an intermediate
            // alpha surface must never receive ClearType fringes.
            context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            auto p = D2D1::LayerParameters1();
            p.opacity = .5f;
            context->PushLayer(p, nullptr);
        }
        ComPtr<ID2D1SolidColorBrush> brush;
        check(context->CreateSolidColorBrush(D2D1::ColorF(0xffffff), &brush));
        const std::wstring text = L"CatLive 01 REGÊNCIA  Patch  Env  FX  Center  -3.0 dB  00:03:24  120 BPM";
        std::vector<UINT32> unicode(text.begin(), text.end());
        std::vector<UINT16> indices(text.size());
        check(face->GetGlyphIndices(unicode.data(), (UINT32)unicode.size(), indices.data()));
        std::vector<DWRITE_GLYPH_METRICS> metrics(indices.size());
        check(face->GetDesignGlyphMetrics(indices.data(), (UINT32)indices.size(), metrics.data(), FALSE));
        DWRITE_FONT_METRICS fontMetrics{}; face->GetMetrics(&fontMetrics);
        std::vector<float> advances(indices.size());
        for (int row = 0; row < 5; ++row) {
            const float size = (12.f + row * 2) * .9f; // same existing CatLive calibration
            for (size_t i = 0; i < advances.size(); ++i)
                advances[i] = size * metrics[i].advanceWidth / fontMetrics.designUnitsPerEm;
            DWRITE_GLYPH_RUN run{}; run.fontFace = face.Get(); run.fontEmSize = size;
            run.glyphCount = (UINT32)indices.size(); run.glyphIndices = indices.data(); run.glyphAdvances = advances.data();
            // Half-pixel origins are intentional: actual layouts can have them.
            context->DrawGlyphRun(D2D1::Point2F(16.5f, 30.5f + row * 44), &run, brush.Get(), DWRITE_MEASURING_MODE_NATURAL);
        }
        if (layer) {
            context->PopLayer();
            context->SetTextAntialiasMode(parentTextMode);
            if (context->GetTextAntialiasMode() != mode) throw std::runtime_error("Parent text mode not restored");
        }
        check(context->EndDraw()); context->SetTarget(nullptr);
        properties.bitmapOptions = D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW;
        ComPtr<ID2D1Bitmap1> read;
        check(context->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, &properties, &read));
        check(read->CopyFromBitmap(nullptr, target.Get(), nullptr));
        D2D1_MAPPED_RECT mapped{}; check(read->Map(D2D1_MAP_OPTIONS_READ, &mapped));
        Image result{width, height, std::vector<unsigned char>((size_t)width * height * 4)};
        for (unsigned y = 0; y < height; ++y)
            std::copy_n(mapped.bits + (size_t)y * mapped.pitch, width * 4, result.pixels.data() + (size_t)y * width * 4);
        check(read->Unmap()); return result;
    }
};
int wmain(int argc, wchar_t** argv) {
    if (argc < 3) return 2;
    try {
        check(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED));
        Renderer renderer(argv[1]); const std::filesystem::path output(argv[2]);
        std::filesystem::create_directories(output);
        std::ofstream report(output / "result.txt");
        report << "adapter=" << renderer.adapter << "\n";
        for (float dpi : {96.f, 120.f, 144.f}) {
            const auto before = renderer.render(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE, dpi);
            const auto after = renderer.render(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE, dpi);
            if (before.coloured() != 0 || after.coloured() < 100 || !before.opaque() || !after.opaque())
                throw std::runtime_error("ClearType missing or invalid opaque alpha");
            auto name = std::to_string((int)dpi);
            before.save(output / (name + "-before-grayscale.png")); after.save(output / (name + "-after-cleartype.png"));
            const auto rgbCache = renderer.render(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE, dpi, false, false, true);
            if (rgbCache.coloured() < 100) throw std::runtime_error("Opaque RGB cache lost ClearType");
            rgbCache.save(output / (name + "-opaque-rgb-cache.png"));
            report << "dpi=" << dpi << " grayscaleColourPixels=" << before.coloured()
                   << " clearTypeColourPixels=" << after.coloured() << " opaqueAlpha=PASS dimensions="
                   << after.width << "x" << after.height << " rgbCacheColourPixels=" << rgbCache.coloured() << "\n";
        }
        const auto imageCache = renderer.render(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE, 96, true);
        if (imageCache.coloured() != 0 || imageCache.opaque()) throw std::runtime_error("Transparent cache changed");
        const auto translucentLayer = renderer.render(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE, 96, false, true);
        if (translucentLayer.coloured() != 0 || !translucentLayer.opaque()) throw std::runtime_error("Layer alpha fallback failed");
        report << "transparentImage=PASS translucentLayerFallback=PASS\nPASS\n";
        std::cout << "Direct2D text rendering passed at 96/120/144 DPI; transparent caches/layers preserved\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
