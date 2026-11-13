// Public libibus engine API, in C: the GNOME build needs no C++ compiler. Rust
// owns matching, consent and ordinary-library access. Only a backslash-started
// query crosses the authenticated local socket.
#define _GNU_SOURCE
#include <ibus.h>
#include <glib-unix.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <locale.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define LIMIT ((size_t)256 * 1024)

static GDBusConnection *session_bus = NULL;
// Every live engine, so a lock or a lost Shell clears all of them.
static GHashTable *engines = NULL;

static void wipe(void *data, size_t size) {
  volatile unsigned char *p = data;
  while (size--) *p++ = 0;
}

// Clears a string's bytes before it lets go of them.
static void erase(GString *s) {
  if (!s) return;
  wipe(s->str, s->len);
  g_string_truncate(s, 0);
}

static void erase_free(GString *s) {
  if (!s) return;
  erase(s);
  g_string_free(s, TRUE);
}

static bool valid_utf8(const char *s, size_t size) {
  return g_utf8_validate(s, (gssize)size, NULL);
}

#include "inline_rows_c.h"

// The unique name owning org.gnome.Shell, or NULL.
static char *shell_owner(GDBusConnection *bus) {
  char *name = NULL;
  GVariant *reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
      g_variant_new("(s)", "org.gnome.Shell"), G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NO_AUTO_START,
      150, NULL, NULL);
  if (reply) {
    const char *value = NULL;
    g_variant_get(reply, "(&s)", &value);
    if (value && value[0] == ':' && strlen(value) <= 256) name = g_strdup(value);
    g_variant_unref(reply);
  }
  return name;
}

// This runs on the I/O worker, never on IBus's key-event thread. Address the
// unique Shell owner and recheck ownership after reading its lock state.
static bool unlocked(GDBusConnection *bus) {
  if (!bus || g_dbus_connection_is_closed(bus)) return false;
  char *expected = shell_owner(bus);
  if (!expected) return false;
  GVariant *reply = g_dbus_connection_call_sync(
      bus, expected, "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver", "GetActive", NULL,
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 150, NULL, NULL);
  gboolean active = TRUE;
  if (reply) {
    g_variant_get(reply, "(b)", &active);
    g_variant_unref(reply);
  }
  bool result = false;
  if (!active && !g_dbus_connection_is_closed(bus)) {
    char *again = shell_owner(bus);
    result = again && strcmp(again, expected) == 0;
    g_free(again);
  }
  g_free(expected);
  return result;
}

// The authenticated stream to the Snippets app. Requests running on the worker
// hold references; the descriptor closes with the last one.
typedef struct {
  int fd;
} Connection;

static void connection_close(gpointer data) { close(((Connection *)data)->fd); }

static Connection *connection_ref(Connection *c) { return c ? g_atomic_rc_box_acquire(c) : NULL; }

static void connection_unref(Connection *c) {
  if (c) g_atomic_rc_box_release_full(c, connection_close);
}

static void connection_cancel(Connection *c) { shutdown(c->fd, SHUT_RDWR); }

