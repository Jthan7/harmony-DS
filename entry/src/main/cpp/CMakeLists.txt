cmake_minimum_required(VERSION 3.5.0)
project(MyDeepSeek)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(entry SHARED napi_init.cpp deepseek_pow.c)

target_link_libraries(entry PUBLIC libace_napi.z.so)
