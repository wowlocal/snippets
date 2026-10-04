/* Closed public shortcut registration. No keyboard grab, keymap, clipboard,
 * text field, credential, command execution or persistent identifier. */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "snippets-shortcuts.h"
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
typedef int (*snip_check)(void *);
struct snip_shortcuts;
struct shortcut {
    struct hyprland_global_shortcut_v1 *proxy;
    struct snip_shortcuts *owner;
    uint32_t id;
    int down;
};
struct event { uint32_t id; int64_t arrived; };
struct snip_shortcuts {
    struct wl_display *display;
    struct wl_registry *registry;
    struct hyprland_global_shortcuts_manager_v1 *manager;
    uint32_t manager_name;
    struct shortcut shortcuts[3];
    struct event events[8];
    unsigned head, count;
    int failed, started;
};
static int64_t now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_BOOTTIME, &value)) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int admitted(snip_check check, void *context) { return check && check(context); }
static void pressed(void *data, struct hyprland_global_shortcut_v1 *proxy,
    uint32_t hi, uint32_t lo, uint32_t nano) {
    (void)proxy; (void)hi; (void)lo;
    struct shortcut *shortcut = data;
    struct snip_shortcuts *owner = shortcut->owner;
    if (nano >= 1000000000) { owner->failed = 1; return; }
    if (shortcut->down) return;
    shortcut->down = 1;
    if (owner->count == 8) { owner->failed = 1; return; }
    int64_t stamp = now_ms();
    if (stamp < 0) { owner->failed = 1; return; }
    owner->events[(owner->head + owner->count++) % 8] = (struct event){ shortcut->id, stamp };
}
static void released(void *data, struct hyprland_global_shortcut_v1 *proxy,
    uint32_t hi, uint32_t lo, uint32_t nano) {
    (void)proxy; (void)hi; (void)lo;
    struct shortcut *shortcut = data;
    if (nano >= 1000000000) shortcut->owner->failed = 1;
    shortcut->down = 0;
}
static const struct hyprland_global_shortcut_v1_listener shortcut_listener = { pressed, released };
static void global(void *data, struct wl_registry *registry, uint32_t name,
    const char *interface, uint32_t version) {
    struct snip_shortcuts *owner = data;
    if (!strcmp(interface, "hyprland_global_shortcuts_manager_v1")) {
        if (owner->manager || !version) { owner->failed = 1; return; }
        owner->manager_name = name;
        owner->manager = wl_registry_bind(registry, name, &hyprland_global_shortcuts_manager_v1_interface, 1);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)registry;
    struct snip_shortcuts *owner = data;
    if (name == owner->manager_name) owner->failed = 1;
}
static const struct wl_registry_listener registry_listener = { global, removed };
static int pump(struct snip_shortcuts *owner, int64_t deadline, snip_check check, void *context) {
    if (!admitted(check, context)) return 2;
    if (owner->failed || wl_display_dispatch_pending(owner->display) < 0 || owner->failed) return 3;
    while (wl_display_prepare_read(owner->display)) {
        if (wl_display_dispatch_pending(owner->display) < 0 || owner->failed) return 3;
        if (!admitted(check, context)) return 2;
    }
    int flushed = wl_display_flush(owner->display);
    if (flushed < 0 && errno != EAGAIN) { wl_display_cancel_read(owner->display); return 3; }
    int64_t stamp = now_ms(), remaining = deadline - stamp;
    if (stamp < 0 || deadline < 0 || remaining <= 0 || remaining > 5000) {
        wl_display_cancel_read(owner->display); return 1;
    }
    struct pollfd descriptor = { .fd = wl_display_get_fd(owner->display),
        .events = POLLIN | (flushed < 0 ? POLLOUT : 0) };
    int ready = poll(&descriptor, 1, remaining > 100 ? 100 : (int)remaining);
    if (ready < 0 && errno != EINTR) { wl_display_cancel_read(owner->display); return 3; }
    if (ready > 0 && (descriptor.revents & POLLIN)) {
        if (wl_display_read_events(owner->display) < 0) return 3;
    } else wl_display_cancel_read(owner->display);
    if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) ||
        wl_display_dispatch_pending(owner->display) < 0 || owner->failed) return 3;
    return admitted(check, context) ? 0 : 2;
}
static void done(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial;
    *(int *)data = 1;
    wl_callback_destroy(callback);
}
static const struct wl_callback_listener callback_listener = { done };
static int synchronize(struct snip_shortcuts *owner, snip_check check, void *context) {
    int complete = 0;
    struct wl_callback *callback = wl_display_sync(owner->display);
    if (!callback) return 3;
    wl_callback_add_listener(callback, &callback_listener, &complete);
    int64_t stamp = now_ms(), deadline = stamp < 0 ? -1 : stamp + 2000;
    while (!complete) {
        int status = pump(owner, deadline, check, context);
        if (status) { if (!complete) wl_callback_destroy(callback); return status; }
    }
    return owner->failed ? 3 : 0;
}
void snip_shortcuts_close(struct snip_shortcuts *owner) {
    if (!owner) return;
    for (unsigned index = 0; index < 3; index++)
        if (owner->shortcuts[index].proxy) hyprland_global_shortcut_v1_destroy(owner->shortcuts[index].proxy);
    if (owner->manager) hyprland_global_shortcuts_manager_v1_destroy(owner->manager);
    if (owner->registry) wl_registry_destroy(owner->registry);
    if (owner->display) wl_display_disconnect(owner->display);
    free(owner);
}
/* Takes ownership on every outcome. The private socketpair fixture uses the
 * same protocol client; production checks the real compositor before start. */
