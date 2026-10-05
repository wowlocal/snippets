#include <adwaita.h>
/* Public dialog-only reproduction. The timer ends observation after layout;
 * it does not delay presentation or change GTK's fatal-warning policy. */
static gboolean finish(gpointer app) { g_application_quit(G_APPLICATION(app)); return G_SOURCE_REMOVE; }
static void activate(GApplication *app, gpointer unused) {
  (void) unused;
  GtkWidget *window = adw_application_window_new(GTK_APPLICATION(app));
  gtk_window_set_default_size(GTK_WINDOW(window), 480, 720);
  AdwDialog *dialog = adw_alert_dialog_new("Unlock the Vaults for Restoration", "Verify the saved secure changes with their vault password or recovery key. When the previous vault is selected, its changes will be encrypted in the current vault. Review the result before applying it.");
  adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "back", "Cancel", "file", "Choose Previous Vault File…", "files", "Choose Several Vault Files…", "unlock", "Verify Saved Changes", NULL);
  adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "back");
  gtk_window_present(GTK_WINDOW(window));
  adw_dialog_present(dialog, window);
  g_timeout_add(500, finish, app);
}
int main(void) {
  AdwApplication *app = adw_application_new("com.khm.snippets.headingrepro", G_APPLICATION_NON_UNIQUE);
  g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
  int result = g_application_run(G_APPLICATION(app), 0, NULL);
  g_object_unref(app);
  return result;
}
