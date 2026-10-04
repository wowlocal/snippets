/* Exercises production callback privacy/publication boundaries without IPC. */
#include "../../src/inline_wayland.c"
#include <assert.h>
static int consent(void *data) { return *(int *)data; }
static int empty(const unsigned char *bytes, size_t length) {
    while (length--) if (*bytes++) return 0;
    return 1;
}
int main(void) {
    struct snip_ime owner = {0};
    struct snip_ime_frame frame;
    int enabled = 1;
    assert(!snip_ime_frame(&owner, &frame));
    activate(&owner, NULL);
    surrounding(&owner, NULL, "Public \\caf", 11, 11);
    cause(&owner, NULL, 1);
    content(&owner, NULL, 0, 0);
    assert(!snip_ime_frame(&owner, &frame));
    done(&owner, NULL);
    assert(snip_ime_frame(&owner, &frame));
    assert(frame.field == 1 && frame.serial == 1 && frame.has_text);
    assert(frame.length == 11 && !strcmp((char *)frame.text, "Public \\caf"));
    assert(empty(owner.pending.text, sizeof(owner.pending.text)));
    owner.payload = 1;
    owner.expected_field = frame.field; owner.expected_serial = frame.serial;
    assert(allowed(&owner, consent, &enabled));
    surrounding(&owner, NULL, "Public \\cafe", 12, 12);
    assert(!allowed(&owner, consent, &enabled));
    assert(!snip_ime_frame(&owner, &frame));
    owner.payload = 0;
    done(&owner, NULL);
    assert(snip_ime_frame(&owner, &frame) && frame.serial == 2 && frame.cause == 0);
    for (unsigned kind = 0; kind < 6; kind++) {
        surrounding(&owner, NULL, "Fictional private", 17, 17);
        content(&owner, NULL, kind < 4 ? (1U << (kind == 0 ? 6 : kind == 1 ? 7 : kind == 2 ? 12 : 15)) : 0,
                kind == 4 ? 8 : kind == 5 ? 9 : 0);
        assert(empty(owner.pending.text, sizeof(owner.pending.text)));
        assert(empty(owner.current.text, sizeof(owner.current.text)));
        done(&owner, NULL);
        assert(snip_ime_frame(&owner, &frame) && !frame.has_text);
        content(&owner, NULL, 0, 0);
        done(&owner, NULL);
        assert(snip_ime_frame(&owner, &frame) && !frame.has_text);
    }
    surrounding(&owner, NULL, "Public", 6, 6);
    done(&owner, NULL);
    deactivate(&owner, NULL);
    assert(!snip_ime_frame(&owner, &frame));
    assert(empty(owner.current.text, sizeof(owner.current.text)));
    done(&owner, NULL);
    assert(snip_ime_frame(&owner, &frame) && !frame.active && !frame.has_text);
    owner.pending.serial = UINT32_MAX;
    activate(&owner, NULL);
    done(&owner, NULL);
    assert(snip_ime_frame(&owner, &frame) && frame.field == 2 && frame.serial == 0 && !frame.has_type);
    enabled = 0;
    assert(!allowed(&owner, consent, &enabled));
    content(&owner, NULL, 0, 0);
    surrounding(&owner, NULL, "Public", 6, 6);
    done(&owner, NULL);
    owner.seat_name = 1;
    removed(&owner, NULL, 1);
    assert(owner.failed && !snip_ime_frame(&owner, &frame));
    assert(empty(owner.current.text, sizeof(owner.current.text)));
    assert(empty(owner.pending.text, sizeof(owner.pending.text)));
    erase(&owner, sizeof(owner));
    capabilities(&owner, NULL, WL_SEAT_CAPABILITY_KEYBOARD);
    assert(owner.keyboard && !owner.failed);
    capabilities(&owner, NULL, 0);
    assert(owner.failed);
    erase(&owner, sizeof(owner));
    owner.pending.field = UINT64_MAX;
    activate(&owner, NULL);
    assert(owner.failed);
    erase(&owner, sizeof(owner));
    char oversize[4002]; memset(oversize, 'X', 4001); oversize[4001] = 0;
    surrounding(&owner, NULL, oversize, 4001, 4001);
    assert(owner.failed);
    return 0;
}
