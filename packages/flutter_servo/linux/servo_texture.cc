#include "servo_texture.h"
#include "shared_frame.h"

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
  EGLDisplay consumer_display;
  ServoSharedFrame* shared_frame;
  bool shared_enabled;
};

G_DEFINE_TYPE(ServoTexture, servo_texture, fl_texture_gl_get_type())

static guint transfer_failed_signal;

static gboolean notify_transfer_failed(gpointer data) {
  g_signal_emit(data, transfer_failed_signal, 0);
  return G_SOURCE_REMOVE;
}

namespace {

class ScopedUploadState {
 public:
  ScopedUploadState() {
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture_);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &buffer_);
    for (int i = 0; i < 4; i++) glGetIntegerv(fields_[i], &values_[i]);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    for (int i = 1; i < 4; i++) glPixelStorei(fields_[i], 0);
  }
  ~ScopedUploadState() {
    for (int i = 0; i < 4; i++) glPixelStorei(fields_[i], values_[i]);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, buffer_);
    glBindTexture(GL_TEXTURE_2D, texture_);
  }
 private:
  const GLenum fields_[4] = {GL_UNPACK_ALIGNMENT, GL_UNPACK_ROW_LENGTH,
                            GL_UNPACK_SKIP_ROWS, GL_UNPACK_SKIP_PIXELS};
  GLint values_[4] = {}, texture_ = 0, buffer_ = 0;
};

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
    servo_shared_frame_free(self->shared_frame);
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
  self->consumer_display = eglGetCurrentDisplay();
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

  const ScopedUploadState upload_state;
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

  if (self->texture_width != self->front_width ||
      self->texture_height != self->front_height) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, self->front_width, self->front_height, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, self->shared_frame ? nullptr : pixels);
    self->texture_width = self->front_width;
    self->texture_height = self->front_height;
  } else if (self->upload_pending && !self->shared_frame) {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, self->front_width, self->front_height, GL_RGBA,
                    GL_UNSIGNED_BYTE, pixels);
  }
  if (self->shared_frame && self->upload_pending) {
    if (!servo_shared_frame_copy(self->shared_frame, self->texture_id)) {
      g_warning("flutter_servo: shared GPU frame import failed; disabling GPU transfer");
      self->shared_enabled = false;
      servo_shared_frame_free(self->shared_frame);
      self->shared_frame = nullptr;
      self->upload_pending = false;
      // Raster-thread failure must wake the producer even for an idle page.
      g_idle_add_full(G_PRIORITY_DEFAULT, notify_transfer_failed,
                      g_object_ref(self), g_object_unref);
      return FALSE;
    }
  }
  self->upload_pending = false;

  *target = GL_TEXTURE_2D;
  *name = self->texture_id;
  *width = self->front_width;
  *height = self->front_height;
  return TRUE;
}

static void servo_texture_class_init(ServoTextureClass* klass) {
  transfer_failed_signal = g_signal_new(
      "transfer-failed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST,
      0, nullptr, nullptr, nullptr, G_TYPE_NONE, 0);
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
  self->consumer_display = EGL_NO_DISPLAY;
  self->shared_frame = nullptr;
  self->shared_enabled = g_strcmp0(g_getenv("FLUTTER_SERVO_GPU_TEXTURES"), "1") == 0;
}

bool servo_texture_wants_shared_frame(ServoTexture* self) {
  const ScopedMutexLock lock(&self->buffer_mutex);
  return self->shared_enabled && self->consumer_display != EGL_NO_DISPLAY;
}

bool servo_texture_publish_current_frame(ServoTexture* self) {
  const ScopedMutexLock lock(&self->buffer_mutex);
  const bool reuse = self->shared_frame &&
      self->shared_frame->display == self->consumer_display &&
      self->shared_frame->width == self->width &&
      self->shared_frame->height == self->height;
  auto* frame = reuse
      ? (servo_shared_frame_update(self->shared_frame) ? self->shared_frame : nullptr)
      : servo_shared_frame_capture(self->consumer_display, self->width, self->height);
  if (!frame) {
    self->shared_enabled = false;
    g_warning("flutter_servo: GPU export unavailable; using CPU frame transfer");
    return false;
  }
  if (!self->shared_frame) g_message("flutter_servo: using shared EGL/DMA-BUF frames");
  if (!reuse) servo_shared_frame_free(self->shared_frame);
  self->shared_frame = frame;
  g_clear_pointer(&self->published_bytes, g_bytes_unref);
  self->front_width = self->width;
  self->front_height = self->height;
  self->upload_pending = true;
  return true;
}

void servo_texture_clear_shared_frame(ServoTexture* self) {
  const ScopedMutexLock lock(&self->buffer_mutex);
  servo_shared_frame_free(self->shared_frame);
  self->shared_frame = nullptr;
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
  servo_shared_frame_free(self->shared_frame);
  self->shared_frame = nullptr;
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
  servo_shared_frame_free(self->shared_frame);
  self->shared_frame = nullptr;
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
