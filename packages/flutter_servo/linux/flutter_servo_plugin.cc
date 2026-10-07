#include "include/flutter_servo/flutter_servo_plugin.h"

#include <algorithm>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <cstring>
#include <glib-unix.h>
#include <sys/socket.h>
#include <unistd.h>

#include "rust_render_bridge.h"
#include "servo_texture.h"

#define FLUTTER_SERVO_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_servo_plugin_get_type(), \
                              FlutterServoPlugin))

struct _FlutterServoPlugin {
  GObject parent_instance;
  FlTextureRegistrar* texture_registrar;
  ServoTexture* texture;
  RustRenderBridge* rust_render_bridge;
  RustRenderSessionHandle session;
  FlMethodChannel* method_channel;
  gchar* http_proxy_uri;
  gchar* https_proxy_uri;
  gchar* no_proxy;
  guint frame_source_id;
  guint wake_source_id;
  int wake_fd;
  int load_progress;
  bool has_frame;
};

G_DEFINE_TYPE(FlutterServoPlugin, flutter_servo_plugin, g_object_get_type())

static constexpr int kFailedLoadProgress = 3;

static bool render_texture(FlutterServoPlugin* self);
static void update_load_progress(FlutterServoPlugin* self);

static void dispatch_control_events(FlutterServoPlugin* self) {
  for (int i = 0; i < 64; i++) {
    g_autofree gchar* event = rust_render_bridge_take_control_event(
        self->rust_render_bridge, self->session);
    if (!event) break;
    g_autoptr(FlValue) args = fl_value_new_string(event);
    fl_method_channel_invoke_method(self->method_channel, "embedderControl",
                                    args, nullptr, nullptr, nullptr);
  }
}

static gboolean pump_servo_frame(gpointer user_data) {
  FlutterServoPlugin* self = FLUTTER_SERVO_PLUGIN(user_data);
  self->frame_source_id = 0;
  if (self->session != nullptr && self->texture != nullptr &&
      rust_render_bridge_poll(self->rust_render_bridge, self->session)) {
    render_texture(self);
  }
  update_load_progress(self);
  dispatch_control_events(self);
  if (self->load_progress != kFailedLoadProgress &&
      (self->wake_fd < 0 || rust_render_bridge_is_animating(
          self->rust_render_bridge, self->session))) {
    self->frame_source_id = g_timeout_add(16, pump_servo_frame, self);
  }
  return G_SOURCE_REMOVE;
}

static void schedule_servo_frame(FlutterServoPlugin* self) {
  if (self->frame_source_id == 0) {
    self->frame_source_id = g_idle_add_full(
        G_PRIORITY_HIGH_IDLE, pump_servo_frame, self, nullptr);
  }
}

static gboolean servo_woke(gint fd, GIOCondition condition, gpointer user_data) {
  FlutterServoPlugin* self = FLUTTER_SERVO_PLUGIN(user_data);
  if (condition & (G_IO_ERR | G_IO_HUP | G_IO_NVAL)) {
    self->wake_source_id = 0;
    close(self->wake_fd);
    self->wake_fd = -1;
    if (self->frame_source_id == 0) {
      self->frame_source_id = g_timeout_add(16, pump_servo_frame, self);
    }
    g_warning("flutter_servo: wake channel failed; using timer fallback");
    return G_SOURCE_REMOVE;
  }
  char buffer[256];
  // Bound draining so a busy producer cannot starve GTK input dispatch.
  for (int i = 0; i < 256 && recv(fd, buffer, sizeof(buffer), MSG_DONTWAIT) > 0; i++) {}
  if (rust_render_bridge_is_animating(self->rust_render_bridge,
                                      self->session)) {
    if (self->frame_source_id == 0) {
      self->frame_source_id = g_timeout_add_full(
          G_PRIORITY_HIGH_IDLE, 16, pump_servo_frame, self, nullptr);
    }
    return G_SOURCE_CONTINUE;
  }
  if (self->frame_source_id != 0) {
    g_source_remove(self->frame_source_id);
    self->frame_source_id = 0;
  }
  pump_servo_frame(self);
  return G_SOURCE_CONTINUE;
}

