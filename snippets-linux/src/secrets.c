/* Stable libsecret API. No error text, labels, paths or secrets are logged.
 * Background operations never run a keyring prompt, including a lock race.
 * All synchronous work is cancellable and runs off the native UI thread. */
#include <libsecret/secret.h>
#include <stdint.h>
#include <string.h>

enum { OK = 0, MISSING = 1, LOCKED = 2, UNAVAILABLE = 3, INVALID = 4,
       DUPLICATE = 5, TIMEOUT = 6, UNSUPPORTED = 7, INVALID_TYPE = 8 };
enum { READ = 0, WRITE = 1, DELETE = 2 };
#define LIMIT (128 * 1024)
static const SecretSchema schema = {
    .name = "com.khm.snippets.linux.secrets.v1",
    .flags = SECRET_SCHEMA_NONE,
    .attributes = { { "install", SECRET_SCHEMA_ATTRIBUTE_STRING },
                    { "slot", SECRET_SCHEMA_ATTRIBUTE_STRING }, { NULL, 0 } }
};
typedef struct { SecretService parent; } SnipSecretService;
typedef struct { SecretServiceClass parent; } SnipSecretServiceClass;
G_DEFINE_TYPE(SnipSecretService, snip_secret_service, SECRET_TYPE_SERVICE)
static GQuark no_prompt_domain(void) {
    return g_quark_from_static_string("snippets-keyring-prompt-refused");
}
static GVariant *no_prompt_sync(SecretService *service, SecretPrompt *prompt,
        GCancellable *cancel, const GVariantType *type, GError **error) {
    (void)service; (void)prompt; (void)cancel; (void)type;
    g_set_error_literal(error, no_prompt_domain(), 1, "Keyring interaction is required");
    return NULL;
}
static void no_prompt_async(SecretService *service, SecretPrompt *prompt,
        const GVariantType *type, GCancellable *cancel,
        GAsyncReadyCallback callback, gpointer user_data) {
    (void)prompt; (void)type;
    GTask *task = g_task_new(service, cancel, callback, user_data);
    g_task_return_new_error(task, no_prompt_domain(), 1, "Keyring interaction is required");
    g_object_unref(task);
}
static GVariant *no_prompt_finish(SecretService *service, GAsyncResult *result, GError **error) {
    (void)service;
    return g_task_propagate_pointer(G_TASK(result), error);
}
static void snip_secret_service_class_init(SnipSecretServiceClass *klass) {
    SecretServiceClass *service = SECRET_SERVICE_CLASS(klass);
    service->prompt_sync = no_prompt_sync;
    service->prompt_async = no_prompt_async;
    service->prompt_finish = no_prompt_finish;
}
static void snip_secret_service_init(SnipSecretService *self) { (void)self; }
typedef struct {
    GCancellable *cancel;
    GMutex mutex;
    GCond condition;
    gboolean finished;
} Deadline;
static gpointer cancel_at_deadline(gpointer pointer) {
    Deadline *deadline = pointer;
    const gint64 until = g_get_monotonic_time() + 10 * G_TIME_SPAN_SECOND;
    g_mutex_lock(&deadline->mutex);
    while (!deadline->finished) {
        if (!g_cond_wait_until(&deadline->condition, &deadline->mutex, until)) {
            g_cancellable_cancel(deadline->cancel);
            break;
        }
    }
    g_mutex_unlock(&deadline->mutex);
    return NULL;
}
static int classify_error(const GError *error) {
    if (!error) return UNAVAILABLE;
    if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)
            || g_error_matches(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT)) return TIMEOUT;
    if (error->domain == no_prompt_domain()
            || g_error_matches(error, SECRET_ERROR, SECRET_ERROR_IS_LOCKED)) return LOCKED;
    return UNAVAILABLE;
}
/* Caller provides a zeroizing output buffer. Searches include locked items and
 * every duplicate; none is mistaken for absence or arbitrarily selected. */
