# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "rust_lib_flutter_servo")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")

# Flutter builds plugin code from a symlink under `.plugin_symlinks`, so resolve
# the real crate path first and then compute a relative path from the active
# CMake source directory.
get_filename_component(FLUTTER_SERVO_RUST_DIR
  "${CMAKE_CURRENT_LIST_DIR}/../../../../rust"
  REALPATH
)
file(RELATIVE_PATH FLUTTER_SERVO_RUST_DIR_REL
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${FLUTTER_SERVO_RUST_DIR}"
)

apply_cargokit(${PROJECT_NAME} "${FLUTTER_SERVO_RUST_DIR_REL}" rust_lib_flutter_servo "")

set(rust_lib_flutter_servo_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
