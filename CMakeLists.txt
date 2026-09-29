cmake_minimum_required(VERSION 3.20 FATAL_ERROR)

project(fakefish CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(FAKELUA_BUILD_TESTS OFF CACHE BOOL "Build tests" FORCE)
set(FAKELUA_BUILD_BENCHMARKS OFF CACHE BOOL "Build benchmarks" FORCE)

add_subdirectory(third_party/fakelua)

add_executable(fakefish host/main.cpp)

target_include_directories(fakefish PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/fakelua/include
)

IF (WIN32)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,--export-all-symbols")
ELSEIF (APPLE)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,-export_dynamic")
ELSE ()
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,-E")
ENDIF ()

target_link_libraries(fakefish PRIVATE fakelua)
