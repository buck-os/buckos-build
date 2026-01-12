cmake_minimum_required(VERSION 3.10)
project(dirent VERSION 1.23.2 LANGUAGES C CXX)

# Header-only library
# Install the header file
install(FILES include/dirent.h
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