int snip_secret_operation(const char *install, const char *slot, int operation,
        const uint8_t *input, size_t input_size,
        uint8_t *output, size_t output_capacity, size_t *output_size) {
    int result = UNAVAILABLE;
    GError *error = NULL;
    SecretService *service = NULL;
    SecretCollection *collection = NULL;
    SecretValue *value = NULL;
    GHashTable *attributes = NULL;
    GList *items = NULL;
    *output_size = 0;
    if (!install || !slot || input_size > LIMIT || output_capacity > LIMIT
            || operation < READ || operation > DELETE) return INVALID;
    Deadline deadline = { .cancel = g_cancellable_new(), .finished = FALSE };
    g_mutex_init(&deadline.mutex); g_cond_init(&deadline.condition);
    GThread *timer = g_thread_new("snippets-keyring-deadline", cancel_at_deadline, &deadline);
    service = secret_service_open_sync(snip_secret_service_get_type(), NULL,
        SECRET_SERVICE_OPEN_SESSION, deadline.cancel, &error);
    if (!service) goto done;
    /* libsecret negotiates the session. Never accept plaintext fallback. */
    if (g_strcmp0(secret_service_get_session_algorithms(service),
            "dh-ietf1024-sha256-aes128-cbc-pkcs7") != 0) { result = UNSUPPORTED; goto done; }
    attributes = secret_attributes_build(&schema, "install", install, "slot", slot, NULL);
    items = secret_service_search_sync(service, &schema, attributes, SECRET_SEARCH_ALL,
        deadline.cancel, &error);
    if (error) goto done;
    if (items && items->next) { result = DUPLICATE; goto done; }
    SecretItem *item = items ? items->data : NULL;
    if (item && secret_item_get_locked(item)) { result = LOCKED; goto done; }
    if (operation == READ) {
        if (!item) { result = MISSING; goto done; }
        if (!secret_item_load_secret_sync(item, deadline.cancel, &error)) goto done;
        value = secret_item_get_secret(item);
        /* GNOME Keyring returns text/plain even for stored binary SecretValues.
         * Preserve the explicit byte length; Rust validates the typed payload. */
        const gchar *type = value ? secret_value_get_content_type(value) : NULL;
        if (!value || (g_strcmp0(type, "application/octet-stream") != 0
                && g_strcmp0(type, "text/plain") != 0)) {
            result = INVALID_TYPE; goto done;
        }
        gsize length = 0;
        const char *bytes = secret_value_get(value, &length);
        if (!bytes || !length || length > output_capacity) { result = INVALID; goto done; }
        memcpy(output, bytes, length); *output_size = length; result = OK;
    } else if (operation == DELETE) {
        if (!item) { result = MISSING; goto done; }
        if (secret_item_delete_sync(item, deadline.cancel, &error)) result = OK;
    } else {
        if (!input || !input_size) { result = INVALID; goto done; }
        value = secret_value_new((const char *)input, input_size, "application/octet-stream");
        if (item) {
            if (secret_item_set_secret_sync(item, value, deadline.cancel, &error)) result = OK;
        } else {
            collection = secret_collection_for_alias_sync(service, SECRET_COLLECTION_DEFAULT,
                SECRET_COLLECTION_NONE, deadline.cancel, &error);
            if (!collection) goto done;
            if (secret_collection_get_locked(collection)) { result = LOCKED; goto done; }
            SecretItem *created = secret_item_create_sync(collection, &schema, attributes,
                "Snippets cloud secrets", value, SECRET_ITEM_CREATE_NONE, deadline.cancel, &error);
            if (created) { result = OK; g_object_unref(created); }
        }
    }
done:
    if (error) { result = classify_error(error); g_error_free(error); }
    if (value) secret_value_unref(value);
    g_list_free_full(items, g_object_unref);
    if (attributes) g_hash_table_unref(attributes);
    if (collection) g_object_unref(collection);
    if (service) g_object_unref(service);
    g_mutex_lock(&deadline.mutex);
    deadline.finished = TRUE; g_cond_signal(&deadline.condition);
    g_mutex_unlock(&deadline.mutex);
    g_thread_join(timer);
    g_cond_clear(&deadline.condition); g_mutex_clear(&deadline.mutex);
    g_object_unref(deadline.cancel);
    return result;
}
