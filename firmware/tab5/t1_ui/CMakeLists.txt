# T1 touchscreen UI with labelled MOCK data for the M5Stack Tab5 (ESP32-P4).
cmake_minimum_required(VERSION 3.16)
set(EXTRA_COMPONENT_DIRS "${CMAKE_CURRENT_LIST_DIR}/../components")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(t1_ui)
