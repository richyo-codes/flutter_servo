#include "shared_frame.h"

#include <glib.h>
#include <gbm.h>
#include <fcntl.h>
#include <unistd.h>

#ifndef EGL_DRM_RENDER_NODE_FILE_EXT
#define EGL_DRM_RENDER_NODE_FILE_EXT 0x3377
#endif

static ServoSharedFrame* capture_linear_dmabuf(EGLDisplay producer,
    EGLDisplay consumer, uint32_t width, uint32_t height) {
  if (!epoxy_has_egl_extension(EGL_NO_DISPLAY, "EGL_EXT_device_query") ||
      !epoxy_has_egl_extension(producer, "EGL_EXT_image_dma_buf_import_modifiers") ||
      !epoxy_has_egl_extension(consumer, "EGL_EXT_image_dma_buf_import_modifiers")) {
    g_warning("flutter_servo: GPU device-query or DMA-BUF modifier import unavailable");
    return nullptr;
  }
  EGLAttrib device_attrib = 0;
  if (!eglQueryDisplayAttribEXT(producer, EGL_DEVICE_EXT, &device_attrib)) {
    g_warning("flutter_servo: cannot query producer EGL device"); return nullptr;
  }
  auto device = reinterpret_cast<EGLDeviceEXT>(device_attrib);
  const char* node = eglQueryDeviceStringEXT(device, EGL_DRM_RENDER_NODE_FILE_EXT);
  if (!node) node = eglQueryDeviceStringEXT(device, EGL_DRM_DEVICE_FILE_EXT);
  if (!node) {
    g_warning("flutter_servo: producer has no DRM device; renderer=%s", glGetString(GL_RENDERER));
    return nullptr;
  }
  const int device_fd = open(node, O_RDWR | O_CLOEXEC);
  if (device_fd < 0) { g_warning("flutter_servo: cannot open producer render node"); return nullptr; }
  gbm_device* gbm = gbm_create_device(device_fd);
  gbm_bo* buffer = gbm ? gbm_bo_create(gbm, width, height, GBM_FORMAT_ABGR8888,
      GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR) : nullptr;
  const int fd = buffer ? gbm_bo_get_fd(buffer) : -1;
  EGLImageKHR source = EGL_NO_IMAGE_KHR, destination = EGL_NO_IMAGE_KHR;
  // GBM_BO_USE_LINEAR requires linear storage even on drivers that report an
  // implicit modifier for legacy gbm_bo_create allocations.
  if (fd >= 0) {
    const EGLint attrs[] = {EGL_WIDTH, static_cast<EGLint>(width),
        EGL_HEIGHT, static_cast<EGLint>(height), EGL_LINUX_DRM_FOURCC_EXT, GBM_FORMAT_ABGR8888,
        EGL_DMA_BUF_PLANE0_FD_EXT, fd, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
        EGL_DMA_BUF_PLANE0_PITCH_EXT, static_cast<EGLint>(gbm_bo_get_stride(buffer)),
        EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, 0, EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0, EGL_NONE};
    source = eglCreateImageKHR(producer, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, attrs);
    destination = eglCreateImageKHR(consumer, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, attrs);
  }
  bool copied = false;
  if (source != EGL_NO_IMAGE_KHR && destination != EGL_NO_IMAGE_KHR) {
    GLint old_texture = 0, old_draw = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &old_texture);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &old_draw);
    GLuint texture = 0, framebuffer = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, source);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    const bool scissor = glIsEnabled(GL_SCISSOR_TEST);
    glDisable(GL_SCISSOR_TEST);
    if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
      glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
      glFinish();
      copied = glGetError() == GL_NO_ERROR;
    }
    if (scissor) glEnable(GL_SCISSOR_TEST);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, old_draw);
    glBindTexture(GL_TEXTURE_2D, old_texture);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
  }
  if (source != EGL_NO_IMAGE_KHR) eglDestroyImageKHR(producer, source);
  if (fd >= 0) close(fd);
  if (buffer) gbm_bo_destroy(buffer);
  if (gbm) gbm_device_destroy(gbm);
  close(device_fd);
  if (!copied) {
    g_warning("flutter_servo: linear DMA-BUF capture failed: allocation=%d source=%d destination=%d EGL=0x%x GL=0x%x",
        fd >= 0, source != EGL_NO_IMAGE_KHR, destination != EGL_NO_IMAGE_KHR, eglGetError(), glGetError());
    if (destination != EGL_NO_IMAGE_KHR) eglDestroyImageKHR(consumer, destination);
    return nullptr;
  }
  return new ServoSharedFrame{consumer, destination, width, height};
}

