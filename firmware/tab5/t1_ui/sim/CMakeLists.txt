# Desktop build of the T1 UI: unit tests plus a touch-driven LVGL simulator.
# Run through run_sim.sh, which fetches LVGL 9.5.0 the first time.
cmake_minimum_required(VERSION 3.16)
project(t1_sim C)

set(CMAKE_C_STANDARD 11)
set(LVGL_DIR "" CACHE PATH "LVGL 9.5.0 source tree")
if(NOT EXISTS "${LVGL_DIR}/lvgl.h")
    message(FATAL_ERROR "Set -DLVGL_DIR to an LVGL 9.5.0 checkout")
endif()

set(MAIN ${CMAKE_CURRENT_SOURCE_DIR}/../main)
set(WARN -Wall -Wextra -Werror -Wno-unused-parameter)
set(CODEC ${MAIN}/../../components/dbglink)
add_executable(test_link_device test_link_device.c ${MAIN}/device/link_device.c ${MAIN}/state/app_state.c
               ${CODEC}/dbglink.c ${CODEC}/dbglink_client.c)
target_include_directories(test_link_device PRIVATE ${MAIN} ${CODEC}/include)
target_compile_options(test_link_device PRIVATE ${WARN} -fsanitize=address,undefined -fno-pie)
target_link_options(test_link_device PRIVATE -fsanitize=address,undefined -no-pie)

file(GLOB_RECURSE LVGL_SRC ${LVGL_DIR}/src/*.c)
add_library(lvgl STATIC ${LVGL_SRC})
target_include_directories(lvgl PUBLIC ${LVGL_DIR} ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(lvgl PUBLIC LV_CONF_INCLUDE_SIMPLE)
target_compile_options(lvgl PRIVATE -O2 -w)

add_executable(test_state test_state.c ${MAIN}/state/app_state.c ${MAIN}/device/mock_device.c)
target_include_directories(test_state PRIVATE ${MAIN})
target_compile_options(test_state PRIVATE ${WARN} -fsanitize=address,undefined)
target_link_options(test_state PRIVATE -fsanitize=address,undefined)

file(GLOB UI_SRC ${MAIN}/ui/*.c)
add_executable(t1_sim sim_main.c ${UI_SRC} ${MAIN}/state/app_state.c ${MAIN}/device/mock_device.c)
target_include_directories(t1_sim PRIVATE ${MAIN})
target_link_libraries(t1_sim lvgl m)
target_compile_options(t1_sim PRIVATE ${WARN} -fsanitize=address,undefined)
target_link_options(t1_sim PRIVATE -fsanitize=address,undefined)