static Connection *connect_app(void) {
  const char *runtime = g_getenv("XDG_RUNTIME_DIR");
  struct stat directory = {0}, socket_file = {0};
  if (!runtime || lstat(runtime, &directory) || !S_ISDIR(directory.st_mode) ||
      directory.st_uid != geteuid() || (directory.st_mode & 0077))
    return NULL;
  char *path = g_strconcat(runtime, "/snippets-ibus.sock", NULL);
  struct sockaddr_un address = {0};
  address.sun_family = AF_UNIX;
  size_t length = strlen(path);
  bool usable = length < sizeof(address.sun_path) && !lstat(path, &socket_file) &&
                S_ISSOCK(socket_file.st_mode) && socket_file.st_uid == geteuid() &&
                (socket_file.st_mode & 0777) == 0600;
  if (usable) memcpy(address.sun_path, path, length + 1);
  g_free(path);
  if (!usable) return NULL;
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  if (fd < 0) return NULL;
  Connection *result = g_atomic_rc_box_new0(Connection);
  result->fd = fd;
  if (connect(fd, (struct sockaddr *)&address, sizeof(address))) goto refuse;
  struct ucred peer = {0};
  socklen_t size = sizeof(peer);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) || size != sizeof(peer) ||
      peer.uid != geteuid() || peer.pid <= 0)
    goto refuse;
  // The peer must be the `snippets` executable installed beside this engine.
  char executable[4096];
  ssize_t count = readlink("/proc/self/exe", executable, sizeof(executable));
  if (count <= 0 || (size_t)count == sizeof(executable)) goto refuse;
  executable[count] = '\0';
  char *slash = strrchr(executable, '/');
  if (slash) *slash = '\0';
  char *expected = g_strconcat(executable, "/snippets", NULL);
  char actual[64];
  snprintf(actual, sizeof(actual), "/proc/%d/exe", (int)peer.pid);
  struct stat a = {0}, b = {0};
  bool same = !stat(expected, &a) && !stat(actual, &b) && S_ISREG(a.st_mode) &&
              a.st_dev == b.st_dev && a.st_ino == b.st_ino;
  g_free(expected);
  if (same) return result;
refuse:
  connection_unref(result);
  return NULL;
}

static bool transfer(int fd, void *buffer, size_t size, bool sending, gint64 deadline) {
  char *p = buffer;
  while (size) {
    gint64 remaining = (deadline - g_get_monotonic_time()) / 1000;
    if (remaining <= 0) return false;
    struct pollfd descriptor = {fd, (short)(sending ? POLLOUT : POLLIN), 0};
    if (poll(&descriptor, 1, (int)remaining) <= 0) return false;
    ssize_t count = sending ? send(fd, p, size, MSG_DONTWAIT | MSG_NOSIGNAL)
                            : recv(fd, p, size, MSG_DONTWAIT);
    if (count <= 0) return false;
    p += count;
    size -= (size_t)count;
  }
  return true;
}

typedef struct {
  Connection *connection;
  guint64 generation;
  unsigned char kind, reply_kind;
  GString *payload, *query, *reply;
  GDBusConnection *session;
  bool revoked;
} Request;

static void request_free(gpointer data) {
  Request *r = data;
  if (r->session) g_object_unref(r->session);
  connection_unref(r->connection);
  erase_free(r->payload);
  erase_free(r->query);
  erase_free(r->reply);
  g_free(r);
}

#define CONSUMED_LIMIT 64

typedef struct {
  guint64 generation;
  bool focused, enabled;
  guint disconnect_watch;
  struct xkb_compose_state *compose;
  Connection *connection;
  bool active, pending, append_only, selected_by_user;
  bool accept;
  char accept_literal;
  int navigation;
  GString *query, *tail;
  GPtrArray *rows;
  size_t selected;
  // Keys whose press this engine consumed, so their releases are consumed too.
  guint consumed[CONSUMED_LIMIT];
  size_t consumed_count;
} State;

typedef struct {
  IBusEngine parent;
  State *state;
} SnippetsEngine;
typedef struct {
  IBusEngineClass parent;
} SnippetsEngineClass;
G_DEFINE_TYPE(SnippetsEngine, snippets_engine, IBUS_TYPE_ENGINE)

static State *state(IBusEngine *e) { return ((SnippetsEngine *)e)->state; }

static SnippetRow *row_at(State *s, size_t index) { return s->rows->pdata[index]; }

static bool consumed_remove(State *s, guint identity) {
  for (size_t i = 0; i < s->consumed_count; ++i)
    if (s->consumed[i] == identity) {
      s->consumed[i] = s->consumed[--s->consumed_count];
      return true;
    }
  return false;
}

