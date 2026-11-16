cmake_minimum_required(VERSION 3.5.0)
project(boxtone_audiodec)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(audiodec SHARED
    audiodec.cpp
)

target_include_directories(audiodec PRIVATE ${NATIVE_ROOT})

# libace_napi.z.so：NAPI 框架
# 其余四个：解封装（AVSource / AVDemuxer）与音频解码（AudioCodec）
target_link_libraries(audiodec PUBLIC
    libace_napi.z.so
    libnative_media_avsource.so
    libnative_media_avdemuxer.so
    libnative_media_acodec.so
    libnative_media_codecbase.so
    libnative_media_core.so
)
