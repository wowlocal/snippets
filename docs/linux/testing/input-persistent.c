#define _GNU_SOURCE
#include "live-keyboard.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;
static void global(void *data, struct wl_registry *r, uint32_t id,
                   const char *name, uint32_t version) {
  (void)data;
  (void)version;
  if (!strcmp(name, "wl_seat"))
    seat = wl_registry_bind(r, id, &wl_seat_interface, 1);
  if (!strcmp(name, "zwp_virtual_keyboard_manager_v1"))
    manager =
        wl_registry_bind(r, id, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *r, uint32_t id) {
  (void)data;
  (void)r;
  (void)id;
}
static const struct wl_registry_listener listener = {global, removed};
static uint32_t now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}
static uint32_t code(struct xkb_keymap *map, xkb_keysym_t symbol) {
  for (xkb_keycode_t k = xkb_keymap_min_keycode(map);
       k <= xkb_keymap_max_keycode(map); k++) {
    const xkb_keysym_t *symbols = NULL;
    if (xkb_keymap_key_get_syms_by_level(map, k, 0, 0, &symbols) > 0 &&
        symbols[0] == symbol)
      return k - 8;
  }
  return 0;
}
static int modified(struct wl_display *d,
                    struct zwp_virtual_keyboard_v1 *keyboard,
                    struct xkb_state *state, uint32_t key, int press) {
  xkb_state_update_key(state, key + 8, press ? XKB_KEY_DOWN : XKB_KEY_UP);
  zwp_virtual_keyboard_v1_modifiers(
      keyboard, xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
      xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
      xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
      xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
  zwp_virtual_keyboard_v1_key(keyboard, now(), key, (uint32_t)press);
  if (wl_display_roundtrip(d) < 0)
    return 0;
  usleep(70000);
  return 1;
}
int main(void) {
  struct wl_display *display = wl_display_connect(NULL);
  if (!display)
    return 2;
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &listener, NULL);
  if (wl_display_roundtrip(display) < 0 || !seat || !manager)
    return 3;
  struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_rule_names names = {.layout = "us"};
  struct xkb_keymap *map =
      xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (!map)
    return 4;
  char *text = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1);
  size_t size = strlen(text) + 1;
  int fd = memfd_create("public-fixture-keymap", MFD_CLOEXEC);
  if (fd < 0 || write(fd, text, size) != (ssize_t)size)
    return 5;
  struct zwp_virtual_keyboard_v1 *keyboard =
      zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
  zwp_virtual_keyboard_v1_keymap(keyboard, 1, fd, (uint32_t)size);
  close(fd);
  free(text);
  zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);
  if (wl_display_roundtrip(display) < 0)
    return 6;
  puts("ready");
  fflush(stdout);
  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, stdin) > 0) {
    line[strcspn(line, "\r\n")] = 0;
    if (!strcmp(line, "quit"))
      break;
    if (!strncmp(line, "text ", 5)) {
      const char *value = line + 5;
      if (strcmp(value, "\\nativeinline") && strcmp(value, "\\nat") &&
          strcmp(value, "\\") && strcmp(value, "n"))
        return 7;
      for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        uint32_t key = code(map, *p);
        if (!key)
          return 8;
        zwp_virtual_keyboard_v1_key(keyboard, now(), key, 1);
        if (wl_display_roundtrip(display) < 0)
          return 9;
        zwp_virtual_keyboard_v1_key(keyboard, now(), key, 0);
        if (wl_display_roundtrip(display) < 0)
          return 9;
        usleep(100000);
      }
    } else if (!strncmp(line, "key ", 4)) {
      const char *name = line + 4;
      if (strcmp(name, "Return") && strcmp(name, "Down") &&
          strcmp(name, "Up") && strcmp(name, "Tab") && strcmp(name, "Escape"))
        return 10;
      uint32_t key =
          code(map, xkb_keysym_from_name(name, XKB_KEYSYM_CASE_INSENSITIVE));
      if (!key)
        return 8;
      zwp_virtual_keyboard_v1_key(keyboard, now(), key, 1);
      if (wl_display_roundtrip(display) < 0)
        return 9;
      usleep(70000);
      zwp_virtual_keyboard_v1_key(keyboard, now(), key, 0);
      if (wl_display_roundtrip(display) < 0)
        return 9;
      usleep(70000);
    } else if (!strncmp(line, "chord ", 6)) {
      const char *name = line + 6;
      xkb_keysym_t modifier = XKB_KEY_Control_L, symbol = XKB_KEY_n;
      if (!strcmp(name, "CtrlP"))
        symbol = XKB_KEY_p;
      else if (!strcmp(name, "ShiftTab")) {
        modifier = XKB_KEY_Shift_L;
        symbol = XKB_KEY_Tab;
      } else if (strcmp(name, "CtrlN"))
        return 11;
      struct xkb_state *state = xkb_state_new(map);
      if (!state)
        return 12;
      uint32_t m = code(map, modifier), k = code(map, symbol);
      if (!m || !k)
        return 13;
      int ok = modified(display, keyboard, state, m, 1) &&
               modified(display, keyboard, state, k, 1) &&
               modified(display, keyboard, state, k, 0) &&
               modified(display, keyboard, state, m, 0);
      xkb_state_unref(state);
      if (!ok)
        return 14;
    } else if (!strncmp(line, "shortcut ", 9)) {
      const char *name = line + 9;
      if (strcmp(name, "n") && strcmp(name, "p") && strcmp(name, "c"))
        return 15;
      xkb_mod_index_t alt = xkb_keymap_mod_get_index(map, XKB_MOD_NAME_ALT),
                      logo = xkb_keymap_mod_get_index(map, XKB_MOD_NAME_LOGO);
      if (alt >= 32 || logo >= 32)
        return 16;
      uint32_t key = code(map, (xkb_keysym_t)name[0]);
      if (!key)
        return 13;
      zwp_virtual_keyboard_v1_modifiers(keyboard, (1u << alt) | (1u << logo), 0,
                                        0, 0);
      zwp_virtual_keyboard_v1_key(keyboard, now(), key, 1);
      if (wl_display_roundtrip(display) < 0)
        return 9;
      usleep(70000);
      zwp_virtual_keyboard_v1_key(keyboard, now(), key, 0);
      if (wl_display_roundtrip(display) < 0)
        return 9;
      usleep(70000);
      zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);
      if (wl_display_roundtrip(display) < 0)
        return 9;
    } else
      return 11;
    puts("ok");
    fflush(stdout);
  }
  free(line);
  zwp_virtual_keyboard_v1_destroy(keyboard);
  wl_display_roundtrip(display);
  xkb_keymap_unref(map);
  xkb_context_unref(context);
  wl_display_disconnect(display);
  return 0;
}
