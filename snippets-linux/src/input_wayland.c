/* Bounded native virtual-keyboard owner. No body strings, clipboard objects,
 * logging, subprocesses or file-backed text. Rust supplies an anonymous keymap
 * descriptor and revalidates consent on every I/O wait and before each key. */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "snippets-input.h"
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <stdarg.h>
#include <xkbcommon/xkbcommon.h>
typedef int (*snip_check)(void *);
struct snip_input {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct zwp_virtual_keyboard_manager_v1 *manager;
    struct zwp_virtual_keyboard_v1 *keyboard;
    uint32_t seat_name, manager_name;
    unsigned seats, managers;
    int failed, keymap, keyboard_capability;
};
static int64_t now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_BOOTTIME, &value)) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int64_t deadline_after(int milliseconds) {
    int64_t value = now_ms();
    return value < 0 ? -1 : value + milliseconds;
}
static int admitted(snip_check check, void *context) { return check && check(context); }
static void capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
    (void)seat;
    struct snip_input *owner = data;
    owner->keyboard_capability = !!(caps & WL_SEAT_CAPABILITY_KEYBOARD);
    if (!owner->keyboard_capability) owner->failed = 1;
}
static const struct wl_seat_listener seat_listener = { .capabilities = capabilities };
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    struct snip_input *owner = data;
    if (!strcmp(interface, "wl_seat")) {
        if (++owner->seats != 1 || version < 1) { owner->failed = 1; return; }
        owner->seat_name = name;
        owner->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
        if (!owner->seat) { owner->failed = 1; return; }
        wl_seat_add_listener(owner->seat, &seat_listener, owner);
    } else if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1")) {
        if (++owner->managers != 1 || version < 1) { owner->failed = 1; return; }
        owner->manager_name = name;
        owner->manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
        if (!owner->manager) owner->failed = 1;
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)registry;
    struct snip_input *owner = data;
    if (name == owner->seat_name || name == owner->manager_name) owner->failed = 1;
}
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };

/* The balanced bounded pump and synchronize helpers are shared in shape with
 * the existing read-only clipboard adapter. They check consent before flush. */