static gboolean consume(State *s, guint identity) {
  bool known = false;
  for (size_t i = 0; i < s->consumed_count; ++i) known = known || s->consumed[i] == identity;
  if (!known && s->consumed_count < CONSUMED_LIMIT) s->consumed[s->consumed_count++] = identity;
  return TRUE;
}

static bool public_field(IBusEngine *e) {
  guint purpose = 0, hints = 0;
  ibus_engine_get_content_type(e, &purpose, &hints);
  // libibus exposes legacy has_focus/enabled fields but does not maintain them.
  // Own the lifecycle through its documented callbacks instead.
  const guint public_hints =
      IBUS_INPUT_HINT_SPELLCHECK | IBUS_INPUT_HINT_NO_SPELLCHECK | IBUS_INPUT_HINT_WORD_COMPLETION |
      IBUS_INPUT_HINT_LOWERCASE | IBUS_INPUT_HINT_UPPERCASE_CHARS | IBUS_INPUT_HINT_UPPERCASE_WORDS |
      IBUS_INPUT_HINT_UPPERCASE_SENTENCES | IBUS_INPUT_HINT_INHIBIT_OSK |
      IBUS_INPUT_HINT_VERTICAL_WRITING | IBUS_INPUT_HINT_EMOJI | IBUS_INPUT_HINT_NO_EMOJI |
      // Public protocol bits for LATIN and MULTILINE, added after older supported
      // headers. PRIVATE (11), HIDDEN_TEXT (12) and unknown future bits stay denied.
      (1u << 13) | (1u << 14);
  State *s = state(e);
  return s->focused && s->enabled && (e->client_capabilities & IBUS_CAP_PREEDIT_TEXT) &&
         purpose <= IBUS_INPUT_PURPOSE_TERMINAL && purpose != IBUS_INPUT_PURPOSE_PASSWORD &&
         purpose != IBUS_INPUT_PURPOSE_PIN && !(hints & ~public_hints);
}

// `\` + query + tail, the text the user has typed into the composition.
static GString *composition(State *s) {
  GString *text = g_string_sized_new(1 + s->query->len + s->tail->len + 1);
  g_string_append_c(text, '\\');
  g_string_append_len(text, s->query->str, (gssize)s->query->len);
  g_string_append_len(text, s->tail->str, (gssize)s->tail->len);
  return text;
}

static void render(IBusEngine *e) {
  State *s = state(e);
  GString *preedit = s->active ? composition(s) : g_string_new("");
  IBusText *text = ibus_text_new_from_string(preedit->str);
  ibus_engine_update_preedit_text_with_mode(e, text, (guint)g_utf8_strlen(preedit->str, -1),
                                           s->active, IBUS_ENGINE_PREEDIT_CLEAR);
  erase_free(preedit);
  IBusLookupTable *table = ibus_lookup_table_new(8, (guint)s->selected, TRUE, TRUE);
  ibus_lookup_table_set_orientation(table, IBUS_ORIENTATION_VERTICAL);
  for (guint i = 0; i < s->rows->len; ++i) {
    SnippetRow *row = row_at(s, i);
    char *label = g_strconcat(row->name, "\n", row->keyword, NULL);
    ibus_lookup_table_append_candidate(table, ibus_text_new_from_string(label));
    g_free(label);
  }
  ibus_engine_update_lookup_table(e, table, s->active && s->rows->len > 0);
}

static void clear(IBusEngine *e) {
  State *s = state(e);
  ++s->generation;
  if (s->disconnect_watch) g_source_remove(s->disconnect_watch);
  s->disconnect_watch = 0;
  if (s->connection) connection_cancel(s->connection);
  connection_unref(s->connection);
  s->connection = NULL;
  s->active = s->pending = s->accept = s->selected_by_user = false;
  s->accept_literal = 0;
  s->navigation = 0;
  s->selected = 0;
  g_ptr_array_set_size(s->rows, 0);
  erase(s->query);
  erase(s->tail);
  render(e);
}