static void send_load_state_changed(FlutterServoPlugin* self, int progress) {
  if (self == nullptr || self->method_channel == nullptr) {
    return;
  }
  if (self->load_progress == progress) {
    return;
  }
  self->load_progress = progress;

  g_autoptr(FlValue) args = fl_value_new_int(progress);
  fl_method_channel_invoke_method(self->method_channel, "loadStateChanged",
                                  args, nullptr, nullptr, nullptr);
}

static void update_load_progress(FlutterServoPlugin* self) {
  if (self != nullptr && self->session != nullptr) {
    send_load_state_changed(
        self, rust_render_bridge_load_progress(self->rust_render_bridge,
                                               self->session));
  }
}

static void send_navigation_state_changed(FlutterServoPlugin* self) {
  if (self == nullptr || self->method_channel == nullptr || self->session == nullptr) {
    return;
  }

  gchar url[4096] = {};
  bool can_go_back = false;
  bool can_go_forward = false;
  if (!rust_render_bridge_get_navigation_state(
          self->rust_render_bridge, self->session, url, sizeof(url),
          &can_go_back, &can_go_forward)) {
    return;
  }

  g_autoptr(FlValue) args = fl_value_new_list();
  fl_value_append_take(args, fl_value_new_string(url));
  fl_value_append_take(args, fl_value_new_bool(can_go_back));
  fl_value_append_take(args, fl_value_new_bool(can_go_forward));
  fl_method_channel_invoke_method(self->method_channel, "navigationStateChanged",
                                  args, nullptr, nullptr, nullptr);
}

static bool ensure_session(FlutterServoPlugin* self) {
  if (self->session != nullptr) {
    return true;
  }

  g_message("flutter_servo: linux plugin creating Rust render session");
  self->session = rust_render_bridge_create_session(
      self->rust_render_bridge, self->http_proxy_uri, self->https_proxy_uri, self->no_proxy);
  if (self->session == nullptr) {
    g_warning("flutter_servo: linux plugin failed to create Rust render session");
  }
  if (self->session != nullptr && self->frame_source_id == 0) {
    self->wake_fd = rust_render_bridge_wake_fd(self->rust_render_bridge, self->session);
    if (self->wake_fd >= 0) {
      self->wake_source_id = g_unix_fd_add(
          self->wake_fd, static_cast<GIOCondition>(G_IO_IN | G_IO_ERR | G_IO_HUP),
          servo_woke, self);
    }
    self->frame_source_id = g_timeout_add_full(
        G_PRIORITY_HIGH_IDLE, 16, pump_servo_frame, self, nullptr);
  }
  return self->session != nullptr;
}

static bool render_texture(FlutterServoPlugin* self) {
  if (self->texture == nullptr) {
    g_warning("flutter_servo: linux plugin render requested before texture creation");
    return false;
  }

  bool rendered = false;
  if (ensure_session(self)) {
    const uint32_t width = servo_texture_get_width(self->texture);
    const uint32_t height = servo_texture_get_height(self->texture);
    if (servo_texture_wants_shared_frame(self->texture) &&
        rust_render_bridge_paint(self->rust_render_bridge, self->session, width, height)) {
      rendered = servo_texture_publish_current_frame(self->texture);
    }
    if (!rendered && rust_render_bridge_supports_owned_frames(self->rust_render_bridge)) {
      GBytes* frame = rust_render_bridge_render_frame(
          self->rust_render_bridge, self->session, width, height);
      if (frame != nullptr) {
        rendered = servo_texture_publish_bytes(self->texture, frame, width, height);
        if (!rendered) {
          g_bytes_unref(frame);
        }
      }
    } else if (!rendered) {
      rendered = rust_render_bridge_render_session(
          self->rust_render_bridge, self->session, width, height,
          servo_texture_get_buffer(self->texture),
          servo_texture_get_buffer_size(self->texture));
      if (rendered) {
        servo_texture_publish_frame(self->texture);
      }
    }
  }

  if (rendered) {
    fl_texture_registrar_mark_texture_frame_available(self->texture_registrar,
                                                      FL_TEXTURE(self->texture));
  }
  if (rendered) {
    if (!self->has_frame) {
      self->has_frame = true;
      fl_method_channel_invoke_method(self->method_channel, "frameAvailable",
                                      nullptr, nullptr, nullptr, nullptr);
    }
    send_navigation_state_changed(self);
  }
  update_load_progress(self);
  return rendered;
}