ServoSharedFrame* servo_shared_frame_capture(EGLDisplay consumer_display,
                                            uint32_t width, uint32_t height) {
  const EGLDisplay producer_display = eglGetCurrentDisplay();
  const EGLContext context = eglGetCurrentContext();
  if (producer_display == EGL_NO_DISPLAY || consumer_display == EGL_NO_DISPLAY ||
      context == EGL_NO_CONTEXT ||
      !epoxy_has_egl_extension(producer_display, "EGL_KHR_gl_texture_2D_image")) {
    g_warning("flutter_servo: EGL sharing unavailable: producer=%p consumer=%p context=%p",
        producer_display, consumer_display, context);
    return nullptr;
  }
  if (producer_display != consumer_display) {
    return capture_linear_dmabuf(producer_display, consumer_display, width, height);
  }

  GLint previous_texture = 0, previous_unpack_buffer = 0;
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &previous_texture);
  glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &previous_unpack_buffer);
  // nullptr means an offset into a bound PBO, not allocation-only storage.
  // WebRender owns the producer context, so preserve its upload-buffer state.
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
  GLuint texture = 0;
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, width, height);
  const GLenum copy_error = glGetError();
  const EGLint attributes[] = {EGL_GL_TEXTURE_LEVEL_KHR, 0,
                              EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
  EGLImageKHR image = copy_error == GL_NO_ERROR
      ? eglCreateImageKHR(producer_display, context, EGL_GL_TEXTURE_2D_KHR,
          reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(texture)), attributes)
      : EGL_NO_IMAGE_KHR;
  // Completion is explicit at this first implementation boundary. Replace this
  // with native fence FD transfer once the producer/consumer path is validated.
  glFinish();
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER, previous_unpack_buffer);
  glBindTexture(GL_TEXTURE_2D, previous_texture);
  glDeleteTextures(1, &texture);
  if (image == EGL_NO_IMAGE_KHR) {
    g_debug("flutter_servo: EGL snapshot failed: GL=0x%x EGL=0x%x", copy_error, eglGetError());
    return nullptr;
  }

  return new ServoSharedFrame{consumer_display, image, width, height};
}

bool servo_shared_frame_copy(ServoSharedFrame* frame, GLuint destination) {
  if (eglGetCurrentDisplay() != frame->display ||
      !epoxy_has_gl_extension("GL_OES_EGL_image")) return false;
  GLint old_read = 0, old_draw = 0, old_texture = 0;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &old_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &old_draw);
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &old_texture);
  GLuint imported = 0, fbos[2] = {};
  glGenTextures(1, &imported);
  glBindTexture(GL_TEXTURE_2D, imported);
  glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, frame->image);
  glGenFramebuffers(2, fbos);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fbos[0]);
  glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, imported, 0);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbos[1]);
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, destination, 0);
  bool complete = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE &&
      glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  const bool scissor = glIsEnabled(GL_SCISSOR_TEST);
  glDisable(GL_SCISSOR_TEST);
  if (complete) {
    // Match read_to_image's vertical flip, without reading pixels to the CPU.
    glBlitFramebuffer(0, 0, frame->width, frame->height,
        0, frame->height, frame->width, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glFinish();
    complete = glGetError() == GL_NO_ERROR;
  }
  if (scissor) glEnable(GL_SCISSOR_TEST);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, old_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, old_draw);
  glBindTexture(GL_TEXTURE_2D, old_texture);
  glDeleteFramebuffers(2, fbos);
  glDeleteTextures(1, &imported);
  return complete;
}

void servo_shared_frame_free(ServoSharedFrame* frame) {
  if (!frame) return;
  eglDestroyImageKHR(frame->display, frame->image);
  delete frame;
}