static void literal(IBusEngine *e) {
  State *s = state(e);
  bool permitted = public_field(e) && s->active;
  GString *text = composition(s);
  clear(e);
  if (permitted) ibus_engine_commit_text(e, ibus_text_new_from_string(text->str));
  erase_free(text);
}

static void request(IBusEngine *e, unsigned char kind, const char *payload, size_t size);

static void select_row(IBusEngine *e) {
  State *s = state(e);
  if (!public_field(e) || !s->active) return;
  if (s->pending) {
    s->accept = true;
    return;
  }
  if (s->selected < s->rows->len) {
    char index = (char)s->selected;
    request(e, 2, &index, 1);
  }
}

static void io(GTask *task, gpointer source G_GNUC_UNUSED, gpointer data,
               GCancellable *cancellable G_GNUC_UNUSED) {
  Request *r = data;
  gint64 deadline = g_get_monotonic_time() + 500 * G_TIME_SPAN_MILLISECOND;
  GString *frame = g_string_sized_new(9 + r->payload->len);
  g_string_append_len(frame, "SNI3", 4);
  g_string_append_c(frame, (char)r->kind);
  for (unsigned i = 0; i < 4; ++i) g_string_append_c(frame, (char)(r->payload->len >> (8 * i)));
  g_string_append_len(frame, r->payload->str, (gssize)r->payload->len);
  bool ok = transfer(r->connection->fd, frame->str, frame->len, true, deadline);
  erase_free(frame);
  unsigned char header[9] = {0};
  if (ok && r->kind != 3) {
    ok = transfer(r->connection->fd, header, sizeof(header), false, deadline);
    size_t length = 0;
    for (unsigned i = 0; i < 4; ++i) length |= (size_t)header[5 + i] << (8 * i);
    ok = ok && memcmp(header, "SNI3", 4) == 0 && (header[4] == 1 || header[4] == 2) &&
         length <= LIMIT;
    if (ok) {
      r->reply_kind = header[4];
      g_string_set_size(r->reply, length);
      ok = transfer(r->connection->fd, r->reply->str, length, false, deadline);
    }
  }
  if (ok && r->kind != 3 && !unlocked(r->session)) {
    r->revoked = true;
    ok = false;
  }
  g_task_return_boolean(task, ok);
}

static bool has_prefix(const GString *text, const GString *prefix) {
  return text->len >= prefix->len && memcmp(text->str, prefix->str, prefix->len) == 0;
}

static void insert_accept_literal(State *s) {
  if (s->accept_literal) g_string_prepend_c(s->tail, s->accept_literal);
}

