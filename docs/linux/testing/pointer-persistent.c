// Test-only pointer: keep this process alive before Fcitx starts and throughout
// all receiver cases. Recreating the last seat pointer invalidates coordinates
// on affected Hyprland versions. Use only in owned, focused fixture windows.
#define _POSIX_C_SOURCE 200809L
#include "pointer.h"
#include <wayland-client.h>
#include <linux/input-event-codes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
static struct zwlr_virtual_pointer_manager_v1 *manager;
static void global(void *data, struct wl_registry *r, uint32_t id,
                   const char *name, uint32_t version) {
  (void)data; (void)version;
  if (!strcmp(name, "zwlr_virtual_pointer_manager_v1"))
    manager = wl_registry_bind(r, id, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *r, uint32_t id) {
  (void)data; (void)r; (void)id;
}
static uint32_t stamp(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}
int main(void) {
  struct wl_display *d = wl_display_connect(NULL);
  if (!d) return 2;
  struct wl_registry *r = wl_display_get_registry(d);
  const struct wl_registry_listener listener = {global, removed};
  wl_registry_add_listener(r, &listener, NULL);
  if (wl_display_roundtrip(d) < 0 || !manager) return 3;
  struct zwlr_virtual_pointer_v1 *p =
      zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
  if (wl_display_roundtrip(d) < 0) return 4;
  puts("ready"); fflush(stdout);
  char line[128];
  while (fgets(line, sizeof(line), stdin)) {
    unsigned x, y, width, height; char extra;
    if (!strcmp(line, "quit\n")) break;
    if (sscanf(line, "move %u %u %u %u %c", &x, &y, &width, &height, &extra) == 4
        && width && height && width <= 32768 && height <= 32768
        && x < width && y < height) {
      zwlr_virtual_pointer_v1_motion_absolute(p, stamp(), x, y, width, height);
      zwlr_virtual_pointer_v1_frame(p);
    } else if (!strcmp(line, "click\n")) {
      zwlr_virtual_pointer_v1_button(p, stamp(), BTN_LEFT, 1);
      zwlr_virtual_pointer_v1_frame(p);
      if (wl_display_roundtrip(d) < 0) return 5;
      zwlr_virtual_pointer_v1_button(p, stamp(), BTN_LEFT, 0);
      zwlr_virtual_pointer_v1_frame(p);
    } else return 6;
    if (wl_display_roundtrip(d) < 0) return 5;
    puts("ok"); fflush(stdout);
  }
  zwlr_virtual_pointer_v1_destroy(p);
  zwlr_virtual_pointer_manager_v1_destroy(manager);
  wl_registry_destroy(r);
  wl_display_roundtrip(d);
  wl_display_disconnect(d);
  return 0;
}
