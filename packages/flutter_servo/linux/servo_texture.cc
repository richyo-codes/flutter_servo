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
  (void)seed;
  std::fill_n(self->back_buffer, servo_texture_get_buffer_size(self), 0);
  servo_texture_publish_frame(self);
}