static void complete(GObject *object, GAsyncResult *result, gpointer data G_GNUC_UNUSED) {
  IBusEngine *e = IBUS_ENGINE(object);
  State *s = state(e);
  Request *r = g_task_get_task_data(G_TASK(result));
  bool ok = g_task_propagate_boolean(G_TASK(result), NULL);
  if (s->generation != r->generation || s->connection != r->connection) return;
  s->pending = false;
  if (r->kind == 3 || r->revoked || !public_field(e)) {
    clear(e);
    return;
  }
  if (!ok) {
    literal(e);
    return;
  }
  if (r->reply_kind == 2) {
    if (!s->append_only || !has_prefix(s->query, r->query) ||
        !valid_utf8(r->reply->str, r->reply->len) || memchr(r->reply->str, '\0', r->reply->len)) {
      literal(e);
      return;
    }
    GString *text = g_string_sized_new(r->reply->len + s->query->len + s->tail->len + 2);
    g_string_append_len(text, r->reply->str, (gssize)r->reply->len);
    g_string_append_len(text, s->query->str + r->query->len, (gssize)(s->query->len - r->query->len));
    if (r->kind == 1 && s->accept) g_string_append_c(text, s->accept_literal);
    g_string_append_len(text, s->tail->str, (gssize)s->tail->len);
    if (text->len > LIMIT || memchr(text->str, '\0', text->len)) {
      erase_free(text);
      literal(e);
      return;
    }
    // Clear visible composition before committing to this same engine context.
    // Keep its authenticated connection alive long enough for the usage ACK.
    s->active = false;
    g_ptr_array_set_size(s->rows, 0);
    erase(s->query);
    erase(s->tail);
    render(e);
    ibus_engine_commit_text(e, ibus_text_new_from_string(text->str));
    erase_free(text);
    request(e, 3, "", 0);
    return;
  }
  if (!g_string_equal(s->query, r->query)) {
    request(e, 1, s->query->str, s->query->len);
    return;
  }
  GPtrArray *rows = g_ptr_array_new_with_free_func(snippet_row_free);
  if (!row_metadata((const unsigned char *)r->reply->str, r->reply->len, rows)) {
    g_ptr_array_unref(rows);
    literal(e);
    return;
  }
  unsigned char previous[16] = {0};
  if (s->selected < s->rows->len) memcpy(previous, row_at(s, s->selected)->identity, 16);
  g_ptr_array_unref(s->rows);
  s->rows = rows;
  s->selected = 0;
  if (s->selected_by_user) {
    bool found = false;
    for (guint i = 0; i < s->rows->len; ++i)
      if (!memcmp(row_at(s, i)->identity, previous, 16)) {
        s->selected = i;
        found = true;
      }
    if (!found) {
      s->selected_by_user = false;
      // A queued acceptance belongs to the row the user actually chose, not
      // whichever row happens to occupy its former index after a query update.
      if (s->accept) {
        insert_accept_literal(s);
        literal(e);
        return;
      }
    }
  }
  if (s->rows->len > 0 && s->navigation) {
    int count = (int)s->rows->len;
    s->selected = (size_t)((((int)s->selected + s->navigation) % count + count) % count);
    s->selected_by_user = true;
  }
  s->navigation = 0;
  render(e);
  if (s->accept) {
    s->accept = false;
    if (s->rows->len > 0) {
      select_row(e);
    } else {
      insert_accept_literal(s);
      literal(e);
    }
  } else if (s->tail->len > 0) {
    literal(e);
  }
}

static void request(IBusEngine *e, unsigned char kind, const char *payload, size_t size) {
  State *s = state(e);
  if (!s->connection || s->pending) return;
  s->pending = true;
  s->append_only = true;
  Request *data = g_new0(Request, 1);
  data->connection = connection_ref(s->connection);
  data->generation = s->generation;
  data->kind = kind;
  data->payload = g_string_new_len(payload, (gssize)size);
  data->query = g_string_new_len(s->query->str, (gssize)s->query->len);
  data->reply = g_string_new("");
  if (session_bus) data->session = g_object_ref(session_bus);
  GTask *task = g_task_new(e, NULL, complete, NULL);
  g_task_set_task_data(task, data, request_free);
  g_task_run_in_thread(task, io);
  g_object_unref(task);
}

static bool modifier(guint key) {
  return (key >= IBUS_KEY_Shift_L && key <= IBUS_KEY_Hyper_R) || key == IBUS_KEY_ISO_Level3_Shift ||
         key == IBUS_KEY_ISO_Level5_Shift || key == IBUS_KEY_ISO_Group_Shift;
}

// Removes the last UTF-8 character of a non-empty string.
static void drop_last_character(GString *text) {
  const char *last = g_utf8_find_prev_char(text->str, text->str + text->len);
  size_t keep = (size_t)(last - text->str);
  wipe(text->str + keep, text->len - keep);
  g_string_truncate(text, keep);
}

static gboolean app_disconnected(gint fd G_GNUC_UNUSED, GIOCondition condition G_GNUC_UNUSED,
                                 gpointer data) {
  IBusEngine *engine = IBUS_ENGINE(data);
  state(engine)->disconnect_watch = 0;
  clear(engine);
  return G_SOURCE_REMOVE;
}