static void publish_placeholder_texture(FlutterServoPlugin* self,
                                        const gchar* seed) {
  if (self->texture == nullptr) {
    return;
  }

  servo_texture_paint_placeholder(self->texture, seed);
  fl_texture_registrar_mark_texture_frame_available(self->texture_registrar,
                                                    FL_TEXTURE(self->texture));
}

static bool parse_size_args(FlMethodCall* method_call,
                            uint32_t* width_out,
                            uint32_t* height_out) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(args) != 2) {
    return false;
  }

  FlValue* width_value = fl_value_get_list_value(args, 0);
  FlValue* height_value = fl_value_get_list_value(args, 1);
  if (fl_value_get_type(width_value) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(height_value) != FL_VALUE_TYPE_INT) {
    return false;
  }

  *width_out = std::max<int64_t>(1, fl_value_get_int(width_value));
  *height_out = std::max<int64_t>(1, fl_value_get_int(height_value));
  return true;
}

static const gchar* parse_single_string_arg(FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(args) != 1) {
    return nullptr;
  }

  FlValue* value = fl_value_get_list_value(args, 0);
  if (fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }

  return fl_value_get_string(value);
}

static bool parse_nullable_string_value(FlValue* value, const gchar** out) {
  if (fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
    *out = fl_value_get_string(value);
    return true;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_NULL) {
    *out = nullptr;
    return true;
  }
  return false;
}

static bool parse_proxy_settings_args(FlMethodCall* method_call,
                                     const gchar** http_proxy_uri_out,
                                     const gchar** https_proxy_uri_out,
                                     const gchar** no_proxy_out) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(args) != 3) {
    return false;
  }

  FlValue* http_proxy_value = fl_value_get_list_value(args, 0);
  FlValue* https_proxy_value = fl_value_get_list_value(args, 1);
  FlValue* no_proxy_value = fl_value_get_list_value(args, 2);

  const gchar* http_proxy_uri = nullptr;
  const gchar* https_proxy_uri = nullptr;
  const gchar* no_proxy = nullptr;
  if (!parse_nullable_string_value(http_proxy_value, &http_proxy_uri) ||
      !parse_nullable_string_value(https_proxy_value, &https_proxy_uri) ||
      !parse_nullable_string_value(no_proxy_value, &no_proxy)) {
    return false;
  }

  *http_proxy_uri_out = http_proxy_uri;
  *https_proxy_uri_out = https_proxy_uri;
  *no_proxy_out = no_proxy;
  return true;
}

static void set_string_override(gchar** target, const gchar* value) {
  g_free(*target);
  *target = value == nullptr ? nullptr : g_strdup(value);
}

static bool parse_point_button_args(FlMethodCall* method_call,
                                    int32_t* x_out,
                                    int32_t* y_out,
                                    uint8_t* button_out,
                                    bool* is_down_out) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(args) != 4) {
    return false;
  }

  FlValue* x_value = fl_value_get_list_value(args, 0);
  FlValue* y_value = fl_value_get_list_value(args, 1);
  FlValue* button_value = fl_value_get_list_value(args, 2);
  FlValue* is_down_value = fl_value_get_list_value(args, 3);
  if (fl_value_get_type(x_value) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(y_value) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(button_value) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(is_down_value) != FL_VALUE_TYPE_BOOL) {
    return false;
  }

  *x_out = static_cast<int32_t>(fl_value_get_int(x_value));
  *y_out = static_cast<int32_t>(fl_value_get_int(y_value));
  *button_out = static_cast<uint8_t>(std::max<int64_t>(0, fl_value_get_int(button_value)));
  *is_down_out = fl_value_get_bool(is_down_value);
  return true;
}

