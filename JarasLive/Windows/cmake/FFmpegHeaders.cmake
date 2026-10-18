# FFmpeg release archives contain a root-level `version` text file. Exposing
# that source root as /I shadows the C++ <version> header on MSVC (VS 2022).
# Copy only the library header trees, preserving their public include paths.
function(catlive_prepare_ffmpeg_headers source destination)
    file(MAKE_DIRECTORY "${destination}")
    foreach(library libavcodec libavformat libavutil libswscale)
        if(NOT IS_DIRECTORY "${source}/${library}")
            message(FATAL_ERROR "Missing FFmpeg header directory: ${source}/${library}")
        endif()
        file(COPY "${source}/${library}" DESTINATION "${destination}"
            FILES_MATCHING PATTERN "*.h")
    endforeach()
endfunction()
