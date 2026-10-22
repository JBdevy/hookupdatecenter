# JUCE maintainer reuk, 2026-07-17, commit 54ca5e9afff345f8d8586962ebc207d674adb338:
# https://forum.juce.com/uploads/short-url/afd9xTuEA1kqdnTkeNbREcs9Nh7.patch
# Wait for the flip queue without blocking the message thread. Also consume the
# readiness token after DXGI_STATUS_OCCLUDED (a successful Present1 result), so
# unlocking the desktop doesn't permanently disable frame pacing.
function(catlive_prepare_juce source output)
    set(relative modules/juce_gui_basics/native/juce_Direct2DHwndContext_windows.cpp)
    file(READ "${source}/${relative}" original)
    string(REPLACE "\r\n" "\n" original "${original}")
    string(SHA256 source_hash "${original}")
    if(NOT source_hash STREQUAL "051296cc50a105ce9b4bd115c022fecad80a70fbc232faab21d99d72a7f0b62c")
        message(FATAL_ERROR "Direct2D frame-pacing patch requires the unmodified JUCE 8.0.15 source. Review the patch before changing JUCE versions.")
    endif()
    set(patched "${CMAKE_BINARY_DIR}/catlive-juce-8.0.15")
    file(COPY "${source}/" DESTINATION "${patched}"
         PATTERN ".git" EXCLUDE PATTERN "examples" EXCLUDE
         PATTERN "juce_Direct2DHwndContext_windows.cpp" EXCLUDE
         PATTERN "juce_Direct2DImageContext_windows.cpp" EXCLUDE
         PATTERN "juce_Direct2DGraphicsContext_windows.cpp" EXCLUDE
         PATTERN "juce_Direct2DGraphicsContextImpl_windows.cpp" EXCLUDE)
    # Keep the existing unused event wrapper unchanged to minimise the backport.
    string(REPLACE "chain2->SetMaximumFrameLatency (1);"
        "chain2->SetMaximumFrameLatency (1);\n        frameReady.reset (chain2->GetFrameLatencyWaitableObject());"
        result "${original}")
    string(REPLACE "    static constexpr uint32 swapChainFlags"
        "    bool canPresent()\n    {\n        didWait = didWait || frameReady == nullptr || (WaitForSingleObjectEx (frameReady.get(), 0, true) == WAIT_OBJECT_0);\n        return didWait;\n    }\n\n    void didPresent() { didWait = false; }\n\n    static constexpr uint32 swapChainFlags"
        result "${result}")
    string(REPLACE "    ComSmartPtr<ID2D1Bitmap1> buffer;"
        "    ComSmartPtr<ID2D1Bitmap1> buffer;\n    std::unique_ptr<std::remove_pointer_t<HANDLE>, FunctionPointerDestructor<CloseHandle>> frameReady;\n    bool didWait = false;"
        result "${result}")
    string(REPLACE "        ready &= swap.canPaint();"
        "        ready &= swap.canPaint();\n        ready &= swap.canPresent();"
        result "${result}")
    string(REPLACE "        // There's nothing waiting to be displayed in the backbuffer."
        "        swap.didPresent();\n\n        // There's nothing waiting to be displayed in the backbuffer."
        result "${result}")
    # JUCE's shared Direct2D factory deliberately defaults to grayscale because
    # it also renders alpha images. HwndPimpl is only used for opaque native
    # windows, so it can honour Windows' ClearType setting without putting
    # coloured fringes into transparent image caches, popups, or effects.
    # Keep the premultiplied swapchain and all sizing/DPI logic unchanged.
    set(text_context_original [=[        if (deviceContext == nullptr)
            deviceContext = Direct2DDeviceContext::create (adapter);
]=])
    set(text_context_replacement [=[        if (deviceContext == nullptr)
        {
            deviceContext = Direct2DDeviceContext::create (adapter);

            BOOL smoothingEnabled = FALSE;
            UINT smoothingType = 0;
            if (deviceContext != nullptr
                && SystemParametersInfoW (SPI_GETFONTSMOOTHING, 0, &smoothingEnabled, 0)
                && smoothingEnabled
                && SystemParametersInfoW (SPI_GETFONTSMOOTHINGTYPE, 0, &smoothingType, 0)
                && smoothingType == FE_FONTSMOOTHINGCLEARTYPE)
                deviceContext->SetTextAntialiasMode (D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
        }
]=])
    string(FIND "${result}" "${text_context_original}" text_context_position)
    if(text_context_position EQUAL -1)
        message(FATAL_ERROR "Opaque-window ClearType patch no longer matches JUCE. Review the rendering changes.")
    endif()
    string(REPLACE "${text_context_original}" "${text_context_replacement}" result "${result}")
    set(existing "")
    if(EXISTS "${patched}/${relative}")
        file(READ "${patched}/${relative}" existing)
    endif()
    if(NOT existing STREQUAL result)
        file(WRITE "${patched}/${relative}" "${result}")
    endif()
    # A geometry/transparency layer has its own alpha surface. Direct2D does
    # not automatically suppress an explicitly requested ClearType mode there.
    # Scope grayscale to that layer and restore the parent's mode on every pop,
    # including JUCE's nested clip/save-state and clip-consolidation paths.
    set(layer_relative modules/juce_graphics/native/juce_Direct2DGraphicsContextImpl_windows.cpp)
    file(READ "${source}/${layer_relative}" layer_original)
    string(REPLACE "\r\n" "\n" layer_original "${layer_original}")
    string(SHA256 layer_hash "${layer_original}")
    if(NOT layer_hash STREQUAL "8d93ca3dccf65e820712dc6198baac236a6ce837caa4d4801b03090c757468f1")
        message(FATAL_ERROR "ClearType layer protection requires the unmodified JUCE 8.0.15 source.")
    endif()
    string(REPLACE "                context->PushLayer (layer->params, nullptr);"
        "            {\n                previousTextAntialias = context->GetTextAntialiasMode();\n                context->SetTextAntialiasMode (D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);\n                context->PushLayer (layer->params, nullptr);\n            }"
        layer_result "${layer_original}")
    string(REPLACE "                context->PopLayer();"
        "            {\n                context->PopLayer();\n                context->SetTextAntialiasMode (previousTextAntialias);\n            }"
        layer_result "${layer_result}")
    string(REPLACE "        std::variant<OwningLayer, Rectangle<float>> var;"
        "        std::variant<OwningLayer, Rectangle<float>> var;\n        mutable D2D1_TEXT_ANTIALIAS_MODE previousTextAntialias = D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE;"
        layer_result "${layer_result}")
    set(layer_existing "")
    if(EXISTS "${patched}/${layer_relative}")
        file(READ "${patched}/${layer_relative}" layer_existing)
    endif()
    if(NOT layer_existing STREQUAL layer_result)
        file(WRITE "${patched}/${layer_relative}" "${layer_result}")
    endif()
    # Opaque component caches (including the timeline canvas) are native RGB
    # bitmaps at the destination's physical scale. Give these the same text
    # rasterisation as the HWND while leaving ARGB/effect images grayscale.
    set(image_relative modules/juce_graphics/native/juce_Direct2DImageContext_windows.cpp)
    file(READ "${source}/${image_relative}" image_original)
    string(REPLACE "\r\n" "\n" image_original "${image_original}")
    string(SHA256 image_hash "${image_original}")
    if(NOT image_hash STREQUAL "e3bb591a6dacdbd42d836b3241a8e594c5de3a915116769c3f63bca0943052f0")
        message(FATAL_ERROR "Opaque-cache ClearType patch requires the unmodified JUCE 8.0.15 source.")
    endif()
    set(image_context_original [=[          paintAreas (paintAreasIn)
    {
    }
]=])
    set(image_context_replacement [=[          paintAreas (paintAreasIn)
    {
        BOOL smoothingEnabled = FALSE;
        UINT smoothingType = 0;
        if (context != nullptr && bitmap != nullptr
            && bitmap->GetPixelFormat().alphaMode == D2D1_ALPHA_MODE_IGNORE
            && SystemParametersInfoW (SPI_GETFONTSMOOTHING, 0, &smoothingEnabled, 0)
            && smoothingEnabled
            && SystemParametersInfoW (SPI_GETFONTSMOOTHINGTYPE, 0, &smoothingType, 0)
            && smoothingType == FE_FONTSMOOTHINGCLEARTYPE)
            context->SetTextAntialiasMode (D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    }
]=])
    string(REPLACE "${image_context_original}" "${image_context_replacement}" image_result "${image_original}")
    set(image_existing "")
    if(EXISTS "${patched}/${image_relative}")
        file(READ "${patched}/${image_relative}" image_existing)
    endif()
    if(NOT image_existing STREQUAL image_result)
        file(WRITE "${patched}/${image_relative}" "${image_result}")
    endif()
    # Align compact one-line text on physical vertical pixels. Do not alter
    # glyph advances, fonts, colours, clip layers or transparency composition.
    set(glyph_relative modules/juce_graphics/native/juce_Direct2DGraphicsContext_windows.cpp)
    file(READ "${source}/${glyph_relative}" glyph_original)
    string(REPLACE "\r\n" "\n" glyph_original "${glyph_original}")
    string(SHA256 glyph_hash "${glyph_original}")
    if(NOT glyph_hash STREQUAL "1c57142cb019f0f06a70e85b48507a3353c5de75e082496990e86c149eb99622")
        message(FATAL_ERROR "Compact-text baseline patch requires the unmodified JUCE 8.0.15 source.")
    endif()
    set(glyph_original_text [=[    const auto textAndWorldTransform = textTransform.followedBy (worldTransform);
    const auto onlyTranslated = textAndWorldTransform.isOnlyTranslation();]=])
    set(glyph_aligned_text [=[    auto textAndWorldTransform = textTransform.followedBy (worldTransform);

    // Centre-aligned compact labels otherwise land on different fractional
    // baselines as their control height changes (e.g. 14.43 vs 16.93 pixels).
    // Align only a single, small, axis-aligned text run to a physical pixel.
    // Horizontal glyph advances, clip geometry and alpha composition stay intact.
    if (currentState->fillType.isColour()
        && textAndWorldTransform.mat01 == 0.0f
        && textAndWorldTransform.mat10 == 0.0f
        && textAndWorldTransform.mat11 > 0.0f
        && std::all_of (positions.begin(), positions.end(), [&] (const auto& p)
                       { return approximatelyEqual (p.y, positions[0].y); }))
    {
        float dpiX = 96.0f, dpiY = 96.0f;
        deviceContext->GetDpi (&dpiX, &dpiY);
        const auto pixelsPerDip = dpiY / 96.0f;
        const auto physicalEm = font.getHeightInPoints() * textAndWorldTransform.mat11 * pixelsPerDip;
        if (pixelsPerDip > 0.0f && std::isfinite (physicalEm) && physicalEm > 0.0f && physicalEm <= 18.0f)
        {
            const auto baseline = positions[0].transformedBy (textAndWorldTransform).y;
            const auto snapped = std::round (baseline * pixelsPerDip) / pixelsPerDip;
            if (std::isfinite (baseline) && std::isfinite (snapped))
                textAndWorldTransform = textAndWorldTransform.translated (0.0f, snapped - baseline);
        }
    }

    const auto onlyTranslated = textAndWorldTransform.isOnlyTranslation();]=])
    string(FIND "${glyph_original}" "${glyph_original_text}" glyph_position)
    if(glyph_position EQUAL -1)
        message(FATAL_ERROR "Compact-text baseline patch no longer matches JUCE.")
    endif()
    string(REPLACE "${glyph_original_text}" "${glyph_aligned_text}" glyph_result "${glyph_original}")
    set(glyph_existing "")
    if(EXISTS "${patched}/${glyph_relative}")
        file(READ "${patched}/${glyph_relative}" glyph_existing)
    endif()
    if(NOT glyph_existing STREQUAL glyph_result)
        file(WRITE "${patched}/${glyph_relative}" "${glyph_result}")
    endif()
    set(${output} "${patched}" PARENT_SCOPE)
endfunction()
