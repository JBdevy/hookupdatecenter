cmake_minimum_required(VERSION 3.16)
project(JarasLiveCore VERSION 1.1.0 LANGUAGES CXX)
add_library(JarasLiveCore Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp)
target_compile_features(JarasLiveCore PUBLIC cxx_std_17)
target_include_directories(JarasLiveCore PUBLIC Core)
add_executable(JarasCoreTests Tests/Core/CoreTests.cpp)
target_link_libraries(JarasCoreTests PRIVATE JarasLiveCore)
enable_testing()
add_test(NAME JarasCoreTests COMMAND JarasCoreTests)

add_executable(SmoothSeekTests Tests/Core/SmoothSeekTests.cpp)
target_link_libraries(SmoothSeekTests PRIVATE JarasLiveCore)
add_test(NAME SmoothSeekTests COMMAND SmoothSeekTests)

add_executable(ProjectSyncTests Tests/Core/ProjectSyncTests.cpp)
target_link_libraries(ProjectSyncTests PRIVATE JarasLiveCore)
add_test(NAME ProjectSyncTests COMMAND ProjectSyncTests)

find_package(Threads REQUIRED)
add_executable(RealtimeMIDIQueueTests Tests/Core/RealtimeMIDIQueueTests.cpp)
target_compile_features(RealtimeMIDIQueueTests PRIVATE cxx_std_17)
target_link_libraries(RealtimeMIDIQueueTests PRIVATE Threads::Threads)
# The queue tests exercise operations inside assertions, also in Release CI.
if(MSVC)
    target_compile_options(RealtimeMIDIQueueTests PRIVATE /UNDEBUG)
else()
    target_compile_options(RealtimeMIDIQueueTests PRIVATE -UNDEBUG)
endif()
add_test(NAME RealtimeMIDIQueueTests COMMAND RealtimeMIDIQueueTests)

# The Windows item magnet is pure C++ and also runs on macOS/Linux CI.
add_executable(WindowsTimelineSnapTests Tests/Core/WindowsTimelineSnapTests.cpp)
target_compile_features(WindowsTimelineSnapTests PRIVATE cxx_std_17)
add_test(NAME WindowsTimelineSnapTests COMMAND WindowsTimelineSnapTests)
