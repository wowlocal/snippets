/* Native input-popup metadata rendering and bounded keyboard events.
 * Included by inline_wayland.c on its own verified Wayland connection. */
#define SNIP_POPUP_WIDTH 360
#define SNIP_POPUP_ROW 56
struct snip_popup_span { uint32_t start, end; };
struct snip_popup_row {
    char name[513], keyword[257];
    uint32_t pinned, name_count, keyword_count;
    struct snip_popup_span names[120], keywords[120];
};
struct snip_ime_key {
    uint64_t field;
    uint32_t serial, key, state, time, symbol, modifiers, kind;
    uint32_t depressed, latched, locked, group, map_generation;
};
struct snip_popup_buffer {
    struct wl_buffer *buffer;
    void *pixels;
    size_t bytes;
    int released;
    struct snip_popup_buffer *next;
};
struct snip_popup {
    struct wl_surface *surface;
    struct zwp_input_popup_surface_v2 *role;
    struct zwp_input_method_keyboard_grab_v2 *grab;
    struct zwp_virtual_keyboard_v1 *keyboard;
    struct xkb_context *xkb;
    struct xkb_keymap *map;
    struct xkb_state *state;
    int map_fd;
    uint32_t map_size, map_generation, forwarded_map;
    uint32_t depressed, latched, locked, group;
    uint64_t field;
    uint32_t serial;
    unsigned visible;
    struct snip_ime_key keys[32];
    unsigned keys_count;
    struct snip_popup_buffer *buffers;
};
static void popup_rectangle(void *data, struct zwp_input_popup_surface_v2 *popup,
                            int32_t x, int32_t y, int32_t width, int32_t height) {
    (void)data; (void)popup; (void)x; (void)y; (void)width; (void)height;
    /* The compositor positions input_popup at its active text-input area. */
}
static const struct zwp_input_popup_surface_v2_listener popup_listener = { .text_input_rectangle = popup_rectangle };
static void popup_release(void *data, struct wl_buffer *buffer) {
    (void)buffer; ((struct snip_popup_buffer *)data)->released = 1;
}
static const struct wl_buffer_listener popup_buffer_listener = { .release = popup_release };
static void popup_collect(struct snip_popup *popup, int all) {
    struct snip_popup_buffer **at = &popup->buffers;
    while (*at) {
        struct snip_popup_buffer *buffer = *at;
        if (all || buffer->released) {
            *at = buffer->next;
            if (all) wl_proxy_destroy((struct wl_proxy *)buffer->buffer);
            else wl_buffer_destroy(buffer->buffer);
            munmap(buffer->pixels, buffer->bytes); free(buffer);
        } else at = &buffer->next;
    }
}
static void popup_local_close(struct snip_popup *popup) {
    popup_collect(popup, 1);
    if (popup->grab) wl_proxy_destroy((struct wl_proxy *)popup->grab);
    if (popup->keyboard) wl_proxy_destroy((struct wl_proxy *)popup->keyboard);
    if (popup->role) wl_proxy_destroy((struct wl_proxy *)popup->role);
    if (popup->surface) wl_proxy_destroy((struct wl_proxy *)popup->surface);
    if (popup->state) xkb_state_unref(popup->state);
    if (popup->map) xkb_keymap_unref(popup->map);
    if (popup->xkb) xkb_context_unref(popup->xkb);
    if (popup->map_fd >= 0) close(popup->map_fd);
    memset(popup, 0, sizeof(*popup)); popup->map_fd = -1;
}
/* Public metadata only; invalid strings/ranges fail before drawing. */
static int popup_text(cairo_t *cr, const char *text, size_t maximum, int y,
                      const struct snip_popup_span *spans, uint32_t count,
                      const uint32_t *colors, int small) {
    size_t length = strnlen(text, maximum + 1);
    if (length > maximum || count > 120 || !g_utf8_validate(text, (gssize)length, NULL)) return 0;
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string(small ? "Sans 9" : "Sans 11");
    pango_layout_set_font_description(layout, font); pango_font_description_free(font);
    pango_layout_set_text(layout, text, (int)length);
    pango_layout_set_width(layout, (SNIP_POPUP_WIDTH - 48) * PANGO_SCALE);
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    PangoAttrList *attributes = pango_attr_list_new();
    for (unsigned i = 0; i < count; i++) {
        if (spans[i].start >= spans[i].end || spans[i].end > length
            || (spans[i].start && (text[spans[i].start] & 0xc0) == 0x80)
            || (spans[i].end < length && (text[spans[i].end] & 0xc0) == 0x80)) {
            pango_attr_list_unref(attributes); g_object_unref(layout); return 0;
        }
        uint32_t color = colors[2];
        PangoAttribute *attribute = pango_attr_foreground_new(((color >> 16) & 255) * 257,
                                                             ((color >> 8) & 255) * 257, (color & 255) * 257);
        attribute->start_index = spans[i].start; attribute->end_index = spans[i].end;
        pango_attr_list_insert(attributes, attribute);
        attribute = pango_attr_weight_new(PANGO_WEIGHT_BOLD);
        attribute->start_index = spans[i].start; attribute->end_index = spans[i].end;
        pango_attr_list_insert(attributes, attribute);
    }
    pango_layout_set_attributes(layout, attributes); pango_attr_list_unref(attributes);
    uint32_t color = colors[1];
    cairo_set_source_rgb(cr, ((color >> 16) & 255) / 255.0, ((color >> 8) & 255) / 255.0, (color & 255) / 255.0);
    cairo_move_to(cr, 16, y); pango_cairo_show_layout(cr, layout); g_object_unref(layout);
    return cairo_status(cr) == CAIRO_STATUS_SUCCESS;
}
int snip_popup_render(void *pixels, size_t bytes, const struct snip_popup_row *rows,
                      uint32_t count, uint32_t selected, const uint32_t *colors) {
    if (!pixels || !rows || !colors || !count || count > 8 || selected >= count) return 0;
    int height = (int)count * SNIP_POPUP_ROW + 36;
    if (bytes != (size_t)SNIP_POPUP_WIDTH * (size_t)height * 4) return 0;
    cairo_surface_t *surface = cairo_image_surface_create_for_data(pixels, CAIRO_FORMAT_ARGB32,
        SNIP_POPUP_WIDTH, height, SNIP_POPUP_WIDTH * 4);
    cairo_t *cr = cairo_create(surface);
    uint32_t bg = colors[0];
    cairo_set_source_rgb(cr, ((bg >> 16) & 255) / 255.0, ((bg >> 8) & 255) / 255.0, (bg & 255) / 255.0); cairo_paint(cr);
    for (unsigned i = 0; i < count; i++) {
        if (i == selected) {
            uint32_t accent = colors[2];
            cairo_set_source_rgba(cr, ((accent >> 16) & 255) / 255.0, ((accent >> 8) & 255) / 255.0, (accent & 255) / 255.0, 0.18);
            cairo_rectangle(cr, 4, i * SNIP_POPUP_ROW + 4, SNIP_POPUP_WIDTH - 8, SNIP_POPUP_ROW - 4); cairo_fill(cr);
        }
        if (!popup_text(cr, rows[i].name, 512, (int)i * SNIP_POPUP_ROW + 9, rows[i].names, rows[i].name_count, colors, 0)
            || !popup_text(cr, rows[i].keyword, 256, (int)i * SNIP_POPUP_ROW + 32, rows[i].keywords, rows[i].keyword_count, colors, 1)) {
            cairo_destroy(cr); cairo_surface_destroy(surface); return 0;
        }
        if (rows[i].pinned) {
            uint32_t color = colors[2]; cairo_set_source_rgb(cr, ((color >> 16)&255)/255.0, ((color>>8)&255)/255.0, (color&255)/255.0);
            cairo_arc(cr, SNIP_POPUP_WIDTH - 16, i * SNIP_POPUP_ROW + 20, 3, 0, 6.283185307); cairo_fill(cr);
        }
    }
    int good = popup_text(cr, "↑ ↓ select · Return/Tab insert · Esc close", 128, (int)count * SNIP_POPUP_ROW + 12, NULL, 0, colors, 1);
    cairo_surface_flush(surface); cairo_destroy(cr); cairo_surface_destroy(surface); return good;
}
