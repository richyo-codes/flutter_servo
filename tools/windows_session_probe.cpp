#include <windows.h>

#include <cstdint>
#include <iostream>
#include <string>

#include "rust_bridge.h"

namespace {
void Wake(void *context) { SetEvent(static_cast<HANDLE>(context)); }

bool AwaitColor(flutter_servo::RustBridge &bridge, void *session, HANDLE wake,
                uint32_t width, uint32_t height, uint8_t red, uint8_t green,
                uint8_t blue) {
  const auto deadline = GetTickCount64() + 15000;
  // The first call submits navigation/resize. Subsequent attempts require a
  // Servo wake, so the probe detects a lost wake as well as a missing frame.
  bool first = true;
  while (GetTickCount64() < deadline) {
    if (!first && WaitForSingleObject(wake, 1000) != WAIT_OBJECT_0)
      continue;
    first = false;
    bridge.poll(session);
    const uint8_t *pixels = nullptr;
    size_t length = 0;
    void *frame = bridge.render_frame(session, width, height, &pixels, &length);
    bool match = false;
    if (frame) {
      match = pixels && length == static_cast<size_t>(width) * height * 4 &&
              pixels[0] == red && pixels[1] == green && pixels[2] == blue &&
              pixels[3] == 255;
      bridge.frame_free(frame);
    }
    if (match)
      return true;
    if (bridge.load_progress(session) == 3)
      return false;
  }
  return false;
}
} // namespace

int main() {
  flutter_servo::RustBridge bridge;
  std::string error;
  if (!bridge.Load(error)) {
    std::cerr << error << '\n';
    return 1;
  }
  HANDLE wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!wake)
    return 1;
  void *session = bridge.session_new(nullptr, nullptr, nullptr);
  if (!session) {
    CloseHandle(wake);
    return 1;
  }
  bridge.set_wake_callback(session, Wake, wake);
  bool passed =
      bridge.set_html(
          session,
          "<!doctype "
          "html><style>html,body{margin:0;width:100%;height:100%;background:"
          "rgb(17,101,53)}</style>"
          "<body "
          "onclick=\"document.documentElement.style.background='rgb(33,66,99)';"
          "document.body.style.background='rgb(33,66,99)'\"></body>") &&
      AwaitColor(bridge, session, wake, 320, 240, 17, 101, 53);
  if (passed) {
    bridge.focus(session);
    bridge.mouse_move(session, 40, 40);
    bridge.mouse_button(session, 40, 40, 0, true);
    bridge.mouse_button(session, 40, 40, 0, false);
    passed = AwaitColor(bridge, session, wake, 320, 240, 33, 66, 99);
  }
  if (passed)
    passed = AwaitColor(bridge, session, wake, 480, 320, 33, 66, 99);
  bridge.set_wake_callback(session, nullptr, nullptr);
  CloseHandle(wake);
  bridge.session_free(session);
  std::cout
      << (passed ? "PASS: Windows load, wake, pixels, click, resize, shutdown\n"
                 : "FAIL: Windows native render/input probe\n");
  return passed ? 0 : 1;
}
