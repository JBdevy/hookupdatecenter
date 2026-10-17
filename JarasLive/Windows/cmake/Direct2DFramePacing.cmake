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
         PATTERN "juce_Direct2DHwndContext_windows.cpp" EXCLUDE)
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
    set(existing "")
    if(EXISTS "${patched}/${relative}")
        file(READ "${patched}/${relative}" existing)
    endif()
    if(NOT existing STREQUAL result)
        file(WRITE "${patched}/${relative}" "${result}")
    endif()
    set(${output} "${patched}" PARENT_SCOPE)
endfunction()
