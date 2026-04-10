#include <dlfcn.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include <gtk/gtk.h>

namespace {

using SessionNewFn = void* (*)();
using SessionFreeFn = void (*)(void* session);
using SessionSetTextFn = bool (*)(void* session, const char* text);
using SessionRenderFn =
    bool (*)(void* session,
             uint32_t width,
             uint32_t height,
             uint8_t* out_rgba,
             size_t out_len);

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
  int dlopen_flags = RTLD_NOW | RTLD_LOCAL;
  std::string library_path;

  for (int i = 1; i < argc; ++i) {
    const std::string arg(argv[i]);
    if (arg == "--gtk-init") {
      gtk_init = true;
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
  void* session = session_new();
  std::cerr << "native_probe: session_new returned " << session << "\n";
  if (session == nullptr) {
    dlclose(handle);
    return 6;
  }

  const char* html =
      "<!DOCTYPE html><html><body><h1>Servo Probe</h1><p>Native host probe.</p></body></html>";
  std::cerr << "native_probe: session_set_html start\n";
  if (!session_set_html(session, html)) {
    std::cerr << "native_probe: session_set_html failed\n";
    session_free(session);
    dlclose(handle);
    return 7;
  }

  std::vector<uint8_t> rgba(800 * 600 * 4);
  std::cerr << "native_probe: session_render start\n";
  if (!session_render(session, 800, 600, rgba.data(), rgba.size())) {
    std::cerr << "native_probe: session_render failed\n";
    session_free(session);
    dlclose(handle);
    return 8;
  }
  std::cerr << "native_probe: session_render ok\n";

  session_free(session);
  dlclose(handle);
  std::cerr << "native_probe: done\n";
  return 0;
}
