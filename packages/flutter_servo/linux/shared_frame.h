#ifndef FLUTTER_SERVO_SHARED_FRAME_H_
#define FLUTTER_SERVO_SHARED_FRAME_H_

#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <cstdint>

// An immutable GPU snapshot. EGLImage owns the storage after its GL texture is
// deleted. The consumer blits into its stable Flutter texture before releasing it.
struct ServoSharedFrame {
  EGLDisplay display;
  EGLImageKHR image;
  uint32_t width;
  uint32_t height;
};

ServoSharedFrame* servo_shared_frame_capture(EGLDisplay consumer_display,
                                            uint32_t width, uint32_t height);
bool servo_shared_frame_copy(ServoSharedFrame* frame, GLuint destination);
void servo_shared_frame_free(ServoSharedFrame* frame);

#endif
