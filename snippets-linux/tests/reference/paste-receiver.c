#include <gtk/gtk.h>
#include <string.h>

static void changed(GtkTextBuffer *buffer, gpointer data) {
    (void)data;
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    char *text = gtk_text_buffer_get_text(buffer, &start, &end, TRUE);
    if (strcmp(text, "fictional snippet fictional clipboard fixture") == 0) {
        // Report only the public fixture match, never receiving-field contents.
        g_file_set_contents(g_getenv("SNIPPETS_TEST_PASTE_RESULT"), "matched\n", -1, NULL);
    }
    g_free(text);
}

static void activate(GtkApplication *application, gpointer data) {
    (void)data;
    GtkWidget *window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(window), "Snippets Smoke Paste Target");
    gtk_window_set_default_size(GTK_WINDOW(window), 440, 200);
    GtkWidget *view = gtk_text_view_new();
    gtk_window_set_child(GTK_WINDOW(window), view);
    g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)), "changed",
                     G_CALLBACK(changed), NULL);
    gtk_window_present(GTK_WINDOW(window));
    gtk_widget_grab_focus(view);
}

static gboolean finish(gpointer data) {
    g_application_quit(G_APPLICATION(data));
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
    if (g_getenv("SNIPPETS_TEST_PASTE_RESULT") == NULL) return 2;
    GtkApplication *application = gtk_application_new(
        "com.khm.snippets.linux.PasteReceiver", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(application, "activate", G_CALLBACK(activate), NULL);
    // Bound cleanup even if the Rust test aborts before its owned-child guard.
    g_timeout_add_seconds(60, finish, application);
    int status = g_application_run(G_APPLICATION(application), argc, argv);
    g_object_unref(application);
    return status;
}
