cmake_minimum_required(VERSION 3.24)
project(CatLiveWindows VERSION 1.1.0 LANGUAGES C CXX)
set(CATLIVE_VERSION "1.02" CACHE STRING "Public CatLive version (X.XX)")
if(NOT CATLIVE_VERSION MATCHES "^[0-9]+\\.[0-9][0-9]$")
    message(FATAL_ERROR "CATLIVE_VERSION must use X.XX format.")
endif()
set(CATLIVE_BINARY_VERSION "${CATLIVE_VERSION}.0")
if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "CatLive Windows requires Windows x64.")
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(CATLIVEROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(CATLIVE_JUCE_SOURCE "" CACHE PATH "Existing JUCE 8.0.15 source directory")
if(NOT CATLIVE_JUCE_SOURCE)
    include(FetchContent)
    FetchContent_Declare(JUCE GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
        GIT_TAG 8.0.15 GIT_SHALLOW TRUE SOURCE_SUBDIR catlive-download-only)
    FetchContent_MakeAvailable(JUCE)
    set(CATLIVE_JUCE_SOURCE "${juce_SOURCE_DIR}")
endif()
# Isolate the presentation fix from the user's shared JUCE checkout/cache.
include(cmake/Direct2DFramePacing.cmake)
catlive_prepare_juce("${CATLIVE_JUCE_SOURCE}" CATLIVE_PATCHED_JUCE)
add_subdirectory("${CATLIVE_PATCHED_JUCE}" "${CMAKE_BINARY_DIR}/juce-framepaced")
add_library(CatLiveCore STATIC "${CATLIVEROOT}/Core/Project/Models.cpp"
    "${CATLIVEROOT}/Core/Transport/Engine.cpp" "${CATLIVEROOT}/Core/Import/TrackTaxonomy.cpp")
target_include_directories(CatLiveCore PUBLIC "${CATLIVEROOT}/Core")
target_compile_options(CatLiveCore PRIVATE /utf-8 /W4)
add_library(CatLiveLoudness STATIC "${CATLIVEROOT}/Core/ThirdParty/EBUR128/ebur128.c")
target_include_directories(CatLiveLoudness PRIVATE "${CATLIVEROOT}/Core/ThirdParty/EBUR128/queue")
target_compile_definitions(CatLiveLoudness PRIVATE _USE_MATH_DEFINES)
# Keep LAME replaceable as a DLL; no proprietary Media Foundation MP3 restrictions.
set(CATLIVE_LAME_ROOT "${CATLIVEROOT}/Core/ThirdParty/Lame")
set(CATLIVE_LAME_SOURCES bitstream encoder fft gain_analysis id3tag lame newmdct presets
    psymodel quantize quantize_pvt reservoir set_get tables takehiro util vbrquantize VbrTag version)
set(CATLIVE_LAME_FILES)
foreach(name IN LISTS CATLIVE_LAME_SOURCES)
    list(APPEND CATLIVE_LAME_FILES "${CATLIVE_LAME_ROOT}/${name}.c")
endforeach()
add_library(CatLiveLame SHARED ${CATLIVE_LAME_FILES})
set_target_properties(CatLiveLame PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
target_include_directories(CatLiveLame PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/Lame" "${CATLIVE_LAME_ROOT}")
target_compile_definitions(CatLiveLame PRIVATE HAVE_CONFIG_H _CRT_SECURE_NO_WARNINGS)
target_compile_options(CatLiveLame PRIVATE /utf-8)
juce_add_binary_data(CatLiveAssets SOURCES
    Assets/Localization/English.json Assets/Localization/Portuguese.json
    Assets/Localization/StageDefaults.json Assets/Localization/StageFields.json
    Assets/Localization/InstrumentCatalog.json Assets/Teleprompter.html
    "${CATLIVEROOT}/Apple/Resources/Click.mp3"
    "${CATLIVEROOT}/Resources/Fonts/Inter/Inter-Regular.ttf"
    "${CATLIVEROOT}/Resources/Fonts/Inter/Inter-Medium.ttf"
    "${CATLIVEROOT}/Resources/Fonts/Inter/Inter-SemiBold.ttf"
    "${CATLIVEROOT}/Resources/Fonts/Inter/Inter-Bold.ttf"
    "${CATLIVEROOT}/Resources/Fonts/Inter/Inter-BoldItalic.ttf"
    "${CATLIVEROOT}/Apple/Assets.xcassets/CatLiveSplash.imageset/CatLiveSplash.png"
    "${CATLIVEROOT}/Apple/Assets.xcassets/CatLiveIcon.appiconset/icon-256@1x.png")
juce_add_gui_app(CatLive PRODUCT_NAME "CatLive" COMPANY_NAME "Hook Developer"
    BUNDLE_ID "com.hookdeveloper.catlive" VERSION "${CATLIVE_BINARY_VERSION}"
    ICON_BIG "${CATLIVEROOT}/Apple/Assets.xcassets/CatLiveIcon.appiconset/icon-256@1x.png")
juce_generate_juce_header(CatLive)
add_library(CatLiveVST3 STATIC "${CATLIVEROOT}/WindowsNative/Source/VST3Host.cpp"
    "${CATLIVEROOT}/Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp"
    "${CATLIVEROOT}/Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp"
    "${CATLIVEROOT}/Core/ThirdParty/VST3/pluginterfaces/base/coreiids.cpp")
target_include_directories(CatLiveVST3 PUBLIC "${CATLIVEROOT}/WindowsNative/Source" PRIVATE "${CATLIVEROOT}/Core/ThirdParty/VST3")
target_compile_definitions(CatLiveVST3 PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(CatLiveVST3 PRIVATE /utf-8)
target_link_libraries(CatLiveVST3 PRIVATE ole32 user32)
add_executable(CatLiveVST3Probe "${CATLIVEROOT}/WindowsNative/Tests/VST3Probe.cpp")
target_include_directories(CatLiveVST3Probe PRIVATE "${CATLIVEROOT}/WindowsNative/ThirdParty")
target_link_libraries(CatLiveVST3Probe PRIVATE CatLiveVST3)
add_dependencies(CatLive CatLiveVST3Probe)
add_custom_command(TARGET CatLive POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "$<TARGET_FILE:CatLiveVST3Probe>" "$<TARGET_FILE_DIR:CatLive>/CatLiveVST3Probe.exe")
install(TARGETS CatLiveVST3Probe RUNTIME DESTINATION .)
add_custom_command(TARGET CatLive POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CATLIVEROOT}/Core/ThirdParty/VST3/VST3-LICENSE.txt" "$<TARGET_FILE_DIR:CatLive>/VST3-LICENSE.txt")
install(FILES "${CATLIVEROOT}/Core/ThirdParty/VST3/VST3-LICENSE.txt" DESTINATION .)
set(CATLIVE_APP_OUTPUT_DIRECTORY "" CACHE PATH "Optional application output directory for local validation builds")
if(CATLIVE_APP_OUTPUT_DIRECTORY)
    set_target_properties(CatLive PROPERTIES RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CATLIVE_APP_OUTPUT_DIRECTORY}")
endif()
target_sources(CatLive PRIVATE Source/Main.cpp Source/Session.cpp Source/ProjectCodec.cpp Source/ProjectBrowser.cpp
    Source/ProjectMigration.cpp Source/LogicProjectImporter.cpp Source/Typography.cpp Source/AdvancedPanel.cpp
    Source/AudioEngine.cpp Source/Instrument.cpp Source/Projection.cpp Source/native_video_decoder_ffmpeg.cpp Source/NativeFX.cpp Source/Lighting.cpp Source/Auth.cpp Source/Workspace.cpp Source/Tests.cpp Source/MP3Writer.cpp Source/AudioFormats.cpp Source/MediaSource.cpp
    "${CATLIVEROOT}/WindowsNative/Source/AudioFile.cpp"
    "${CATLIVEROOT}/WindowsNative/Source/StemSeparator.cpp"
    ThirdParty/QRCode/qrcodegen.cpp
    ThirdParty/Monocypher/monocypher.c ThirdParty/Monocypher/monocypher-ed25519.c)
target_include_directories(CatLive PRIVATE ThirdParty/Monocypher)
find_path(CATLIVE_FFMPEG_INCLUDE_DIR NAMES libavcodec/avcodec.h
    HINTS "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/ffmpeg-8.1.2")
if(NOT CATLIVE_FFMPEG_INCLUDE_DIR)
    include(FetchContent)
    FetchContent_Declare(catlive_ffmpeg_headers
        URL "https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz"
        URL_HASH SHA256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_GetProperties(catlive_ffmpeg_headers)
    if(NOT catlive_ffmpeg_headers_POPULATED)
        FetchContent_MakeAvailable(catlive_ffmpeg_headers)
    endif()
    set(CATLIVE_FFMPEG_INCLUDE_DIR "${catlive_ffmpeg_headers_SOURCE_DIR}")
endif()
target_include_directories(CatLive PRIVATE ThirdParty/FFmpeg/include "${CATLIVE_FFMPEG_INCLUDE_DIR}")
target_link_libraries(CatLive PRIVATE CatLiveCore CatLiveLoudness CatLiveLame CatLiveAssets CatLiveVST3 juce::juce_audio_utils
    juce::juce_dsp juce::juce_osc juce::juce_cryptography d2d1 dwrite bcrypt crypt32 normaliz dnsapi comctl32 psapi mfplat mfreadwrite mfuuid mf d3d11 dxgi winmm msimg32
    juce::juce_recommended_config_flags juce::juce_recommended_warning_flags)
target_compile_definitions(CatLive PRIVATE JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0
    JUCE_APPLICATION_NAME_STRING="CatLive" JUCE_APPLICATION_VERSION_STRING="${CATLIVE_VERSION}"
    JUCE_ASIO=1 JUCE_WASAPI=1 JUCE_USE_MP3AUDIOFORMAT=1 JUCE_WIN_PER_MONITOR_DPI_AWARE=1
    JUCE_MODAL_LOOPS_PERMITTED=0 NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
target_compile_options(CatLive PRIVATE /utf-8 /bigobj)
enable_testing()
foreach(name Core PlaybackScope SmoothSeek MultiLoop RegionBoundaryOwnership RegionOnsetOwnership TempoOwnership Timecode TimecodePlayback ClickTrack)
    add_executable(${name}Tests "${CATLIVEROOT}/Tests/Core/${name}Tests.cpp")
    target_link_libraries(${name}Tests PRIVATE CatLiveCore)
    target_compile_options(${name}Tests PRIVATE /utf-8)
    add_test(NAME ${name}Tests COMMAND ${name}Tests)
endforeach()
add_test(NAME WindowsIntegration COMMAND CatLive --self-test "${CMAKE_BINARY_DIR}/test-results")
set_tests_properties(WindowsIntegration PROPERTIES TIMEOUT 90)
find_program(CATLIVE_NODE node)
if(CATLIVE_NODE)
    add_test(NAME IndependentDocumentCodec COMMAND "${CATLIVE_NODE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/verify-project-compatibility.cjs" "${CMAKE_BINARY_DIR}/test-results" "$<TARGET_FILE:CatLive>")
    set_tests_properties(IndependentDocumentCodec PROPERTIES DEPENDS WindowsIntegration)
    add_test(NAME IndependentRemoteCipher COMMAND "${CATLIVE_NODE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/verify-remote-cipher.cjs" "${CMAKE_BINARY_DIR}/test-results")
    set_tests_properties(IndependentRemoteCipher PROPERTIES DEPENDS WindowsIntegration)
    add_test(NAME DAWImportCompatibility COMMAND "${CATLIVE_NODE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/verify-daw-imports.cjs" "$<TARGET_FILE:CatLive>" "${CMAKE_BINARY_DIR}/migration-tests")
    set_tests_properties(DAWImportCompatibility PROPERTIES TIMEOUT 120)
endif()
install(TARGETS CatLive RUNTIME DESTINATION . RESOURCE DESTINATION .)

# Local validation output and installed product both carry the replaceable encoder,
# license, exact upstream source and the build configuration needed to rebuild it.
add_custom_command(TARGET CatLive POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:CatLiveLame>" "$<TARGET_FILE_DIR:CatLive>/CatLiveLame.dll"
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:CatLive>/Licenses/LAME" "$<TARGET_FILE_DIR:CatLive>/Licenses/dr_libs"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CATLIVE_LAME_ROOT}/COPYING" "$<TARGET_FILE_DIR:CatLive>/Licenses/LAME/COPYING"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CATLIVE_LAME_ROOT}/lame-3.100-source.tar.gz" "$<TARGET_FILE_DIR:CatLive>/Licenses/LAME/lame-3.100-source.tar.gz"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/Lame/config.h" "$<TARGET_FILE_DIR:CatLive>/Licenses/LAME/config.h"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/Lame/BUILD.txt" "$<TARGET_FILE_DIR:CatLive>/Licenses/LAME/BUILD.txt"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CATLIVEROOT}/WindowsNative/ThirdParty/dr_libs/LICENSE" "$<TARGET_FILE_DIR:CatLive>/Licenses/dr_libs/LICENSE"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/THIRD-PARTY-NOTICES.txt" "$<TARGET_FILE_DIR:CatLive>/THIRD-PARTY-NOTICES.txt")
install(TARGETS CatLiveLame RUNTIME DESTINATION .)
install(FILES "${CATLIVE_LAME_ROOT}/COPYING" "${CATLIVE_LAME_ROOT}/lame-3.100-source.tar.gz"
    "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/Lame/config.h" "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/Lame/BUILD.txt" DESTINATION Licenses/LAME)
install(FILES "${CATLIVEROOT}/WindowsNative/ThirdParty/dr_libs/LICENSE" DESTINATION Licenses/dr_libs)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/THIRD-PARTY-NOTICES.txt" DESTINATION .)

# CatStem DSP/protocol tests do not load a model or require physical audio.
add_executable(CatStemCoreTests "${CATLIVEROOT}/WindowsNative/Tests/StemSeparatorCoreTests.cpp")
target_compile_options(CatStemCoreTests PRIVATE /utf-8)
add_test(NAME CatStemCoreTests COMMAND CatStemCoreTests)

add_executable(CatStemProcessTests "${CATLIVEROOT}/WindowsNative/Tests/StemSeparatorProcessTests.cpp"
    "${CATLIVEROOT}/WindowsNative/Source/StemSeparator.cpp")
target_compile_definitions(CatStemProcessTests PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
target_compile_options(CatStemProcessTests PRIVATE /utf-8)