static gboolean key(IBusEngine *e, guint keyval, guint keycode, guint modifiers) {
  State *s = state(e);
  guint identity = keycode ? keycode : keyval;
  IBusEngineClass *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (modifiers & IBUS_RELEASE_MASK) {
    if (consumed_remove(s, identity)) return TRUE;
    return parent->process_key_event ? parent->process_key_event(e, keyval, keycode, modifiers)
                                     : FALSE;
  }
  if (!public_field(e)) {
    if (s->active) clear(e);
    return FALSE;
  }
  if (modifier(keyval)) return FALSE;
  guint chord = modifiers & (IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_SUPER_MASK |
                             IBUS_HYPER_MASK | IBUS_META_MASK);
  if (!s->active) {
    // xkbcommon owns Compose/dead-key state using its public API. In particular,
    // a backslash inside a Compose sequence must never open a snippet query.
    if (!chord && s->compose) {
      xkb_compose_state_feed(s->compose, keyval);
      switch (xkb_compose_state_get_status(s->compose)) {
        case XKB_COMPOSE_COMPOSING:
          return consume(s, identity);
        case XKB_COMPOSE_COMPOSED: {
          int size = xkb_compose_state_get_utf8(s->compose, NULL, 0);
          if (size > 0 && (size_t)size <= LIMIT) {
            char *text = g_malloc0((size_t)size + 1);
            xkb_compose_state_get_utf8(s->compose, text, (size_t)size + 1);
            ibus_engine_commit_text(e, ibus_text_new_from_string(text));
            wipe(text, (size_t)size + 1);
            g_free(text);
          }
          xkb_compose_state_reset(s->compose);
          return consume(s, identity);
        }
        case XKB_COMPOSE_CANCELLED:
          xkb_compose_state_reset(s->compose);
          return consume(s, identity);
        case XKB_COMPOSE_NOTHING:
          break;
      }
    }
    if (keyval != IBUS_KEY_backslash || chord) return FALSE;
    // A completed commit may still be acknowledging usage. It cannot capture a
    // later query or share a stream with it.
    clear(e);
    s->connection = connect_app();
    if (!s->connection) return FALSE;
    s->disconnect_watch = g_unix_fd_add(s->connection->fd, G_IO_HUP | G_IO_ERR | G_IO_NVAL,
                                        app_disconnected, e);
    s->active = true;
    request(e, 1, "", 0);
    render(e);
    return consume(s, identity);
  }
  bool control = chord == IBUS_CONTROL_MASK;
  if ((!chord && (keyval == IBUS_KEY_Down || keyval == IBUS_KEY_Up)) ||
      (control && (keyval == IBUS_KEY_n || keyval == IBUS_KEY_p))) {
    int delta = keyval == IBUS_KEY_Down || keyval == IBUS_KEY_n ? 1 : -1;
    if (s->pending) {
      s->navigation += delta;
    } else if (s->rows->len > 0) {
      int count = (int)s->rows->len;
      s->selected = (size_t)(((int)s->selected + delta + count) % count);
      s->selected_by_user = true;
      render(e);
    }
    return consume(s, identity);
  }
  if (!chord && keyval == IBUS_KEY_Escape) {
    literal(e);
    return consume(s, identity);
  }
  if (!chord && (keyval == IBUS_KEY_Return || keyval == IBUS_KEY_Tab)) {
    s->accept_literal = keyval == IBUS_KEY_Return ? '\n' : '\t';
    if (s->pending || s->rows->len > 0) {
      select_row(e);
    } else {
      g_string_append_c(s->tail, s->accept_literal);
      literal(e);
    }
    return consume(s, identity);
  }
  if (!chord && keyval == IBUS_KEY_BackSpace) {
    s->append_only = false;
    if (s->tail->len > 0) {
      drop_last_character(s->tail);
      render(e);
    } else if (s->query->len == 0) {
      clear(e);
    } else {
      drop_last_character(s->query);
      if (!s->pending) request(e, 1, s->query->str, s->query->len);
      render(e);
    }
    return consume(s, identity);
  }
  gunichar value = ibus_keyval_to_unicode(keyval);
  if (chord || !value || g_unichar_iscntrl(value)) {
    literal(e);
    return FALSE;
  }
  char encoded[8] = {0};
  size_t length = (size_t)g_unichar_to_utf8(value, encoded);
  if (value == '\\' || g_unichar_isspace(value) || s->query->len + length > 480 ||
      g_utf8_strlen(s->query->str, -1) >= 120 || s->tail->len > 0) {
    if (s->tail->len + length > 480) {
      literal(e);
      return FALSE;
    }
    g_string_append_len(s->tail, encoded, (gssize)length);
    if (!s->pending)
      literal(e);
    else
      render(e);
    return consume(s, identity);
  }
  g_string_append_len(s->query, encoded, (gssize)length);
  if (!s->pending) request(e, 1, s->query->str, s->query->len);
  render(e);
  return consume(s, identity);
}