static bool parse_point_args(FlMethodCall* method_call,
                             int32_t* x_out,
                             int32_t* y_out) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(args) != 2) {
    return false;
  }

  FlValue* x_value = fl_value_get_list_value(args, 0);
  FlValue* y_value = fl_value_get_list_value(args, 1);
  if (fl_value_get_type(x_value) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(y_value) != FL_VALUE_TYPE_INT) {
    return false;
  }

  *x_out = static_cast<int32_t>(fl_value_get_int(x_value));
  *y_out = static_cast<int32_t>(fl_value_get_int(y_value));
  return true;
}

static bool parse_wheel_args(FlMethodCall* method_call,
                             int32_t* x_out,
                             int32_t* y_out,
                             int32_t* delta_x_out,
                             int32_t* delta_y_out) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(args) != 4) {
    return false;
  }

  FlValue* x_value = fl_value_get_list_value(args, 0);
  FlValue* y_value = fl_value_get_list_value(args, 1);
  FlValue* delta_x_value = fl_value_get_list_value(args, 2);
  FlValue* delta_y_value = fl_value_get_list_value(args, 3);
  if (fl_value_get_type(x_value) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(y_value) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(delta_x_value) != FL_VALUE_TYPE_INT ||
      fl_value_get_type(delta_y_value) != FL_VALUE_TYPE_INT) {
    return false;
  }

  *x_out = static_cast<int32_t>(fl_value_get_int(x_value));
  *y_out = static_cast<int32_t>(fl_value_get_int(y_value));
  *delta_x_out = static_cast<int32_t>(fl_value_get_int(delta_x_value));
  *delta_y_out = static_cast<int32_t>(fl_value_get_int(delta_y_value));
  return true;
}

static bool parse_key_args(FlMethodCall* method_call,
                           const gchar** key_label_out,
                           const gchar** character_out,
                           bool* is_down_out) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(args) != 3) {
    return false;
  }

  FlValue* key_label_value = fl_value_get_list_value(args, 0);
  FlValue* character_value = fl_value_get_list_value(args, 1);
  FlValue* is_down_value = fl_value_get_list_value(args, 2);
  if (fl_value_get_type(key_label_value) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(character_value) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(is_down_value) != FL_VALUE_TYPE_BOOL) {
    return false;
  }

  *key_label_out = fl_value_get_string(key_label_value);
  *character_out = fl_value_get_string(character_value);
  *is_down_out = fl_value_get_bool(is_down_value);
  return true;
}

static FlMethodResponse* handle_focus_webview(FlutterServoPlugin* self) {
  if (!ensure_session(self) ||
      !rust_render_bridge_focus_webview(self->rust_render_bridge, self->session)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "input-failed", "Failed to focus Servo webview.", nullptr));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_blur_webview(FlutterServoPlugin* self) {
  if (!ensure_session(self) ||
      !rust_render_bridge_blur_webview(self->rust_render_bridge, self->session)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "input-failed", "Failed to blur Servo webview.", nullptr));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_create_texture(FlutterServoPlugin* self,
                                               FlMethodCall* method_call) {
  uint32_t width = 1;
  uint32_t height = 1;
  if (!parse_size_args(method_call, &width, &height)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [width, height].", nullptr));
  }

  if (self->texture == nullptr) {
    g_message("flutter_servo: linux plugin creating texture %ux%u", width, height);
    self->texture = servo_texture_new(width, height, "servo");
    if (!fl_texture_registrar_register_texture(self->texture_registrar,
                                               FL_TEXTURE(self->texture))) {
      g_clear_object(&self->texture);
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "texture-register-failed", "Failed to register texture.", nullptr));
    }
  } else {
    g_message("flutter_servo: linux plugin resizing existing texture to %ux%u", width, height);
    servo_texture_resize(self->texture, width, height);
  }
  publish_placeholder_texture(self, "servo");

  g_autoptr(FlValue) id =
      fl_value_new_int(fl_texture_get_id(FL_TEXTURE(self->texture)));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(id));
}

