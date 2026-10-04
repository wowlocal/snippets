/* Independent private protocol peer. Never opens a display, renders or sends input. */
#include <wayland-server.h>
#include "snippets-session-lock-server.h"
#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct fixture {
    struct wl_display *display;
    struct wl_resource *lock;
    int delayed, denied, quit, locked, destroyed, unlocked;
};
static void destroy(struct wl_client *client, struct wl_resource *resource) {
    (void)client; wl_resource_destroy(resource);
}
static void lock_destroy(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    struct fixture *fixture = wl_resource_get_user_data(resource);
    assert(fixture->denied && !fixture->locked && !fixture->unlocked);
    fixture->destroyed++;
    wl_resource_destroy(resource);
    fixture->lock = NULL;
}
static void forbidden_surface(struct wl_client *client, struct wl_resource *resource,
    uint32_t id, struct wl_resource *surface, struct wl_resource *output) {
    (void)client; (void)resource; (void)id; (void)surface; (void)output;
    abort();
}
static void unlock(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    struct fixture *fixture = wl_resource_get_user_data(resource);
    assert(fixture->locked && !fixture->unlocked && !fixture->destroyed);
    fixture->unlocked++;
    wl_resource_destroy(resource);
    fixture->lock = NULL;
}
static const struct ext_session_lock_v1_interface lock_impl = {
    .destroy = lock_destroy, .get_lock_surface = forbidden_surface, .unlock_and_destroy = unlock
};
static void lock(struct wl_client *client, struct wl_resource *manager, uint32_t id) {
    struct fixture *fixture = wl_resource_get_user_data(manager);
    assert(!fixture->lock && !fixture->locked && !fixture->unlocked && !fixture->destroyed);
    fixture->lock = wl_resource_create(client, &ext_session_lock_v1_interface, 1, id);
    assert(fixture->lock);
    wl_resource_set_implementation(fixture->lock, &lock_impl, fixture, NULL);
    if (fixture->denied) ext_session_lock_v1_send_finished(fixture->lock);
    else if (!fixture->delayed) {
        fixture->locked = 1;
        ext_session_lock_v1_send_locked(fixture->lock);
    }
}
static const struct ext_session_lock_manager_v1_interface manager_impl = {
    .destroy = destroy, .lock = lock
};
static void bind_manager(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    assert(version == 1);
    struct wl_resource *resource = wl_resource_create(client, &ext_session_lock_manager_v1_interface, 1, id);
    assert(resource);
    wl_resource_set_implementation(resource, &manager_impl, data, NULL);
}
static int command(int fd, uint32_t mask, void *data) {
    struct fixture *fixture = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { fixture->quit = 1; return 0; }
    char byte;
    if (read(fd, &byte, 1) != 1 || byte == 'Q') { fixture->quit = 1; return 0; }
    if (byte == 'L') {
        assert(fixture->delayed && fixture->lock && !fixture->locked && !fixture->denied);
        fixture->locked = 1;
        ext_session_lock_v1_send_locked(fixture->lock);
        wl_display_flush_clients(fixture->display);
    }
    if (byte == 'K') byte = fixture->lock ? 'P' : fixture->unlocked == 1 ? 'U' : fixture->destroyed == 1 ? 'F' : 'N';
    assert(write(fd, &byte, 1) == 1);
    return 0;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    signal(SIGPIPE, SIG_IGN);
    struct fixture fixture = { .delayed = !strcmp(argv[1], "delayed"), .denied = !strcmp(argv[1], "denied") };
    fixture.display = wl_display_create();
    assert(fixture.display);
    if (strcmp(argv[1], "missing")) {
        assert(wl_global_create(fixture.display, &ext_session_lock_manager_v1_interface, 1, &fixture, bind_manager));
        if (!strcmp(argv[1], "duplicate"))
            assert(wl_global_create(fixture.display, &ext_session_lock_manager_v1_interface, 1, &fixture, bind_manager));
    }
    assert(wl_client_create(fixture.display, STDIN_FILENO));
    struct wl_event_loop *loop = wl_display_get_event_loop(fixture.display);
    struct wl_event_source *commands = wl_event_loop_add_fd(loop, STDERR_FILENO, WL_EVENT_READABLE, command, &fixture);
    assert(commands && write(STDERR_FILENO, "!", 1) == 1);
    while (!fixture.quit) { assert(wl_event_loop_dispatch(loop, 20) == 0); wl_display_flush_clients(fixture.display); }
    wl_event_source_remove(commands);
    wl_display_destroy_clients(fixture.display);
    wl_display_destroy(fixture.display);
    return 0;
}
