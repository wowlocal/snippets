// Independent GTK clipboard owner. Commands select only fixed public fixtures;
// neither control file nor acknowledgements contain desktop clipboard data.
#include <gtk/gtk.h>
#include <string.h>

static GtkWidget *source_window;
static unsigned last_command;

static gboolean publish(gpointer data) {
    (void)data;
    char *command = NULL;
    gsize size = 0;
    if (!g_file_get_contents(g_getenv("SNIPPETS_TEST_CLIPBOARD_COMMAND"),
                             &command, &size, NULL)) return G_SOURCE_CONTINUE;
    unsigned selected = size == 1 && command[0] >= '1' && command[0] <= '5'
        ? (unsigned)(command[0] - '0') : 0;
    g_free(command);
    if (!selected || selected == last_command) return G_SOURCE_CONTINUE;
    const char *text[] = {
        "", "Public pre-existing clipboard fixture",
        "Public background clipboard fixture",
        "Public sensitivity-hinted clipboard fixture",
        "Public internally marked clipboard fixture",
        "Public collection-disabled clipboard fixture"
    };
    GdkClipboard *clipboard = gtk_widget_get_clipboard(source_window);
    if (selected == 3 || selected == 4) {
        GBytes *body = g_bytes_new_static(text[selected], strlen(text[selected]));
        GBytes *marker = g_bytes_new_static("1", 1);
        GdkContentProvider *providers[] = {
            gdk_content_provider_new_for_bytes("text/plain;charset=utf-8", body),
            gdk_content_provider_new_for_bytes(selected == 3
                ? "x-kde-passwordManagerHint"
                : "application/x-snippets-clipboard-history", marker)
        };
        GdkContentProvider *provider = gdk_content_provider_new_union(providers, 2);
        gdk_clipboard_set_content(clipboard, provider);
        g_object_unref(provider);
        g_bytes_unref(body);
        g_bytes_unref(marker);
    } else {
        gdk_clipboard_set_text(clipboard, text[selected]);
    }
    last_command = selected;
    char ack[] = { (char)('0' + selected), '\0' };
    g_file_set_contents(g_getenv("SNIPPETS_TEST_CLIPBOARD_ACK"), ack, 1, NULL);
    return G_SOURCE_CONTINUE;
}

static void activate(GtkApplication *application, gpointer data) {
    (void)data;
    source_window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(source_window), "Snippets Public Clipboard Source");
    gtk_window_set_default_size(GTK_WINDOW(source_window), 440, 160);
    gtk_window_set_child(GTK_WINDOW(source_window),
        gtk_label_new("Public clipboard history acceptance fixture"));
    gtk_window_present(GTK_WINDOW(source_window));
    g_timeout_add(30, publish, NULL);
}

static gboolean finish(gpointer data) {
    g_application_quit(G_APPLICATION(data));
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
    if (!g_getenv("SNIPPETS_TEST_CLIPBOARD_COMMAND") ||
        !g_getenv("SNIPPETS_TEST_CLIPBOARD_ACK")) return 2;
    GtkApplication *application = gtk_application_new(
        "com.khm.snippets.linux.ClipboardSource", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(application, "activate", G_CALLBACK(activate), NULL);
    g_timeout_add_seconds(60, finish, application);
    int status = g_application_run(G_APPLICATION(application), argc, argv);
    g_object_unref(application);
    return status;
}
