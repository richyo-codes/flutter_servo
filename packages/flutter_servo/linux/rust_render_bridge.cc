#include "rust_render_bridge.h"

#include <dlfcn.h>
#include <glib.h>

namespace {

using FlutterServoSessionNewFn = void* (*)(const char* http_proxy_uri,
                                           const char* https_proxy_uri,
                                           const char* no_proxy);
using FlutterServoSessionFreeFn = void (*)(void* session);
using FlutterServoSessionSetTextFn = bool (*)(void* session, const char* text);
using FlutterServoSessionCommandFn = bool (*)(void* session);
using FlutterServoSessionLoadProgressFn = uint8_t (*)(const void* session);
using FlutterServoSessionNavigationStateFn = bool (*)(const void* session,
                                                      char* url_out,
                                                      size_t url_out_len,
                                                      bool* can_go_back_out,
                                                      bool* can_go_forward_out);
using FlutterServoSessionNotifyMouseMoveFn = bool (*)(void* session, int32_t x, int32_t y);
using FlutterServoSessionNotifyMouseButtonFn =
    bool (*)(void* session, int32_t x, int32_t y, uint8_t button, bool is_down);
using FlutterServoSessionNotifyMouseLeaveViewportFn = bool (*)(void* session);
using FlutterServoSessionNotifyMouseWheelFn =
    bool (*)(void* session, int32_t x, int32_t y, int32_t delta_x, int32_t delta_y);
using FlutterServoSessionNotifyKeyEventFn =
    bool (*)(void* session, const char* key_label, const char* character, bool is_down);
using FlutterServoSessionFocusWebViewFn = bool (*)(void* session);
using FlutterServoSessionBlurWebViewFn = bool (*)(void* session);
using FlutterServoSessionRenderFn =
    bool (*)(const void* session,
             uint32_t width,
             uint32_t height,
             uint8_t* out_rgba,
             size_t out_len);
using FlutterServoSessionRenderFrameFn = void* (*)(
    void* session,
    uint32_t width,
    uint32_t height,
    const uint8_t** data_out,
    size_t* len_out);
using FlutterServoFrameFreeFn = void (*)(void* frame);

struct RustFrameOwner {
  void* frame;
  FlutterServoFrameFreeFn free_frame;
};

void release_rust_frame(gpointer data) {
  auto* owner = static_cast<RustFrameOwner*>(data);
  owner->free_frame(owner->frame);
  g_free(owner);
}

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
  bool (*paint)(void*, uint32_t, uint32_t);
  char* (*take_control_event)(void*);
  void (*control_event_free)(char*);
  bool (*control_response)(void*, const char*);
  int (*session_wake_fd)(void*);
  bool (*set_viewport_scale)(void*, float, float);
  FlutterServoSessionNewFn session_new;
  FlutterServoSessionFreeFn session_free;
  FlutterServoSessionSetTextFn session_set_url;
  FlutterServoSessionSetTextFn session_set_html;
  FlutterServoSessionCommandFn session_go_back;
  FlutterServoSessionCommandFn session_go_forward;
  FlutterServoSessionCommandFn session_reload;
  FlutterServoSessionCommandFn session_is_animating;
  FlutterServoSessionLoadProgressFn session_load_progress;
  FlutterServoSessionCommandFn session_poll;
  FlutterServoSessionNavigationStateFn session_get_navigation_state;
  FlutterServoSessionNotifyMouseMoveFn session_notify_mouse_move;
  FlutterServoSessionNotifyMouseButtonFn session_notify_mouse_button;
  FlutterServoSessionNotifyMouseLeaveViewportFn session_notify_mouse_leave_viewport;
  FlutterServoSessionNotifyMouseWheelFn session_notify_mouse_wheel;
  FlutterServoSessionNotifyKeyEventFn session_notify_key_event;
  FlutterServoSessionFocusWebViewFn session_focus_webview;
  FlutterServoSessionBlurWebViewFn session_blur_webview;
  FlutterServoSessionRenderFn session_render;
  FlutterServoSessionRenderFrameFn session_render_frame;
  FlutterServoFrameFreeFn frame_free;
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
  auto session_go_back = resolve_symbol<FlutterServoSessionCommandFn>(
      RTLD_DEFAULT, "flutter_servo_session_go_back");
  auto session_go_forward = resolve_symbol<FlutterServoSessionCommandFn>(
      RTLD_DEFAULT, "flutter_servo_session_go_forward");
  auto session_reload = resolve_symbol<FlutterServoSessionCommandFn>(
      RTLD_DEFAULT, "flutter_servo_session_reload");
  auto session_is_animating = resolve_symbol<FlutterServoSessionCommandFn>(
      RTLD_DEFAULT, "flutter_servo_session_is_animating");
  auto session_poll = resolve_symbol<FlutterServoSessionCommandFn>(
      RTLD_DEFAULT, "flutter_servo_session_poll");
  auto session_get_navigation_state = resolve_symbol<FlutterServoSessionNavigationStateFn>(
      RTLD_DEFAULT, "flutter_servo_session_get_navigation_state");
  auto session_notify_mouse_move = resolve_symbol<FlutterServoSessionNotifyMouseMoveFn>(
      RTLD_DEFAULT, "flutter_servo_session_notify_mouse_move");
  auto session_notify_mouse_button =
      resolve_symbol<FlutterServoSessionNotifyMouseButtonFn>(
          RTLD_DEFAULT, "flutter_servo_session_notify_mouse_button");
  auto session_notify_mouse_leave_viewport =
      resolve_symbol<FlutterServoSessionNotifyMouseLeaveViewportFn>(
          RTLD_DEFAULT, "flutter_servo_session_notify_mouse_leave_viewport");
  auto session_notify_mouse_wheel =
      resolve_symbol<FlutterServoSessionNotifyMouseWheelFn>(
          RTLD_DEFAULT, "flutter_servo_session_notify_mouse_wheel");
  auto session_notify_key_event = resolve_symbol<FlutterServoSessionNotifyKeyEventFn>(
      RTLD_DEFAULT, "flutter_servo_session_notify_key_event");
  auto session_focus_webview =
      resolve_symbol<FlutterServoSessionFocusWebViewFn>(RTLD_DEFAULT, "flutter_servo_session_focus_webview");
  auto session_blur_webview =
      resolve_symbol<FlutterServoSessionBlurWebViewFn>(RTLD_DEFAULT, "flutter_servo_session_blur_webview");
  auto session_render = resolve_symbol<FlutterServoSessionRenderFn>(
      RTLD_DEFAULT, "flutter_servo_session_render_rgba");