static void reset(IBusEngine *e) {
  clear(e);
  if (state(e)->compose) xkb_compose_state_reset(state(e)->compose);
  IBusEngineClass *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->reset) parent->reset(e);
}

static void focus_out(IBusEngine *e) {
  state(e)->focused = false;
  reset(e);
  IBusEngineClass *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->focus_out) parent->focus_out(e);
}

static void disable(IBusEngine *e) {
  state(e)->enabled = false;
  reset(e);
  IBusEngineClass *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->disable) parent->disable(e);
}

static void focus_in(IBusEngine *e) {
  reset(e);
  state(e)->focused = true;
  IBusEngineClass *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->focus_in) parent->focus_in(e);
}

static void enable(IBusEngine *e) {
  state(e)->enabled = true;
  IBusEngineClass *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->enable) parent->enable(e);
}

static void content_type(IBusEngine *e, guint purpose G_GNUC_UNUSED, guint hints G_GNUC_UNUSED) {
  reset(e);
}

static void clicked(IBusEngine *e, guint index, guint button, guint state_mask G_GNUC_UNUSED) {
  State *s = state(e);
  if (button == 1 && index < s->rows->len && !s->pending) {
    s->selected = index;
    select_row(e);
  }
}

static void destroy(IBusObject *object) {
  IBusEngine *e = IBUS_ENGINE(object);
  g_hash_table_remove(engines, e);
  clear(e);
  IBUS_OBJECT_CLASS(snippets_engine_parent_class)->destroy(object);
}

static void finalize(GObject *object) {
  State *s = ((SnippetsEngine *)object)->state;
  if (s->compose) xkb_compose_state_unref(s->compose);
  if (s->disconnect_watch) g_source_remove(s->disconnect_watch);
  if (s->connection) connection_cancel(s->connection);
  connection_unref(s->connection);
  erase_free(s->query);
  erase_free(s->tail);
  g_ptr_array_unref(s->rows);
  g_free(s);
  G_OBJECT_CLASS(snippets_engine_parent_class)->finalize(object);
}

static void snippets_engine_class_init(SnippetsEngineClass *type) {
  IBusEngineClass *engine = IBUS_ENGINE_CLASS(type);
  engine->process_key_event = key;
  engine->reset = reset;
  engine->focus_out = focus_out;
  engine->focus_in = focus_in;
  engine->enable = enable;
  engine->disable = disable;
  engine->set_content_type = content_type;
  engine->candidate_clicked = clicked;
  IBUS_OBJECT_CLASS(type)->destroy = destroy;
  G_OBJECT_CLASS(type)->finalize = finalize;
}

