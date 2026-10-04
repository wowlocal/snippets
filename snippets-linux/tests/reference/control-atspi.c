/* Development-only actor for the real installed app, on a private AT-SPI bus.
 * No secret argv, body reads, caller names, paths or PID output. */
#include <atspi/atspi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *mode, *window_title;
static AtspiAccessible *window, *target;
static guint nodes, windows, targets, owned_apps;

static gboolean showing(AtspiAccessible *item) {
  AtspiStateSet *states = atspi_accessible_get_state_set(item);
  gboolean value = states && atspi_state_set_contains(states, ATSPI_STATE_SHOWING);
  g_clear_object(&states);
  return value;
}
static void visit(AtspiAccessible *item, guint depth, gboolean scoped) {
  if (depth > 32 || ++nodes > 4096) return;
  GError *error = NULL;
  AtspiRole role = atspi_accessible_get_role(item, &error);
  g_clear_error(&error);
  gchar *name = atspi_accessible_get_name(item, &error);
  g_clear_error(&error);
  gboolean is_window = name && strcmp(name, window_title) == 0 &&
    (role == ATSPI_ROLE_FRAME || role == ATSPI_ROLE_WINDOW || role == ATSPI_ROLE_DIALOG) && showing(item);
  if (is_window) { windows++; g_set_object(&window, item); }
  scoped |= is_window;
  const char *wanted = strcmp(mode,"approve") == 0 ? "Approve and Authenticate" :
    strcmp(mode,"deny") == 0 ? "Deny" : strcmp(mode,"authenticate") == 0 ? "Authenticate" :
    strcmp(mode,"cancel") == 0 ? "Cancel" :
    strcmp(mode,"editor-unlock") == 0 ? "Unlock…" :
    strcmp(mode,"editor-authenticate") == 0 ? "Unlock" :
    (!strcmp(mode,"recovery") || !strcmp(mode,"recovery-selected")) ? "Use recovery key" : NULL;
  gboolean match = scoped && showing(item) && wanted && name && strcmp(wanted,name) == 0 &&
    (role == ATSPI_ROLE_PUSH_BUTTON || role == ATSPI_ROLE_CHECK_BOX);
  if (scoped && showing(item) && strcmp(mode,"input") == 0 && role == ATSPI_ROLE_PASSWORD_TEXT) {
    AtspiEditableText *text = atspi_accessible_get_editable_text_iface(item);
    match = text != NULL; g_clear_object(&text);
  }
  if (match) { targets++; g_set_object(&target,item); }
  gint count = atspi_accessible_get_child_count(item,&error); g_clear_error(&error);
  for (gint i=0; i<count && nodes<4096; i++) {
    AtspiAccessible *child = atspi_accessible_get_child_at_index(item,i,&error); g_clear_error(&error);
    if (child) { visit(child,depth+1,scoped); g_object_unref(child); }
  }
  g_free(name);
}
int main(int argc,char **argv) {
  if (argc != 2) return 2;
  mode = argv[1];
  window_title = g_getenv("SNIPPETS_CONTROL_TEST_WINDOW");
  if (!window_title) window_title="Snippets CLI Request";
  if (strcmp(window_title,"Snippets CLI Request") && strcmp(window_title,"Secure Snippets")) return 2;
  if (strcmp(mode,"approve") && strcmp(mode,"deny") && strcmp(mode,"authenticate") &&
      strcmp(mode,"cancel") && strcmp(mode,"recovery") &&
      strcmp(mode,"recovery-selected") && strcmp(mode,"input") &&
      strcmp(mode,"editor-unlock") && strcmp(mode,"editor-authenticate")) return 2;
  const char *value = g_getenv("SNIPPETS_CONTROL_TEST_PID");
  if (!value || !*value) return 2;
  char *end = NULL; unsigned long parsed = strtoul(value,&end,10);
  if (!end || *end || !parsed || parsed>G_MAXUINT || atspi_init()!=0) return 3;
  guint pid = (guint)parsed;
  AtspiAccessible *desktop = atspi_get_desktop(0); if (!desktop) return 4;
  GError *error = NULL;
  gint count = atspi_accessible_get_child_count(desktop,&error); g_clear_error(&error);
  for (gint i=0; i<count; i++) {
    AtspiAccessible *app = atspi_accessible_get_child_at_index(desktop,i,&error); g_clear_error(&error);
    if (!app) continue;
    guint candidate = atspi_accessible_get_process_id(app,&error); g_clear_error(&error);
    if (candidate == pid) { owned_apps++; visit(app,0,FALSE); }
    g_object_unref(app);
  }
  int result = 0;
  if (windows != 1 || targets != 1 || !window || !target) result = 5;
  else {
    AtspiStateSet *states = atspi_accessible_get_state_set(target);
    /* GTK 4 advertises SENSITIVE for operable controls; ENABLED is absent. */
    gboolean ready = states && atspi_state_set_contains(states,ATSPI_STATE_SHOWING) &&
      atspi_state_set_contains(states,ATSPI_STATE_SENSITIVE);
    g_clear_object(&states);
    if (!ready) result = 6;
    else if (!strcmp(mode,"recovery") || !strcmp(mode,"recovery-selected")) {
      /* GTK 4 provides neither an action nor component focus for this control.
       * Observe native focus/check state; the fixture navigates with real keys. */
      states=atspi_accessible_get_state_set(target);
      AtspiStateType state=!strcmp(mode,"recovery") ? ATSPI_STATE_FOCUSED : ATSPI_STATE_CHECKED;
      if (!states || !atspi_state_set_contains(states,state)) result=11;
      g_clear_object(&states);
    } else if (strcmp(mode,"input") == 0) {
      char buffer[4097] = {0}; size_t size = fread(buffer,1,sizeof(buffer),stdin);
      if (!size || size>4096 || memchr(buffer,0,size)) result = 7;
      else {
        AtspiEditableText *text = atspi_accessible_get_editable_text_iface(target);
        if (!text || !atspi_editable_text_set_text_contents(text,buffer,&error)) result=8;
        g_clear_error(&error); g_clear_object(&text);
      }
      explicit_bzero(buffer,sizeof(buffer));
    } else {
      AtspiAction *action = atspi_accessible_get_action_iface(target);
      gint count = action ? atspi_action_get_n_actions(action,&error) : 0;
      gint chosen = -1;
      for (gint i=0; i<count && i<8; i++) {
        gchar *action_name = atspi_action_get_action_name(action,i,&error);
        if (action_name && (!strcmp(action_name,"click") || !strcmp(action_name,"toggle") || !strcmp(action_name,"activate"))) chosen=i;
        g_free(action_name);
      }
      if (!action || chosen<0 || !atspi_action_do_action(action,chosen,&error)) result=9;
      if (result) printf("native_action_interface=%d,native_action_count=%d,known_action_found=%d\n",action!=NULL,count,chosen>=0);
      g_clear_error(&error); g_clear_object(&action);
    }
  }
  printf("owned_application=%d,owned_request_window=%d,unique_owned_control=%d,action_succeeded=%d\n",owned_apps==1,windows==1,targets==1,result==0);
  g_clear_object(&target); g_clear_object(&window); g_object_unref(desktop); atspi_exit();
  return result;
}
