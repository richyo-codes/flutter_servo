#ifndef FLUTTER_SERVO_TEXTURE_H_
#define FLUTTER_SERVO_TEXTURE_H_

#include <cstddef>
#include <cstdint>

#include <flutter_linux/flutter_linux.h>

G_DECLARE_FINAL_TYPE(ServoTexture,
                     servo_texture,
                     SERVO,
                     TEXTURE,
                     FlTextureGL)

ServoTexture* servo_texture_new(uint32_t width,
                                uint32_t height,
                                const gchar* seed);

void servo_texture_resize(ServoTexture* self, uint32_t width, uint32_t height);

uint32_t servo_texture_get_width(ServoTexture* self);

uint32_t servo_texture_get_height(ServoTexture* self);

uint8_t* servo_texture_get_buffer(ServoTexture* self);

size_t servo_texture_get_buffer_size(ServoTexture* self);

void servo_texture_paint_placeholder(ServoTexture* self, const gchar* seed);

#endif  // FLUTTER_SERVO_TEXTURE_H_
