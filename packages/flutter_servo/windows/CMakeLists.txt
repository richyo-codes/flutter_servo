cmake_minimum_required(VERSION 3.14)
project(flutter_servo LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "flutter_servo_plugin")
add_library(${PLUGIN_NAME} SHARED
  "flutter_servo_plugin.cpp"
  "rust_bridge.cpp"
  "include/flutter_servo/flutter_servo_plugin_c_api.h"
)
apply_standard_settings(${PLUGIN_NAME})
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin user32)

# The Native Assets hook builds and bundles rust_lib_flutter_servo.dll.
set(flutter_servo_bundled_libraries "" PARENT_SCOPE)
