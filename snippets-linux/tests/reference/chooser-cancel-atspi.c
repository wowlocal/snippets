/* Exact public controls in our installed process on a private accessibility bus.
 * Never extract text, credentials, other process trees or caller identifiers. */
#include <atspi/atspi.h>
#include <stdlib.h>
#include <string.h>

static guint pid, matches, nodes;
static const char *wanted;
static AtspiAccessible *target;

static void visit(AtspiAccessible *item, guint depth) {
  if (depth > 32 || ++nodes > 4096) return;
  GError *error = NULL;
  gchar *name = atspi_accessible_get_name(item, &error);
  g_clear_error(&error);
  AtspiRole role = atspi_accessible_get_role(item, &error);
  g_clear_error(&error);
  AtspiStateSet *states = atspi_accessible_get_state_set(item);
  if (!strcmp(wanted, "public-folder") && role != ATSPI_ROLE_PASSWORD_TEXT && states &&
      atspi_state_set_contains(states, ATSPI_STATE_SHOWING) &&
      atspi_state_set_contains(states, ATSPI_STATE_SENSITIVE) &&
      atspi_state_set_contains(states, ATSPI_STATE_FOCUSED)) {
    AtspiEditableText *editable = atspi_accessible_get_editable_text_iface(item);
    if (editable) { matches++; g_set_object(&target, item); }
    g_clear_object(&editable);
  }
  if (role == ATSPI_ROLE_PUSH_BUTTON && name && !strcmp(name, wanted) && states &&
      atspi_state_set_contains(states, ATSPI_STATE_SHOWING) &&
      atspi_state_set_contains(states, ATSPI_STATE_SENSITIVE)) {
    matches++;
    g_set_object(&target, item);
  }
  g_free(name);
  g_clear_object(&states);
  gint count = atspi_accessible_get_child_count(item, &error);
  g_clear_error(&error);
  for (gint i = 0; i < count && nodes < 4096; i++) {
    AtspiAccessible *child = atspi_accessible_get_child_at_index(item, i, &error);
    g_clear_error(&error);
    if (child) { visit(child, depth + 1); g_object_unref(child); }
  }
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  char *end = NULL;
  unsigned long value = strtoul(argv[1], &end, 10);
  if (!value || value > G_MAXUINT || !end || *end) return 2;
  pid = (guint)value;
  wanted = argv[2];
  if (strcmp(wanted, "Library Recovery History…") && strcmp(wanted, "Review…") &&
      strcmp(wanted, "Choose Several Vault Files…") && strcmp(wanted, "Cancel") &&
      strcmp(wanted, "public-folder")) return 2;
  if (atspi_init() != 0) return 3;
  AtspiAccessible *desktop = atspi_get_desktop(0);
  if (!desktop) return 3;
  GError *error = NULL;
  gint count = atspi_accessible_get_child_count(desktop, &error);
  g_clear_error(&error);
  for (gint i = 0; i < count; i++) {
    AtspiAccessible *app = atspi_accessible_get_child_at_index(desktop, i, &error);
    g_clear_error(&error);
    if (app && atspi_accessible_get_process_id(app, &error) == pid) visit(app, 0);
    g_clear_error(&error);
    g_clear_object(&app);
  }
  int result = 5;
  if (matches == 1 && target) {
    if (!strcmp(wanted, "public-folder")) {
      const char *folder = g_getenv("SNIPPETS_CHOOSER_PUBLIC_FOLDER");
      AtspiEditableText *editable = atspi_accessible_get_editable_text_iface(target);
      if (folder && editable && atspi_editable_text_set_text_contents(editable, folder, &error) && !error) result = 0;
      g_clear_object(&editable);
    } else {
      AtspiAction *action = atspi_accessible_get_action_iface(target);
      if (action && atspi_action_do_action(action, 0, &error) && !error) result = 0;
      g_clear_object(&action);
    }
    g_clear_error(&error);
  }
  g_clear_object(&target);
  g_object_unref(desktop);
  atspi_exit();
  return result;
}
