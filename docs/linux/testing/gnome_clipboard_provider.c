/* Owned GTK protocol fixture. Native GTask ownership is preserved across delay. */
#include <gtk/gtk.h>
typedef struct { GdkContentProvider parent; guint requests; } SnippetsDelayedProvider;
typedef struct { GdkContentProviderClass parent; } SnippetsDelayedProviderClass;
G_DEFINE_TYPE(SnippetsDelayedProvider, snippets_delayed_provider, GDK_TYPE_CONTENT_PROVIDER)
static GdkContentFormats *formats(GdkContentProvider *provider) {
    (void)provider;
    const char *values[] = {"text/plain;charset=utf-8"};
    return gdk_content_formats_new(values, 1);
}
static void property(GObject *object, guint id, GValue *value, GParamSpec *spec) {
    if (id == 1) g_value_set_uint(value, ((SnippetsDelayedProvider *)object)->requests);
    else G_OBJECT_WARN_INVALID_PROPERTY_ID(object, id, spec);
}
static void written(GObject *stream, GAsyncResult *result, gpointer data) {
    GTask *task = G_TASK(data);
    GError *error = NULL;
    if (g_output_stream_write_all_finish(G_OUTPUT_STREAM(stream), result, NULL, &error))
        g_task_return_boolean(task, TRUE);
    else g_task_return_error(task, error);
    g_object_unref(task);
}
static gboolean delayed_write(gpointer data) {
    GTask *task = G_TASK(data);
    static const char text[] = "Public delayed text";
    g_output_stream_write_all_async(g_task_get_task_data(task), text, sizeof(text) - 1,
        G_PRIORITY_DEFAULT, g_task_get_cancellable(task), written, task);
    return G_SOURCE_REMOVE;
}
static void write_async(GdkContentProvider *provider, const char *mime, GOutputStream *stream,
                        int priority, GCancellable *cancel, GAsyncReadyCallback callback, gpointer data) {
    (void)mime; (void)priority;
    ((SnippetsDelayedProvider *)provider)->requests++;
    GTask *task = g_task_new(provider, cancel, callback, data);
    g_task_set_task_data(task, g_object_ref(stream), g_object_unref);
    g_timeout_add(400, delayed_write, task);
}
static gboolean write_finish(GdkContentProvider *provider, GAsyncResult *result, GError **error) {
    g_return_val_if_fail(g_task_is_valid(result, provider), FALSE);
    return g_task_propagate_boolean(G_TASK(result), error);
}
static void snippets_delayed_provider_class_init(SnippetsDelayedProviderClass *klass) {
    G_OBJECT_CLASS(klass)->get_property = property;
    g_object_class_install_property(G_OBJECT_CLASS(klass), 1,
        g_param_spec_uint("requests", "Requests", "Public fixture request count", 0, G_MAXUINT, 0, G_PARAM_READABLE));
    GdkContentProviderClass *provider = GDK_CONTENT_PROVIDER_CLASS(klass);
    provider->ref_formats = formats;
    provider->write_mime_type_async = write_async;
    provider->write_mime_type_finish = write_finish;
}
static void snippets_delayed_provider_init(SnippetsDelayedProvider *self) { (void)self; }
