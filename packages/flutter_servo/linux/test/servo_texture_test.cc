// Include the implementation to inspect publication without a display server.
#include "../servo_texture.cc"
#include "../navigation_state.h"

#include <cstring>

static unsigned captures = 0;
static unsigned updates = 0;
static bool update_succeeds = true;
static unsigned uploads = 0;
static unsigned released_frames = 0;
static GLint gl_state[6] = {73, 91, 8, 100, 2, 3};
static const GLenum state_fields[] = {GL_TEXTURE_BINDING_2D,
    GL_PIXEL_UNPACK_BUFFER_BINDING, GL_UNPACK_ALIGNMENT, GL_UNPACK_ROW_LENGTH,
    GL_UNPACK_SKIP_ROWS, GL_UNPACK_SKIP_PIXELS};

ServoSharedFrame* servo_shared_frame_capture(EGLDisplay display, uint32_t width, uint32_t height) {
  captures++;
  return new ServoSharedFrame{display, EGL_NO_IMAGE_KHR, width, height};
}
bool servo_shared_frame_copy(ServoSharedFrame*, GLuint) { return false; }
bool servo_shared_frame_update(ServoSharedFrame*) { updates++; return update_succeeds; }
void servo_shared_frame_free(ServoSharedFrame* frame) { delete frame; }

static void assert_upload_state() {
  g_assert_cmpint(gl_state[1], ==, 0);
  g_assert_cmpint(gl_state[2], ==, 1);
  for (int i = 3; i < 6; i++) g_assert_cmpint(gl_state[i], ==, 0);
}

static void mock_gl() {
  epoxy_glGetIntegerv = [](GLenum field, GLint* value) {
    for (int i = 0; i < 6; i++) if (state_fields[i] == field) *value = gl_state[i];
  };
  epoxy_glBindBuffer = [](GLenum, GLuint value) { gl_state[1] = value; };
  epoxy_glBindTexture = [](GLenum, GLuint value) { gl_state[0] = value; };
  epoxy_glPixelStorei = [](GLenum field, GLint value) {
    for (int i = 2; i < 6; i++) if (state_fields[i] == field) gl_state[i] = value;
  };
  epoxy_glGenTextures = [](GLsizei, GLuint* name) { *name = 1; };
  epoxy_glTexParameteri = [](GLenum, GLenum, GLint) {};
  epoxy_glTexImage2D = [](GLenum, GLint, GLint, GLsizei, GLsizei, GLint,
                          GLenum, GLenum, const void*) { assert_upload_state(); uploads++; };
  epoxy_glTexSubImage2D = [](GLenum, GLint, GLint, GLint, GLsizei, GLsizei,
                             GLenum, GLenum, const void*) { assert_upload_state(); uploads++; };
}

static void release_test_frame(gpointer data) {
  released_frames++;
  g_free(data);
}

static GBytes* test_frame(uint32_t width, uint32_t height, uint8_t value) {
  const size_t len = static_cast<size_t>(width) * height * 4;
  auto* data = static_cast<uint8_t*>(g_malloc(len));
  std::memset(data, value, len);
  return g_bytes_new_with_free_func(data, len, release_test_frame, data);
}

static void repeated_populate_reuses_upload() {
  uploads = 0;
  mock_gl();
  ServoTexture* texture = servo_texture_new(64, 64, "test");
  uint32_t target, name, width, height;
  auto populate = [&]() {
    g_assert_true(servo_texture_populate(FL_TEXTURE_GL(texture), &target,
                                         &name, &width, &height, nullptr));
    const GLint expected[] = {73, 91, 8, 100, 2, 3};
    for (int i = 0; i < 6; i++) g_assert_cmpint(gl_state[i], ==, expected[i]);
  };
  populate();
  g_assert_cmpuint(uploads, ==, 1);
  populate();
  g_assert_cmpuint(uploads, ==, 1);
  servo_texture_resize(texture, 128, 96);
  populate();
  g_assert_cmpuint(uploads, ==, 1);
  g_assert_cmpuint(width, ==, 64);
  std::memset(servo_texture_get_buffer(texture), 42,
              servo_texture_get_buffer_size(texture));
  servo_texture_publish_frame(texture);
  populate();
  g_assert_cmpuint(uploads, ==, 2);
  g_assert_cmpuint(width, ==, 128);
  g_assert_cmpuint(height, ==, 96);
  servo_texture_paint_placeholder(texture, "next");
  populate();
  populate();
  g_assert_cmpuint(uploads, ==, 3);
  g_object_unref(texture);
}

static void failed_import_requests_fallback() {
  mock_gl();
  ServoTexture* texture = servo_texture_new(16, 16, "test");
  texture->shared_frame = new ServoSharedFrame{};
  texture->shared_enabled = true;
  unsigned notifications = 0;
  g_signal_connect(texture, "transfer-failed", G_CALLBACK(+[](ServoTexture*, gpointer data) {
    ++*static_cast<unsigned*>(data);
  }), &notifications);
  uint32_t target, name, width, height;
  g_test_expect_message(nullptr, G_LOG_LEVEL_WARNING, "*shared GPU frame import failed*");
  g_assert_false(servo_texture_populate(FL_TEXTURE_GL(texture), &target, &name,
                                       &width, &height, nullptr));
  g_test_assert_expected_messages();
  g_assert_false(texture->shared_enabled);
  g_assert_null(texture->shared_frame);
  g_assert_cmpuint(notifications, ==, 0);
  while (g_main_context_iteration(nullptr, FALSE)) {}
  g_assert_cmpuint(notifications, ==, 1);
  const GLint expected[] = {73, 91, 8, 100, 2, 3};
  for (int i = 0; i < 6; i++) g_assert_cmpint(gl_state[i], ==, expected[i]);
  servo_texture_paint_placeholder(texture, "cpu fallback");
  g_assert_true(servo_texture_populate(FL_TEXTURE_GL(texture), &target, &name,
                                      &width, &height, nullptr));
  while (g_main_context_iteration(nullptr, FALSE)) {}
  g_assert_cmpuint(notifications, ==, 1);
  g_object_unref(texture);
}

