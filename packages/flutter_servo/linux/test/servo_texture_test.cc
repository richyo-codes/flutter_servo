// Include the implementation to inspect publication without a display server.
#include "../servo_texture.cc"

#include <cstring>

static unsigned uploads = 0;
static unsigned released_frames = 0;

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
  epoxy_glGenTextures = [](GLsizei, GLuint* name) { *name = 1; };
  epoxy_glBindTexture = [](GLenum, GLuint) {};
  epoxy_glTexParameteri = [](GLenum, GLenum, GLint) {};
  epoxy_glPixelStorei = [](GLenum, GLint) {};
  epoxy_glTexImage2D = [](GLenum, GLint, GLint, GLsizei, GLsizei, GLint,
                          GLenum, GLenum, const void*) { uploads++; };
  epoxy_glTexSubImage2D = [](GLenum, GLint, GLint, GLint, GLsizei, GLsizei,
                             GLenum, GLenum, const void*) { uploads++; };
  ServoTexture* texture = servo_texture_new(64, 64, "test");
  uint32_t target, name, width, height;
  auto populate = [&]() {
    g_assert_true(servo_texture_populate(FL_TEXTURE_GL(texture), &target,
                                         &name, &width, &height, nullptr));
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

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/servo/texture/resize-publication",
                  resize_preserves_published_frame);
  g_test_add_func("/servo/texture/upload-once", repeated_populate_reuses_upload);
  g_test_add_func("/servo/texture/owned-frame-lifetime",
                  owned_frames_live_until_replaced);
  return g_test_run();
}