static FlMethodResponse* handle_resize_texture(FlutterServoPlugin* self,
                                               FlMethodCall* method_call) {
  if (self->texture == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "texture-missing", "Create the texture before resizing it.", nullptr));
  }

  uint32_t width = 1;
  uint32_t height = 1;
  if (!parse_size_args(method_call, &width, &height)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [width, height].", nullptr));
  }

  g_message("flutter_servo: linux plugin resizeTexture %ux%u", width, height);
  servo_texture_resize(self->texture, width, height);
  if (self->session == nullptr) {
    publish_placeholder_texture(self, "resize");
  } else if (!render_texture(self)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "render-failed", "Failed to render resized content.", nullptr));
  }

  g_autoptr(FlValue) id =
      fl_value_new_int(fl_texture_get_id(FL_TEXTURE(self->texture)));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(id));
}

static FlMethodResponse* handle_refresh_texture(FlutterServoPlugin* self) {
  if (self->texture == nullptr || self->session == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-missing", "Load content before refreshing the Servo texture.",
        nullptr));
  }
  if (!render_texture(self)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "render-failed", "Failed to refresh Servo content.", nullptr));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(
      rust_render_bridge_is_animating(self->rust_render_bridge, self->session))));
}

static FlMethodResponse* handle_navigation_command(FlutterServoPlugin* self,
                                                    const gchar* command) {
  if (!ensure_session(self)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-missing", "Load content before navigating.", nullptr));
  }

  bool accepted = false;
  if (strcmp(command, "back") == 0) {
    accepted = rust_render_bridge_go_back(self->rust_render_bridge, self->session);
  } else if (strcmp(command, "forward") == 0) {
    accepted = rust_render_bridge_go_forward(self->rust_render_bridge, self->session);
  } else if (strcmp(command, "reload") == 0) {
    accepted = rust_render_bridge_reload(self->rust_render_bridge, self->session);
  }
  if (!accepted) {
    send_navigation_state_changed(self);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(false)));
  }

  send_load_state_changed(self, 0);
  // Navigation acceptance is independent of whether Servo has a framebuffer
  // ready synchronously. The wake-driven frame pump publishes it later.
  render_texture(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(
      fl_value_new_bool(true)));
}

