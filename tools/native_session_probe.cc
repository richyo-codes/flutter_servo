#include <dlfcn.h>

#include <cstdint>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
#include <thread>

#include <gtk/gtk.h>

namespace {

using SessionNewFn = void* (*)(const char*, const char*, const char*);
using SessionFreeFn = void (*)(void* session);
using SessionSetTextFn = bool (*)(void* session, const char* text);
using SessionRenderFn =
    bool (*)(void* session,
             uint32_t width,
             uint32_t height,
             uint8_t* out_rgba,
             size_t out_len);
using SessionWheelFn = bool (*)(void*, int32_t, int32_t, int32_t, int32_t);

template <typename T>
T Resolve(void* handle, const char* symbol) {
  return reinterpret_cast<T>(dlsym(handle, symbol));
}

void Usage(const char* argv0) {
  std::cerr << "usage: " << argv0
            << " [--gtk-init] [--rtld-global] <path-to-librust_lib_flutter_servo.so>\n";
}

}  // namespace

int main(int argc, char** argv) {
  bool gtk_init = false;
  bool close_loading = false;
  bool scroll_benchmark = false;
  int dlopen_flags = RTLD_NOW | RTLD_LOCAL;
  std::string library_path;

  for (int i = 1; i < argc; ++i) {
    const std::string arg(argv[i]);
    if (arg == "--gtk-init") {
      gtk_init = true;
      continue;
    }
    if (arg == "--close-loading") {
      close_loading = true;
      continue;
    }
    if (arg == "--scroll-benchmark") {
      scroll_benchmark = true;
      continue;
    }
    if (arg == "--rtld-global") {
      dlopen_flags = RTLD_NOW | RTLD_GLOBAL;
      continue;
    }
    if (!library_path.empty()) {
      Usage(argv[0]);
      return 2;
    }
    library_path = arg;
  }

  if (library_path.empty()) {
    Usage(argv[0]);
    return 2;
  }

  if (gtk_init) {
    std::cerr << "native_probe: gtk_init_check start\n";
    if (!gtk_init_check(&argc, &argv)) {
      std::cerr << "native_probe: gtk_init_check failed\n";
      return 3;
    }
    std::cerr << "native_probe: gtk_init_check ok\n";
  }

  std::cerr << "native_probe: dlopen " << library_path << "\n";
  void* handle = dlopen(library_path.c_str(), dlopen_flags);
  if (handle == nullptr) {
    std::cerr << "native_probe: dlopen failed: " << dlerror() << "\n";
    return 4;
  }

  auto session_new = Resolve<SessionNewFn>(handle, "flutter_servo_session_new");
  auto session_free = Resolve<SessionFreeFn>(handle, "flutter_servo_session_free");
  auto session_set_html =
      Resolve<SessionSetTextFn>(handle, "flutter_servo_session_set_html");
  auto session_render =
      Resolve<SessionRenderFn>(handle, "flutter_servo_session_render_rgba");
  if (session_new == nullptr || session_free == nullptr ||
      session_set_html == nullptr || session_render == nullptr) {
    std::cerr << "native_probe: symbol resolution failed\n";
    dlclose(handle);
    return 5;
  }

  std::cerr << "native_probe: session_new start\n";
  void* session = session_new(nullptr, nullptr, nullptr);
  std::cerr << "native_probe: session_new returned " << session << "\n";
  if (session == nullptr) {
    dlclose(handle);
    return 6;
  }

  const char* html =
      "<!DOCTYPE html><html><body style='height:4000px'>"
      "<h1>Servo Probe</h1><p>Native host probe.</p></body></html>";
  std::cerr << "native_probe: session_set_html start\n";
  if (!session_set_html(session, html)) {
    std::cerr << "native_probe: session_set_html failed\n";
    session_free(session);
    dlclose(handle);
    return 7;
  }

  std::vector<uint8_t> rgba(800 * 600 * 4);
  std::cerr << "native_probe: session_render start\n";
  bool rendered = false;
  const auto start = std::chrono::steady_clock::now();
  double max_call_ms = 0;
  for (int attempt = 0; attempt < (close_loading ? 1 : 500) && !rendered; ++attempt) {
    const auto call_start = std::chrono::steady_clock::now();
    rendered = session_render(session, 800, 600, rgba.data(), rgba.size());
    const double call_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - call_start).count();
    max_call_ms = std::max(max_call_ms, call_ms);
    if (!rendered) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  if (!rendered && !close_loading) {
    std::cerr << "native_probe: session_render failed\n";
    session_free(session);
    dlclose(handle);
    return 8;
  }
  std::cerr << "native_probe: session_render ok elapsed_ms="
            << std::chrono::duration<double, std::milli>(
                   std::chrono::steady_clock::now() - start).count()
            << " max_call_ms=" << max_call_ms << "\n";

  if (scroll_benchmark) {
    auto wheel = Resolve<SessionWheelFn>(handle, "flutter_servo_session_notify_mouse_wheel");
    if (wheel == nullptr) return 9;
    double max_frame_ms = 0;
    int frames = 0;
    for (int sample = 0; sample < 60; ++sample) {
      wheel(session, 100, 100, 0, -20);
      const auto frame_start = std::chrono::steady_clock::now();
      if (session_render(session, 800, 600, rgba.data(), rgba.size())) ++frames;
      max_frame_ms = std::max(max_frame_ms, std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - frame_start).count());
      std::this_thread::sleep_for(std::chrono::milliseconds(16));
    }
    std::cerr << "native_probe: scroll_frames=" << frames
              << " max_frame_call_ms=" << max_frame_ms << "\n";
  }

  const auto close_start = std::chrono::steady_clock::now();
  session_free(session);
  std::cerr << "native_probe: shutdown_ms="
            << std::chrono::duration<double, std::milli>(
                   std::chrono::steady_clock::now() - close_start).count() << "\n";
  dlclose(handle);
  std::cerr << "native_probe: done\n";
  return 0;
}
