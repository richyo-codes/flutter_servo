#ifndef FLUTTER_SERVO_RUST_RENDER_BRIDGE_H_
#define FLUTTER_SERVO_RUST_RENDER_BRIDGE_H_

#include <cstddef>
#include <cstdint>
#include <glib.h>

typedef struct _RustRenderBridge RustRenderBridge;
typedef void* RustRenderSessionHandle;

RustRenderBridge* rust_render_bridge_new();

void rust_render_bridge_free(RustRenderBridge* self);

RustRenderSessionHandle rust_render_bridge_create_session(
    RustRenderBridge* self,
    const char* http_proxy_uri,
    const char* https_proxy_uri,
    const char* no_proxy);

void rust_render_bridge_destroy_session(RustRenderBridge* self,
                                        RustRenderSessionHandle session);

bool rust_render_bridge_set_url(RustRenderBridge* self,
                                RustRenderSessionHandle session,
                                const char* url);

bool rust_render_bridge_set_html(RustRenderBridge* self,
                                 RustRenderSessionHandle session,
                                 const char* html);

bool rust_render_bridge_go_back(RustRenderBridge* self,
                                RustRenderSessionHandle session);

bool rust_render_bridge_go_forward(RustRenderBridge* self,
                                   RustRenderSessionHandle session);

bool rust_render_bridge_reload(RustRenderBridge* self,
                               RustRenderSessionHandle session);

bool rust_render_bridge_is_animating(RustRenderBridge* self,
                                     RustRenderSessionHandle session);

bool rust_render_bridge_poll(RustRenderBridge* self,
                             RustRenderSessionHandle session);

// Returns an owned nonblocking descriptor, or -1 for an older bridge.
int rust_render_bridge_wake_fd(RustRenderBridge* self,
                               RustRenderSessionHandle session);

bool rust_render_bridge_get_navigation_state(RustRenderBridge* self,
                                             RustRenderSessionHandle session,
                                             char* url_out,
                                             size_t url_out_len,
                                             bool* can_go_back_out,
                                             bool* can_go_forward_out);

bool rust_render_bridge_notify_mouse_move(RustRenderBridge* self,
                                          RustRenderSessionHandle session,
                                          int32_t x,
                                          int32_t y);

bool rust_render_bridge_notify_mouse_button(RustRenderBridge* self,
                                            RustRenderSessionHandle session,
                                            int32_t x,
                                            int32_t y,
                                            uint8_t button,
                                            bool is_down);

bool rust_render_bridge_notify_mouse_leave_viewport(
    RustRenderBridge* self,
    RustRenderSessionHandle session);

bool rust_render_bridge_notify_mouse_wheel(RustRenderBridge* self,
                                           RustRenderSessionHandle session,
                                           int32_t x,
                                           int32_t y,
                                           int32_t delta_x,
                                           int32_t delta_y);

bool rust_render_bridge_notify_key_event(RustRenderBridge* self,
                                         RustRenderSessionHandle session,
                                         const char* key_label,
                                         const char* character,
                                         bool is_down);

bool rust_render_bridge_focus_webview(RustRenderBridge* self,
                                      RustRenderSessionHandle session);

bool rust_render_bridge_blur_webview(RustRenderBridge* self,
                                     RustRenderSessionHandle session);

bool rust_render_bridge_render_session(RustRenderBridge* self,
                                       RustRenderSessionHandle session,
                                       uint32_t width,
                                       uint32_t height,
                                       uint8_t* out_buffer,
                                       size_t out_len);

// Returns a Rust-owned immutable RGBA frame, or null when unsupported.
GBytes* rust_render_bridge_render_frame(RustRenderBridge* self,
                                        RustRenderSessionHandle session,
                                        uint32_t width,
                                        uint32_t height);

bool rust_render_bridge_supports_owned_frames(RustRenderBridge* self);

#endif  // FLUTTER_SERVO_RUST_RENDER_BRIDGE_H_
