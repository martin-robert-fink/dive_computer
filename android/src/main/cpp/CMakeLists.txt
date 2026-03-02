cmake_minimum_required(VERSION 3.22.1)
project("dive_computer_jni" LANGUAGES C CXX)

# ── libdivecomputer (prebuilt static library) ────────────────────────────
#
# Static .a files are linked into our JNI bridge at build time.
# The final libdive_computer_jni.so contains everything — no separate
# libdivecomputer.so to ship. Same approach as iOS/macOS.

add_library(divecomputer STATIC IMPORTED)
set_target_properties(divecomputer PROPERTIES
    IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/libs/${ANDROID_ABI}/libdivecomputer.a"
)

# ── JNI bridge ───────────────────────────────────────────────────────────

add_library(dive_computer_jni SHARED
    jni_bridge.cpp
)

target_include_directories(dive_computer_jni PRIVATE
    ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(dive_computer_jni
    divecomputer
    log
)

set_target_properties(dive_computer_jni PROPERTIES
    C_STANDARD   11
    CXX_STANDARD 17
)