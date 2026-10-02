/* Read-only ext-data-control client. No clipboard writes, logs, file-backed
 * buffers or keys. Every wait is bounded and checks revocable Rust consent.
 * Protocol bindings are generated from the installed wayland-protocols XML. */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "snippets-data-control.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

typedef int (*snip_check)(void *);
struct snip_control;
struct snip_offer {
    struct ext_data_control_offer_v1 *proxy;
    struct snip_control *owner;
    struct snip_offer *next;
    char formats[256][257];
    unsigned count;
    int invalid;
};
struct snip_control {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct ext_data_control_manager_v1 *manager;
    struct ext_data_control_device_v1 *device;
    struct snip_offer *offers, *selected;
    uint32_t seat_name, manager_name;
    unsigned seats, offer_count;
    uint64_t generation;
    int failed;
};
static int64_t now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_BOOTTIME, &value) != 0) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int64_t deadline_after(int milliseconds) {
    int64_t now = now_ms();
    return now < 0 ? -1 : now + milliseconds;
}
static int admitted(snip_check check, void *context) {
    return check && check(context);
}
static void drop_offer(struct snip_offer *offer) {
    if (!offer) return;
    struct snip_control *owner = offer->owner;
    struct snip_offer **link = &owner->offers;
    while (*link && *link != offer) link = &(*link)->next;
    if (*link) { *link = offer->next; owner->offer_count--; }
    if (owner->selected == offer) owner->selected = NULL;
    ext_data_control_offer_v1_destroy(offer->proxy);
    free(offer);
}
static void offer_format(void *data, struct ext_data_control_offer_v1 *proxy, const char *mime) {
    (void)proxy;
    struct snip_offer *offer = data;
    size_t length = mime ? strnlen(mime, 257) : 257;
    if (offer->count == 256 || length > 256) { offer->invalid = 1; return; }
    memcpy(offer->formats[offer->count], mime, length + 1);
    offer->count++;
}
static const struct ext_data_control_offer_v1_listener offer_listener = { .offer = offer_format };
static void data_offer(void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *proxy) {
    (void)device;
    struct snip_control *owner = data;
    if (owner->offer_count == 8) {
        owner->failed = 1;
        ext_data_control_offer_v1_destroy(proxy);
        return;
    }
    struct snip_offer *offer = calloc(1, sizeof(*offer));
    if (!offer) { owner->failed = 1; ext_data_control_offer_v1_destroy(proxy); return; }
    offer->owner = owner; offer->proxy = proxy;
    offer->next = owner->offers; owner->offers = offer; owner->offer_count++;
    ext_data_control_offer_v1_add_listener(proxy, &offer_listener, offer);
}
static void selection(void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *proxy) {
    (void)device;
    struct snip_control *owner = data;
    struct snip_offer *offer = proxy ? ext_data_control_offer_v1_get_user_data(proxy) : NULL;
    if (offer && (offer->owner != owner || offer == owner->selected)) { owner->failed = 1; return; }
    drop_offer(owner->selected);
    owner->selected = offer;
    owner->generation++;
}
static void finished(void *data, struct ext_data_control_device_v1 *device) {
    (void)device;
    ((struct snip_control *)data)->failed = 1;
}
static void primary_selection(void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *proxy) {
    (void)device;
    struct snip_control *owner = data;
    struct snip_offer *offer = proxy ? ext_data_control_offer_v1_get_user_data(proxy) : NULL;
    if (offer == owner->selected && offer) { owner->failed = 1; return; }
    // Primary selection (mouse selection) is never requested or retained.
    drop_offer(offer);
}
static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = data_offer, .selection = selection, .finished = finished, .primary_selection = primary_selection
};
static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t capabilities) {
    (void)data; (void)seat; (void)capabilities;
}
static void seat_label(void *data, struct wl_seat *seat, const char *name) {
    (void)data; (void)seat; (void)name;
}
static const struct wl_seat_listener seat_listener = { .capabilities = seat_capabilities, .name = seat_label };
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    struct snip_control *owner = data;
    if (!strcmp(interface, "wl_seat")) {
        if (version == 0) { owner->failed = 1; return; }
        owner->seats++;
        if (owner->seats != 1) { owner->failed = 1; return; }
        owner->seat_name = name;
        owner->seat = wl_registry_bind(registry, name, &wl_seat_interface, version < 2 ? version : 2);
        wl_seat_add_listener(owner->seat, &seat_listener, owner);
    } else if (!strcmp(interface, "ext_data_control_manager_v1")) {
        if (owner->manager || version < 1) { owner->failed = 1; return; }
        owner->manager_name = name;
        owner->manager = wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1);
    }
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)registry;
    struct snip_control *owner = data;
    if (name == owner->seat_name || name == owner->manager_name) owner->failed = 1;
}
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = global_remove };
// Pump exactly one bounded poll; read and cancel always balance prepare_read.
static int pump(struct snip_control *owner, int other_fd, int64_t deadline, snip_check check, void *context) {
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
static int synchronize(struct snip_control *owner, snip_check check, void *context) {
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
void snip_control_close(struct snip_control *owner) {
    if (!owner) return;
    while (owner->offers) drop_offer(owner->offers);
    if (owner->device) ext_data_control_device_v1_destroy(owner->device);
    if (owner->manager) ext_data_control_manager_v1_destroy(owner->manager);
    if (owner->seat) wl_seat_destroy(owner->seat);
    if (owner->registry) wl_registry_destroy(owner->registry);
    if (owner->display) wl_display_disconnect(owner->display);
    free(owner);
}
// Takes ownership of fd even on failure. Also used by the private socket-pair
// protocol fixture; no socket bind or real desktop is needed by that fixture.
struct snip_control *snip_control_open_fd(int fd, snip_check check, void *context, int *status) {
    *status = 2;
    if (!admitted(check, context)) { close(fd); return NULL; }
    struct snip_control *owner = calloc(1, sizeof(*owner));
    if (!owner) { close(fd); *status = 3; return NULL; }
    owner->display = wl_display_connect_to_fd(fd);
    /* libwayland owns fd even when connecting fails. */
    if (!owner->display) { free(owner); *status = 3; return NULL; }
    owner->registry = wl_display_get_registry(owner->display);
    if (!owner->registry) { *status = 3; snip_control_close(owner); return NULL; }
    wl_registry_add_listener(owner->registry, &registry_listener, owner);
    *status = synchronize(owner, check, context);
    if (*status || owner->seats != 1 || !owner->manager || !owner->seat) {
        if (!*status) *status = 3;
        snip_control_close(owner); return NULL;
    }
    owner->device = ext_data_control_manager_v1_get_data_device(owner->manager, owner->seat);
    if (!owner->device) { *status = 3; snip_control_close(owner); return NULL; }
    ext_data_control_device_v1_add_listener(owner->device, &device_listener, owner);
    *status = synchronize(owner, check, context);
    if (*status || owner->generation == 0) {
        if (!*status) *status = 3;
        snip_control_close(owner); return NULL;
    }
    return owner;
}
struct snip_control *snip_control_open(snip_check check, void *context, int *status) {
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
        int64_t deadline = deadline_after(2000);
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
    return snip_control_open_fd(fd, check, context, status);
}
uint64_t snip_control_generation(struct snip_control *owner) { return owner->generation; }
// 0=changed, 1=idle/deadline, 2=revoked, 3=unavailable.
int snip_control_next(struct snip_control *owner, uint64_t previous, snip_check check, void *context) {
    int64_t deadline = deadline_after(100);
    while (owner->generation == previous) {
        int status = pump(owner, -1, deadline, check, context);
        if (status) return status;
    }
    return admitted(check, context) ? 0 : 2;
}
unsigned snip_control_formats(struct snip_control *owner) {
    return owner->selected && !owner->selected->invalid ? owner->selected->count : 0;
}
const char *snip_control_format(struct snip_control *owner, unsigned index) {
    return owner->selected && !owner->selected->invalid && index < owner->selected->count ? owner->selected->formats[index] : NULL;
}
// Receive to caller-owned, zeroizing memory, never to a file. Selection changes,
// overflow, stalls and revocation invalidate the whole transfer.
int snip_control_receive(struct snip_control *owner, uint64_t generation, const char *mime,
    uint8_t *bytes, size_t capacity, size_t *length, snip_check check, void *context) {
    *length = 0;
    if (!admitted(check, context)) return 2;
    if (!owner->selected || owner->selected->invalid || owner->generation != generation || capacity > 256 * 1024 + 1) return 3;
    int offered = 0;
    for (unsigned index = 0; index < owner->selected->count; index++)
        if (!strcmp(mime, owner->selected->formats[index])) offered = 1;
    if (!offered) return 3;
    int descriptors[2];
    if (pipe2(descriptors, O_CLOEXEC) < 0) return 3;
    if (fcntl(descriptors[0], F_SETFL, O_NONBLOCK) < 0) { close(descriptors[0]); close(descriptors[1]); return 3; }
    ext_data_control_offer_v1_receive(owner->selected->proxy, mime, descriptors[1]);
    close(descriptors[1]);
    int result = 3;
    int64_t deadline = deadline_after(5000);
    for (;;) {
        int64_t stamp = now_ms();
        if (deadline < 0 || stamp < 0 || stamp >= deadline || deadline - stamp > 5000) { result = 1; break; }
        if (!admitted(check, context)) { result = 2; break; }
        if (owner->generation != generation) { result = 2; break; }
        if (*length == capacity) { result = 3; break; }
        ssize_t count = read(descriptors[0], bytes + *length, capacity - *length);
        if (count > 0) { *length += (size_t)count; continue; }
        if (count == 0) {
            // Dispatch already-arrived replacement events before accepting EOF.
            result = pump(owner, -1, deadline_after(1), check, context);
            if (result == 1) result = 0;
            if (owner->generation != generation) result = 2;
            break;
        }
        if (errno != EAGAIN && errno != EINTR) break;
        result = pump(owner, descriptors[0], deadline, check, context);
        if (result) break;
    }
    close(descriptors[0]);
    if (result == 0 && !admitted(check, context)) result = 2;
    return result;
}
