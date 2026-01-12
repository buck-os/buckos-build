cmake_minimum_required(VERSION 3.10)
project(ThreadPool VERSION 1.0.0 LANGUAGES CXX)

# Header-only library
# Install the header file
install(FILES ThreadPool.h
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