static FlMethodResponse* handle_set_url(FlutterServoPlugin* self,
                                        FlMethodCall* method_call) {
  const gchar* url = parse_single_string_arg(method_call);
  if (url == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [url].", nullptr));
  }
  g_message("flutter_servo: linux plugin setUrl");
  send_load_state_changed(self, 0);
  if (!ensure_session(self) ||
      !rust_render_bridge_set_url(self->rust_render_bridge, self->session,
                                  url)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-update-failed", "Failed to set URL content.", nullptr));
  }
  // Navigation is accepted even when its first frame is not ready yet. Dart
  // schedules bounded refresh attempts without blocking the platform thread.
  render_texture(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_set_html(FlutterServoPlugin* self,
                                         FlMethodCall* method_call) {
  const gchar* html = parse_single_string_arg(method_call);
  if (html == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [html].", nullptr));
  }
  g_message("flutter_servo: linux plugin setHtml");
  send_load_state_changed(self, 0);
  if (!ensure_session(self) ||
      !rust_render_bridge_set_html(self->rust_render_bridge, self->session,
                                   html)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-update-failed", "Failed to set HTML content.", nullptr));
  }
  render_texture(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_set_proxy_settings(FlutterServoPlugin* self,
                                                   FlMethodCall* method_call) {
  const gchar* http_proxy_uri = nullptr;
  const gchar* https_proxy_uri = nullptr;
  const gchar* no_proxy = nullptr;
  if (!parse_proxy_settings_args(method_call, &http_proxy_uri, &https_proxy_uri, &no_proxy)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [httpProxyUri, httpsProxyUri, noProxy].", nullptr));
  }

  if (self->session != nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-locked",
        "Proxy settings must be configured before the first Servo session is created.",
        nullptr));
  }

  g_message("flutter_servo: linux plugin setProxySettings");
  set_string_override(&self->http_proxy_uri, http_proxy_uri);
  set_string_override(&self->https_proxy_uri, https_proxy_uri);
  set_string_override(&self->no_proxy, no_proxy);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_notify_mouse_move(FlutterServoPlugin* self,
                                                  FlMethodCall* method_call) {
  int32_t x = 0;
  int32_t y = 0;
  if (!parse_point_args(method_call, &x, &y)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [x, y].", nullptr));
  }

  if (!ensure_session(self) ||
      !rust_render_bridge_notify_mouse_move(self->rust_render_bridge, self->session, x, y)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "input-failed", "Failed to forward mouse move.", nullptr));
  }
  schedule_servo_frame(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_notify_mouse_button(FlutterServoPlugin* self,
                                                    FlMethodCall* method_call) {
  int32_t x = 0;
  int32_t y = 0;
  uint8_t button = 0;
  bool is_down = false;
  if (!parse_point_button_args(method_call, &x, &y, &button, &is_down)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [x, y, button, isDown].", nullptr));
  }

  if (!ensure_session(self) ||
      !rust_render_bridge_notify_mouse_button(self->rust_render_bridge, self->session, x, y,
                                              button, is_down)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "input-failed", "Failed to forward mouse button.", nullptr));
  }
  schedule_servo_frame(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_notify_mouse_leave_viewport(FlutterServoPlugin* self) {
  if (!ensure_session(self) ||
      !rust_render_bridge_notify_mouse_leave_viewport(self->rust_render_bridge, self->session)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "input-failed", "Failed to forward mouse leave viewport.", nullptr));
  }
  schedule_servo_frame(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_notify_mouse_wheel(FlutterServoPlugin* self,
                                                   FlMethodCall* method_call) {
  int32_t x = 0;
  int32_t y = 0;
  int32_t delta_x = 0;
  int32_t delta_y = 0;
  if (!parse_wheel_args(method_call, &x, &y, &delta_x, &delta_y)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [x, y, deltaX, deltaY].", nullptr));
  }

  if (!ensure_session(self) ||
      !rust_render_bridge_notify_mouse_wheel(self->rust_render_bridge, self->session, x, y,
                                             delta_x, delta_y)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "input-failed", "Failed to forward mouse wheel.", nullptr));
  }
  schedule_servo_frame(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_notify_key_event(FlutterServoPlugin* self,
                                                 FlMethodCall* method_call) {
  const gchar* key_label = nullptr;
  const gchar* character = nullptr;
  bool is_down = false;
  if (!parse_key_args(method_call, &key_label, &character, &is_down)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [keyLabel, character, isDown].", nullptr));
  }

  if (!ensure_session(self) ||
      !rust_render_bridge_notify_key_event(self->rust_render_bridge, self->session,
                                           key_label, character, is_down)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "input-failed", "Failed to forward key event.", nullptr));
  }
  schedule_servo_frame(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void flutter_servo_plugin_dispose(GObject* object) {
  FlutterServoPlugin* self = FLUTTER_SERVO_PLUGIN(object);
  if (self->wake_source_id != 0) {
    g_source_remove(self->wake_source_id);
    self->wake_source_id = 0;
  }
  if (self->wake_fd >= 0) {
    close(self->wake_fd);
    self->wake_fd = -1;
  }
  if (self->frame_source_id != 0) {
    g_source_remove(self->frame_source_id);
    self->frame_source_id = 0;
  }
  if (self->texture) servo_texture_clear_shared_frame(self->texture);
  rust_render_bridge_destroy_session(self->rust_render_bridge, self->session);
  self->session = nullptr;
  if (self->texture != nullptr && self->texture_registrar != nullptr) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture));
  }
  g_clear_object(&self->texture);
  rust_render_bridge_free(self->rust_render_bridge);
  self->rust_render_bridge = nullptr;
  g_clear_object(&self->method_channel);
  g_clear_pointer(&self->http_proxy_uri, g_free);
  g_clear_pointer(&self->https_proxy_uri, g_free);
  g_clear_pointer(&self->no_proxy, g_free);
  g_clear_object(&self->texture_registrar);
  G_OBJECT_CLASS(flutter_servo_plugin_parent_class)->dispose(object);
}

static void flutter_servo_plugin_class_init(FlutterServoPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_servo_plugin_dispose;
}

