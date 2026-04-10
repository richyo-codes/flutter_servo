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
};

G_DEFINE_TYPE(FlutterServoPlugin, flutter_servo_plugin, g_object_get_type())

static bool ensure_session(FlutterServoPlugin* self) {
  if (self->session != nullptr) {
    return true;
  }

  g_message("flutter_servo: linux plugin creating Rust render session");
  self->session = rust_render_bridge_create_session(self->rust_render_bridge);
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
  publish_placeholder_texture(self, "resize");

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
  if (!ensure_session(self) ||
      !rust_render_bridge_set_url(self->rust_render_bridge, self->session,
                                  url)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-update-failed", "Failed to set URL content.", nullptr));
  }
  render_texture(self, url);
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
  if (!ensure_session(self) ||
      !rust_render_bridge_set_html(self->rust_render_bridge, self->session,
                                   html)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "session-update-failed", "Failed to set HTML content.", nullptr));
  }
  render_texture(self, html);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void flutter_servo_plugin_dispose(GObject* object) {
  FlutterServoPlugin* self = FLUTTER_SERVO_PLUGIN(object);
  g_clear_object(&self->texture);
  rust_render_bridge_destroy_session(self->rust_render_bridge, self->session);
  self->session = nullptr;
  rust_render_bridge_free(self->rust_render_bridge);
  self->rust_render_bridge = nullptr;
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
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);
  g_message("flutter_servo: linux plugin method channel ready");

  g_object_unref(plugin);
}
