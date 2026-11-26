#pragma once
#include <windows.h>
#include <d3d11.h>
#include <d2d1.h>
#include <dcomp.h>
#include <wrl/client.h>
#include <stdexcept>

namespace catlive::native {
// A retained tint layer fades the button into its parent surface. DWM advances
// the animation even when the application is busy, just like the Mac CA layer.
class SavePulseComposition final {
    template<class T> using Ptr = Microsoft::WRL::ComPtr<T>;
public:
    explicit SavePulseComposition(HWND window) {
        HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                      nullptr, 0, D3D11_SDK_VERSION, &graphics, nullptr, nullptr);
        if (FAILED(hr)) hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                             nullptr, 0, D3D11_SDK_VERSION, &graphics, nullptr, nullptr);
        check(hr); Ptr<IDXGIDevice> dxgi; check(graphics.As(&dxgi));
        check(DCompositionCreateDevice(dxgi.Get(), __uuidof(IDCompositionDevice), reinterpret_cast<void **>(device.GetAddressOf())));
        check(device->CreateTargetForHwnd(window, TRUE, &target));
        check(device->CreateVisual(&visual));
        check(device->CreateSurface(1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
        check(visual->SetContent(surface.Get()));
        check(device->CreateEffectGroup(&opacity)); check(opacity->SetOpacity(0.f)); check(visual->SetEffect(opacity.Get()));
        check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, factory.GetAddressOf()));
        check(device->CreateAnimation(&animation));
        // 0.9 seconds in each direction, opacity 1.0 <-> 0.48. The derivative
        // is zero at both endpoints, so the reversal has no abrupt change.
        constexpr float half = .9f, depth = .52f;
        check(animation->AddCubic(0, 0, 0, 3 * depth / (half * half), -2 * depth / (half * half * half)));
        check(animation->AddCubic(.9, depth, 0, -3 * depth / (half * half), 2 * depth / (half * half * half)));
        check(animation->AddRepeat(1.8, 1.8));
    }
    bool update(bool enabled, int width, int height, unsigned background) noexcept {
        try {
            check(graphics->GetDeviceRemovedReason());
            if (enabled == active && width == lastWidth && height == lastHeight && background == lastBackground) return true;
            if (!painted || background != lastBackground) {
                Ptr<IDXGISurface> drawSurface; POINT offset{};
                check(surface->BeginDraw(nullptr, __uuidof(IDXGISurface), reinterpret_cast<void **>(drawSurface.GetAddressOf()), &offset));
                HRESULT result = S_OK;
                {
                    Ptr<ID2D1RenderTarget> draw;
                    auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
                        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
                    result = factory->CreateDxgiSurfaceRenderTarget(drawSurface.Get(), props, &draw);
                    if (SUCCEEDED(result)) {
                        Ptr<ID2D1SolidColorBrush> brush;
                        result = draw->CreateSolidColorBrush(D2D1::ColorF(background & 0xffffff), &brush);
                        if (SUCCEEDED(result)) {
                            draw->BeginDraw(); draw->FillRectangle(D2D1::RectF(float(offset.x), float(offset.y), float(offset.x + 1), float(offset.y + 1)), brush.Get());
                            result = draw->EndDraw();
                        }
                    }
                }
                const auto end = surface->EndDraw(); check(result); check(end); painted = true;
            }
            check(visual->SetTransform(D2D1::Matrix3x2F::Scale(float(width), float(height))));
            if (enabled != active) {
                if (enabled) { check(opacity->SetOpacity(animation.Get())); check(target->SetRoot(visual.Get())); }
                // Detach the tint when saved: a zero-opacity effect alone can
                // retain the last composited frame until the HWND repaints.
                else { check(target->SetRoot(nullptr)); check(opacity->SetOpacity(0.f)); }
            }
            check(device->Commit());
            active = enabled; lastWidth = width; lastHeight = height; lastBackground = background;
            return true;
        } catch (...) { return false; }
    }
    bool running() const { return active; }
private:
    static void check(HRESULT result) { if (FAILED(result)) throw std::runtime_error("Save animation composition unavailable"); }
    Ptr<ID3D11Device> graphics;
    Ptr<IDCompositionDevice> device;
    Ptr<IDCompositionTarget> target;
    Ptr<IDCompositionVisual> visual;
    Ptr<IDCompositionSurface> surface;
    Ptr<IDCompositionAnimation> animation;
    Ptr<IDCompositionEffectGroup> opacity;
    Ptr<ID2D1Factory> factory;
    bool active = false, painted = false;
    int lastWidth = 0, lastHeight = 0;
    unsigned lastBackground = 0;
};
} // namespace catlive::native
