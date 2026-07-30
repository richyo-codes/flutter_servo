#include "include/flutter_servo/flutter_servo_plugin.h"

#include <algorithm>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <cstring>

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
};

G_DEFINE_TYPE(FlutterServoPlugin, flutter_servo_plugin, g_object_get_type())

static void send_load_state_changed(FlutterServoPlugin* self, bool is_loading) {
  if (self == nullptr || self->method_channel == nullptr) {
    return;
  }

  g_autoptr(FlValue) args = fl_value_new_bool(is_loading);
  fl_method_channel_invoke_method(self->method_channel, "loadStateChanged",
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
  return self->session != nullptr;
}

static bool render_texture(FlutterServoPlugin* self, const gchar* fallback_seed) {
  if (self->texture == nullptr) {
    g_warning("flutter_servo: linux plugin render requested before texture creation");
    return false;
  }

  const bool rendered = ensure_session(self) &&
                        rust_render_bridge_render_session(
                            self->rust_render_bridge, self->session,
                            servo_texture_get_width(self->texture),
                            servo_texture_get_height(self->texture),
                            servo_texture_get_buffer(self->texture),
                            servo_texture_get_buffer_size(self->texture));

  if (!rendered) {
    g_warning("flutter_servo: linux plugin falling back to placeholder texture");
    servo_texture_paint_placeholder(self->texture, fallback_seed);
  }

  fl_texture_registrar_mark_texture_frame_available(self->texture_registrar,
                                                    FL_TEXTURE(self->texture));
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
  } else if (!render_texture(self, "resize")) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "render-failed", "Failed to render resized content.", nullptr));
  }

  g_autoptr(FlValue) id =
      fl_value_new_int(fl_texture_get_id(FL_TEXTURE(self->texture)));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(id));
}

static FlMethodResponse* handle_set_url(FlutterServoPlugin* self,
                                        FlMethodCall* method_call) {
  const gchar* url = parse_single_string_arg(method_call);
  if (url == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid-args", "Expected [url].", nullptr));
  }
  g_message("flutter_servo: linux plugin setUrl");
  send_load_state_changed(self, true);
  if (!ensure_session(self) ||
      !rust_render_bridge_set_url(self->rust_render_bridge, self->session,
                                  url)) {
    send_load_state_changed(self, false);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-update-failed", "Failed to set URL content.", nullptr));
  }
  if (!render_texture(self, url)) {
    send_load_state_changed(self, false);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "render-failed", "Failed to render URL content.", nullptr));
  }
  send_load_state_changed(self, false);
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
  send_load_state_changed(self, true);
  if (!ensure_session(self) ||
      !rust_render_bridge_set_html(self->rust_render_bridge, self->session,
                                   html)) {
    send_load_state_changed(self, false);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-update-failed", "Failed to set HTML content.", nullptr));
  }
  if (!render_texture(self, html)) {
    send_load_state_changed(self, false);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "render-failed", "Failed to render HTML content.", nullptr));
  }
  send_load_state_changed(self, false);
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
  render_texture(self, "mouse-move");
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
  render_texture(self, "mouse-button");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_notify_mouse_leave_viewport(FlutterServoPlugin* self) {
  if (!ensure_session(self) ||
      !rust_render_bridge_notify_mouse_leave_viewport(self->rust_render_bridge, self->session)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "input-failed", "Failed to forward mouse leave viewport.", nullptr));
  }
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
  render_texture(self, "mouse-wheel");
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
  render_texture(self, "key-event");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void flutter_servo_plugin_dispose(GObject* object) {
  FlutterServoPlugin* self = FLUTTER_SERVO_PLUGIN(object);
  g_clear_object(&self->texture);
  rust_render_bridge_destroy_session(self->rust_render_bridge, self->session);
  self->session = nullptr;
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
  } else if (strcmp(method, "focusWebView") == 0) {
    response = handle_focus_webview(plugin);
  } else if (strcmp(method, "blurWebView") == 0) {
    response = handle_blur_webview(plugin);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
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

  g_object_unref(plugin);
}
