#include "my_application.h"

#include <glib.h>

int main(int argc, char** argv) {
  // Seed surfman's software-render path before Flutter spins up worker threads.
  g_setenv("LIBGL_ALWAYS_SOFTWARE", "1", FALSE);
  g_unsetenv("DRI_PRIME");

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
