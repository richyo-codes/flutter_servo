#ifndef FLUTTER_SERVO_WINDOWS_RUST_BRIDGE_H_
#define FLUTTER_SERVO_WINDOWS_RUST_BRIDGE_H_

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <string>

namespace flutter_servo {

// These signatures mirror the C exports in rust/src/render_bridge.rs.
struct RustBridge {
  bool Load(std::string &error);

  void *(*session_new)(const char *, const char *, const char *) = nullptr;
  void (*session_free)(void *) = nullptr;
  bool (*set_url)(void *, const char *) = nullptr;
  bool (*set_html)(void *, const char *) = nullptr;
  bool (*go_back)(void *) = nullptr;
  bool (*go_forward)(void *) = nullptr;
  bool (*reload)(void *) = nullptr;
  bool (*is_animating)(const void *) = nullptr;
  uint8_t (*load_progress)(const void *) = nullptr;
  bool (*poll)(const void *) = nullptr;
  bool (*set_wake_callback)(const void *, void (*)(void *), void *) = nullptr;
  bool (*navigation_state)(const void *, char *, size_t, bool *,
                           bool *) = nullptr;
  bool (*mouse_move)(void *, int32_t, int32_t) = nullptr;
  bool (*mouse_button)(void *, int32_t, int32_t, uint8_t, bool) = nullptr;
  bool (*mouse_leave)(void *) = nullptr;
  bool (*mouse_wheel)(void *, int32_t, int32_t, int32_t, int32_t) = nullptr;
  bool (*key_event)(void *, const char *, const char *, bool) = nullptr;
  bool (*focus)(void *) = nullptr;
  bool (*blur)(void *) = nullptr;
  void *(*render_frame)(void *, uint32_t, uint32_t, const uint8_t **,
                        size_t *) = nullptr;
  void (*frame_free)(void *) = nullptr;
  char *(*take_control_event)(void *) = nullptr;
  void (*control_event_free)(char *) = nullptr;
  bool (*control_response)(void *, const char *) = nullptr;

private:
  HMODULE module_ = nullptr;
};

} // namespace flutter_servo
#endif