  if (session_new == nullptr || session_free == nullptr ||
      session_set_url == nullptr || session_set_html == nullptr ||
      session_go_back == nullptr || session_go_forward == nullptr ||
      session_reload == nullptr || session_is_animating == nullptr || session_poll == nullptr ||
      session_get_navigation_state == nullptr ||
      session_notify_mouse_move == nullptr || session_notify_mouse_button == nullptr ||
      session_notify_mouse_leave_viewport == nullptr || session_notify_mouse_wheel == nullptr ||
      session_notify_key_event == nullptr || session_focus_webview == nullptr ||
      session_blur_webview == nullptr || session_render == nullptr) {
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
    session_go_back = resolve_symbol<FlutterServoSessionCommandFn>(
        handle, "flutter_servo_session_go_back");
    session_go_forward = resolve_symbol<FlutterServoSessionCommandFn>(
        handle, "flutter_servo_session_go_forward");
    session_reload = resolve_symbol<FlutterServoSessionCommandFn>(
        handle, "flutter_servo_session_reload");
    session_is_animating = resolve_symbol<FlutterServoSessionCommandFn>(
        handle, "flutter_servo_session_is_animating");
    session_poll = resolve_symbol<FlutterServoSessionCommandFn>(
        handle, "flutter_servo_session_poll");
    session_get_navigation_state = resolve_symbol<FlutterServoSessionNavigationStateFn>(
        handle, "flutter_servo_session_get_navigation_state");
    session_notify_mouse_move = resolve_symbol<FlutterServoSessionNotifyMouseMoveFn>(
        handle, "flutter_servo_session_notify_mouse_move");
    session_notify_mouse_button =
        resolve_symbol<FlutterServoSessionNotifyMouseButtonFn>(
            handle, "flutter_servo_session_notify_mouse_button");
    session_notify_mouse_leave_viewport =
        resolve_symbol<FlutterServoSessionNotifyMouseLeaveViewportFn>(
            handle, "flutter_servo_session_notify_mouse_leave_viewport");
    session_notify_mouse_wheel =
        resolve_symbol<FlutterServoSessionNotifyMouseWheelFn>(
            handle, "flutter_servo_session_notify_mouse_wheel");
    session_notify_key_event = resolve_symbol<FlutterServoSessionNotifyKeyEventFn>(
        handle, "flutter_servo_session_notify_key_event");
    session_focus_webview =
        resolve_symbol<FlutterServoSessionFocusWebViewFn>(handle, "flutter_servo_session_focus_webview");
    session_blur_webview =
        resolve_symbol<FlutterServoSessionBlurWebViewFn>(handle, "flutter_servo_session_blur_webview");
    session_render = resolve_symbol<FlutterServoSessionRenderFn>(
        handle, "flutter_servo_session_render_rgba");
    if (session_new == nullptr || session_free == nullptr ||
        session_set_url == nullptr || session_set_html == nullptr ||
        session_go_back == nullptr || session_go_forward == nullptr ||
        session_reload == nullptr || session_is_animating == nullptr || session_poll == nullptr ||
        session_get_navigation_state == nullptr ||
        session_notify_mouse_move == nullptr || session_notify_mouse_button == nullptr ||
        session_notify_mouse_leave_viewport == nullptr || session_notify_mouse_wheel == nullptr ||
        session_notify_key_event == nullptr || session_focus_webview == nullptr ||
        session_blur_webview == nullptr || session_render == nullptr) {
      g_warning("flutter_servo: rust bridge failed to resolve required session symbols");
      dlclose(handle);
      return nullptr;
    }
  }

