#include "servo_texture.h"

#include <algorithm>
#include <cstdint>

#include <epoxy/gl.h>
#include <gtk/gtk.h>

struct _ServoTexture {
  FlTextureGL parent_instance;

  uint32_t width;
  uint32_t height;
  uint8_t* front_buffer;
  uint8_t* back_buffer;
  uint32_t front_width;
  uint32_t front_height;
  bool upload_pending;
  GBytes* published_bytes;
  GMutex buffer_mutex;
  GLuint texture_id;
  uint32_t texture_width;
  uint32_t texture_height;
};

G_DEFINE_TYPE(ServoTexture, servo_texture, fl_texture_gl_get_type())

namespace {

class ScopedMutexLock {
 public:
  explicit ScopedMutexLock(GMutex* mutex) : mutex_(mutex) {
    g_mutex_lock(mutex_);
  }
  ~ScopedMutexLock() { g_mutex_unlock(mutex_); }

  ScopedMutexLock(const ScopedMutexLock&) = delete;
  ScopedMutexLock& operator=(const ScopedMutexLock&) = delete;

 private:
  GMutex* mutex_;
};

constexpr uint8_t kAlpha = 255;

uint32_t hash_seed(const gchar* seed) {
  uint32_t value = 2166136261u;
  if (seed == nullptr) {
    return value;
  }

  for (const unsigned char* ptr =
           reinterpret_cast<const unsigned char*>(seed);
       *ptr != '\0'; ptr++) {
    value ^= *ptr;
    value *= 16777619u;
  }
  return value;
}

void write_pixel(uint8_t* pixel, uint8_t r, uint8_t g, uint8_t b) {
  pixel[0] = r;
  pixel[1] = g;
  pixel[2] = b;
  pixel[3] = kAlpha;
}

void fill_rect(ServoTexture* self,
               uint32_t x,
               uint32_t y,
               uint32_t width,
               uint32_t height,
               uint8_t r,
               uint8_t g,
               uint8_t b) {
  const uint32_t max_x = std::min(self->width, x + width);
  const uint32_t max_y = std::min(self->height, y + height);
  for (uint32_t yy = y; yy < max_y; yy++) {
    for (uint32_t xx = x; xx < max_x; xx++) {
      uint8_t* pixel = self->back_buffer + ((yy * self->width + xx) * 4);
      write_pixel(pixel, r, g, b);
    }
  }
}

void ensure_buffer_locked(ServoTexture* self) {
  const size_t size = static_cast<size_t>(self->width) * self->height * 4;
  self->back_buffer =
      static_cast<uint8_t*>(g_realloc(self->back_buffer, size));
}

void ensure_buffer(ServoTexture* self) {
  const ScopedMutexLock lock(&self->buffer_mutex);
  ensure_buffer_locked(self);
}

}  // namespace

static void servo_texture_dispose(GObject* object) {
  ServoTexture* self = SERVO_TEXTURE(object);
  if (self->texture_id != 0 && gdk_gl_context_get_current() != nullptr) {
    glDeleteTextures(1, &self->texture_id);
  }
  self->texture_id = 0;
  self->texture_width = 0;
  self->texture_height = 0;
  G_OBJECT_CLASS(servo_texture_parent_class)->dispose(object);
}

static void servo_texture_finalize(GObject* object) {
  ServoTexture* self = SERVO_TEXTURE(object);
  {
    const ScopedMutexLock lock(&self->buffer_mutex);
    g_free(self->front_buffer);
    g_free(self->back_buffer);
    g_clear_pointer(&self->published_bytes, g_bytes_unref);
    self->front_buffer = nullptr;
    self->back_buffer = nullptr;
  }
  g_mutex_clear(&self->buffer_mutex);

  G_OBJECT_CLASS(servo_texture_parent_class)->finalize(object);
}

