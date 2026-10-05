/* Write only public fixture credentials in the exact owned Release process.
 * Never read password text, export a tree or access another application's UI. */
#include <atspi/atspi.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static const char *operation, *wanted;
static AtspiAccessible *target;
static guint matches, nodes, owned_apps;
static guint data_controls, operable_data_controls;
static gboolean complete = TRUE;
static gboolean selected;
static guint headers, selected_headers, reviews, scoped_reviews;
static guint history, empty_history, storage_changed, keyring_failed, operation_failed, history_controls;

static gboolean allowed(const char *name) {
  const char *names[] = {
    "Library Recovery History…", "Reconnect Saved Account", "Review…", "Choose Previous Vault File…",
    "Choose Several Vault Files…", "Cancel", "Verify Saved Changes",
    "Verify All Saved Changes", "Restore Changes", "Keep Current State",
    "Authorize", "Current vault passphrase or recovery key",
    "Account saved. Reconnect to choose a library.",
    "Previous vault passphrase or recovery key", "Previous vault backup password",
    "Computer login password", "Also unlock the vault retained in recovery history",
    "Send Local Changes", "Receive Cloud Changes", "Sync Now",
    "Saved changes restored. Current versions and previous keys are kept. Reconnect and select a library before syncing."
  };
  for (guint i = 0; i < G_N_ELEMENTS(names); i++) if (!strcmp(name, names[i])) return TRUE;
  const char *prefixes[] = { "Vault file 1: public ", "Vault file 2: public " };
  for (guint i = 0; i < G_N_ELEMENTS(prefixes); i++)
    if (g_str_has_prefix(name, prefixes[i]) && strlen(name) < 180 &&
        (g_str_has_suffix(name, " — passphrase or recovery key") ||
         g_str_has_suffix(name, " — backup password"))) return TRUE;
  return FALSE;
}

