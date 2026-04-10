#include "rust_render_bridge.h"

#include <dlfcn.h>
#include <glib.h>

namespace {

using FlutterServoSessionNewFn = void* (*)();
using FlutterServoSessionFreeFn = void (*)(void* session);
using FlutterServoSessionSetTextFn = bool (*)(void* session, const char* text);
using FlutterServoSessionRenderFn =
    bool (*)(const void* session,
             uint32_t width,
             uint32_t height,
             uint8_t* out_rgba,
             size_t out_len);

template <typename T>
T resolve_symbol(void* handle, const char* name) {
  return reinterpret_cast<T>(dlsym(handle, name));
}

gchar* resolve_library_path() {
  Dl_info info = {};
  if (dladdr(reinterpret_cast<void*>(&resolve_library_path), &info) == 0 ||
      info.dli_fname == nullptr) {
    return nullptr;
  }

  g_autofree gchar* current_path = g_strdup(info.dli_fname);
  g_autofree gchar* current_dir = g_path_get_dirname(current_path);
  return g_build_filename(current_dir, "librust_lib_flutter_servo.so", nullptr);
}

}  // namespace

struct _RustRenderBridge {
  void* handle;
  FlutterServoSessionNewFn session_new;
  FlutterServoSessionFreeFn session_free;
  FlutterServoSessionSetTextFn session_set_url;
  FlutterServoSessionSetTextFn session_set_html;
  FlutterServoSessionRenderFn session_render;
};

RustRenderBridge* rust_render_bridge_new() {
  g_message("flutter_servo: rust bridge init");
  void* handle = nullptr;
  auto session_new =
      resolve_symbol<FlutterServoSessionNewFn>(RTLD_DEFAULT, "flutter_servo_session_new");
  auto session_free =
      resolve_symbol<FlutterServoSessionFreeFn>(RTLD_DEFAULT, "flutter_servo_session_free");
  auto session_set_url = resolve_symbol<FlutterServoSessionSetTextFn>(
      RTLD_DEFAULT, "flutter_servo_session_set_url");
  auto session_set_html = resolve_symbol<FlutterServoSessionSetTextFn>(
      RTLD_DEFAULT, "flutter_servo_session_set_html");
  auto session_render = resolve_symbol<FlutterServoSessionRenderFn>(
      RTLD_DEFAULT, "flutter_servo_session_render_rgba");

  if (session_new == nullptr || session_free == nullptr ||
      session_set_url == nullptr || session_set_html == nullptr ||
      session_render == nullptr) {
    g_message("flutter_servo: rust bridge resolving Rust symbols via dlopen fallback");
    g_autofree gchar* library_path = resolve_library_path();
    if (library_path == nullptr) {
      g_warning("flutter_servo: rust bridge could not resolve Rust library path");
      return nullptr;
    }

    handle = dlopen(library_path, RTLD_LAZY | RTLD_LOCAL);
    if (handle == nullptr) {
      g_warning("flutter_servo: rust bridge dlopen failed: %s", dlerror());
      return nullptr;
    }

    session_new =
        resolve_symbol<FlutterServoSessionNewFn>(handle, "flutter_servo_session_new");
    session_free =
        resolve_symbol<FlutterServoSessionFreeFn>(handle, "flutter_servo_session_free");
    session_set_url = resolve_symbol<FlutterServoSessionSetTextFn>(
        handle, "flutter_servo_session_set_url");
    session_set_html = resolve_symbol<FlutterServoSessionSetTextFn>(
        handle, "flutter_servo_session_set_html");
    session_render = resolve_symbol<FlutterServoSessionRenderFn>(
        handle, "flutter_servo_session_render_rgba");
    if (session_new == nullptr || session_free == nullptr ||
        session_set_url == nullptr || session_set_html == nullptr ||
        session_render == nullptr) {
      g_warning("flutter_servo: rust bridge failed to resolve required session symbols");
      dlclose(handle);
      return nullptr;
    }
  }

  g_message("flutter_servo: rust bridge ready");

  RustRenderBridge* self = g_new0(RustRenderBridge, 1);
  self->handle = handle;
  self->session_new = session_new;
  self->session_free = session_free;
  self->session_set_url = session_set_url;
  self->session_set_html = session_set_html;
  self->session_render = session_render;
  return self;
}

void rust_render_bridge_free(RustRenderBridge* self) {
  if (self == nullptr) {
    return;
  }

  if (self->handle != nullptr) {
    dlclose(self->handle);
  }
  g_free(self);
}

RustRenderSessionHandle rust_render_bridge_create_session(RustRenderBridge* self) {
  if (self == nullptr || self->session_new == nullptr) {
    g_warning("flutter_servo: rust bridge cannot create session");
    return nullptr;
  }
  RustRenderSessionHandle session = self->session_new();
  if (session == nullptr) {
    g_warning("flutter_servo: Rust session creation returned null");
  } else {
    g_message("flutter_servo: Rust session created");
  }
  return session;
}

void rust_render_bridge_destroy_session(RustRenderBridge* self,
                                        RustRenderSessionHandle session) {
  if (self == nullptr || self->session_free == nullptr || session == nullptr) {
    return;
  }
  self->session_free(session);
}

bool rust_render_bridge_set_url(RustRenderBridge* self,
                                RustRenderSessionHandle session,
                                const char* url) {
  return self != nullptr && self->session_set_url != nullptr &&
         session != nullptr && self->session_set_url(session, url);
}

bool rust_render_bridge_set_html(RustRenderBridge* self,
                                 RustRenderSessionHandle session,
                                 const char* html) {
  return self != nullptr && self->session_set_html != nullptr &&
         session != nullptr && self->session_set_html(session, html);
}

bool rust_render_bridge_render_session(RustRenderBridge* self,
                                       RustRenderSessionHandle session,
                                       uint32_t width,
                                       uint32_t height,
                                       uint8_t* out_buffer,
                                       size_t out_len) {
  const bool ok = self != nullptr && self->session_render != nullptr &&
                  session != nullptr &&
                  self->session_render(session, width, height, out_buffer, out_len);
  if (!ok) {
    g_warning("flutter_servo: Rust session render failed for %ux%u", width, height);
  }
  return ok;
}
