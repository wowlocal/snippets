/* Private socket-pair compositor. Only fictional text; no display lookup,
 * clipboard, keyring, PAM, user library or real application receives input. */
#define _GNU_SOURCE
#include <wayland-server.h>
#include "snippets-input-server.h"
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdarg.h>
static void quiet_wayland(const char *format, va_list arguments) {
    (void)format; (void)arguments;
}
struct fixture {
    struct wl_display *display;
    struct xkb_context *context;
    struct xkb_keymap *map;
    unsigned maps, modifiers, presses, releases;
    uint32_t held;
    int quit, keyboard_capability, silent_seat;
    char text[8192];
    size_t length;
};
static void destroy(struct wl_client *client, struct wl_resource *resource) {
    (void)client; wl_resource_destroy(resource);
}
static void keymap(struct wl_client *client, struct wl_resource *resource, uint32_t format, int fd, uint32_t size) {
    (void)client;
    struct fixture *f = wl_resource_get_user_data(resource);
    assert(format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 && size > 0 && size <= 65536);
    assert(f->held == 0);
    struct stat info;
    assert(fstat(fd, &info) == 0 && info.st_size == size && S_ISREG(info.st_mode));
    int seals = F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_WRITE | F_SEAL_SEAL;
    assert((fcntl(fd, F_GET_SEALS) & seals) == seals);
    const char *bytes = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    assert(bytes != MAP_FAILED && bytes[size - 1] == '\0');
    struct xkb_keymap *next = xkb_keymap_new_from_string(f->context, bytes,
        XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    assert(next);
    if (f->map) xkb_keymap_unref(f->map);
    f->map = next; f->maps++;
    assert(munmap((void *)bytes, size) == 0);
    close(fd);
}
static void key(struct wl_client *client, struct wl_resource *resource, uint32_t time, uint32_t code, uint32_t state) {
    (void)client; (void)time;
    struct fixture *f = wl_resource_get_user_data(resource);
    assert(f->map && f->modifiers == f->maps && code > 0 && code <= 247);
    if (state == WL_KEYBOARD_KEY_STATE_PRESSED) {
        assert(f->held == 0); f->held = code; f->presses++;
        const xkb_keysym_t *symbols;
        assert(xkb_keymap_key_get_syms_by_level(f->map, code + 8, 0, 0, &symbols) == 1);
        char text[8]; int length;
        if (symbols[0] == XKB_KEY_Return || symbols[0] == XKB_KEY_Tab) {
            text[0] = symbols[0] == XKB_KEY_Return ? '\n' : '\t'; length = 1;
        } else {
            length = xkb_keysym_to_utf8(symbols[0], text, sizeof(text)) - 1;
            assert(length > 0);
        }
        assert(f->length + (size_t)length < sizeof(f->text));
        memcpy(f->text + f->length, text, length); f->length += length;
    } else {
        assert(state == WL_KEYBOARD_KEY_STATE_RELEASED && f->held == code);
        f->held = 0; f->releases++;
    }
}
static void modifiers(struct wl_client *client, struct wl_resource *resource, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    (void)client;
    struct fixture *f = wl_resource_get_user_data(resource);
    assert(!depressed && !latched && !locked && !group && f->maps == f->modifiers + 1);
    f->modifiers++;
}
static const struct zwp_virtual_keyboard_v1_interface keyboard_impl = {
    .keymap = keymap, .key = key, .modifiers = modifiers, .destroy = destroy
};
static void create_keyboard(struct wl_client *client, struct wl_resource *manager, struct wl_resource *seat, uint32_t id) {
    assert(wl_resource_instance_of(seat, &wl_seat_interface, NULL));
    struct wl_resource *resource = wl_resource_create(client, &zwp_virtual_keyboard_v1_interface, 1, id);
    assert(resource);
    wl_resource_set_implementation(resource, &keyboard_impl, wl_resource_get_user_data(manager), NULL);
}
static const struct zwp_virtual_keyboard_manager_v1_interface manager_impl = {
    .create_virtual_keyboard = create_keyboard
};
static void bind_manager(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    assert(version == 1);
    struct wl_resource *resource = wl_resource_create(client, &zwp_virtual_keyboard_manager_v1_interface, version, id);
    assert(resource); wl_resource_set_implementation(resource, &manager_impl, data, NULL);
}
static void bind_seat(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct fixture *f = data;
    assert(version == 1);
    struct wl_resource *resource = wl_resource_create(client, &wl_seat_interface, version, id);
    assert(resource); wl_resource_set_implementation(resource, NULL, NULL, NULL);
    if (!f->silent_seat) wl_seat_send_capabilities(resource, f->keyboard_capability ? WL_SEAT_CAPABILITY_KEYBOARD : 0);
}
static int command(int fd, uint32_t mask, void *data) {
    struct fixture *f = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { f->quit = 1; return 0; }
    unsigned char kind;
    if (read(fd, &kind, 1) != 1 || kind == 'Q') { f->quit = 1; return 0; }
    unsigned char reply = kind;
    if (kind == 'K') {
        assert(f->presses == f->releases && f->presses < 255 && !f->held);
        reply = (unsigned char)f->presses;
    } else if (kind == 'V') {
        const char expected[] = "Aя中🙂\t\nZ\n!";
        assert(f->maps == 1 && f->modifiers == 1 && f->presses == 9 && f->releases == 9 && !f->held);
        assert(f->length == sizeof(expected) - 1 && !memcmp(f->text, expected, f->length));
    } else if (kind == 'B') {
        /* Independent decoder checks map changes and the exact emitted order. */
        assert(f->maps == 3 && f->modifiers == 3 && f->presses == 481 && f->releases == 481 && !f->held);
        assert(f->length == 481 && !memcmp(f->text, "ABC", 3));
        for (size_t i = 0; i < f->length; i++) assert(f->text[i] == "ABC"[i % 3]);
    } else abort();
    assert(write(fd, &reply, 1) == 1); return 0;
}
int main(int argc, char **argv) {
    assert(argc == 2); signal(SIGPIPE, SIG_IGN);
    wl_log_set_handler_server(quiet_wayland);
    struct fixture f = {0};
    f.keyboard_capability = strcmp(argv[1], "no-keyboard") != 0;
    f.silent_seat = !strcmp(argv[1], "silent-seat");
    f.display = wl_display_create(); f.context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    assert(f.display && f.context);
    assert(wl_global_create(f.display, &wl_seat_interface, 1, &f, bind_seat));
    if (!strcmp(argv[1], "two-seats")) assert(wl_global_create(f.display, &wl_seat_interface, 1, &f, bind_seat));
    if (strcmp(argv[1], "missing")) assert(wl_global_create(f.display, &zwp_virtual_keyboard_manager_v1_interface, 1, &f, bind_manager));
    if (!strcmp(argv[1], "two-managers")) assert(wl_global_create(f.display, &zwp_virtual_keyboard_manager_v1_interface, 1, &f, bind_manager));
    if (!wl_client_create(f.display, STDIN_FILENO)) {
        unsigned char failure[2] = {'?', errno > 0 && errno < 255 ? (unsigned char)errno : 255};
        (void)write(STDERR_FILENO, failure, sizeof(failure));
        wl_display_destroy(f.display); xkb_context_unref(f.context); return 77;
    }
    struct wl_event_loop *loop = wl_display_get_event_loop(f.display);
    struct wl_event_source *commands = wl_event_loop_add_fd(loop, STDERR_FILENO, WL_EVENT_READABLE, command, &f);
    assert(commands && write(STDERR_FILENO, "!", 1) == 1);
    if (!strcmp(argv[1], "stall")) {
        unsigned char kind;
        while (read(STDERR_FILENO, &kind, 1) == 1 && kind != 'Q') {}
    } else while (!f.quit) {
        assert(wl_event_loop_dispatch(loop, 100) == 0); wl_display_flush_clients(f.display);
    }
    wl_event_source_remove(commands); wl_display_destroy_clients(f.display);
    wl_display_destroy(f.display);
    if (f.map) xkb_keymap_unref(f.map);
    xkb_context_unref(f.context); return 0;
}
