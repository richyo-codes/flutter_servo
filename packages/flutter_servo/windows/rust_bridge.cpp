#include "rust_bridge.h"

#include <cstring>
#include <filesystem>
#include <vector>

namespace flutter_servo {
namespace {
template <typename T>
bool Resolve(HMODULE module, const char *name, T &function,
             std::string &error) {
  const auto address = GetProcAddress(module, name);
  if (!address) {
    error = std::string("Rust DLL is missing ") + name +
            ". Rebuild with the servo-engine feature enabled.";
    return false;
  }
  static_assert(sizeof(function) == sizeof(address));
  std::memcpy(&function, &address, sizeof(function));
  return true;
}
} // namespace

bool RustBridge::Load(std::string &error) {
  if (module_)
    return true;
  std::vector<wchar_t> path(32768);
  // Prefer the DLL already loaded by Dart Native Assets. Otherwise use the
  // application directory, never the working directory or an arbitrary PATH
  // DLL.
  const auto existing = GetModuleHandleW(L"rust_lib_flutter_servo.dll");
  const DWORD length = GetModuleFileNameW(existing, path.data(),
                                          static_cast<DWORD>(path.size()));
  if (!length || length >= path.size()) {
    error = "Cannot locate the application or Rust DLL.";
    return false;
  }
  auto library = std::filesystem::path(path.data());
  if (!existing)
    library = library.parent_path() / L"rust_lib_flutter_servo.dll";
  auto module = LoadLibraryExW(library.c_str(), nullptr,
                               LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                                   LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  if (!module) {
    error = "Cannot load rust_lib_flutter_servo.dll or one of its dependencies "
            "(Windows error " +
            std::to_string(GetLastError()) +
            "). Check the Native Assets build and DLL bundle.";
    return false;
  }

#define SERVO_SYMBOL(field, name)                                              \
  if (!Resolve(module, "flutter_servo_" name, field, error)) {                 \
    FreeLibrary(module);                                                       \
    return false;                                                              \
  }
  SERVO_SYMBOL(session_new, "session_new")
  SERVO_SYMBOL(session_free, "session_free")
  SERVO_SYMBOL(set_url, "session_set_url")
  SERVO_SYMBOL(set_html, "session_set_html")
  SERVO_SYMBOL(go_back, "session_go_back")
  SERVO_SYMBOL(go_forward, "session_go_forward")
  SERVO_SYMBOL(reload, "session_reload")
  SERVO_SYMBOL(is_animating, "session_is_animating")
  SERVO_SYMBOL(load_progress, "session_load_progress")
  SERVO_SYMBOL(poll, "session_poll")
  SERVO_SYMBOL(set_wake_callback, "session_set_wake_callback")
  SERVO_SYMBOL(navigation_state, "session_get_navigation_state")
  SERVO_SYMBOL(mouse_move, "session_notify_mouse_move")
  SERVO_SYMBOL(mouse_button, "session_notify_mouse_button")
  SERVO_SYMBOL(mouse_leave, "session_notify_mouse_leave_viewport")
  SERVO_SYMBOL(mouse_wheel, "session_notify_mouse_wheel")
  SERVO_SYMBOL(key_event, "session_notify_key_event")
  SERVO_SYMBOL(focus, "session_focus_webview")
  SERVO_SYMBOL(blur, "session_blur_webview")
  SERVO_SYMBOL(render_frame, "session_render_frame")
  SERVO_SYMBOL(frame_free, "frame_free")
  SERVO_SYMBOL(take_control_event, "session_take_control_event")
  SERVO_SYMBOL(control_event_free, "control_event_free")
  SERVO_SYMBOL(control_response, "session_control_response")
#undef SERVO_SYMBOL
  // Keep one process-lifetime reference: Flutter's raster thread can release
  // Rust-owned frames after plugin teardown, and Servo has global worker state.
  module_ = module;
  return true;
}
} // namespace flutter_servo