static void resize_preserves_published_frame() {
  ServoTexture* texture = servo_texture_new(64, 64, "test");
  uint8_t* published = texture->front_buffer;
  const uint8_t first_pixel = published[0];
  servo_texture_resize(texture, 128, 96);
  g_assert_true(texture->front_buffer == published);
  g_assert_cmpuint(texture->front_width, ==, 64);
  g_assert_cmpuint(texture->front_height, ==, 64);
  g_assert_cmpuint(texture->front_buffer[0], ==, first_pixel);

  std::memset(servo_texture_get_buffer(texture), 42,
              servo_texture_get_buffer_size(texture));
  servo_texture_publish_frame(texture);
  g_assert_cmpuint(texture->front_width, ==, 128);
  g_assert_cmpuint(texture->front_height, ==, 96);
  g_assert_cmpuint(texture->front_buffer[128 * 96 * 4 - 1], ==, 42);
  g_assert_true(texture->upload_pending);

  // Exercise the retired smaller buffer after it becomes the writable buffer.
  std::memset(servo_texture_get_buffer(texture), 17,
              servo_texture_get_buffer_size(texture));
  servo_texture_publish_frame(texture);
  g_assert_cmpuint(texture->front_buffer[128 * 96 * 4 - 1], ==, 17);
  servo_texture_resize(texture, 1, 1);
  g_assert_cmpuint(texture->front_width, ==, 128);
  std::memset(servo_texture_get_buffer(texture), 9, 4);
  servo_texture_publish_frame(texture);
  g_assert_cmpuint(texture->front_width, ==, 1);
  g_assert_cmpuint(texture->front_height, ==, 1);
  g_assert_cmpuint(texture->front_buffer[3], ==, 9);
  g_object_unref(texture);
}

static void owned_frames_live_until_replaced() {
  released_frames = 0;
  ServoTexture* texture = servo_texture_new(64, 64, "test");
  g_assert_true(servo_texture_publish_bytes(texture, test_frame(64, 64, 7),
                                            64, 64));
  servo_texture_resize(texture, 128, 96);
  g_assert_cmpuint(texture->front_width, ==, 64);
  g_assert_cmpuint(released_frames, ==, 0);

  g_assert_true(servo_texture_publish_bytes(texture, test_frame(128, 96, 9),
                                            128, 96));
  g_assert_cmpuint(released_frames, ==, 1);
  servo_texture_paint_placeholder(texture, "fallback");
  g_assert_cmpuint(released_frames, ==, 2);
  g_assert_null(texture->published_bytes);
  g_object_unref(texture);
}

static void shared_storage_reused_until_resize() {
  captures = updates = 0;
  ServoTexture* texture = servo_texture_new(64, 64, "test");
  g_assert_true(servo_texture_publish_current_frame(texture));
  auto* first = texture->shared_frame;
  for (int i = 0; i < 10; i++) {
    g_assert_true(servo_texture_publish_current_frame(texture));
    g_assert_true(texture->shared_frame == first);
  }
  g_assert_cmpuint(captures, ==, 1);
  g_assert_cmpuint(updates, ==, 10);
  servo_texture_resize(texture, 128, 96);
  g_assert_true(servo_texture_publish_current_frame(texture));
  g_assert_cmpuint(captures, ==, 2);
  g_assert_cmpuint(texture->shared_frame->width, ==, 128);
  update_succeeds = false;
  g_test_expect_message(nullptr, G_LOG_LEVEL_WARNING, "*GPU export unavailable*");
  g_assert_false(servo_texture_publish_current_frame(texture));
  g_test_assert_expected_messages();
  g_assert_false(texture->shared_enabled);
  update_succeeds = true;
  g_object_unref(texture);
}

static void navigation_only_notifies_changes() {
  ServoNavigationState state{};
  g_assert_true(state.update("", false, false));
  g_assert_false(state.update("", false, false));
  g_assert_true(state.update("https://example.org", false, false));
  for (int i = 0; i < 100; i++)
    g_assert_false(state.update("https://example.org", false, false));
  g_assert_true(state.update("https://example.org", true, false));
  g_assert_true(state.update("https://example.org", true, true));
  state.clear();
  g_assert_true(state.update("https://example.org", true, true));
  state.clear();
  state.clear();
}

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/servo/navigation/deduplicate", navigation_only_notifies_changes);
  g_test_add_func("/servo/texture/reuse-shared-storage", shared_storage_reused_until_resize);
  g_test_add_func("/servo/texture/import-fallback", failed_import_requests_fallback);
  g_test_add_func("/servo/texture/resize-publication",
                  resize_preserves_published_frame);
  g_test_add_func("/servo/texture/upload-once", repeated_populate_reuses_upload);
  g_test_add_func("/servo/texture/owned-frame-lifetime",
                  owned_frames_live_until_replaced);
  return g_test_run();
}
