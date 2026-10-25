cmake_minimum_required(VERSION 3.16)
project(stevedore LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

find_package(MavericksShipyard REQUIRED)
if(APPLE)
  set(MAVERICKS_REQUIRE_APPLECLANG OFF)
  include(Mavericks)
endif()

file(STRINGS "${CMAKE_SOURCE_DIR}/components/zlib/version" STEVEDORE_ZLIB_VERSION LIMIT_COUNT 1)
file(STRINGS "${CMAKE_SOURCE_DIR}/components/zlib/sha256" STEVEDORE_ZLIB_SHA256 LIMIT_COUNT 1)
set(ZLIB_SRC "${CMAKE_BINARY_DIR}/zlib-src")
set(_zlib_stamp "${STEVEDORE_ZLIB_VERSION} ${STEVEDORE_ZLIB_SHA256}")
set(_zlib_have "")
if(EXISTS "${ZLIB_SRC}/.stevedore-pin")
  file(STRINGS "${ZLIB_SRC}/.stevedore-pin" _zlib_have LIMIT_COUNT 1)
endif()
if(NOT _zlib_have STREQUAL _zlib_stamp)
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E env "SHIPYARD_SCRIPTS=${MavericksShipyard_DIR}/scripts"
            sh "${CMAKE_SOURCE_DIR}/build/fetch-zlib.sh" "${ZLIB_SRC}"
    RESULT_VARIABLE _zlib_rc OUTPUT_QUIET)
  if(NOT _zlib_rc EQUAL 0)
    message(FATAL_ERROR "build/fetch-zlib.sh could not provide zlib ${STEVEDORE_ZLIB_VERSION} (exit ${_zlib_rc})")
  endif()
  file(WRITE "${ZLIB_SRC}/.stevedore-pin" "${_zlib_stamp}\n")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${CMAKE_SOURCE_DIR}/components/zlib/version" "${CMAKE_SOURCE_DIR}/components/zlib/sha256")

add_library(stevedore_zlib STATIC
  ${ZLIB_SRC}/adler32.c ${ZLIB_SRC}/compress.c ${ZLIB_SRC}/crc32.c ${ZLIB_SRC}/deflate.c
  ${ZLIB_SRC}/infback.c ${ZLIB_SRC}/inffast.c ${ZLIB_SRC}/inflate.c ${ZLIB_SRC}/inftrees.c
  ${ZLIB_SRC}/trees.c ${ZLIB_SRC}/uncompr.c ${ZLIB_SRC}/zutil.c)
target_include_directories(stevedore_zlib SYSTEM PUBLIC "${ZLIB_SRC}")
set_target_properties(stevedore_zlib PROPERTIES C_EXTENSIONS ON)

configure_file(src/zlib_pin.h.in "${CMAKE_BINARY_DIR}/generated/zlib_pin.h" @ONLY)

set(STEVEDORE_SOURCES src/main.c src/buf.c src/gz.c)

add_executable(stevedore ${STEVEDORE_SOURCES})
target_include_directories(stevedore PRIVATE src "${CMAKE_BINARY_DIR}/generated")
target_link_libraries(stevedore PRIVATE stevedore_zlib)

add_executable(stevedore-pin-mismatch ${STEVEDORE_SOURCES})
target_include_directories(stevedore-pin-mismatch PRIVATE src "${CMAKE_BINARY_DIR}/generated")
target_compile_definitions(stevedore-pin-mismatch PRIVATE FP_ZLIB_PINNED="0.0.0-not-the-pin")
target_link_libraries(stevedore-pin-mismatch PRIVATE stevedore_zlib)

if(APPLE)
  mavericks_assert_binary_compatible(stevedore)
endif()
