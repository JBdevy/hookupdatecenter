include(FetchContent)
# Exact upstream archives, verified before compiling the Windows presentation.
FetchContent_Declare(catlive_imgui
    URL https://codeload.github.com/ocornut/imgui/tar.gz/f1cc2ae15e53a861a874c3034aae6798fde194ab
    URL_HASH SHA256=f30be7f3e2136615b1848a9afb72f6dfd8a60820ddf1c1a85997bf3b722e7cfc
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(catlive_imgui)
add_library(CatLiveImGui STATIC
    "${catlive_imgui_SOURCE_DIR}/imgui.cpp"
    "${catlive_imgui_SOURCE_DIR}/imgui_draw.cpp"
    "${catlive_imgui_SOURCE_DIR}/imgui_tables.cpp"
    "${catlive_imgui_SOURCE_DIR}/imgui_widgets.cpp"
    "${catlive_imgui_SOURCE_DIR}/backends/imgui_impl_win32.cpp"
    "${catlive_imgui_SOURCE_DIR}/backends/imgui_impl_dx11.cpp")
target_include_directories(CatLiveImGui PUBLIC "${catlive_imgui_SOURCE_DIR}")
target_compile_definitions(CatLiveImGui PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(CatLiveImGui PRIVATE d3d11 d3dcompiler dxgi dwmapi)
target_compile_options(CatLiveImGui PRIVATE /utf-8)
target_sources(CatLive PRIVATE Source/ImGuiFrontendHost.cpp Source/ImGuiFrontendView.cpp Source/ImGuiTimeline.cpp)
target_include_directories(CatLive PRIVATE "${CATLIVEROOT}/WindowsNative/ThirdParty")
target_compile_definitions(CatLive PRIVATE CATLIVE_IMGUI_FRONTEND=1)
target_link_libraries(CatLive PRIVATE CatLiveImGui shell32)
add_custom_command(TARGET CatLive POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:CatLive>/Licenses/ImGui" "$<TARGET_FILE_DIR:CatLive>/fonts"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${catlive_imgui_SOURCE_DIR}/LICENSE.txt" "$<TARGET_FILE_DIR:CatLive>/Licenses/ImGui/LICENSE.txt"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CATLIVEROOT}/Resources/Fonts/Inter" "$<TARGET_FILE_DIR:CatLive>/fonts")
install(FILES "${catlive_imgui_SOURCE_DIR}/LICENSE.txt" DESTINATION Licenses/ImGui)
install(DIRECTORY "${CATLIVEROOT}/Resources/Fonts/Inter/" DESTINATION fonts)
