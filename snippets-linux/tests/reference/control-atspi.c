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
    (!strcmp(mode,"editor-authenticate") || !strcmp(mode,"editor-authenticate-start")) ? "Unlock" :
    strcmp(mode,"editor-recovery") == 0 ? "Recovery Key…" :
    strcmp(mode,"editor-idle") == 0 ? "Unlock…" :
    (!strcmp(mode,"setup-open") || !strcmp(mode,"setup-idle")) ? "Set Up…" :
    (!strcmp(mode,"setup-submit") || !strcmp(mode,"setup-submit-start")) ? "Set Up" :
    g_str_has_prefix(mode,"setup-passphrase") ? "Passphrase" :
    g_str_has_prefix(mode,"setup-confirm") ? "Confirm vault setup passphrase" :
    (!strcmp(mode,"recovery-region") || !strcmp(mode,"recovery-focused")) ? "Vault recovery key. Reveal to record offline. Copy and text extraction are disabled." :
    (!strcmp(mode,"sheet-reveal") || !strcmp(mode,"sheet-hidden")) ? "Reveal Recovery Key" :
    (!strcmp(mode,"sheet-recorded") || !strcmp(mode,"sheet-recorded-selected")) ? "I recorded this key offline" :
    strcmp(mode,"sheet-continue") == 0 ? "Continue" :
    strcmp(mode,"sheet-close") == 0 ? "Close" :
    strcmp(mode,"editor-name") == 0 ? "Secure snippet name" :
    strcmp(mode,"editor-keyword") == 0 ? "Secure snippet keyword" :
    strcmp(mode,"editor-tags") == 0 ? "Secure snippet tags" :
    strcmp(mode,"editor-reveal") == 0 ? "Reveal to Edit" :
    strcmp(mode,"editor-undo") == 0 ? "Undo protected body edit" :
    strcmp(mode,"editor-redo") == 0 ? "Redo protected body edit" :
    strcmp(mode,"editor-lock") == 0 ? "Lock" :
    strcmp(mode,"editor-passphrase") == 0 ? "Change Passphrase…" :
    (!strcmp(mode,"editor-change") || !strcmp(mode,"editor-change-start")) ? "Change" :
    g_str_has_prefix(mode,"pw-current") ? "Current vault credential" :
    g_str_has_prefix(mode,"pw-new") ? "New vault passphrase" :
    g_str_has_prefix(mode,"pw-confirm") ? "Confirm new vault passphrase" :
    (!strcmp(mode,"pw-recovery") || !strcmp(mode,"pw-recovery-selected")) ? "Authenticate with recovery key" :
    strcmp(mode,"pw-busy") == 0 ? "Changing passphrase…" :
    strcmp(mode,"auth-busy") == 0 ? "Authenticating…" :
    strcmp(mode,"editor-body") == 0 ? "Protected content. Reveal to edit. Copy and text extraction are disabled." :
    (!strcmp(mode,"recovery") || !strcmp(mode,"recovery-selected")) ? "Use recovery key" : NULL;
  gboolean match = scoped && showing(item) && wanted && name && strcmp(wanted,name) == 0 &&
    (role == ATSPI_ROLE_PUSH_BUTTON || role == ATSPI_ROLE_CHECK_BOX || role == ATSPI_ROLE_TOGGLE_BUTTON);
  if (scoped && showing(item) && wanted && name && !strcmp(wanted,name) &&
      (!strcmp(mode,"editor-name") || !strcmp(mode,"editor-keyword") ||
       !strcmp(mode,"editor-tags") || g_str_has_prefix(mode,"pw-current") ||
       g_str_has_prefix(mode,"pw-new") || g_str_has_prefix(mode,"pw-confirm") ||
       g_str_has_prefix(mode,"setup-passphrase") || g_str_has_prefix(mode,"setup-confirm"))) {
    AtspiEditableText *text=atspi_accessible_get_editable_text_iface(item);
    match=text!=NULL;g_clear_object(&text);
  }
  if (scoped && showing(item) && !strcmp(mode,"editor-body") && wanted && name && !strcmp(wanted,name)) match=TRUE;
  if (scoped && showing(item) && (!strcmp(mode,"recovery-region") || !strcmp(mode,"recovery-focused")) && wanted && name && !strcmp(wanted,name)) match=TRUE;
  if (scoped && showing(item) && (!strcmp(mode,"pw-busy") || !strcmp(mode,"auth-busy")) && wanted && name && !strcmp(wanted,name) && role == ATSPI_ROLE_LABEL) match=TRUE;
  if (scoped && showing(item) && (!strcmp(mode,"input") || !strcmp(mode,"input-empty")) && role == ATSPI_ROLE_PASSWORD_TEXT) {
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
      strcmp(mode,"editor-unlock") && strcmp(mode,"editor-authenticate") &&
      strcmp(mode,"editor-name") && strcmp(mode,"editor-keyword") && strcmp(mode,"editor-tags") &&
      strcmp(mode,"editor-reveal") && strcmp(mode,"editor-body") &&
      strcmp(mode,"editor-undo") && strcmp(mode,"editor-redo") && strcmp(mode,"editor-lock") &&
      strcmp(mode,"editor-passphrase") && strcmp(mode,"editor-change") &&
      strcmp(mode,"pw-current") && strcmp(mode,"pw-new") && strcmp(mode,"pw-confirm") &&
      strcmp(mode,"pw-current-empty") && strcmp(mode,"pw-new-empty") && strcmp(mode,"pw-confirm-empty") &&
      strcmp(mode,"input-empty") && strcmp(mode,"editor-recovery") && strcmp(mode,"editor-idle") &&
      strcmp(mode,"pw-recovery") && strcmp(mode,"pw-recovery-selected") &&
      strcmp(mode,"pw-busy") && strcmp(mode,"auth-busy") &&
      strcmp(mode,"editor-change-start") && strcmp(mode,"editor-authenticate-start") &&
      strcmp(mode,"setup-open") && strcmp(mode,"setup-idle") &&
      strcmp(mode,"setup-submit") && strcmp(mode,"setup-submit-start") &&
      strcmp(mode,"setup-passphrase") && strcmp(mode,"setup-passphrase-empty") &&
      strcmp(mode,"setup-confirm") && strcmp(mode,"setup-confirm-empty") &&
      strcmp(mode,"recovery-region") && strcmp(mode,"recovery-focused") &&
      strcmp(mode,"sheet-reveal") && strcmp(mode,"sheet-hidden") &&
      strcmp(mode,"sheet-recorded") && strcmp(mode,"sheet-recorded-selected") &&
      strcmp(mode,"sheet-continue") && strcmp(mode,"sheet-close")) return 2;
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
    else if (!strcmp(mode,"recovery-region") || !strcmp(mode,"recovery-focused")) {
      AtspiText *text=atspi_accessible_get_text_iface(target);
      AtspiEditableText *editable=atspi_accessible_get_editable_text_iface(target);
      if (text || editable) result=12;
      else if (!strcmp(mode,"recovery-focused")) {
        states=atspi_accessible_get_state_set(target);
        if (!states || !atspi_state_set_contains(states,ATSPI_STATE_FOCUSED)) result=11;
        g_clear_object(&states);
      } else {
        AtspiComponent *root_component=atspi_accessible_get_component_iface(window);
        AtspiRect *root_rect=root_component ? atspi_component_get_extents(root_component,ATSPI_COORD_TYPE_WINDOW,&error) : NULL;
        if (root_rect && !error) printf("recovery_window_bounds=%d,%d,%d,%d\n",root_rect->x,root_rect->y,root_rect->width,root_rect->height);
        if (root_rect) g_boxed_free(ATSPI_TYPE_RECT,root_rect);
        g_clear_error(&error);g_clear_object(&root_component);
        AtspiComponent *component=atspi_accessible_get_component_iface(target);
        AtspiRect *rect=component ? atspi_component_get_extents(component,ATSPI_COORD_TYPE_WINDOW,&error) : NULL;
        if (!rect || error || rect->x<0 || rect->y<0 || rect->width<64 || rect->height<64 || rect->width>4096 || rect->height>2048) result=13;
        else printf("recovery_bounds=%d,%d,%d,%d\n",rect->x,rect->y,rect->width,rect->height);
        if (rect) g_boxed_free(ATSPI_TYPE_RECT,rect);
        g_clear_error(&error);g_clear_object(&component);
      }
      g_clear_object(&text);g_clear_object(&editable);
    } else if (!strcmp(mode,"editor-body")) {
      AtspiText *text=atspi_accessible_get_text_iface(target);
      AtspiEditableText *editable=atspi_accessible_get_editable_text_iface(target);
      if (text || editable) result=12;
      else {
        states=atspi_accessible_get_state_set(target);
        printf("protected_body_focusable=%d,protected_body_focused=%d\n",
          states && atspi_state_set_contains(states,ATSPI_STATE_FOCUSABLE),
          states && atspi_state_set_contains(states,ATSPI_STATE_FOCUSED));
        if (!states || !atspi_state_set_contains(states,ATSPI_STATE_FOCUSED)) result=11;
        g_clear_object(&states);
      }
      g_clear_object(&text);g_clear_object(&editable);
    } else if (!strcmp(mode,"input-empty") || g_str_has_suffix(mode,"-empty")) {
      /* Count only in a uniquely scoped credential field; never get its text. */
      AtspiText *text=atspi_accessible_get_text_iface(target);
      gint characters=text ? atspi_text_get_character_count(text,&error) : -1;
      if (characters != 0 || error) result=11;
      g_clear_error(&error);g_clear_object(&text);
    } else if (!strcmp(mode,"editor-idle") || !strcmp(mode,"setup-idle") || !strcmp(mode,"pw-busy") || !strcmp(mode,"auth-busy")) {
      /* Observation only. A matching static native label/control is required. */
    } else if (!strcmp(mode,"sheet-hidden")) {
      states=atspi_accessible_get_state_set(target);
      if (!states || atspi_state_set_contains(states,ATSPI_STATE_PRESSED)) result=11;
      g_clear_object(&states);
    } else if (!strcmp(mode,"recovery") || !strcmp(mode,"recovery-selected") ||
               !strcmp(mode,"sheet-recorded") || !strcmp(mode,"sheet-recorded-selected") ||
               !strcmp(mode,"pw-recovery") || !strcmp(mode,"pw-recovery-selected")) {
      /* GTK 4 provides neither an action nor component focus for this control.
       * Observe native focus/check state; the fixture navigates with real keys. */
      states=atspi_accessible_get_state_set(target);
      AtspiStateType state=(!strcmp(mode,"recovery") || !strcmp(mode,"pw-recovery") || !strcmp(mode,"sheet-recorded")) ? ATSPI_STATE_FOCUSED : ATSPI_STATE_CHECKED;
      if (!states || !atspi_state_set_contains(states,state)) result=11;
      g_clear_object(&states);
    } else if (!strcmp(mode,"input") || !strcmp(mode,"editor-name") ||
               !strcmp(mode,"editor-keyword") || !strcmp(mode,"editor-tags") ||
               !strcmp(mode,"pw-current") || !strcmp(mode,"pw-new") || !strcmp(mode,"pw-confirm") ||
               !strcmp(mode,"setup-passphrase") || !strcmp(mode,"setup-confirm")) {
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