static void snippets_engine_init(SnippetsEngine *e) {
  State *s = g_new0(State, 1);
  s->append_only = true;
  // Sized for the query and tail bounds, so typing does not leave copies behind.
  s->query = g_string_sized_new(512);
  s->tail = g_string_sized_new(512);
  s->rows = g_ptr_array_new_with_free_func(snippet_row_free);
  e->state = s;
  struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  if (context) {
    struct xkb_compose_table *table = xkb_compose_table_new_from_locale(
        context, setlocale(LC_CTYPE, NULL), XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (table) {
      s->compose = xkb_compose_state_new(table, XKB_COMPOSE_STATE_NO_FLAGS);
      xkb_compose_table_unref(table);
    }
    xkb_context_unref(context);
  }
  g_hash_table_add(engines, e);
}

static void clear_all(void) {
  GHashTableIter iter;
  gpointer engine = NULL;
  g_hash_table_iter_init(&iter, engines);
  while (g_hash_table_iter_next(&iter, &engine, NULL)) clear(IBUS_ENGINE(engine));
}

static void shell_changed(GDBusConnection *connection G_GNUC_UNUSED, const gchar *sender G_GNUC_UNUSED,
                   const gchar *path G_GNUC_UNUSED, const gchar *interface G_GNUC_UNUSED,
                   const gchar *signal G_GNUC_UNUSED, GVariant *parameters G_GNUC_UNUSED,
                   gpointer data G_GNUC_UNUSED) {
  clear_all();
}

static void session_closed(GDBusConnection *connection G_GNUC_UNUSED,
                           gboolean vanished G_GNUC_UNUSED, GError *error G_GNUC_UNUSED,
                           gpointer data G_GNUC_UNUSED) {
  clear_all();
}

static void ibus_disconnected(IBusBus *bus G_GNUC_UNUSED, gpointer data G_GNUC_UNUSED) {
  ibus_quit();
}

int main(int argc, char **argv) {
  bool launched_by_ibus = argc == 2 && strcmp(argv[1], "--ibus") == 0;
  if (argc > 1 && !launched_by_ibus) return 2;
  setlocale(LC_CTYPE, "");
  engines = g_hash_table_new(g_direct_hash, g_direct_equal);
  ibus_init();
  session_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
  if (!session_bus) return 1;
  g_dbus_connection_set_exit_on_close(session_bus, FALSE);
  g_dbus_connection_signal_subscribe(session_bus, "org.gnome.Shell", "org.gnome.ScreenSaver",
                                     "ActiveChanged", "/org/gnome/ScreenSaver", NULL,
                                     G_DBUS_SIGNAL_FLAGS_NONE, shell_changed, NULL, NULL);
  g_dbus_connection_signal_subscribe(session_bus, "org.freedesktop.DBus", "org.freedesktop.DBus",
                                     "NameOwnerChanged", "/org/freedesktop/DBus", "org.gnome.Shell",
                                     G_DBUS_SIGNAL_FLAGS_NONE, shell_changed, NULL, NULL);
  g_signal_connect(session_bus, "closed", G_CALLBACK(session_closed), NULL);
  IBusBus *bus = ibus_bus_new();
  if (!ibus_bus_is_connected(bus)) return 1;
  g_signal_connect(bus, "disconnected", G_CALLBACK(ibus_disconnected), NULL);
  IBusFactory *factory = ibus_factory_new(ibus_bus_get_connection(bus));
  ibus_factory_add_engine(factory, "snippets", snippets_engine_get_type());
  if (launched_by_ibus) {
    if (!ibus_bus_request_name(bus, "org.freedesktop.IBus.Snippets", 0)) return 1;
  } else {
    IBusComponent *component = ibus_component_new("org.freedesktop.IBus.Snippets", "Snippets", "0.1.0",
                                                  "MIT", "Snippets", "", "", "");
    IBusEngineDesc *description = ibus_engine_desc_new("snippets", "Snippets", "Snippets text expansion",
                                                       "en", "MIT", "Snippets", "", "default");
    ibus_component_add_engine(component, description);
    if (!ibus_bus_register_component(bus, component)) return 1;
    g_object_unref(component);
  }
  ibus_main();
  g_object_unref(factory);
  g_object_unref(bus);
  g_object_unref(session_bus);
  return 0;
}
