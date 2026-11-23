# Marco Movie Edge WebView2 native plugin fragment.
# Idempotently included by flutter/prepare_platform.py into windows/runner/CMakeLists.txt.
# Self-contained COM ABI + dynamic Evergreen WebView2 loader; requires no NuGet packages.

set(MARCO_WEBVIEW2_SOURCES
  "${CMAKE_CURRENT_LIST_DIR}/marco_webview2_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/marco_webview2_plugin.h"
)

if(TARGET ${BINARY_NAME})
  target_sources(${BINARY_NAME} PRIVATE ${MARCO_WEBVIEW2_SOURCES})
  target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_CURRENT_LIST_DIR}")
  target_link_libraries(${BINARY_NAME} PRIVATE
    "ole32.lib"
    "advapi32.lib"
    "shell32.lib"
  )
endif()
