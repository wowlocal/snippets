/* Private socket-pair compositor fixture. All offered text is fictional.
 * stdin is a Wayland connection, stderr a private command/ack socket; no
 * display socket, environment lookup, GTK, keyring, PAM or user files. */
#define _GNU_SOURCE
#include <wayland-server.h>
#include "snippets-data-control-server.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct fixture;
struct offer { struct fixture *fixture; char kind; };
struct writer {
    struct fixture *fixture;
    struct writer *next;
    struct wl_event_source *source;
    int fd;
    size_t offset, length;
    const unsigned char *text;
};
struct fixture {
    struct wl_display *display;
    struct wl_resource *device;
    struct writer *writers;
    unsigned receives;
    int quit;
    int initial_capture;
};
static const unsigned char public_text[] = "Public cafe\xc3\xa9 \xf0\x9f\xa6\x80 {clipboard}\n ";
static const unsigned char nul_text[] = "Public\0text";
static const unsigned char invalid_text[] = { 0xff };
static void destroy(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    wl_resource_destroy(resource);
}
static void destroy_offer(struct wl_resource *resource) {
    free(wl_resource_get_user_data(resource));
}
static void drop_writer(struct writer *writer) {
    struct writer **link = &writer->fixture->writers;
    while (*link && *link != writer) link = &(*link)->next;
    assert(*link == writer);
    *link = writer->next;
    if (writer->source) wl_event_source_remove(writer->source);
    close(writer->fd);
    free(writer);
}
static int write_body(int fd, uint32_t mask, void *data) {
    struct writer *writer = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { drop_writer(writer); return 0; }
    unsigned char fill[8192];
    memset(fill, 'x', sizeof(fill));
    while (writer->offset < writer->length) {
        size_t count = writer->length - writer->offset;
        if (count > sizeof(fill)) count = sizeof(fill);
        const unsigned char *bytes = writer->text ? writer->text + writer->offset : fill;
        ssize_t written = write(fd, bytes, count);
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && errno == EAGAIN) return 0;
        if (written <= 0) { drop_writer(writer); return 0; }
        writer->offset += (size_t)written;
    }
    drop_writer(writer);
    return 0;
}
static void selection(struct fixture *fixture, char kind, int primary);
static void receive(struct wl_client *client, struct wl_resource *resource, const char *mime, int fd) {
    (void)client;
    struct offer *offer = wl_resource_get_user_data(resource);
    struct fixture *fixture = offer->fixture;
    assert(offer->kind != 'A' && offer->kind != 'P'); /* baseline / primary */
    assert(!strcmp(mime, "text/plain;charset=utf-8"));
    fixture->receives++;
    if (offer->kind == 'R') {
        selection(fixture, 'T', 0);
        wl_display_flush_clients(fixture->display);
    }
    struct writer *writer = calloc(1, sizeof(*writer));
    assert(writer);
    writer->fixture = fixture; writer->fd = fd;
    writer->next = fixture->writers; fixture->writers = writer;
    writer->text = public_text; writer->length = sizeof(public_text) - 1;
    if (offer->kind == 'M' || offer->kind == 'O') {
        writer->text = NULL;
        writer->length = 256 * 1024 + (offer->kind == 'O' ? 8192 : 0);
    } else if (offer->kind == 'B') {
        writer->text = invalid_text; writer->length = sizeof(invalid_text);
    } else if (offer->kind == 'N') {
        writer->text = nul_text; writer->length = sizeof(nul_text) - 1;
    } else if (offer->kind == 'E') writer->length = 0;
    if (offer->kind == 'S') return; /* intentionally stalled provider */
    assert(fcntl(fd, F_SETFL, O_NONBLOCK) == 0);
    writer->source = wl_event_loop_add_fd(wl_display_get_event_loop(fixture->display),
        fd, WL_EVENT_WRITABLE, write_body, writer);
    assert(writer->source);
}
static const struct ext_data_control_offer_v1_interface offer_impl = {
    .receive = receive, .destroy = destroy
};
static void selection(struct fixture *fixture, char kind, int primary) {
    assert(fixture->device);
    struct wl_resource *resource = wl_resource_create(wl_resource_get_client(fixture->device),
        &ext_data_control_offer_v1_interface, 1, 0);
    assert(resource);
    struct offer *offer = calloc(1, sizeof(*offer));
    assert(offer);
    offer->fixture = fixture; offer->kind = kind;
    wl_resource_set_implementation(resource, &offer_impl, offer, destroy_offer);
    ext_data_control_device_v1_send_data_offer(fixture->device, resource);
    ext_data_control_offer_v1_send_offer(resource, "text/plain;charset=utf-8");
    if (kind == 'H') ext_data_control_offer_v1_send_offer(resource, "x-kde-passwordManagerHint");
    if (kind == 'I') ext_data_control_offer_v1_send_offer(resource, "application/x-snippets-clipboard-history");
    if (kind == 'F') for (unsigned index = 0; index < 256; index++)
        ext_data_control_offer_v1_send_offer(resource, "application/x-fictional-fixture");
    if (kind == 'L') {
        char mime[258]; memset(mime, 'x', sizeof(mime) - 1); mime[sizeof(mime) - 1] = '\0';
        ext_data_control_offer_v1_send_offer(resource, mime);
    }
    if (primary) ext_data_control_device_v1_send_primary_selection(fixture->device, resource);
    else ext_data_control_device_v1_send_selection(fixture->device, resource);
}
static void forbidden_selection(struct wl_client *client, struct wl_resource *resource, struct wl_resource *source) {
    (void)client; (void)resource; (void)source;
    abort(); /* Production reader must never write either selection. */
}
static const struct ext_data_control_device_v1_interface device_impl = {
    .set_selection = forbidden_selection, .destroy = destroy, .set_primary_selection = forbidden_selection
};
static void get_device(struct wl_client *client, struct wl_resource *manager, uint32_t id, struct wl_resource *seat) {
    (void)seat;
    struct fixture *fixture = wl_resource_get_user_data(manager);
    fixture->device = wl_resource_create(client, &ext_data_control_device_v1_interface, 1, id);
    assert(fixture->device);
    wl_resource_set_implementation(fixture->device, &device_impl, fixture, NULL);
    selection(fixture, fixture->initial_capture ? 'T' : 'A', 0);
    selection(fixture, 'P', 1);
}
static void forbidden_source(struct wl_client *client, struct wl_resource *manager, uint32_t id) {
    (void)client; (void)manager; (void)id;
    abort();
}
static const struct ext_data_control_manager_v1_interface manager_impl = {
    .create_data_source = forbidden_source, .get_data_device = get_device, .destroy = destroy
};
static void bind_manager(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    assert(version == 1);
    struct wl_resource *resource = wl_resource_create(client, &ext_data_control_manager_v1_interface, version, id);
    assert(resource);
    wl_resource_set_implementation(resource, &manager_impl, data, NULL);
}
static void bind_seat(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    (void)data;
    struct wl_resource *resource = wl_resource_create(client, &wl_seat_interface, version, id);
    assert(resource);
    /* The reader requests no keyboard, pointer, touch or seat release. */
    wl_resource_set_implementation(resource, NULL, NULL, NULL);
    wl_seat_send_capabilities(resource, WL_SEAT_CAPABILITY_KEYBOARD);
    if (version >= 2) wl_seat_send_name(resource, "fictional-seat");
}
static int command(int fd, uint32_t mask, void *data) {
    struct fixture *fixture = data;
    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) { fixture->quit = 1; return 0; }
    unsigned char kind;
    if (read(fd, &kind, 1) != 1) { fixture->quit = 1; return 0; }
    if (kind == 'Q') { fixture->quit = 1; return 0; }
    if (kind == 'K') {
        assert(fixture->receives < 256);
        unsigned char count = (unsigned char)fixture->receives;
        assert(write(fd, &count, 1) == 1);
        return 0;
    }
    if (kind == 'D') ext_data_control_device_v1_send_finished(fixture->device);
    else selection(fixture, (char)kind, kind == 'P');
    wl_display_flush_clients(fixture->display);
    assert(write(fd, &kind, 1) == 1);
    return 0;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    signal(SIGPIPE, SIG_IGN);
    struct fixture fixture = {0};
    fixture.initial_capture = !strcmp(argv[1], "capture");
    fixture.display = wl_display_create();
    assert(fixture.display);
    assert(wl_global_create(fixture.display, &wl_seat_interface, 2, &fixture, bind_seat));
    if (!strcmp(argv[1], "two-seats"))
        assert(wl_global_create(fixture.display, &wl_seat_interface, 2, &fixture, bind_seat));
    if (strcmp(argv[1], "missing"))
        assert(wl_global_create(fixture.display, &ext_data_control_manager_v1_interface, 1, &fixture, bind_manager));
    assert(wl_client_create(fixture.display, STDIN_FILENO));
    struct wl_event_loop *loop = wl_display_get_event_loop(fixture.display);
    struct wl_event_source *commands = wl_event_loop_add_fd(loop, STDERR_FILENO, WL_EVENT_READABLE, command, &fixture);
    assert(commands);
    assert(write(STDERR_FILENO, "!", 1) == 1);
    while (!fixture.quit) {
        assert(wl_event_loop_dispatch(loop, 100) == 0);
        wl_display_flush_clients(fixture.display);
    }
    while (fixture.writers) drop_writer(fixture.writers);
    wl_event_source_remove(commands);
    wl_display_destroy_clients(fixture.display);
    wl_display_destroy(fixture.display);
    return 0;
}
