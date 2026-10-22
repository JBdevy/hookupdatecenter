# Presentation SDK only. Audio continues through the existing native engine.
# Pin and verify the SDK; the user's installed Evergreen Runtime is not downloaded
# or modified by the application.
set(CATLIVE_WEBVIEW2_SDK "" CACHE PATH "Existing Microsoft.Web.WebView2 1.0.2903.40 NuGet SDK")
if(NOT CATLIVE_WEBVIEW2_SDK)
    include(FetchContent)
    FetchContent_Declare(catlive_webview2_sdk
        URL "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.2903.40/microsoft.web.webview2.1.0.2903.40.nupkg"
        URL_HASH SHA256=ef128016dd1e51c59178c827ed5b8aa3322c57afa8675d930f8109505542ad74
        DOWNLOAD_NAME "microsoft.web.webview2.1.0.2903.40.zip"
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        SOURCE_SUBDIR catlive-download-only)
    FetchContent_MakeAvailable(catlive_webview2_sdk)
    set(CATLIVE_WEBVIEW2_SDK "${catlive_webview2_sdk_SOURCE_DIR}")
endif()
if(NOT EXISTS "${CATLIVE_WEBVIEW2_SDK}/build/native/include/WebView2.h"
   OR NOT EXISTS "${CATLIVE_WEBVIEW2_SDK}/build/native/x64/WebView2LoaderStatic.lib")
    message(FATAL_ERROR "CATLIVE_WEBVIEW2_SDK must point to the extracted WebView2 NuGet SDK.")
endif()
add_library(CatLiveWebView2Loader STATIC IMPORTED)
set_target_properties(CatLiveWebView2Loader PROPERTIES
    IMPORTED_LOCATION "${CATLIVE_WEBVIEW2_SDK}/build/native/x64/WebView2LoaderStatic.lib"
    INTERFACE_INCLUDE_DIRECTORIES "${CATLIVE_WEBVIEW2_SDK}/build/native/include"
    INTERFACE_LINK_LIBRARIES "version;shlwapi;ole32;user32;advapi32;gdi32")