static gboolean servo_texture_populate(FlTextureGL* texture,
                                       uint32_t* target,
                                       uint32_t* name,
                                       uint32_t* width,
                                       uint32_t* height,
                                       GError** error) {
  (void)error;
  ServoTexture* self = SERVO_TEXTURE(texture);
  const ScopedMutexLock lock(&self->buffer_mutex);
  if (self->front_buffer == nullptr) {
    return FALSE;
  }
  const uint8_t* pixels = self->front_buffer;
  if (self->published_bytes != nullptr) {
    gsize len = 0;
    pixels = static_cast<const uint8_t*>(
        g_bytes_get_data(self->published_bytes, &len));
    if (pixels == nullptr ||
        len != static_cast<gsize>(self->front_width) * self->front_height * 4) {
      return FALSE;
    }
  }

  if (self->texture_id == 0) {
    glGenTextures(1, &self->texture_id);
    if (self->texture_id == 0) {
      return FALSE;
    }
    glBindTexture(GL_TEXTURE_2D, self->texture_id);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  } else {
    glBindTexture(GL_TEXTURE_2D, self->texture_id);
  }

  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  if (self->texture_width != self->front_width ||
      self->texture_height != self->front_height) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, self->front_width, self->front_height, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    self->texture_width = self->front_width;
    self->texture_height = self->front_height;
  } else if (self->upload_pending) {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, self->front_width, self->front_height, GL_RGBA,
                    GL_UNSIGNED_BYTE, pixels);
  }
  self->upload_pending = false;
  glBindTexture(GL_TEXTURE_2D, 0);

  *target = GL_TEXTURE_2D;
  *name = self->texture_id;
  *width = self->front_width;
  *height = self->front_height;
  return TRUE;
}

static void servo_texture_class_init(ServoTextureClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = servo_texture_dispose;
  G_OBJECT_CLASS(klass)->finalize = servo_texture_finalize;
  FL_TEXTURE_GL_CLASS(klass)->populate = servo_texture_populate;
}

static void servo_texture_init(ServoTexture* self) {
  self->width = 1;
  self->height = 1;
  self->front_buffer = nullptr;
  self->back_buffer = nullptr;
  self->published_bytes = nullptr;
  g_mutex_init(&self->buffer_mutex);
  self->texture_id = 0;
  self->texture_width = 0;
  self->texture_height = 0;
}

ServoTexture* servo_texture_new(uint32_t width,
                                uint32_t height,
                                const gchar* seed) {
  ServoTexture* self =
      SERVO_TEXTURE(g_object_new(servo_texture_get_type(), nullptr));
  self->width = std::max(width, 1u);
  self->height = std::max(height, 1u);
  ensure_buffer(self);
  servo_texture_paint_placeholder(self, seed);
  return self;
}

void servo_texture_resize(ServoTexture* self, uint32_t width, uint32_t height) {
  g_return_if_fail(SERVO_IS_TEXTURE(self));

  width = std::max(width, 1u);
  height = std::max(height, 1u);
  if (self->width == width && self->height == height) {
    return;
  }

  const ScopedMutexLock lock(&self->buffer_mutex);
  self->width = width;
  self->height = height;
  ensure_buffer_locked(self);
}

uint32_t servo_texture_get_width(ServoTexture* self) {
  g_return_val_if_fail(SERVO_IS_TEXTURE(self), 0);
  return self->width;
}

uint32_t servo_texture_get_height(ServoTexture* self) {
  g_return_val_if_fail(SERVO_IS_TEXTURE(self), 0);
  return self->height;
}

uint8_t* servo_texture_get_buffer(ServoTexture* self) {
  g_return_val_if_fail(SERVO_IS_TEXTURE(self), nullptr);
  return self->back_buffer;
}

size_t servo_texture_get_buffer_size(ServoTexture* self) {
  g_return_val_if_fail(SERVO_IS_TEXTURE(self), 0);
  return static_cast<size_t>(self->width) * self->height * 4;
}