  g_message("flutter_servo: rust bridge ready");

  RustRenderBridge* self = g_new0(RustRenderBridge, 1);
  self->handle = handle;
  self->set_viewport_scale = resolve_symbol<bool (*)(void*, float, float)>(
      handle == nullptr ? RTLD_DEFAULT : handle,
      "flutter_servo_session_set_viewport_scale");
  self->session_wake_fd = resolve_symbol<int (*)(void*)>(
      handle == nullptr ? RTLD_DEFAULT : handle, "flutter_servo_session_wake_fd");
  self->session_new = session_new;
  self->session_free = session_free;
  self->session_set_url = session_set_url;
  self->session_set_html = session_set_html;
  self->session_go_back = session_go_back;
  self->session_go_forward = session_go_forward;
  self->session_reload = session_reload;
  self->session_is_animating = session_is_animating;
  self->session_load_progress =
      resolve_symbol<FlutterServoSessionLoadProgressFn>(
          handle == nullptr ? RTLD_DEFAULT : handle,
          "flutter_servo_session_load_progress");
  self->session_poll = session_poll;
  self->session_get_navigation_state = session_get_navigation_state;
  self->session_notify_mouse_move = session_notify_mouse_move;
  self->session_notify_mouse_button = session_notify_mouse_button;
  self->session_notify_mouse_leave_viewport = session_notify_mouse_leave_viewport;
  self->session_notify_mouse_wheel = session_notify_mouse_wheel;
  self->session_notify_key_event = session_notify_key_event;
  self->session_focus_webview = session_focus_webview;
  self->session_blur_webview = session_blur_webview;
  self->session_render = session_render;
  void* symbol_handle = handle == nullptr ? RTLD_DEFAULT : handle;
  self->session_render_frame = resolve_symbol<FlutterServoSessionRenderFrameFn>(
      symbol_handle, "flutter_servo_session_render_frame");
  self->frame_free = resolve_symbol<FlutterServoFrameFreeFn>(
      symbol_handle, "flutter_servo_frame_free");
  self->take_control_event = resolve_symbol<char* (*)(void*)>(
      symbol_handle, "flutter_servo_session_take_control_event");
  self->control_event_free = resolve_symbol<void (*)(char*)>(
      symbol_handle, "flutter_servo_control_event_free");
  self->control_response = resolve_symbol<bool (*)(void*, const char*)>(
      symbol_handle, "flutter_servo_session_control_response");
  self->paint = resolve_symbol<bool (*)(void*, uint32_t, uint32_t)>(
      symbol_handle, "flutter_servo_session_paint");
  return self;
}

