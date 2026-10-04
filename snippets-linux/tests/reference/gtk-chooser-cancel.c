/* Minimal upstream GTK diagnostic: no Snippets, vault, keyring or file reads.
 * Cancel the real mapped fallback button and keep dispatching async completions.
 * Run only with the private environment provided by chooser-cancel.sh. */
#include <gtk/gtk.h>

static GMainLoop *loop;
static GtkWindow *parent;
static gboolean opened, cancelled, finished;
static gint status = 1;

static gboolean quit_loop(gpointer unused) {
  (void)unused;
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

static void completed(GObject *source, GAsyncResult *result, gpointer unused) {
  (void)unused;
  GError *error = NULL;
  GListModel *files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(source), result, &error);
  finished = TRUE;
  status = cancelled && !files && error && error->domain == GTK_DIALOG_ERROR &&
    error->code == GTK_DIALOG_ERROR_DISMISSED ? 0 : 2;
  g_clear_object(&files);
  g_clear_error(&error);
  /* Observation AFTER cancellation, never a delay intended to fix cancellation. */
  g_timeout_add(2000, quit_loop, NULL);
}

static gboolean act(gpointer unused) {
  (void)unused;
  if (!opened && gtk_window_is_active(parent)) {
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Previous vault or encrypted backup");
    gtk_file_filter_add_pattern(filter, "*.json");
    gtk_file_filter_add_pattern(filter, "*.snippetsbackup");
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Public GTK Cancel Reproduction");
    gtk_file_dialog_set_default_filter(dialog, filter);
    const char *folder = g_getenv("SNIPPETS_CHOOSER_PUBLIC_FOLDER");
    if (folder) {
      GFile *initial = g_file_new_for_path(folder);
      gtk_file_dialog_set_initial_folder(dialog, initial);
      g_object_unref(initial);
    }
    gtk_file_dialog_open_multiple(dialog, parent, NULL, completed, NULL);
    opened = TRUE;
    g_object_unref(filter);
    g_object_unref(dialog);
  }
  GListModel *windows = gtk_window_get_toplevels();
  for (guint i = 0; !cancelled && i < g_list_model_get_n_items(windows); i++) {
    GtkWindow *window = g_list_model_get_item(windows, i);
    if (GTK_IS_FILE_CHOOSER_DIALOG(window) && gtk_widget_get_mapped(GTK_WIDGET(window)) &&
        gtk_window_is_active(window)) {
      GtkWidget *button = gtk_dialog_get_widget_for_response(GTK_DIALOG(window), GTK_RESPONSE_CANCEL);
      if (GTK_IS_BUTTON(button) && gtk_widget_get_mapped(button) && gtk_widget_is_sensitive(button)) {
        cancelled = TRUE;
        g_signal_emit_by_name(button, "clicked");
      }
    }
    g_object_unref(window);
  }
  return !finished;
}

int main(void) {
  gtk_init();
  loop = g_main_loop_new(NULL, FALSE);
  parent = GTK_WINDOW(gtk_window_new());
  gtk_window_set_title(parent, "Public GTK Cancel Parent");
  gtk_window_set_default_size(parent, 400, 160);
  gtk_window_present(parent);
  g_timeout_add(1, act, NULL);
  g_timeout_add_seconds(10, quit_loop, NULL);
  g_main_loop_run(loop);
  gtk_window_destroy(parent);
  g_main_loop_unref(loop);
  g_print("mapped=%d cancelled=%d callback=%d result=%d\n", opened, cancelled, finished, status);
  return status;
}
