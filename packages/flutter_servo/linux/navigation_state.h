#ifndef FLUTTER_SERVO_NAVIGATION_STATE_H_
#define FLUTTER_SERVO_NAVIGATION_STATE_H_

#include <glib.h>

// Zero-initialized with the owning GObject; clear on detach and disposal.
struct ServoNavigationState {
  gchar* url;
  bool back;
  bool forward;

  bool update(const gchar* next_url, bool next_back, bool next_forward) {
    if (g_strcmp0(url, next_url) == 0 && back == next_back && forward == next_forward)
      return false;
    g_free(url);
    url = g_strdup(next_url);
    back = next_back;
    forward = next_forward;
    return true;
  }

  void clear() { g_clear_pointer(&url, g_free); }
};

#endif
