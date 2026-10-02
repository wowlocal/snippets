/* Native input-method-v2 owner. No hardware grab, clipboard writes, logging or
 * retained Rust callbacks. All waits are bounded and consent checked. */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "snippets-ime.h"
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
typedef int (*snip_ime_check)(void *);
struct snip_ime_frame {
    uint64_t field;
    uint32_t serial, active, cursor, anchor, hint, purpose;
    uint32_t has_type, has_text, cause, length;
    unsigned char text[4001];
};
struct snip_ime {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct zwp_input_method_manager_v2 *manager;
    struct zwp_input_method_v2 *method;
    uint32_t seat_name, manager_name;
    unsigned seats, managers;
    int failed, keyboard, dirty, published, payload;
    uint64_t expected_field;
    uint32_t expected_serial;
    struct snip_ime_frame pending, current;
};
static void erase(void *pointer, size_t length) {
    volatile unsigned char *bytes = pointer;
    while (length--) *bytes++ = 0;
}
static int64_t now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_BOOTTIME, &value)) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int allowed(struct snip_ime *owner, snip_ime_check check, void *context) {
    if (!check || !check(context)) return 0;
    return !owner->payload || (!owner->dirty && owner->current.active
        && owner->current.field == owner->expected_field
        && owner->current.serial == owner->expected_serial);
}
static int public_type(const struct snip_ime_frame *frame) {
    return frame->has_type && !(frame->hint & ~0x1fffU)
        && !(frame->hint & 0x10c0U) && frame->purpose <= 13
        && frame->purpose != 8 && frame->purpose != 9;
}
static void activate(void *data, struct zwp_input_method_v2 *method) {
    (void)method;
    struct snip_ime *owner = data;
    uint64_t field = owner->pending.field;
    uint32_t serial = owner->pending.serial;
    if (field == UINT64_MAX) { owner->failed = 1; return; }
    erase(&owner->pending, sizeof(owner->pending));
    erase(owner->current.text, sizeof(owner->current.text));
    owner->pending.field = field + 1;
    owner->pending.serial = serial;
    owner->pending.active = 1;
    owner->dirty = 1;
}
static void deactivate(void *data, struct zwp_input_method_v2 *method) {
    (void)method;
    struct snip_ime *owner = data;
    owner->pending.active = 0;
    owner->dirty = 1;
    erase(owner->pending.text, sizeof(owner->pending.text));
    erase(owner->current.text, sizeof(owner->current.text));
    owner->pending.has_text = 0;
}
static void surrounding(void *data, struct zwp_input_method_v2 *method,
                        const char *text, uint32_t cursor, uint32_t anchor) {
    (void)method;
    struct snip_ime *owner = data;
    owner->dirty = 1;
    erase(owner->pending.text, sizeof(owner->pending.text));
    owner->pending.has_text = 0;
    size_t length = text ? strnlen(text, 4001) : 4001;
    if (length > 4000 || cursor > length || anchor > length) { owner->failed = 1; return; }
    owner->pending.cursor = cursor;
    owner->pending.anchor = anchor;
    owner->pending.length = (uint32_t)length;
    /* A type may arrive after surrounding_text in the same double buffer.
     * No text leaves C until done has confirmed an explicitly public type. */
    if (!owner->pending.has_type || public_type(&owner->pending)) {
        memcpy(owner->pending.text, text, length);
        owner->pending.has_text = 1;
    }
}
static void cause(void *data, struct zwp_input_method_v2 *method, uint32_t value) {
    (void)method;
    struct snip_ime *owner = data;
    owner->pending.cause = value;
    owner->dirty = 1;
}
static void content(void *data, struct zwp_input_method_v2 *method, uint32_t hint, uint32_t purpose) {
    (void)method;
    struct snip_ime *owner = data;
    owner->pending.hint = hint;
    owner->pending.purpose = purpose;
    owner->pending.has_type = 1;
    owner->dirty = 1;
    if (!public_type(&owner->pending)) {
        erase(owner->pending.text, sizeof(owner->pending.text));
        erase(owner->current.text, sizeof(owner->current.text));
        owner->pending.has_text = 0;
    }
}
static void done(void *data, struct zwp_input_method_v2 *method) {
    (void)method;
    struct snip_ime *owner = data;
    owner->pending.serial++;
    erase(&owner->current, sizeof(owner->current));
    owner->current = owner->pending;
    if (!owner->current.active || !public_type(&owner->current)) {
        erase(owner->current.text, sizeof(owner->current.text));
        owner->current.has_text = 0;
    }
    erase(owner->pending.text, sizeof(owner->pending.text));
    owner->pending.has_text = 0;
    owner->pending.length = 0;
    owner->pending.cursor = owner->pending.anchor = 0;
    owner->pending.cause = 0;
    owner->dirty = 0;
    owner->published = 1;
}
static void unavailable(void *data, struct zwp_input_method_v2 *method) {
    (void)method;
    struct snip_ime *owner = data;
    owner->failed = 1;
    erase(&owner->pending, sizeof(owner->pending));
    erase(&owner->current, sizeof(owner->current));
}
static const struct zwp_input_method_v2_listener method_listener = {
    .activate = activate, .deactivate = deactivate, .surrounding_text = surrounding,
    .text_change_cause = cause, .content_type = content, .done = done, .unavailable = unavailable
};
static void capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
    (void)seat;
    struct snip_ime *owner = data;
    owner->keyboard = !!(caps & WL_SEAT_CAPABILITY_KEYBOARD);
    if (!owner->keyboard) owner->failed = 1;
}
static const struct wl_seat_listener seat_listener = { .capabilities = capabilities };
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    struct snip_ime *owner = data;
    if (!strcmp(interface, "wl_seat")) {
        if (++owner->seats != 1 || !version) { owner->failed = 1; return; }
        owner->seat_name = name;
        owner->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
        if (!owner->seat) { owner->failed = 1; return; }
        wl_seat_add_listener(owner->seat, &seat_listener, owner);
    } else if (!strcmp(interface, "zwp_input_method_manager_v2")) {
        if (++owner->managers != 1 || !version) { owner->failed = 1; return; }
        owner->manager_name = name;
        owner->manager = wl_registry_bind(registry, name, &zwp_input_method_manager_v2_interface, 1);
        if (!owner->manager) owner->failed = 1;
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)registry;
    struct snip_ime *owner = data;
    if (name == owner->seat_name || name == owner->manager_name) unavailable(owner, NULL);
}
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };

