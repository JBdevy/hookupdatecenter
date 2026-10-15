cmake_minimum_required(VERSION 3.24)
project(CatLiveWindows VERSION 1.1.0 LANGUAGES C CXX)
set(CATLIVE_VERSION "1.01" CACHE STRING "Public CatLive version (X.XX)")
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
if(CATLIVE_JUCE_SOURCE)
    add_subdirectory("${CATLIVE_JUCE_SOURCE}" "${CMAKE_BINARY_DIR}/juce")
else()
    include(FetchContent)
    FetchContent_Declare(JUCE GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
        GIT_TAG 8.0.15 GIT_SHALLOW TRUE)
    FetchContent_MakeAvailable(JUCE)
endif()
add_library(CatLiveCore STATIC "${CATLIVEROOT}/Core/Project/Models.cpp"
    "${CATLIVEROOT}/Core/Transport/Engine.cpp" "${CATLIVEROOT}/Core/Import/TrackTaxonomy.cpp")
target_include_directories(CatLiveCore PUBLIC "${CATLIVEROOT}/Core")
target_compile_options(CatLiveCore PRIVATE /utf-8 /W4)
add_library(CatLiveLoudness STATIC "${CATLIVEROOT}/Core/ThirdParty/EBUR128/ebur128.c")
target_include_directories(CatLiveLoudness PRIVATE "${CATLIVEROOT}/Core/ThirdParty/EBUR128/queue")
target_compile_definitions(CatLiveLoudness PRIVATE _USE_MATH_DEFINES)
juce_add_binary_data(CatLiveAssets SOURCES
    Assets/Localization/English.json Assets/Localization/Portuguese.json
    Assets/Localization/StageDefaults.json Assets/Localization/StageFields.json
    Assets/Localization/InstrumentCatalog.json
    "${CATLIVEROOT}/Apple/Resources/Click.mp3"
    Assets/Fonts/Figtree-Regular.ttf Assets/Fonts/Figtree-Medium.ttf Assets/Fonts/Figtree-SemiBold.ttf
    Assets/Fonts/Figtree-Bold.ttf Assets/Fonts/Figtree-BoldItalic.ttf
    "${CATLIVEROOT}/Apple/Assets.xcassets/CatLiveSplash.imageset/CatLiveSplash.png"
    "${CATLIVEROOT}/Apple/Assets.xcassets/CatLiveIcon.appiconset/icon-256@1x.png")
juce_add_gui_app(CatLive PRODUCT_NAME "CatLive" COMPANY_NAME "Hook Developer"
    BUNDLE_ID "com.hookdeveloper.catlive" VERSION "${CATLIVE_BINARY_VERSION}"
    ICON_BIG "${CATLIVEROOT}/Apple/Assets.xcassets/CatLiveIcon.appiconset/icon-256@1x.png")
juce_generate_juce_header(CatLive)
target_sources(CatLive PRIVATE Source/Main.cpp Source/Session.cpp Source/ProjectCodec.cpp Source/ProjectBrowser.cpp
    Source/ProjectMigration.cpp Source/LogicProjectImporter.cpp Source/Typography.cpp Source/AdvancedPanel.cpp
    Source/AudioEngine.cpp Source/Instrument.cpp Source/Projection.cpp Source/NativeFX.cpp Source/Lighting.cpp Source/Auth.cpp Source/Workspace.cpp Source/Tests.cpp Source/MP3Writer.cpp
    ThirdParty/Monocypher/monocypher.c ThirdParty/Monocypher/monocypher-ed25519.c)
target_include_directories(CatLive PRIVATE ThirdParty/Monocypher)
target_link_libraries(CatLive PRIVATE CatLiveCore CatLiveLoudness CatLiveAssets juce::juce_audio_utils
    juce::juce_dsp juce::juce_osc juce::juce_video juce::juce_cryptography bcrypt crypt32 normaliz dnsapi mfplat mfreadwrite mfuuid mf
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