void servo_texture_publish_frame(ServoTexture* self) {
  g_return_if_fail(SERVO_IS_TEXTURE(self));

  const ScopedMutexLock lock(&self->buffer_mutex);
  g_clear_pointer(&self->published_bytes, g_bytes_unref);
  std::swap(self->front_buffer, self->back_buffer);
  self->front_width = self->width;
  self->front_height = self->height;
  self->upload_pending = true;
  // The retired front frame may have a different allocation after resize.
  ensure_buffer_locked(self);
}

bool servo_texture_publish_bytes(ServoTexture* self,
                                 GBytes* frame,
                                 uint32_t width,
                                 uint32_t height) {
  g_return_val_if_fail(SERVO_IS_TEXTURE(self), false);
  if (frame == nullptr || width == 0 || height == 0) {
    return false;
  }
  gsize len = 0;
  if (g_bytes_get_data(frame, &len) == nullptr ||
      len != static_cast<gsize>(width) * height * 4) {
    return false;
  }

  const ScopedMutexLock lock(&self->buffer_mutex);
  g_clear_pointer(&self->published_bytes, g_bytes_unref);
  self->published_bytes = frame;
  self->front_width = width;
  self->front_height = height;
  self->upload_pending = true;
  return true;
}

void servo_texture_paint_placeholder(ServoTexture* self, const gchar* seed) {
  g_return_if_fail(SERVO_IS_TEXTURE(self));

  const uint32_t hash = hash_seed(seed);
  const uint8_t accent_r = 48 + (hash & 0x3f);
  const uint8_t accent_g = 110 + ((hash >> 8) & 0x4f);
  const uint8_t accent_b = 120 + ((hash >> 16) & 0x5f);

  for (uint32_t y = 0; y < self->height; y++) {
    for (uint32_t x = 0; x < self->width; x++) {
      const float yf =
          self->height > 1 ? static_cast<float>(y) / (self->height - 1) : 0.f;
      const float xf =
          self->width > 1 ? static_cast<float>(x) / (self->width - 1) : 0.f;

      uint8_t r = static_cast<uint8_t>(250 - yf * 18 - xf * 4);
      uint8_t g = static_cast<uint8_t>(247 - yf * 10 + xf * 4);
      uint8_t b = static_cast<uint8_t>(241 - yf * 6 + xf * 8);
      uint8_t* pixel = self->back_buffer + ((y * self->width + x) * 4);
      write_pixel(pixel, r, g, b);
    }
  }

  const uint32_t toolbar_height = std::max(56u, self->height / 9);
  fill_rect(self, 0, 0, self->width, toolbar_height, 230, 233, 229);

  const uint32_t address_x = std::max(24u, self->width / 8);
  const uint32_t address_y = toolbar_height / 4;
  const uint32_t address_width = std::min(self->width - address_x * 2,
                                          self->width * 3 / 4);
  const uint32_t address_height = std::max(28u, toolbar_height / 2);
  fill_rect(self, address_x, address_y, address_width, address_height, 246, 247,
            245);

  const uint32_t hero_margin = std::max(36u, self->width / 18);
  const uint32_t hero_y = toolbar_height + std::max(28u, self->height / 24);
  const uint32_t hero_height = std::max(84u, self->height / 5);
  fill_rect(self, hero_margin, hero_y, self->width - hero_margin * 2,
            hero_height, accent_r, accent_g, accent_b);

  const uint32_t card_y =
      hero_y + hero_height + std::max(24u, self->height / 32);
  const uint32_t card_width = self->width - hero_margin * 2;
  const uint32_t card_height =
      std::max(160u, self->height - card_y - std::max(32u, self->height / 28));
  fill_rect(self, hero_margin, card_y, card_width, card_height, 255, 255, 255);

  const uint32_t line_x = hero_margin + std::max(18u, self->width / 48);
  uint32_t line_y = card_y + std::max(22u, self->height / 40);
  for (int i = 0; i < 6; i++) {
    const uint32_t line_width =
        card_width - std::max(36u, self->width / 20) - (i % 2 == 0 ? 0 : 64);
    fill_rect(self, line_x, line_y, line_width, 12, 213, 218, 214);
    line_y += 26;
  }

  servo_texture_publish_frame(self);
}
