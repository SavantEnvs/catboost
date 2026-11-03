# Wrapper project: configures only the catboost libraries the fuzz harnesses need (dirs.txt)
# instead of the whole tree, whose default configure needs a JDK, SWIG, Cython and numpy.
cmake_minimum_required(VERSION 3.15)
project(CATBOOST_MAYHEM LANGUAGES C CXX ASM)

get_filename_component(CATBOOST_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(PROJECT_SOURCE_DIR "${CATBOOST_SRC}")

set(BUILD_SHARED_LIBS Off)
# Forced here, not just -D'd in build.sh: cmake drops -D cache entries when it wipes the cache because
# the compiler path changed between the image build (ccache masquerade) and a plain re-run.
set(CUSTOM_ALLOCATORS Off CACHE BOOL "system allocator for sanitizer builds" FORCE)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_EXTENSIONS Off)

list(APPEND CMAKE_MODULE_PATH ${PROJECT_BINARY_DIR} ${CATBOOST_SRC}/cmake)
include_directories(${CATBOOST_SRC} ${PROJECT_BINARY_DIR})

cmake_policy(SET CMP0104 OLD)

include(${CATBOOST_SRC}/cmake/global_flags.cmake)
include(${CATBOOST_SRC}/cmake/global_vars.cmake)
include(${CATBOOST_SRC}/cmake/archive.cmake)
include(${CATBOOST_SRC}/cmake/common.cmake)
include(${CATBOOST_SRC}/cmake/fbs.cmake)
include(${CATBOOST_SRC}/cmake/protobuf.cmake)
include(${CATBOOST_SRC}/cmake/recursive_library.cmake)
include(${CATBOOST_SRC}/cmake/shared_libs.cmake)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/dirs.txt" CATBOOST_DIRS)
foreach(d IN LISTS CATBOOST_DIRS)
  if(NOT d STREQUAL "")
    add_subdirectory(${CATBOOST_SRC}/${d} ${CMAKE_BINARY_DIR}/${d})
  endif()
endforeach()

# TStringUseCow lives in build-cow-on, and atexit/pthread_atfork in libc_nonshared.a (not pulled in by
# -nodefaultlibs when no sanitizer runtime provides them); both must follow libyutil.a on every link line.
target_link_libraries(yutil PUBLIC build-cow-on c_nonshared)

# -nodefaultlibs in common.cmake: host tools need libc spelled out.
foreach(t IN ITEMS enum_parser)
  if(TARGET ${t})
    target_link_libraries(${t} PRIVATE c m dl rt)
  endif()
endforeach()

# One libFuzzer binary and one run-once reproducer (-standalone) per harness.
function(mayhem_harness name)
  cmake_parse_arguments(H "" "" "SRCS;LIBS" ${ARGN})
  set(srcs ${CATBOOST_SRC}/mayhem/lsan_off.cc)
  foreach(s IN LISTS H_SRCS)
    list(APPEND srcs ${CATBOOST_SRC}/${s})
  endforeach()
  set(syslibs c m dl rt)
  add_executable(${name} ${srcs})
  target_link_libraries(${name} PRIVATE ${H_LIBS} $ENV{LIB_FUZZING_ENGINE} ${syslibs})
  add_executable(${name}-standalone ${srcs} $ENV{STANDALONE_FUZZ_MAIN})
  target_link_libraries(${name}-standalone PRIVATE ${H_LIBS} ${syslibs})
endfunction()

mayhem_harness(fuzz_cgiparam SRCS library/cpp/cgiparam/fuzz/main.cpp LIBS library-cpp-cgiparam)
mayhem_harness(fuzz_http_io SRCS library/cpp/http/io/fuzz/main.cpp LIBS cpp-http-io)
mayhem_harness(fuzz_json SRCS library/cpp/json/fuzzy_test/main.cpp LIBS library-cpp-json)
mayhem_harness(fuzz_base64_roundtrip SRCS library/cpp/string_utils/base64/fuzz/lib/main.cpp LIBS cpp-string_utils-base64)
mayhem_harness(fuzz_base64_uneven SRCS library/cpp/string_utils/base64/fuzz/uneven/main.cpp LIBS cpp-string_utils-base64)
mayhem_harness(fuzz_flat_hash_dense_map
  SRCS library/cpp/containers/flat_hash/fuzz/dense_map_fuzz/fuzz.cpp library/cpp/containers/flat_hash/fuzz/fuzz_common/fuzz_common.cpp
  LIBS cpp-containers-flat_hash)
mayhem_harness(fuzz_flat_hash_flat_map
  SRCS library/cpp/containers/flat_hash/fuzz/flat_map_fuzz/fuzz.cpp library/cpp/containers/flat_hash/fuzz/fuzz_common/fuzz_common.cpp
  LIBS cpp-containers-flat_hash)
mayhem_harness(fuzz_rb_tree SRCS library/cpp/containers/intrusive_rb_tree/fuzz/rb_tree_fuzzing.cpp LIBS cpp-containers-intrusive_rb_tree)

# Known-answer self-test for mayhem/test.sh (built with the project's normal flags, see build.sh).
add_executable(catboost_selftest EXCLUDE_FROM_ALL ${CATBOOST_SRC}/mayhem/selftest.cpp)
target_link_libraries(catboost_selftest PRIVATE
  cpp-http-io library-cpp-json library-cpp-cgiparam cpp-string_utils-base64 cpp-containers-flat_hash c m dl rt)
