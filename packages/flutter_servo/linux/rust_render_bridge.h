#ifndef FLUTTER_SERVO_RUST_RENDER_BRIDGE_H_
#define FLUTTER_SERVO_RUST_RENDER_BRIDGE_H_

#include <cstddef>
#include <cstdint>

typedef struct _RustRenderBridge RustRenderBridge;
typedef void* RustRenderSessionHandle;

RustRenderBridge* rust_render_bridge_new();

void rust_render_bridge_free(RustRenderBridge* self);

RustRenderSessionHandle rust_render_bridge_create_session(RustRenderBridge* self);

void rust_render_bridge_destroy_session(RustRenderBridge* self,
                                        RustRenderSessionHandle session);

bool rust_render_bridge_set_url(RustRenderBridge* self,
                                RustRenderSessionHandle session,
                                const char* url);

bool rust_render_bridge_set_html(RustRenderBridge* self,
                                 RustRenderSessionHandle session,
                                 const char* html);

bool rust_render_bridge_render_session(RustRenderBridge* self,
                                       RustRenderSessionHandle session,
                                       uint32_t width,
                                       uint32_t height,
                                       uint8_t* out_buffer,
                                       size_t out_len);

#endif  // FLUTTER_SERVO_RUST_RENDER_BRIDGE_H_