struct snip_shortcuts *snip_shortcuts_connect_fd(int fd, snip_check check, void *context, int *status) {
    *status = 2;
    if (!admitted(check, context)) { close(fd); return NULL; }
    struct snip_shortcuts *owner = calloc(1, sizeof(*owner));
    if (!owner) { close(fd); *status = 3; return NULL; }
    owner->display = wl_display_connect_to_fd(fd);
    if (!owner->display) { free(owner); *status = 3; return NULL; }
    owner->registry = wl_display_get_registry(owner->display);
    if (!owner->registry) { *status = 3; snip_shortcuts_close(owner); return NULL; }
    wl_registry_add_listener(owner->registry, &registry_listener, owner);
    *status = synchronize(owner, check, context);
    if (*status || owner->failed || !owner->manager) {
        if (!*status) *status = 3;
        snip_shortcuts_close(owner); return NULL;
    }
    return owner;
}
uint64_t snip_shortcuts_peer(struct snip_shortcuts *owner) {
    struct ucred peer;
    socklen_t length = sizeof(peer);
    if (getsockopt(wl_display_get_fd(owner->display), SOL_SOCKET, SO_PEERCRED, &peer, &length) ||
        length != sizeof(peer) || peer.uid != getuid() || peer.pid <= 0) return 0;
    return (uint64_t)peer.pid;
}
int snip_shortcuts_start(struct snip_shortcuts *owner, snip_check check, void *context) {
    if (!admitted(check, context)) return 2;
    if (owner->started || owner->failed) return 3;
    owner->started = 1;
    const char *ids[3] = { "open", "picker", "capture" };
    const char *descriptions[3] = { "Open Snippets", "Snippets paste picker", "Capture clipboard in Snippets" };
    for (unsigned index = 0; index < 3; index++) {
        struct shortcut *shortcut = &owner->shortcuts[index];
        shortcut->owner = owner; shortcut->id = index + 1;
        shortcut->proxy = hyprland_global_shortcuts_manager_v1_register_shortcut(owner->manager,
            ids[index], "com.khm.snippets.linux", descriptions[index], "");
        if (!shortcut->proxy) return 3;
        hyprland_global_shortcut_v1_add_listener(shortcut->proxy, &shortcut_listener, shortcut);
    }
    return synchronize(owner, check, context);
}
/* 0=event, 1=idle, 2=revoked, 3=unavailable. Stale events are consumed, never replayed. */
int snip_shortcuts_next(struct snip_shortcuts *owner, uint32_t *id, uint32_t *age,
    snip_check check, void *context) {
    *id = 0; *age = 0;
    if (!owner->started) return 3;
    int64_t stamp = now_ms(), deadline = stamp < 0 ? -1 : stamp + 100;
    while (!owner->count) {
        int status = pump(owner, deadline, check, context);
        if (status) return status;
    }
    if (!admitted(check, context)) return 2;
    if (owner->failed || wl_display_dispatch_pending(owner->display) < 0 || owner->failed) return 3;
    struct event event = owner->events[owner->head];
    owner->head = (owner->head + 1) % 8; owner->count--;
    stamp = now_ms();
    if (stamp < event.arrived || stamp - event.arrived > 1500) return 1;
    *id = event.id; *age = (uint32_t)(stamp - event.arrived);
    return 0;
}

struct snip_shortcuts *snip_shortcuts_connect(snip_check check, void *context, int *status) {
    *status = 2;
    if (!admitted(check, context)) return NULL;
    const char *display = getenv("WAYLAND_DISPLAY");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!display || !*display) display = "wayland-0";
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    size_t display_length = strnlen(display, sizeof(address.sun_path));
    if (!display_length || display_length >= sizeof(address.sun_path)) { *status = 3; return NULL; }
    if (display[0] == '/') memcpy(address.sun_path, display, display_length + 1);
    else {
        size_t root_length = runtime ? strnlen(runtime, sizeof(address.sun_path)) : 0;
        if (!root_length || runtime[0] != '/' || root_length + display_length + 2 > sizeof(address.sun_path)) {
            *status = 3; return NULL;
        }
        memcpy(address.sun_path, runtime, root_length);
        address.sun_path[root_length] = '/';
        memcpy(address.sun_path + root_length + 1, display, display_length + 1);
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) { *status = 3; return NULL; }
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        if (errno != EINPROGRESS && errno != EAGAIN) { close(fd); *status = 3; return NULL; }
        int64_t deadline = now_ms() + 2000;
        for (;;) {
            if (!admitted(check, context)) { close(fd); return NULL; }
            if (now_ms() >= deadline) { close(fd); *status = 1; return NULL; }
            struct pollfd descriptor = { .fd = fd, .events = POLLOUT };
            int ready = poll(&descriptor, 1, 100);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) { close(fd); *status = 3; return NULL; }
            if (!ready) continue;
            int error = 0; socklen_t length = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) || error) { close(fd); *status = 3; return NULL; }
            break;
        }
    }
    return snip_shortcuts_connect_fd(fd, check, context, status);
}
