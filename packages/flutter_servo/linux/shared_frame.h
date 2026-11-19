#ifndef FLUTTER_SERVO_SHARED_FRAME_H_
#define FLUTTER_SERVO_SHARED_FRAME_H_

#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <cstdint>

// Reusable GPU storage. Callers serialize access; fences order GPU access across
// contexts. EGLImages retain storage independently of temporary GL objects.
struct ServoSharedFrame {
  EGLDisplay display;
  EGLImageKHR image;
  uint32_t width;
  uint32_t height;
  EGLDisplay producer_display = EGL_NO_DISPLAY;
  EGLContext producer_context = EGL_NO_CONTEXT;
  EGLContext consumer_context = EGL_NO_CONTEXT;
  EGLImageKHR producer_image = EGL_NO_IMAGE_KHR;
  int ready_fd = -1;
  int release_fd = -1;
  bool native_fences = false;
};

ServoSharedFrame* servo_shared_frame_capture(EGLDisplay consumer_display,
                                            uint32_t width, uint32_t height);
bool servo_shared_frame_copy(ServoSharedFrame* frame, GLuint destination);
bool servo_shared_frame_update(ServoSharedFrame* frame);
void servo_shared_frame_free(ServoSharedFrame* frame);

#endif