static void flutter_servo_plugin_init(FlutterServoPlugin* self) {
  self->texture_registrar = nullptr;
  self->texture = nullptr;
  self->rust_render_bridge = rust_render_bridge_new();
  self->session = nullptr;
  self->method_channel = nullptr;
  self->http_proxy_uri = nullptr;
  self->https_proxy_uri = nullptr;
  self->no_proxy = nullptr;
  self->frame_source_id = 0;
  self->wake_source_id = 0;
  self->wake_fd = -1;
  self->load_progress = -1;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  FlutterServoPlugin* plugin = FLUTTER_SERVO_PLUGIN(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "createTexture") == 0) {
    response = handle_create_texture(plugin, method_call);
  } else if (strcmp(method, "resizeTexture") == 0) {
    response = handle_resize_texture(plugin, method_call);
  } else if (strcmp(method, "refreshTexture") == 0) {
    response = handle_refresh_texture(plugin);
  } else if (strcmp(method, "goBack") == 0) {
    response = handle_navigation_command(plugin, "back");
  } else if (strcmp(method, "goForward") == 0) {
    response = handle_navigation_command(plugin, "forward");
  } else if (strcmp(method, "reload") == 0) {
    response = handle_navigation_command(plugin, "reload");
  } else if (strcmp(method, "setUrl") == 0) {
    response = handle_set_url(plugin, method_call);
  } else if (strcmp(method, "setHtml") == 0) {
    response = handle_set_html(plugin, method_call);
  } else if (strcmp(method, "setProxySettings") == 0) {
    response = handle_set_proxy_settings(plugin, method_call);
  } else if (strcmp(method, "notifyMouseMove") == 0) {
    response = handle_notify_mouse_move(plugin, method_call);
  } else if (strcmp(method, "notifyMouseButton") == 0) {
    response = handle_notify_mouse_button(plugin, method_call);
  } else if (strcmp(method, "notifyMouseLeaveViewport") == 0) {
    response = handle_notify_mouse_leave_viewport(plugin);
  } else if (strcmp(method, "notifyMouseWheel") == 0) {
    response = handle_notify_mouse_wheel(plugin, method_call);
  } else if (strcmp(method, "notifyKeyEvent") == 0) {
    response = handle_notify_key_event(plugin, method_call);
  } else if (strcmp(method, "respondToControl") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    const bool accepted = fl_value_get_type(args) == FL_VALUE_TYPE_STRING &&
        rust_render_bridge_control_response(plugin->rust_render_bridge,
            plugin->session, fl_value_get_string(args));
    if (accepted) schedule_servo_frame(plugin);
    g_autoptr(FlValue) result = fl_value_new_bool(accepted);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "focusWebView") == 0) {
    response = handle_focus_webview(plugin);
  } else if (strcmp(method, "blurWebView") == 0) {
    response = handle_blur_webview(plugin);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void application_shutdown_cb(GApplication* application, FlutterServoPlugin* self) {
  (void)application;
  // Channel callbacks retain the plugin. Break that reference before process
  // teardown, while the graphics display and Servo runtime are still alive.
  g_object_ref(self);
  if (self->method_channel) {
    fl_method_channel_set_method_call_handler(self->method_channel, nullptr, nullptr, nullptr);
  }
  g_object_run_dispose(G_OBJECT(self));
  g_object_unref(self);
}

void flutter_servo_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  g_message("flutter_servo: linux plugin register_with_registrar");
  FlutterServoPlugin* plugin = FLUTTER_SERVO_PLUGIN(
      g_object_new(flutter_servo_plugin_get_type(), nullptr));
  plugin->texture_registrar = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "flutter_servo", FL_METHOD_CODEC(codec));
  plugin->method_channel = FL_METHOD_CHANNEL(g_object_ref(channel));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);
  g_message("flutter_servo: linux plugin method channel ready");

  if (GApplication* application = g_application_get_default()) {
    g_signal_connect_object(application, "shutdown", G_CALLBACK(application_shutdown_cb), plugin,
                            static_cast<GConnectFlags>(0));
  }

  g_object_unref(plugin);
}
