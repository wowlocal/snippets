/* Independent public GDBus consumer; no GTK, desktop clipboard or user bus. */
#include <gio/gio.h>
#include <cairo.h>
#include <stdint.h>
#include <string.h>

static GDBusConnection *connection;
static const char *destination;
static GVariant *call(const char *path, const char *interface, const char *method,
                      GVariant *parameters, const char *type) {
  GError *error = NULL;
  GVariant *result = g_dbus_connection_call_sync(connection, destination, path,
      interface, method, parameters, type ? G_VARIANT_TYPE(type) : NULL,
      G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, NULL, &error);
  if (error) g_error_free(error);
  return result;
}
static int icon(GVariant *pixmaps, const char *output) {
  if (!pixmaps || !g_variant_is_of_type(pixmaps, G_VARIANT_TYPE("a(iiay)")) ||
      g_variant_n_children(pixmaps) != 3) return 0;
  GVariant *image = g_variant_get_child_value(pixmaps, 2);
  gint width, height;
  GVariant *data;
  g_variant_get(image, "(ii@ay)", &width, &height, &data);
  gsize size = 0;
  const guint8 *bytes = g_variant_get_fixed_array(data, &size, 1);
  if (width != 64 || height != 64 || size != 64 * 64 * 4) return 0;
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
  uint32_t *pixels = (uint32_t *)cairo_image_surface_get_data(surface);
  int stride = cairo_image_surface_get_stride(surface) / 4;
  for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
    const guint8 *pixel = bytes + (y * width + x) * 4;
    guint a = pixel[0];
    pixels[y * stride + x] = (a << 24) | (((pixel[1] * a + 127) / 255) << 16) |
        (((pixel[2] * a + 127) / 255) << 8) | ((pixel[3] * a + 127) / 255);
  }
  cairo_surface_mark_dirty(surface);
  int ok = cairo_surface_write_to_png(surface, output) == CAIRO_STATUS_SUCCESS;
  cairo_surface_destroy(surface);
  g_variant_unref(data);
  g_variant_unref(image);
  return ok;
}
int main(int argc, char **argv) {
  if (argc != 4) return 2;
  if (strcmp(argv[1], "--pixmaps") == 0) {
    gchar *data = NULL;
    gsize size = 0;
    if (!g_file_get_contents(argv[2], &data, &size, NULL) || size > 65536) return 17;
    GBytes *bytes = g_bytes_new_take(data, size);
    GVariant *pixmaps = g_variant_new_from_bytes(G_VARIANT_TYPE("a(iiay)"), bytes, FALSE);
    int ok = g_variant_is_normal_form(pixmaps) && icon(pixmaps, argv[3]);
    g_variant_unref(pixmaps);
    g_bytes_unref(bytes);
    return ok ? 0 : 18;
  }
  GError *error = NULL;
  connection = g_dbus_connection_new_for_address_sync(argv[1],
      G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
      NULL, NULL, &error);
  if (!connection) { if (error) g_error_free(error); return 3; }
  destination = argv[2];
  GVariant *all = call("/StatusNotifierItem", "org.freedesktop.DBus.Properties", "GetAll",
      g_variant_new("(s)", "org.kde.StatusNotifierItem"), "(a{sv})");
  if (!all) return 4;
  GVariant *properties;
  g_variant_get(all, "(@a{sv})", &properties);
  const char *category = NULL, *title = NULL, *status = NULL, *menu = NULL, *name = NULL;
  gboolean only_menu = TRUE;
  if (!g_variant_lookup(properties, "Category", "&s", &category) || strcmp(category, "ApplicationStatus") ||
      !g_variant_lookup(properties, "Title", "&s", &title) || strcmp(title, "Snippets") ||
      !g_variant_lookup(properties, "Status", "&s", &status) || strcmp(status, "NeedsAttention") ||
      !g_variant_lookup(properties, "Menu", "&o", &menu) || strcmp(menu, "/com/khm/snippets/Menu") ||
      !g_variant_lookup(properties, "IconName", "&s", &name) || *name ||
      !g_variant_lookup(properties, "ItemIsMenu", "b", &only_menu) || only_menu) return 5;
  GVariant *pixmaps = g_variant_lookup_value(properties, "IconPixmap", G_VARIANT_TYPE("a(iiay)"));
  if (!icon(pixmaps, argv[3])) return 6;
  g_variant_unref(pixmaps);
  GVariant *layout = call(menu, "com.canonical.dbusmenu", "GetLayout",
      g_variant_new("(ii@as)", 0, -1, g_variant_new_strv(NULL, 0)), "(u(ia{sv}av))");
  if (!layout) return 7;
  guint revision;
  GVariant *root;
  g_variant_get(layout, "(u@(ia{sv}av))", &revision, &root);
  gint id;
  GVariant *root_properties, *children;
  g_variant_get(root, "(i@a{sv}@av)", &id, &root_properties, &children);
  if (id != 0 || !revision || g_variant_n_children(children) != 9) return 8;
  for (gsize index = 0; index < 9; ++index) {
    GVariant *wrapped = g_variant_get_child_value(children, index);
    GVariant *child = g_variant_get_variant(wrapped), *props, *nested;
    g_variant_get(child, "(i@a{sv}@av)", &id, &props, &nested);
    if (id != (gint)index + 1 || g_variant_n_children(nested)) return 9;
    if (id == 3) {
      gboolean enabled = TRUE;
      if (!g_variant_lookup(props, "enabled", "b", &enabled) || enabled) return 10;
    }
    g_variant_unref(nested); g_variant_unref(props); g_variant_unref(child); g_variant_unref(wrapped);
  }
  GVariant *reply = call(menu, "com.canonical.dbusmenu", "AboutToShow", g_variant_new("(i)", 0), "(b)");
  if (!reply) return 11;
  g_variant_unref(reply);
  reply = call(menu, "com.canonical.dbusmenu", "Event", g_variant_new("(isvu)", 3, "clicked", g_variant_new_int32(0), 0u), "()");
  if (reply) return 12;
  reply = call(menu, "com.canonical.dbusmenu", "GetProperty", g_variant_new("(is)", 1, "snippet-body"), "(v)");
  if (reply) return 13;
  reply = call(menu, "com.canonical.dbusmenu", "GetLayout", g_variant_new("(s)", "wrong signature"), NULL);
  if (reply) return 14;
  for (int item = 1; item <= 5; item += 4) {
    reply = call(menu, "com.canonical.dbusmenu", "Event", g_variant_new("(isvu)", item, "clicked", g_variant_new_int32(0), 0u), "()");
    if (!reply) return 15;
    g_variant_unref(reply);
  }
  reply = call("/StatusNotifierItem", "org.kde.StatusNotifierItem", "Activate", g_variant_new("(ii)", 0, 0), "()");
  if (!reply) return 16;
  g_variant_unref(reply);
  g_variant_unref(children); g_variant_unref(root_properties); g_variant_unref(root);
  g_variant_unref(layout); g_variant_unref(properties); g_variant_unref(all);
  g_dbus_connection_close_sync(connection, NULL, NULL);
  g_object_unref(connection);
  g_print("Verified public item properties, native icon, nine menu rows, disabled and malformed refusals, and three activations.\n");
  return 0;
}