static void visit(AtspiAccessible *item, guint depth) {
  if (depth > 40 || ++nodes > 8192) { complete = FALSE; return; }
  GError *error = NULL;
  gchar *name = atspi_accessible_get_name(item, &error);
  if (error) complete = FALSE;
  g_clear_error(&error);
  AtspiRole role = atspi_accessible_get_role(item, &error);
  if (error) complete = FALSE;
  g_clear_error(&error);
  AtspiStateSet *states = atspi_accessible_get_state_set(item);
  if (!states) complete = FALSE;
  gboolean visible = states && atspi_state_set_contains(states, ATSPI_STATE_VISIBLE)
      && atspi_state_set_contains(states, ATSPI_STATE_SHOWING);
  gboolean sensitive = states && atspi_state_set_contains(states, ATSPI_STATE_SENSITIVE);
  if (!strcmp(operation, "unavailable") && name && !strcmp(name, wanted)
      && role == ATSPI_ROLE_PUSH_BUTTON) {
    data_controls++;
    operable_data_controls += sensitive;
  }
  if (name) {
    history += !strcmp(name, "Library Recovery History");
    empty_history += !strcmp(name, "No saved switches");
    storage_changed += !strcmp(name, "Secure account storage is missing or changed. Review is required before continuing.");
    keyring_failed += !strcmp(name, "Unlock your system keyring and try again.");
    operation_failed += !strcmp(name, "The account operation could not be completed. Try again.");
    history_controls += !strcmp(name, "Library Recovery History…") && sensitive;
  }
  if (!strcmp(operation, "switch3") && name && g_str_has_prefix(name, "Switch ")) {
    headers++;
    selected = g_str_has_prefix(name, "Switch 3 · finished locally");
    selected_headers += selected;
  }
  if (name && !strcmp(name, "Review…") && role == ATSPI_ROLE_PUSH_BUTTON) {
    reviews++; scoped_reviews += selected;
  }
  gboolean found = name && !strcmp(name, wanted) && visible;
  if (found && !strcmp(operation, "switch3")) found = selected;
  if (found && (!strcmp(operation, "press") || !strcmp(operation, "switch3")))
    found = role == ATSPI_ROLE_PUSH_BUTTON && sensitive;
  else if (found && !strcmp(operation, "fill"))
    found = role == ATSPI_ROLE_PASSWORD_TEXT && sensitive;
  else if (found && !strcmp(operation, "enable"))
    found = role == ATSPI_ROLE_CHECK_BOX && sensitive;
  else if (found && !strcmp(operation, "unavailable"))
    found = role == ATSPI_ROLE_PUSH_BUTTON && !sensitive;
  else if (found && !strcmp(operation, "has")) {
    if (!strcmp(wanted, "Library Recovery History…") || !strcmp(wanted, "Reconnect Saved Account"))
      found = role == ATSPI_ROLE_PUSH_BUTTON && sensitive;
    else if (!strcmp(wanted, "Computer login password"))
      found = role == ATSPI_ROLE_PASSWORD_TEXT && sensitive;
    else found = role == ATSPI_ROLE_LABEL || role == ATSPI_ROLE_STATIC;
  }
  if (found) { matches++; g_set_object(&target, item); }
  g_free(name);
  g_clear_object(&states);
  gint count = atspi_accessible_get_child_count(item, &error);
  if (error || count < 0) complete = FALSE;
  g_clear_error(&error);
  for (gint i = 0; i < count && nodes < 8192; i++) {
    AtspiAccessible *child = atspi_accessible_get_child_at_index(item, i, &error);
    if (error || !child) complete = FALSE;
    g_clear_error(&error);
    if (child) { visit(child, depth + 1); g_object_unref(child); }
  }
  if (count > 0 && nodes >= 8192) complete = FALSE;
}

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  char *end = NULL;
  unsigned long pid = strtoul(argv[1], &end, 10);
  if (!pid || pid > G_MAXUINT || !end || *end) return 2;
  operation = argv[2]; wanted = argv[3];
  if (!allowed(wanted) || (strcmp(operation, "press") && strcmp(operation, "switch3") &&
      strcmp(operation, "fill") && strcmp(operation, "enable") &&
      strcmp(operation, "has") && strcmp(operation, "unavailable"))) return 2;
  if (!strcmp(operation, "unavailable") && strcmp(wanted, "Send Local Changes") &&
      strcmp(wanted, "Receive Cloud Changes") && strcmp(wanted, "Sync Now")) return 2;
  if (atspi_init() != 0) return 3;
  atspi_set_timeout(2000, 2000);
  AtspiAccessible *desktop = atspi_get_desktop(0);
  if (!desktop) return 3;
  GError *error = NULL;
  gint count = atspi_accessible_get_child_count(desktop, &error);
  g_clear_error(&error);
  for (gint i = 0; i < count; i++) {
    AtspiAccessible *app = atspi_accessible_get_child_at_index(desktop, i, &error);
    g_clear_error(&error);
    if (app && atspi_accessible_get_process_id(app, &error) == pid) { owned_apps++; visit(app, 0); }
    g_clear_error(&error); g_clear_object(&app);
  }
  int result = 5;
  if (owned_apps == 1 && complete && matches == 1 && target) {
    if (!strcmp(operation, "has")) result = 0;
    else if (!strcmp(operation, "press") || !strcmp(operation, "switch3")) {
      AtspiStateSet *states = atspi_accessible_get_state_set(target);
      if (states && atspi_state_set_contains(states, ATSPI_STATE_FOCUSED)) result = 0;
      g_clear_object(&states);
    }
    else if (!strcmp(operation, "fill")) {
      const char *value = g_getenv("SNIPPETS_INSTALLED_PUBLIC_INPUT");
      AtspiEditableText *editable = atspi_accessible_get_editable_text_iface(target);
      if (value && strlen(value) <= 4096 && editable &&
          atspi_editable_text_set_text_contents(editable, value, &error) && !error) result = 0;
      g_clear_object(&editable);
    } else if (!strcmp(operation, "enable")) {
      AtspiStateSet *states = atspi_accessible_get_state_set(target);
      gboolean checked = states && atspi_state_set_contains(states, ATSPI_STATE_CHECKED);
      if (checked) result = 6;
      else if (states && atspi_state_set_contains(states, ATSPI_STATE_FOCUSED)) result = 0;
      g_clear_object(&states);
    }
    g_clear_error(&error);
  }
  /* Offline account pages omit these controls from the tree. An absent or
   * insensitive control is unavailable, but an enabled control never passes. */
  if (!strcmp(operation, "unavailable") && owned_apps == 1 && complete && nodes > 0
      && data_controls <= 1 && operable_data_controls == 0) result = 0;
  g_clear_object(&target); g_object_unref(desktop); atspi_exit();
  if (result == 5) printf("[%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u]\n",
      headers, selected_headers, reviews, scoped_reviews, nodes, history,
      empty_history, storage_changed, keyring_failed, operation_failed, history_controls, matches);
  return result;
}