/* Return 1 for an expired observation, 2 for revoked consent, 3 for transport.
 * Reading always balances prepare_read. Cleanup never flushes a payload. */
static int pump(struct snip_ime *owner, int64_t deadline, snip_ime_check check, void *context) {
    if (!allowed(owner, check, context)) return 2;
    int64_t stamp = now_ms();
    if (stamp < 0 || deadline < 0 || deadline - stamp > 5000) return 3;
    if (owner->failed || wl_display_dispatch_pending(owner->display) < 0 || owner->failed) return 3;
    if (!allowed(owner, check, context)) return 2;
    while (wl_display_prepare_read(owner->display) != 0) {
        if (wl_display_dispatch_pending(owner->display) < 0 || owner->failed) return 3;
        if (!allowed(owner, check, context)) return 2;
    }
    if (!allowed(owner, check, context)) { wl_display_cancel_read(owner->display); return 2; }
    int flushed = wl_display_flush(owner->display);
    if (flushed < 0 && errno != EAGAIN) { wl_display_cancel_read(owner->display); return 3; }
    if (flushed >= 0) owner->payload = 0;
    stamp = now_ms();
    if (stamp < 0 || deadline - stamp > 5000) { wl_display_cancel_read(owner->display); return 3; }
    int64_t remaining = deadline > stamp ? deadline - stamp : 0;
    struct pollfd fd = { .fd = wl_display_get_fd(owner->display), .events = POLLIN | (flushed < 0 ? POLLOUT : 0) };
    int result = poll(&fd, 1, remaining > 50 ? 50 : (int)remaining);
    if (result < 0 && errno != EINTR) { wl_display_cancel_read(owner->display); return 3; }
    if (result > 0 && (fd.revents & POLLIN)) {
        if (wl_display_read_events(owner->display) < 0) return 3;
    } else wl_display_cancel_read(owner->display);
    if ((fd.revents & (POLLERR | POLLHUP | POLLNVAL)) || owner->failed
        || wl_display_dispatch_pending(owner->display) < 0) return 3;
    if (!allowed(owner, check, context)) return 2;
    return result > 0 ? 0 : 1;
}
static void synchronized(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial;
    *(int *)data = 1;
    wl_callback_destroy(callback);
}
static const struct wl_callback_listener callback_listener = { .done = synchronized };
static int synchronize(struct snip_ime *owner, snip_ime_check check, void *context) {
    int completed = 0;
    struct wl_callback *callback = wl_display_sync(owner->display);
    if (!callback) return 3;
    wl_callback_add_listener(callback, &callback_listener, &completed);
    int64_t start = now_ms();
    while (!completed) {
        int64_t stamp = now_ms();
        if (start < 0 || stamp < start || stamp >= start + 2000) {
            wl_callback_destroy(callback);
            return 1;
        }
        int status = pump(owner, start < 0 ? -1 : start + 2000, check, context);
        if (status == 1 && now_ms() >= 0 && now_ms() < start + 2000) continue;
        if (status) { if (!completed) wl_callback_destroy(callback); return status; }
    }
    return owner->failed ? 3 : 0;
}
void snip_ime_close(struct snip_ime *owner) {
    if (!owner) return;
    /* Local destruction avoids marshalling/auto-flushing on cancellation. */
    if (owner->method) wl_proxy_destroy((struct wl_proxy *)owner->method);
    if (owner->manager) wl_proxy_destroy((struct wl_proxy *)owner->manager);
    if (owner->seat) wl_proxy_destroy((struct wl_proxy *)owner->seat);
    if (owner->registry) wl_proxy_destroy((struct wl_proxy *)owner->registry);
    if (owner->display) wl_display_disconnect(owner->display);
    erase(owner, sizeof(*owner));
    free(owner);
}
struct snip_ime *snip_ime_connect_fd(int fd, snip_ime_check check, void *context, int *status) {
    *status = 2;
    if (!check || !check(context)) { close(fd); return NULL; }
    struct snip_ime *owner = calloc(1, sizeof(*owner));
    if (!owner) { close(fd); *status = 3; return NULL; }
    owner->display = wl_display_connect_to_fd(fd);
    if (!owner->display) { free(owner); *status = 3; return NULL; }
    *status = 0;
    return owner;
}
struct snip_ime *snip_ime_connect(snip_ime_check check, void *context, int *status) {
    *status = 2;
    if (!check || !check(context)) return NULL;
    const char *display = getenv("WAYLAND_DISPLAY"), *runtime = getenv("XDG_RUNTIME_DIR");
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
        int64_t start = now_ms();
        for (;;) {
            if (!check(context)) { close(fd); return NULL; }
            int64_t stamp = now_ms();
            if (start < 0 || stamp < start || stamp >= start + 2000) { close(fd); *status = 1; return NULL; }
            struct pollfd pollfd = { .fd = fd, .events = POLLOUT };
            int ready = poll(&pollfd, 1, 50);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) { close(fd); *status = 3; return NULL; }
            if (!ready) continue;
            int error = 0; socklen_t size = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) || error) { close(fd); *status = 3; return NULL; }
            break;
        }
    }
    return snip_ime_connect_fd(fd, check, context, status);
}
uint64_t snip_ime_peer(struct snip_ime *owner) {
    struct ucred peer;
    socklen_t size = sizeof(peer);
    if (getsockopt(wl_display_get_fd(owner->display), SOL_SOCKET, SO_PEERCRED, &peer, &size)
        || size != sizeof(peer) || peer.uid != getuid() || peer.pid <= 0) return 0;
    return (uint64_t)peer.pid;
}
int snip_ime_start(struct snip_ime *owner, snip_ime_check check, void *context) {
    if (!allowed(owner, check, context)) return 2;
    if (owner->registry || owner->method) return 3;
    owner->registry = wl_display_get_registry(owner->display);
    if (!owner->registry) return 3;
    wl_registry_add_listener(owner->registry, &registry_listener, owner);
    int status = synchronize(owner, check, context);
    if (status || owner->seats != 1 || owner->managers != 1 || !owner->seat || !owner->manager) return status ? status : 3;
    /* Seat capability events are delivered after its bind is processed. */
    status = synchronize(owner, check, context);
    if (status || !owner->keyboard) return status ? status : 3;
    owner->method = zwp_input_method_manager_v2_get_input_method(owner->manager, owner->seat);
    if (!owner->method) return 3;
    zwp_input_method_v2_add_listener(owner->method, &method_listener, owner);
    return synchronize(owner, check, context);
}
int snip_ime_poll(struct snip_ime *owner, unsigned milliseconds, snip_ime_check check, void *context) {
    if (milliseconds > 50) return 3;
    int64_t stamp = now_ms();
    return pump(owner, stamp < 0 ? -1 : stamp + milliseconds, check, context);
}
int snip_ime_frame(struct snip_ime *owner, struct snip_ime_frame *output) {
    erase(output, sizeof(*output));
    if (owner->failed || owner->dirty || !owner->published) return 0;
    *output = owner->current;
    return 1;
}
int snip_ime_replace(struct snip_ime *owner, uint64_t field, uint32_t serial,
                     uint32_t before, const char *text, snip_ime_check check, void *context) {
    if (!allowed(owner, check, context)) return 2;
    int64_t stamp = now_ms();
    int status = pump(owner, stamp, check, context); /* drain ready focus/text events */
    if (status != 0 && status != 1) return status;
    struct snip_ime_frame *frame = &owner->current;
    size_t length = text ? strnlen(text, 4001) : 4001;
    if (owner->failed || owner->dirty || !owner->method || !frame->active
        || !public_type(frame) || !frame->has_text || frame->cursor != frame->anchor
        || field != frame->field || serial != frame->serial || before > frame->cursor
        || length > 1024 || owner->payload) return 2;
    owner->expected_field = field;
    owner->expected_serial = serial;
    owner->payload = 1;
    zwp_input_method_v2_delete_surrounding_text(owner->method, before, 0);
    zwp_input_method_v2_commit_string(owner->method, text);
    zwp_input_method_v2_commit(owner->method, serial);
    return synchronize(owner, check, context);
}
