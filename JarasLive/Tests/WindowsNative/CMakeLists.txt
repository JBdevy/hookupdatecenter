cmake_minimum_required(VERSION 3.16)
project(CatLiveImGuiFrontendTests LANGUAGES CXX)

# Configure standalone with -DCATLIVE_IMGUI_SOURCE=/path/to/pinned/imgui for
# an offline build. Otherwise FetchContent retrieves the production revision.
set(CATLIVE_IMGUI_SOURCE "" CACHE PATH "Existing Dear ImGui source directory")
if(NOT CATLIVE_IMGUI_SOURCE)
    include(FetchContent)
    FetchContent_Declare(catlive_imgui
        GIT_REPOSITORY https://github.com/ocornut/imgui.git
        GIT_TAG f1cc2ae15e53a861a874c3034aae6798fde194ab)
    FetchContent_MakeAvailable(catlive_imgui)
    set(CATLIVE_IMGUI_SOURCE "${catlive_imgui_SOURCE_DIR}")
endif()
get_filename_component(CATLIVE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
add_executable(ImGuiFrontendTests
    ImGuiFrontendTests.cpp
    "${CATLIVE_ROOT}/Windows/Source/ImGuiTimeline.cpp"
    "${CATLIVE_ROOT}/Windows/Source/ImGuiFrontendView.cpp"
    "${CATLIVE_IMGUI_SOURCE}/imgui.cpp"
    "${CATLIVE_IMGUI_SOURCE}/imgui_draw.cpp"
    "${CATLIVE_IMGUI_SOURCE}/imgui_tables.cpp"
    "${CATLIVE_IMGUI_SOURCE}/imgui_widgets.cpp")
target_compile_features(ImGuiFrontendTests PRIVATE cxx_std_17)
target_compile_definitions(ImGuiFrontendTests PRIVATE IMGUI_ENABLE_TEST_ENGINE)
target_include_directories(ImGuiFrontendTests PRIVATE
    "${CATLIVE_ROOT}/Windows/Source" "${CATLIVE_ROOT}/WindowsNative/ThirdParty" "${CATLIVE_IMGUI_SOURCE}")
if(MSVC)
    target_compile_options(ImGuiFrontendTests PRIVATE /W4 /utf-8 /EHsc)
else()
    target_compile_options(ImGuiFrontendTests PRIVATE -Wall -Wextra -Wpedantic)
endif()
enable_testing()
add_test(NAME ImGuiFrontendTests COMMAND ImGuiFrontendTests)