bool rust_render_bridge_paint(RustRenderBridge* self, RustRenderSessionHandle session,
                              uint32_t width, uint32_t height) {
  return self && session && self->paint && self->paint(session, width, height);
}

gchar* rust_render_bridge_take_control_event(RustRenderBridge* self,
                                            RustRenderSessionHandle session) {
  if (!self || !session || !self->take_control_event || !self->control_event_free) {
    return nullptr;
  }
  char* event = self->take_control_event(session);
  gchar* copy = g_strdup(event);
  if (event) self->control_event_free(event);
  return copy;
}

bool rust_render_bridge_control_response(RustRenderBridge* self,
                                         RustRenderSessionHandle session,
                                         const char* response) {
  return self && session && self->control_response &&
         self->control_response(session, response);
}

int rust_render_bridge_wake_fd(RustRenderBridge* self,
                               RustRenderSessionHandle session) {
  return self != nullptr && self->session_wake_fd != nullptr && session != nullptr
             ? self->session_wake_fd(session) : -1;
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

RustRenderSessionHandle rust_render_bridge_create_session(
    RustRenderBridge* self,
    const char* http_proxy_uri,
    const char* https_proxy_uri,
    const char* no_proxy) {
  if (self == nullptr || self->session_new == nullptr) {
    g_warning("flutter_servo: rust bridge cannot create session");
    return nullptr;
  }
  RustRenderSessionHandle session =
      self->session_new(http_proxy_uri, https_proxy_uri, no_proxy);
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

void rust_render_bridge_set_viewport_scale(RustRenderBridge* self,
    RustRenderSessionHandle session, float display_scale, float page_zoom) {
  if (self != nullptr && self->set_viewport_scale != nullptr && session != nullptr) {
    self->set_viewport_scale(session, display_scale, page_zoom);
  }
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

bool rust_render_bridge_go_back(RustRenderBridge* self,
                                RustRenderSessionHandle session) {
  return self != nullptr && self->session_go_back != nullptr &&
         session != nullptr && self->session_go_back(session);
}

bool rust_render_bridge_go_forward(RustRenderBridge* self,
                                   RustRenderSessionHandle session) {
  return self != nullptr && self->session_go_forward != nullptr &&
         session != nullptr && self->session_go_forward(session);
}

bool rust_render_bridge_reload(RustRenderBridge* self,
                               RustRenderSessionHandle session) {
  return self != nullptr && self->session_reload != nullptr &&
         session != nullptr && self->session_reload(session);
}

bool rust_render_bridge_is_animating(RustRenderBridge* self,
                                     RustRenderSessionHandle session) {
  return self != nullptr && self->session_is_animating != nullptr &&
         session != nullptr && self->session_is_animating(session);
}

uint8_t rust_render_bridge_load_progress(RustRenderBridge* self,
                                         RustRenderSessionHandle session) {
  return self != nullptr && self->session_load_progress != nullptr &&
                 session != nullptr
             ? self->session_load_progress(session)
             : 2;
}

bool rust_render_bridge_poll(RustRenderBridge* self,
                             RustRenderSessionHandle session) {
  return self != nullptr && self->session_poll != nullptr &&
         session != nullptr && self->session_poll(session);
}

bool rust_render_bridge_get_navigation_state(
    RustRenderBridge* self,
    RustRenderSessionHandle session,
    char* url_out,
    size_t url_out_len,
    bool* can_go_back_out,
    bool* can_go_forward_out) {
  return self != nullptr && self->session_get_navigation_state != nullptr &&
         session != nullptr &&
         self->session_get_navigation_state(session, url_out, url_out_len,
                                            can_go_back_out, can_go_forward_out);
}

bool rust_render_bridge_notify_mouse_move(RustRenderBridge* self,
                                          RustRenderSessionHandle session,
                                          int32_t x,
                                          int32_t y) {
  return self != nullptr && self->session_notify_mouse_move != nullptr &&
         session != nullptr && self->session_notify_mouse_move(session, x, y);
}

bool rust_render_bridge_notify_mouse_button(RustRenderBridge* self,
                                            RustRenderSessionHandle session,
                                            int32_t x,
                                            int32_t y,
                                            uint8_t button,
                                            bool is_down) {
  return self != nullptr && self->session_notify_mouse_button != nullptr &&
         session != nullptr &&
         self->session_notify_mouse_button(session, x, y, button, is_down);
}

bool rust_render_bridge_notify_mouse_leave_viewport(
    RustRenderBridge* self,
    RustRenderSessionHandle session) {
  return self != nullptr && self->session_notify_mouse_leave_viewport != nullptr &&
         session != nullptr && self->session_notify_mouse_leave_viewport(session);
}

bool rust_render_bridge_notify_mouse_wheel(RustRenderBridge* self,
                                           RustRenderSessionHandle session,
                                           int32_t x,
                                           int32_t y,
                                           int32_t delta_x,
                                           int32_t delta_y) {
  return self != nullptr && self->session_notify_mouse_wheel != nullptr &&
         session != nullptr &&
         self->session_notify_mouse_wheel(session, x, y, delta_x, delta_y);
}

bool rust_render_bridge_notify_key_event(RustRenderBridge* self,
                                         RustRenderSessionHandle session,
                                         const char* key_label,
                                         const char* character,
                                         bool is_down) {
  return self != nullptr && self->session_notify_key_event != nullptr &&
         session != nullptr &&
         self->session_notify_key_event(session, key_label, character, is_down);
}

bool rust_render_bridge_focus_webview(RustRenderBridge* self,
                                      RustRenderSessionHandle session) {
  return self != nullptr && self->session_focus_webview != nullptr &&
         session != nullptr && self->session_focus_webview(session);
}

bool rust_render_bridge_blur_webview(RustRenderBridge* self,
                                     RustRenderSessionHandle session) {
  return self != nullptr && self->session_blur_webview != nullptr &&
         session != nullptr && self->session_blur_webview(session);
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

GBytes* rust_render_bridge_render_frame(RustRenderBridge* self,
                                        RustRenderSessionHandle session,
                                        uint32_t width,
                                        uint32_t height) {
  if (self == nullptr || self->session_render_frame == nullptr ||
      self->frame_free == nullptr || session == nullptr) {
    return nullptr;
  }
  const uint8_t* data = nullptr;
  size_t len = 0;
  void* frame =
      self->session_render_frame(session, width, height, &data, &len);
  const size_t expected_len = static_cast<size_t>(width) * height * 4;
  if (frame == nullptr || data == nullptr || len != expected_len) {
    if (frame != nullptr) {
      self->frame_free(frame);
    }
    return nullptr;
  }
  auto* owner = g_new(RustFrameOwner, 1);
  owner->frame = frame;
  owner->free_frame = self->frame_free;
  return g_bytes_new_with_free_func(data, len, release_rust_frame, owner);
}

bool rust_render_bridge_supports_owned_frames(RustRenderBridge* self) {
  return self != nullptr && self->session_render_frame != nullptr &&
         self->frame_free != nullptr;
}
