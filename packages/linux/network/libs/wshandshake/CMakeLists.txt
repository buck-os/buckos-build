cmake_minimum_required(VERSION 3.10)
project(wshandshake VERSION 1.0.0 LANGUAGES CXX)

add_library(wshandshake INTERFACE)
target_include_directories(wshandshake INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)

install(FILES libwshandshake.hpp DESTINATION include)
install(TARGETS wshandshake EXPORT wshandshakeTargets)
install(EXPORT wshandshakeTargets
    FILE wshandshakeConfig.cmake
    NAMESPACE wshandshake::
    DESTINATION lib/cmake/wshandshake
)
