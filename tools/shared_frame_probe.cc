#include "../packages/flutter_servo/linux/shared_frame.h"

#include <cstdio>
#include <cstring>
#include <vector>

static EGLContext create_context(EGLDisplay display) {
  const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
      EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
  EGLConfig config;
  EGLint count = 0;
  if (!eglChooseConfig(display, attrs, &config, 1, &count) || count != 1) return EGL_NO_CONTEXT;
  const EGLint context_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3,
      EGL_CONTEXT_MINOR_VERSION, 3, EGL_NONE};
  return eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
}

int main(int argc, char** argv) {
  EGLDisplay producer = eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA,
      EGL_DEFAULT_DISPLAY, nullptr);
  if (!eglInitialize(producer, nullptr, nullptr) || !eglBindAPI(EGL_OPENGL_API)) return 1;
  const bool cross_display = argc > 1 && strcmp(argv[1], "--cross-display") == 0;
  EGLDisplay consumer = cross_display ? eglGetDisplay(EGL_DEFAULT_DISPLAY) : producer;
  if (cross_display && !eglInitialize(consumer, nullptr, nullptr)) return 2;
  EGLContext producer_context = create_context(producer);
  EGLContext consumer_context = create_context(consumer);
  if (producer_context == EGL_NO_CONTEXT || consumer_context == EGL_NO_CONTEXT) return 3;
  eglMakeCurrent(producer, EGL_NO_SURFACE, EGL_NO_SURFACE, producer_context);
  std::printf("producer: %s\n", glGetString(GL_RENDERER));
  eglMakeCurrent(consumer, EGL_NO_SURFACE, EGL_NO_SURFACE, consumer_context);
  std::printf("consumer: %s\n", glGetString(GL_RENDERER));
  for (int sample = 0; sample < 12; sample++) {
    const int width = sample < 2 ? 17 + sample * 14 : (sample % 2 ? 832 : 800);
    const int height = sample < 2 ? 29 - sample * 16 : (sample % 2 ? 640 : 600);
    if (!eglMakeCurrent(producer, EGL_NO_SURFACE, EGL_NO_SURFACE, producer_context)) return 4;
    GLuint source = 0, framebuffer = 0;
    glGenTextures(1, &source);
    glBindTexture(GL_TEXTURE_2D, source);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, source, 0);
    glClearColor(0, 0, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_SCISSOR_TEST);
    glScissor(0, height / 2, width, height - height / 2);
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_SCISSOR_TEST);
    ServoSharedFrame* frame = servo_shared_frame_capture(consumer, width, height);
    if (!frame) { std::fprintf(stderr, "GPU export failed\n"); return 5; }
    // The snapshot must survive both source mutation and source destruction.
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &source);
    if (!eglMakeCurrent(consumer, EGL_NO_SURFACE, EGL_NO_SURFACE, consumer_context)) return 6;
    GLuint destination = 0;
    glGenTextures(1, &destination);
    glBindTexture(GL_TEXTURE_2D, destination);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    if (!servo_shared_frame_copy(frame, destination)) return 7;
    servo_shared_frame_free(frame);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, destination, 0);
    std::vector<unsigned char> pixels(width * height * 4);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    if (pixels[0] != 255 || pixels[1] != 0 || pixels[2] != 0 ||
        pixels[pixels.size() - 4] != 0 || pixels[pixels.size() - 2] != 255) {
      std::fprintf(stderr, "GPU pixel/orientation mismatch sample=%d top=%u,%u,%u bottom=%u,%u,%u\n",
          sample, pixels[0], pixels[1], pixels[2], pixels[pixels.size()-4],
          pixels[pixels.size()-3], pixels[pixels.size()-2]); return 8;
    }
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &destination);
  }
  eglMakeCurrent(consumer, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroyContext(consumer, consumer_context);
  eglDestroyContext(producer, producer_context);
  if (cross_display) eglTerminate(consumer);
  eglTerminate(producer);
  std::printf("GPU sharing passed: %s, 12 frames, resize, orientation, immutable storage\n",
      cross_display ? "cross-display DMA-BUF" : "same-display EGLImage");
}
