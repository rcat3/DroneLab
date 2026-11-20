# The virtual unit: the firmware's core/, built to run on a computer, with its
# screen in a window, its sound through the computer's, and its Bluetooth
# link to the app over a local socket. Linux only, so far.
#
#   cmake -S platforms/host -B build-host && cmake --build build-host -j
#   build-host/dronelab-unit
#
# See README.md.

cmake_minimum_required(VERSION 3.16)
project(dronelab_unit C CXX)

set(REPO_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)
set(THIRD_PARTY ${REPO_ROOT}/third_party)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

# Like the 1.75" board: a 466x466 round screen
set(RCAT_IMAGE_SIZE 466)
set(RCAT_LARGE_IMAGES ON)       # a computer has room for the big GIFs
# Voice effects, which the comm channel's voice goes through. One played out
# loud feeds back from the computer's speakers without headphones, as the
# board has echo cancelling and this hasn't; they're off on a new unit.
set(RCAT_VOICE_FX ON)

# The comm channel on from the start: it's what a virtual unit is for
set(RCAT_DEFAULT_COMM_ON ON)

option(RCAT_SERIAL_CONSOLE "The development console (core/app/console.h), read from the terminal" OFF)

# LVGL, with platforms/host/config/lv_conf.h
set(LV_BUILD_CONF_PATH ${CMAKE_CURRENT_LIST_DIR}/config/lv_conf.h CACHE PATH "" FORCE)
set(CONFIG_LV_BUILD_DEMOS OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_USE_THORVG OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_USE_THORVG_INTERNAL OFF CACHE BOOL "" FORCE)
set(LV_BUILD_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(${THIRD_PARTY}/lvgl lvgl EXCLUDE_FROM_ALL)
find_package(JPEG REQUIRED)     # LV_USE_LIBJPEG_TURBO
target_link_libraries(lvgl PUBLIC JPEG::JPEG m)

# Mbed TLS, as ESP-IDF has it, for direct comms' encryption: its crypto
# library, built here, as its own CMake wants its test framework too
file(GLOB MBEDTLS_SOURCES ${THIRD_PARTY}/mbedtls/library/*.c)
list(FILTER MBEDTLS_SOURCES EXCLUDE REGEX "/(ssl|x509|pkcs7|net_sockets|debug|mps)[^/]*\\.c$")
add_library(mbedcrypto STATIC ${MBEDTLS_SOURCES})
target_include_directories(mbedcrypto PUBLIC ${THIRD_PARTY}/mbedtls/include PRIVATE ${THIRD_PARTY}/mbedtls/library)

# Opus, for the voice over the comm channel
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
add_subdirectory(${THIRD_PARTY}/opus opus EXCLUDE_FROM_ALL)

# The portable core, with the features chosen in features.cmake
include(${CMAKE_CURRENT_LIST_DIR}/features.cmake)
add_subdirectory(${REPO_ROOT}/core core)
target_include_directories(rcat_core PRIVATE ${THIRD_PARTY}/dr_libs)
target_link_libraries(rcat_core PRIVATE mbedcrypto opus)
target_compile_definitions(rcat_core PRIVATE
    RCAT_HAVE_COMM=1            # the app connects over the socket
    RCAT_HAVE_DIRECT=1          # direct comms, between virtual units over the network
    RCAT_HAVE_FILESYSTEM=1      # images and sounds from a folder, as from the SD card
    RCAT_HAVE_NETWORK=1         # the computer's own
    RCAT_BOARD_NAME="virtual_unit")
if(RCAT_SERIAL_CONSOLE)
    target_compile_definitions(rcat_core PRIVATE RCAT_SERIAL_CONSOLE=1)
endif()

# The firmware's version, as on the boards
execute_process(COMMAND git describe --tags --always --dirty
                WORKING_DIRECTORY ${REPO_ROOT}
                OUTPUT_VARIABLE RCAT_GIT_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT RCAT_GIT_VERSION)
    set(RCAT_GIT_VERSION unknown)
endif()

find_package(X11 REQUIRED)
find_package(Threads REQUIRED)

add_executable(dronelab-unit
    main.c
    hal_audio.c
    hal_direct.c
    hal_display.c
    hal_peer.c
    hal_storage.c
    hal_system.c)
target_include_directories(dronelab-unit PRIVATE ${THIRD_PARTY}/miniaudio)
target_compile_definitions(dronelab-unit PRIVATE RCAT_GIT_VERSION="${RCAT_GIT_VERSION}")
target_compile_options(dronelab-unit PRIVATE -Wall)
# core/ calls the HAL in here, which calls back into LVGL, so link the core
# as a group with it
target_link_libraries(dronelab-unit PRIVATE
    -Wl,--start-group rcat_core lvgl -Wl,--end-group
    X11::X11 Threads::Threads ${CMAKE_DL_LIBS} m)
