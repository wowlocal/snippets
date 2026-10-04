/* Development-only lock owner. No authentication, surfaces, input or clipboard.
 * The compositor supplies its opaque fallback. Never exit an accepted lock
 * until unlock_and_destroy has been acknowledged by wl_display.sync. */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "snippets-session-lock.h"
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static void interrupt(int signal) { (void)signal; interrupted = 1; }
static void quiet(const char *format, va_list args) { (void)format; (void)args; }
struct owner {
    struct wl_display *display;
    struct wl_registry *registry;
    struct ext_session_lock_manager_v1 *manager;
    struct ext_session_lock_v1 *lock;
    unsigned managers;
    int prepared, requested, locked, finished, cancel, sync_done, result;
    uint64_t deadline;
};
static uint64_t milliseconds(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time)) return UINT64_MAX;
    return (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
}
static void report(struct owner *owner, char byte) {
    if (write(STDOUT_FILENO, &byte, 1) != 1) owner->cancel = 1;
}
static void synced(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial;
    struct owner *owner = data;
    wl_callback_destroy(callback);
    owner->sync_done = 1;
    report(owner, owner->result == 0 ? 'U' : 'F');
}
static const struct wl_callback_listener sync_listener = { .done = synced };
static void finish(struct owner *owner) {
    if (!owner->lock) return;
    if (owner->locked) {
        ext_session_lock_v1_unlock_and_destroy(owner->lock);
        owner->result = 0;
    } else if (owner->finished) {
        ext_session_lock_v1_destroy(owner->lock);
        owner->result = 3;
    } else return; /* A queued locked event must be read before choosing. */
    owner->lock = NULL;
    struct wl_callback *callback = wl_display_sync(owner->display);
    wl_callback_add_listener(callback, &sync_listener, owner);
}
static void locked(void *data, struct ext_session_lock_v1 *lock) {
    (void)lock;
    struct owner *owner = data;
    owner->locked = 1;
    report(owner, 'L');
    if (owner->cancel || interrupted || milliseconds() >= owner->deadline) finish(owner);
}
static void finished(void *data, struct ext_session_lock_v1 *lock) {
    (void)lock;
    struct owner *owner = data;
    owner->finished = 1;
    finish(owner);
}
static const struct ext_session_lock_v1_listener lock_listener = {
    .locked = locked, .finished = finished
};
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)version;
    struct owner *owner = data;
    if (strcmp(interface, ext_session_lock_manager_v1_interface.name)) return;
    if (++owner->managers == 1)
        owner->manager = wl_registry_bind(registry, name,
            &ext_session_lock_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)registry; (void)name;
    struct owner *owner = data;
    /* Any registry change after arming asks for a graceful unlock. */
    if (owner->requested) owner->cancel = 1;
}
static const struct wl_registry_listener registry_listener = {
    .global = global, .global_remove = removed
};
static void prepared(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial;
    struct owner *owner = data;
    wl_callback_destroy(callback);
    owner->prepared = 1;
    if (owner->managers == 1 && owner->manager) report(owner, 'R');
    else { owner->cancel = 1; owner->result = 2; }
}
static const struct wl_callback_listener prepare_listener = { .done = prepared };
static int live_peer(struct wl_display *display) {
    const char *mode = getenv("SNIPPETS_CONTROL_LIVE");
    const char *value = getenv("SNIPPETS_CONTROL_LOCK_PEER_PID");
    if (!mode || strcmp(mode, "public-private-roots") || !value || !*value) return 0;
    char *end;
    errno = 0;
    long pid = strtol(value, &end, 10);
    if (errno || *end || pid < 2 || pid > INT32_MAX || geteuid() == 0) return 0;
    struct ucred peer;
    socklen_t length = sizeof(peer);
    return !getsockopt(wl_display_get_fd(display), SOL_SOCKET, SO_PEERCRED,
                       &peer, &length) && length == sizeof(peer)
        && peer.pid == pid && peer.uid == geteuid();
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int live = !strcmp(argv[1], "--live");
    if (!live && strcmp(argv[1], "--private-socket")) return 2;
    signal(SIGPIPE, SIG_IGN);
    struct sigaction action = { .sa_handler = interrupt };
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    wl_log_set_handler_client(quiet);
    struct owner owner = { .result = 2, .deadline = milliseconds() + 5000 };
    owner.display = live ? wl_display_connect(NULL) : wl_display_connect_to_fd(STDERR_FILENO);
    if (!owner.display) return 2;
    if (live && !live_peer(owner.display)) { wl_display_disconnect(owner.display); return 2; }
    owner.registry = wl_display_get_registry(owner.display);
    wl_registry_add_listener(owner.registry, &registry_listener, &owner);
    wl_callback_add_listener(wl_display_sync(owner.display), &prepare_listener, &owner);
    int commands = 1, failed = 0;
    for (;;) {
        if (interrupted || milliseconds() >= owner.deadline) owner.cancel = 1;
        if (owner.cancel) {
            if (!owner.requested) break;
            finish(&owner);
        }
        if (owner.sync_done) break;
        while (wl_display_prepare_read(owner.display)) {
            if (wl_display_dispatch_pending(owner.display) < 0) { failed = 1; break; }
        }
        if (failed) break;
        int flushed = wl_display_flush(owner.display);
        if (flushed < 0 && errno != EAGAIN) {
            wl_display_cancel_read(owner.display); failed = 1; break;
        }
        struct pollfd descriptors[2] = {
            { .fd = wl_display_get_fd(owner.display), .events = POLLIN | (flushed < 0 ? POLLOUT : 0) },
            { .fd = commands ? STDIN_FILENO : -1, .events = POLLIN }
        };
        int count = poll(descriptors, 2, 20);
        if (count < 0) {
            wl_display_cancel_read(owner.display);
            if (errno == EINTR) continue;
            failed = 1; break;
        }
        if (descriptors[0].revents & POLLIN) {
            if (wl_display_read_events(owner.display) < 0) { failed = 1; break; }
        } else wl_display_cancel_read(owner.display);
        if (wl_display_dispatch_pending(owner.display) < 0) { failed = 1; break; }
        if (descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) { failed = 1; break; }
        if (descriptors[1].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
            char command;
            if (read(STDIN_FILENO, &command, 1) != 1) { owner.cancel = 1; commands = 0; }
            else if (command == 'L' && owner.prepared && !owner.requested && !owner.cancel) {
                owner.lock = ext_session_lock_manager_v1_lock(owner.manager);
                owner.requested = 1;
                owner.deadline = milliseconds() + 2000;
                ext_session_lock_v1_add_listener(owner.lock, &lock_listener, &owner);
            } else owner.cancel = 1;
        }
    }
    /* On transport failure the compositor has already disconnected this owner.
     * Never send invalid destroy/unlock requests or kill a still-live owner. */
    if (owner.manager) ext_session_lock_manager_v1_destroy(owner.manager);
    wl_registry_destroy(owner.registry);
    wl_display_flush(owner.display);
    wl_display_disconnect(owner.display);
    return failed ? 4 : owner.result;
}