// Pump exactly one bounded poll; read and cancel always balance prepare_read.
static int pump(struct snip_input *owner, int other_fd, int64_t deadline, snip_check check, void *context) {
    if (!admitted(check, context)) return 2;
    if (owner->failed || wl_display_dispatch_pending(owner->display) < 0) return 3;
    while (wl_display_prepare_read(owner->display) != 0) {
        if (wl_display_dispatch_pending(owner->display) < 0 || owner->failed) return 3;
        if (!admitted(check, context)) return 2;
    }
    int flushed = wl_display_flush(owner->display);
    if (flushed < 0 && errno != EAGAIN) { wl_display_cancel_read(owner->display); return 3; }
    int64_t stamp = now_ms();
    int64_t remaining = deadline - stamp;
    if (deadline < 0 || stamp < 0) { wl_display_cancel_read(owner->display); return 1; }
    if (remaining <= 0 || remaining > 5000) { wl_display_cancel_read(owner->display); return 1; }
    struct pollfd descriptors[2] = {
        { .fd = wl_display_get_fd(owner->display), .events = POLLIN | (flushed < 0 ? POLLOUT : 0) },
        { .fd = other_fd, .events = POLLIN }
    };
    int result = poll(descriptors, other_fd < 0 ? 1 : 2, remaining > 100 ? 100 : (int)remaining);
    if (result < 0 && errno != EINTR) { wl_display_cancel_read(owner->display); return 3; }
    if (result > 0 && (descriptors[0].revents & POLLIN)) {
        if (wl_display_read_events(owner->display) < 0) return 3;
    } else wl_display_cancel_read(owner->display);
    if ((descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) || owner->failed
        || wl_display_dispatch_pending(owner->display) < 0) return 3;
    if (!admitted(check, context)) return 2;
    return 0;
}
static void sync_done(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial;
    *(int *)data = 1;
    wl_callback_destroy(callback);
}
static const struct wl_callback_listener callback_listener = { .done = sync_done };
static int synchronize(struct snip_input *owner, snip_check check, void *context) {
    int done = 0;
    struct wl_callback *callback = wl_display_sync(owner->display);
    if (!callback) return 3;
    wl_callback_add_listener(callback, &callback_listener, &done);
    int64_t deadline = deadline_after(2000);
    while (!done) {
        int status = pump(owner, -1, deadline, check, context);
        if (status) { if (!done) wl_callback_destroy(callback); return status; }
    }
    return owner->failed ? 3 : 0;
}
void snip_input_close(struct snip_input *owner) {
    if (!owner) return;
    /* Disconnect drops any unflushed payload. Never flush queued keys as part
     * of cancellation/cleanup. Each successful request already paired key-up. */
    if (owner->keyboard) zwp_virtual_keyboard_v1_destroy(owner->keyboard);
    if (owner->manager) wl_proxy_destroy((struct wl_proxy *)owner->manager);
    if (owner->seat) wl_seat_destroy(owner->seat);
    if (owner->registry) wl_registry_destroy(owner->registry);
    if (owner->display) wl_display_disconnect(owner->display);
    free(owner);
}
struct snip_input *snip_input_open_fd(int fd, snip_check check, void *context, int *status) {
    *status = 2;
    if (!admitted(check, context)) { close(fd); return NULL; }
    struct snip_input *owner = calloc(1, sizeof(*owner));
    if (!owner) { close(fd); *status = 3; return NULL; }
    owner->display = wl_display_connect_to_fd(fd);
    /* libwayland owns fd even when connecting fails. */
    if (!owner->display) { free(owner); *status = 3; return NULL; }
    owner->registry = wl_display_get_registry(owner->display);
    if (!owner->registry) { *status = 3; snip_input_close(owner); return NULL; }
    wl_registry_add_listener(owner->registry, &registry_listener, owner);
    *status = synchronize(owner, check, context);
    if (*status || owner->seats != 1 || owner->managers != 1 || !owner->seat || !owner->manager) {
        if (!*status) *status = 3;
        snip_input_close(owner); return NULL;
    }
    owner->keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(owner->manager, owner->seat);
    if (!owner->keyboard) { *status = 3; snip_input_close(owner); return NULL; }
    *status = synchronize(owner, check, context);
    if (*status || !owner->keyboard_capability) {
        if (!*status) *status = 3;
        snip_input_close(owner); return NULL;
    }
    return owner;
}
struct snip_input *snip_input_open(snip_check check, void *context, int *status) {
    *status = 2;
    if (!admitted(check, context)) return NULL;
    const char *display = getenv("WAYLAND_DISPLAY");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    size_t length = display ? strnlen(display, sizeof(address.sun_path)) : 0;
    if (!length || length >= sizeof(address.sun_path)) { *status = 3; return NULL; }
    if (display[0] == '/') memcpy(address.sun_path, display, length + 1);
    else {
        size_t root = runtime ? strnlen(runtime, sizeof(address.sun_path)) : 0;
        if (!root || runtime[0] != '/' || root + length + 2 > sizeof(address.sun_path)) { *status = 3; return NULL; }
        memcpy(address.sun_path, runtime, root); address.sun_path[root] = '/';
        memcpy(address.sun_path + root + 1, display, length + 1);
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) { *status = 3; return NULL; }
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        if (errno != EINPROGRESS && errno != EAGAIN) { close(fd); *status = 3; return NULL; }
        int64_t deadline = deadline_after(2000);
        for (;;) {
            if (!admitted(check, context)) { close(fd); return NULL; }
            if (deadline < 0 || now_ms() < 0 || now_ms() >= deadline) { close(fd); *status = 1; return NULL; }
            struct pollfd descriptor = { .fd = fd, .events = POLLOUT };
            int ready = poll(&descriptor, 1, 100);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) { close(fd); *status = 3; return NULL; }
            if (!ready) continue;
            int error = 0; socklen_t size = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) || error) { close(fd); *status = 3; return NULL; }
            break;
        }
    }
    return snip_input_open_fd(fd, check, context, status);
}
int snip_input_keymap(struct snip_input *owner, int fd, uint32_t size, snip_check check, void *context) {
    if (!admitted(check, context)) return 2;
    if (owner->failed || fd < 0 || !size || size > 65536) return 3;
    zwp_virtual_keyboard_v1_keymap(owner->keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    zwp_virtual_keyboard_v1_modifiers(owner->keyboard, 0, 0, 0, 0);
    int result = synchronize(owner, check, context);
    if (!result) owner->keymap = 1;
    return result;
}
int snip_input_key(struct snip_input *owner, uint32_t code, snip_check check, void *context) {
    if (!admitted(check, context)) return 2;
    if (owner->failed || !owner->keymap || !code || code > 247) return 3;
    int64_t stamp = now_ms();
    if (stamp < 0) return 1;
    zwp_virtual_keyboard_v1_key(owner->keyboard, (uint32_t)stamp, code, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_key(owner->keyboard, (uint32_t)stamp, code, WL_KEYBOARD_KEY_STATE_RELEASED);
    return synchronize(owner, check, context);
}
uint64_t snip_input_peer_process(struct snip_input *owner) {
    struct ucred peer;
    socklen_t size = sizeof(peer);
    if (getsockopt(wl_display_get_fd(owner->display), SOL_SOCKET, SO_PEERCRED, &peer, &size)
        || size != sizeof(peer) || peer.uid != getuid() || peer.pid <= 0) return 0;
    return (uint64_t)peer.pid;
}
static void quiet_xkb(struct xkb_context *context, enum xkb_log_level level, const char *format, va_list arguments) {
    (void)context; (void)level; (void)format; (void)arguments;
}
int snip_input_validate_keymap(const char *map) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!context) return 0;
    xkb_context_set_log_fn(context, quiet_xkb);
    struct xkb_keymap *keymap = xkb_keymap_new_from_string(context, map, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    int valid = keymap != NULL;
    if (keymap) xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    return valid;
}
