cmake_minimum_required(VERSION 3.20)
project(screen-dimmer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

find_package(Qt6 REQUIRED COMPONENTS Core Gui)
find_package(KF6Screen REQUIRED)

add_executable(screen-dimmer main.cpp)
target_link_libraries(screen-dimmer PRIVATE Qt6::Core Qt6::Gui KF6::Screen)
