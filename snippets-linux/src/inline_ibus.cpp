// Public libibus engine API. Rust owns matching, consent and ordinary-library
// access. Only a backslash-started query crosses the authenticated local socket.
#include <ibus.h>
#include <glib-unix.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <clocale>
#include <memory>
#include <poll.h>
#include <set>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr size_t Limit = 256 * 1024;
GDBusConnection *sessionBus = nullptr;
std::set<IBusEngine *> engines;
// This runs on the I/O worker, never on IBus's key-event thread. Address the
// unique Shell owner and recheck ownership after reading its lock state.
bool unlocked(GDBusConnection *bus) {
  if (!bus || g_dbus_connection_is_closed(bus)) return false;
  auto owner = [&]() {
    std::string name;
    auto *reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
        g_variant_new("(s)", "org.gnome.Shell"), G_VARIANT_TYPE("(s)"),
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 150, nullptr, nullptr);
    if (reply) {
      const char *value = nullptr;
      g_variant_get(reply, "(&s)", &value);
      if (value && value[0] == ':' && std::strlen(value) <= 256) name = value;
      g_variant_unref(reply);
    }
    return name;
  };
  std::string expected = owner();
  if (expected.empty()) return false;
  auto *reply = g_dbus_connection_call_sync(bus, expected.c_str(),
      "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver", "GetActive", nullptr,
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 150, nullptr, nullptr);
  gboolean active = TRUE;
  if (reply) { g_variant_get(reply, "(b)", &active); g_variant_unref(reply); }
  return !active && !g_dbus_connection_is_closed(bus) && owner() == expected;
}
void erase(std::string &s) {
  volatile char *p = s.data();
  for (size_t i = 0; i < s.size(); ++i) p[i] = 0;
  s.clear();
}
bool validUtf8(const std::string &s) {
  return g_utf8_validate(s.data(), gssize(s.size()), nullptr);
}
#include "inline_rows.h"
struct Connection {
  int fd;
  explicit Connection(int value) : fd(value) {}
  ~Connection() { close(fd); }
  void cancel() { shutdown(fd, SHUT_RDWR); }
};
std::shared_ptr<Connection> connectApp() {
  const char *runtime = g_getenv("XDG_RUNTIME_DIR");
  struct stat directory{}, socketFile{};
  if (!runtime || lstat(runtime, &directory) || !S_ISDIR(directory.st_mode) ||
      directory.st_uid != geteuid() || (directory.st_mode & 0077)) return {};
  std::string path = std::string(runtime) + "/snippets-ibus.sock";
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (path.size() >= sizeof(address.sun_path) || lstat(path.c_str(), &socketFile) ||
      !S_ISSOCK(socketFile.st_mode) || socketFile.st_uid != geteuid() ||
      (socketFile.st_mode & 0777) != 0600) return {};
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  if (fd < 0) return {};
  auto result = std::make_shared<Connection>(fd);
  if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address))) return {};
  ucred peer{};
  socklen_t size = sizeof(peer);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) || size != sizeof(peer) ||
      peer.uid != geteuid() || peer.pid <= 0) return {};
  std::array<char, 4096> executable{};
  ssize_t length = readlink("/proc/self/exe", executable.data(), executable.size());
  if (length <= 0 || size_t(length) == executable.size()) return {};
  std::string expected(executable.data(), size_t(length));
  expected = expected.substr(0, expected.find_last_of('/')) + "/snippets";
  std::string actual = "/proc/" + std::to_string(peer.pid) + "/exe";
  struct stat a{}, b{};
  if (stat(expected.c_str(), &a) || stat(actual.c_str(), &b) || !S_ISREG(a.st_mode) ||
      a.st_dev != b.st_dev || a.st_ino != b.st_ino) return {};
  return result;
}
bool transfer(int fd, void *buffer, size_t size, bool sending,
              std::chrono::steady_clock::time_point deadline) {
  auto *p = static_cast<char *>(buffer);
  while (size) {
    auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - std::chrono::steady_clock::now()).count();
    if (remaining <= 0) return false;
    pollfd descriptor{fd, short(sending ? POLLOUT : POLLIN), 0};
    if (poll(&descriptor, 1, int(remaining)) <= 0) return false;
    auto count = sending ? send(fd, p, size, MSG_DONTWAIT | MSG_NOSIGNAL)
                         : recv(fd, p, size, MSG_DONTWAIT);
    if (count <= 0) return false;
    p += count;
    size -= size_t(count);
  }
  return true;
}
struct Request {
  std::shared_ptr<Connection> connection;
  uint64_t generation;
  unsigned char kind, replyKind = 0;
  std::string payload, query, reply;
  GDBusConnection *session = nullptr;
  bool revoked = false;
  ~Request() {
    if (session) g_object_unref(session);
    erase(payload); erase(query); erase(reply);
  }
};
struct State {
  uint64_t generation = 0;
  bool focused = false, enabled = false;
  guint disconnectWatch = 0;
  xkb_compose_state *compose = nullptr;
  std::shared_ptr<Connection> connection;
  bool active = false, pending = false, appendOnly = true, selectedByUser = false;
  bool accept = false;
  char acceptLiteral = 0;
  int navigation = 0;
  std::string query, tail;
  std::vector<Row> rows;
  size_t selected = 0;
  std::set<guint> consumed;
  ~State() {
    if (compose) xkb_compose_state_unref(compose);
    if (disconnectWatch) g_source_remove(disconnectWatch);
    if (connection) connection->cancel();
    erase(query); erase(tail);
  }
};
} // namespace

typedef struct { IBusEngine parent; State *state; } SnippetsEngine;
typedef struct { IBusEngineClass parent; } SnippetsEngineClass;
G_DEFINE_TYPE(SnippetsEngine, snippets_engine, IBUS_TYPE_ENGINE)

namespace {
State &state(IBusEngine *e) { return *reinterpret_cast<SnippetsEngine *>(e)->state; }
bool publicField(IBusEngine *e) {
  guint purpose = 0, hints = 0;
  ibus_engine_get_content_type(e, &purpose, &hints);
  // libibus exposes legacy has_focus/enabled fields but does not maintain them.
  // Own the lifecycle through its documented callbacks instead.
  constexpr guint publicHints = IBUS_INPUT_HINT_SPELLCHECK | IBUS_INPUT_HINT_NO_SPELLCHECK |
      IBUS_INPUT_HINT_WORD_COMPLETION | IBUS_INPUT_HINT_LOWERCASE |
      IBUS_INPUT_HINT_UPPERCASE_CHARS | IBUS_INPUT_HINT_UPPERCASE_WORDS |
      IBUS_INPUT_HINT_UPPERCASE_SENTENCES | IBUS_INPUT_HINT_INHIBIT_OSK |
      IBUS_INPUT_HINT_VERTICAL_WRITING | IBUS_INPUT_HINT_EMOJI | IBUS_INPUT_HINT_NO_EMOJI |
      // Public protocol bits for LATIN and MULTILINE, added after older supported
      // headers. PRIVATE (11), HIDDEN_TEXT (12) and unknown future bits stay denied.
      (1u << 13) | (1u << 14);
  return state(e).focused && state(e).enabled && (e->client_capabilities & IBUS_CAP_PREEDIT_TEXT) &&
         purpose <= IBUS_INPUT_PURPOSE_TERMINAL &&
         purpose != IBUS_INPUT_PURPOSE_PASSWORD && purpose != IBUS_INPUT_PURPOSE_PIN &&
         !(hints & ~publicHints);
}
void render(IBusEngine *e) {
  auto &s = state(e);
  std::string preedit = s.active ? "\\" + s.query + s.tail : "";
  auto *text = ibus_text_new_from_string(preedit.c_str());
  ibus_engine_update_preedit_text_with_mode(e, text, guint(g_utf8_strlen(preedit.c_str(), -1)),
                                           s.active, IBUS_ENGINE_PREEDIT_CLEAR);
  erase(preedit);
  auto *table = ibus_lookup_table_new(8, guint(s.selected), TRUE, TRUE);
  ibus_lookup_table_set_orientation(table, IBUS_ORIENTATION_VERTICAL);
  for (const auto &row : s.rows) {
    auto label = row.name + "\n" + row.keyword;
    ibus_lookup_table_append_candidate(table, ibus_text_new_from_string(label.c_str()));
  }
  ibus_engine_update_lookup_table(e, table, s.active && !s.rows.empty());
}
void clear(IBusEngine *e) {
  auto &s = state(e);
  ++s.generation;
  if (s.disconnectWatch) g_source_remove(s.disconnectWatch);
  s.disconnectWatch = 0;
  if (s.connection) s.connection->cancel();
  s.connection.reset();
  s.active = s.pending = s.accept = s.selectedByUser = false;
  s.acceptLiteral = 0;
  s.navigation = 0;
  s.selected = 0;
  s.rows.clear();
  erase(s.query);
  erase(s.tail);
  render(e);
}
void literal(IBusEngine *e) {
  auto &s = state(e);
  bool permitted = publicField(e) && s.active;
  std::string text = "\\" + s.query + s.tail;
  clear(e);
  if (permitted) ibus_engine_commit_text(e, ibus_text_new_from_string(text.c_str()));
  erase(text);
}
void request(IBusEngine *e, unsigned char kind, std::string payload);
void select(IBusEngine *e) {
  auto &s = state(e);
  if (!publicField(e) || !s.active) return;
  if (s.pending) { s.accept = true; return; }
  if (s.selected < s.rows.size()) request(e, 2, std::string(1, char(s.selected)));
}
void io(GTask *task, gpointer, gpointer data, GCancellable *) {
  auto &r = *static_cast<Request *>(data);
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  std::string frame = "SNI3";
  frame += char(r.kind);
  for (unsigned i = 0; i < 4; ++i) frame += char(r.payload.size() >> (8 * i));
  frame += r.payload;
  bool ok = transfer(r.connection->fd, frame.data(), frame.size(), true, deadline);
  erase(frame);
  std::array<unsigned char, 9> header{};
  if (ok && r.kind != 3) {
    ok = transfer(r.connection->fd, header.data(), header.size(), false, deadline);
    size_t length = 0;
    for (unsigned i = 0; i < 4; ++i) length |= size_t(header[5 + i]) << (8 * i);
    ok = ok && std::memcmp(header.data(), "SNI3", 4) == 0 &&
         (header[4] == 1 || header[4] == 2) && length <= Limit;
    if (ok) {
      r.replyKind = header[4];
      r.reply.resize(length);
      ok = transfer(r.connection->fd, r.reply.data(), length, false, deadline);
    }
  }
  if (ok && r.kind != 3 && !unlocked(r.session)) { r.revoked = true; ok = false; }
  g_task_return_boolean(task, ok);
}
void complete(GObject *object, GAsyncResult *result, gpointer) {
  auto *e = IBUS_ENGINE(object);
  auto &s = state(e);
  auto &r = *static_cast<Request *>(g_task_get_task_data(G_TASK(result)));
  bool ok = g_task_propagate_boolean(G_TASK(result), nullptr);
  if (s.generation != r.generation || s.connection != r.connection) return;
  s.pending = false;
  if (r.kind == 3) { clear(e); return; }
  if (r.revoked) { clear(e); return; }
  if (!publicField(e)) { clear(e); return; }
  if (!ok) { literal(e); return; }
  if (r.replyKind == 2) {
    if (!s.appendOnly || !s.query.starts_with(r.query) || !validUtf8(r.reply) ||
        r.reply.find('\0') != std::string::npos) { literal(e); return; }
    std::string text = r.reply + s.query.substr(r.query.size());
    if (r.kind == 1 && s.accept) text += s.acceptLiteral;
    text += s.tail;
    if (text.size() > Limit || text.find('\0') != std::string::npos) { erase(text); literal(e); return; }
    // Clear visible composition before committing to this same engine context.
    // Keep its authenticated connection alive long enough for the usage ACK.
    s.active = false;
    s.rows.clear();
    erase(s.query);
    erase(s.tail);
    render(e);
    ibus_engine_commit_text(e, ibus_text_new_from_string(text.c_str()));
    erase(text);
    request(e, 3, "");
    return;
  }
  if (s.query != r.query) { request(e, 1, s.query); return; }
  std::vector<Row> rows;
  PanelPalette palette;
  if (!rowMetadata(r.reply, rows, palette)) { literal(e); return; }
  auto previous = s.selected < s.rows.size() ? s.rows[s.selected].identity : std::array<unsigned char, 16>{};
  s.rows = std::move(rows);
  s.selected = 0;
  if (s.selectedByUser) {
    bool found = false;
    for (size_t i = 0; i < s.rows.size(); ++i)
      if (s.rows[i].identity == previous) { s.selected = i; found = true; }
    if (!found) {
      s.selectedByUser = false;
      // A queued acceptance belongs to the row the user actually chose, not
      // whichever row happens to occupy its former index after a query update.
      if (s.accept) {
        if (s.acceptLiteral) s.tail.insert(s.tail.begin(), s.acceptLiteral);
        literal(e);
        return;
      }
    }
  }
  if (!s.rows.empty() && s.navigation) {
    int count = int(s.rows.size());
    s.selected = size_t(((int(s.selected) + s.navigation) % count + count) % count);
    s.selectedByUser = true;
  }
  s.navigation = 0;
  render(e);
  if (s.accept) {
    s.accept = false;
    if (!s.rows.empty()) select(e);
    else { if (s.acceptLiteral) s.tail.insert(s.tail.begin(), s.acceptLiteral); literal(e); }
  } else if (!s.tail.empty()) literal(e);
}
void request(IBusEngine *e, unsigned char kind, std::string payload) {
  auto &s = state(e);
  if (!s.connection || s.pending) return;
  s.pending = true;
  s.appendOnly = true;
  auto *data = new Request{s.connection, s.generation, kind, 0, std::move(payload), s.query, {}};
  if (sessionBus) data->session = G_DBUS_CONNECTION(g_object_ref(sessionBus));
  GTask *task = g_task_new(e, nullptr, complete, nullptr);
  g_task_set_task_data(task, data, [](gpointer p) { delete static_cast<Request *>(p); });
  g_task_run_in_thread(task, io);
  g_object_unref(task);
}
bool modifier(guint key) {
  return (key >= IBUS_KEY_Shift_L && key <= IBUS_KEY_Hyper_R) ||
         key == IBUS_KEY_ISO_Level3_Shift || key == IBUS_KEY_ISO_Level5_Shift ||
         key == IBUS_KEY_ISO_Group_Shift;
}
gboolean key(IBusEngine *e, guint keyval, guint keycode, guint modifiers) {
  auto &s = state(e);
  guint identity = keycode ? keycode : keyval;
  auto *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (modifiers & IBUS_RELEASE_MASK) {
    if (s.consumed.erase(identity)) return TRUE;
    return parent->process_key_event ? parent->process_key_event(e, keyval, keycode, modifiers) : FALSE;
  }
  auto consume = [&] { if (s.consumed.size() < 64) s.consumed.insert(identity); return TRUE; };
  if (!publicField(e)) { if (s.active) clear(e); return FALSE; }
  if (modifier(keyval)) return FALSE;
  guint chord = modifiers & (IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_SUPER_MASK |
                             IBUS_HYPER_MASK | IBUS_META_MASK);
  if (!s.active) {
    // xkbcommon owns Compose/dead-key state using its public API. In particular,
    // a backslash inside a Compose sequence must never open a snippet query.
    if (!chord && s.compose) {
      xkb_compose_state_feed(s.compose, keyval);
      switch (xkb_compose_state_get_status(s.compose)) {
        case XKB_COMPOSE_COMPOSING: return consume();
        case XKB_COMPOSE_COMPOSED: {
          int size = xkb_compose_state_get_utf8(s.compose, nullptr, 0);
          if (size > 0 && size <= int(Limit)) {
            std::string text(size_t(size) + 1, '\0');
            xkb_compose_state_get_utf8(s.compose, text.data(), text.size());
            ibus_engine_commit_text(e, ibus_text_new_from_string(text.c_str()));
            erase(text);
          }
          xkb_compose_state_reset(s.compose);
          return consume();
        }
        case XKB_COMPOSE_CANCELLED:
          xkb_compose_state_reset(s.compose);
          return consume();
        case XKB_COMPOSE_NOTHING: break;
      }
    }
    if (keyval != IBUS_KEY_backslash || chord) return FALSE;
    // A completed commit may still be acknowledging usage. It cannot capture a
    // later query or share a stream with it.
    clear(e);
    s.connection = connectApp();
    if (!s.connection) return FALSE;
    s.disconnectWatch = g_unix_fd_add(s.connection->fd,
        GIOCondition(G_IO_HUP | G_IO_ERR | G_IO_NVAL),
        +[](gint, GIOCondition, gpointer data) -> gboolean {
          auto *engine = IBUS_ENGINE(data);
          state(engine).disconnectWatch = 0;
          clear(engine);
          return G_SOURCE_REMOVE;
        }, e);
    s.active = true;
    request(e, 1, "");
    render(e);
    return consume();
  }
  bool control = chord == IBUS_CONTROL_MASK;
  if ((!chord && (keyval == IBUS_KEY_Down || keyval == IBUS_KEY_Up)) ||
      (control && (keyval == IBUS_KEY_n || keyval == IBUS_KEY_p))) {
    int delta = keyval == IBUS_KEY_Down || keyval == IBUS_KEY_n ? 1 : -1;
    if (s.pending) s.navigation += delta;
    else if (!s.rows.empty()) {
      s.selected = size_t((int(s.selected) + delta + int(s.rows.size())) % int(s.rows.size()));
      s.selectedByUser = true;
      render(e);
    }
    return consume();
  }
  if (!chord && keyval == IBUS_KEY_Escape) { literal(e); return consume(); }
  if (!chord && (keyval == IBUS_KEY_Return || keyval == IBUS_KEY_Tab)) {
    s.acceptLiteral = keyval == IBUS_KEY_Return ? '\n' : '\t';
    if (s.pending || !s.rows.empty()) select(e);
    else { s.tail += s.acceptLiteral; literal(e); }
    return consume();
  }
  if (!chord && keyval == IBUS_KEY_BackSpace) {
    s.appendOnly = false;
    if (!s.tail.empty()) {
      size_t last = size_t(g_utf8_find_prev_char(s.tail.data(), s.tail.data() + s.tail.size()) - s.tail.data());
      s.tail.resize(last);
      render(e);
    } else if (s.query.empty()) clear(e);
    else {
      size_t last = size_t(g_utf8_find_prev_char(s.query.data(), s.query.data() + s.query.size()) - s.query.data());
      s.query.resize(last);
      if (!s.pending) request(e, 1, s.query);
      render(e);
    }
    return consume();
  }
  gunichar value = ibus_keyval_to_unicode(keyval);
  if (chord || !value || g_unichar_iscntrl(value)) { literal(e); return FALSE; }
  char encoded[8]{};
  int length = g_unichar_to_utf8(value, encoded);
  if (value == '\\' || g_unichar_isspace(value) || s.query.size() + size_t(length) > 480 ||
      g_utf8_strlen(s.query.c_str(), -1) >= 120 || !s.tail.empty()) {
    if (s.tail.size() + size_t(length) > 480) { literal(e); return FALSE; }
    s.tail.append(encoded, size_t(length));
    if (!s.pending) literal(e);
    else render(e);
    return consume();
  }
  s.query.append(encoded, size_t(length));
  if (!s.pending) request(e, 1, s.query);
  render(e);
  return consume();
}
void reset(IBusEngine *e) {
  clear(e);
  if (state(e).compose) xkb_compose_state_reset(state(e).compose);
  auto *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->reset) parent->reset(e);
}
void focusOut(IBusEngine *e) {
  state(e).focused = false;
  reset(e);
  auto *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->focus_out) parent->focus_out(e);
}
void disable(IBusEngine *e) {
  state(e).enabled = false;
  reset(e);
  auto *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->disable) parent->disable(e);
}
void focusIn(IBusEngine *e) {
  reset(e);
  state(e).focused = true;
  auto *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->focus_in) parent->focus_in(e);
}
void enable(IBusEngine *e) {
  state(e).enabled = true;
  auto *parent = IBUS_ENGINE_CLASS(snippets_engine_parent_class);
  if (parent->enable) parent->enable(e);
}
void contentType(IBusEngine *e, guint, guint) { reset(e); }
void clicked(IBusEngine *e, guint index, guint button, guint) {
  auto &s = state(e);
  if (button == 1 && index < s.rows.size() && !s.pending) { s.selected = index; select(e); }
}
void destroy(IBusObject *object) {
  auto *e = IBUS_ENGINE(object);
  engines.erase(e);
  clear(e);
  IBUS_OBJECT_CLASS(snippets_engine_parent_class)->destroy(object);
}
void finalize(GObject *object) {
  delete reinterpret_cast<SnippetsEngine *>(object)->state;
  G_OBJECT_CLASS(snippets_engine_parent_class)->finalize(object);
}
} // namespace

static void snippets_engine_class_init(SnippetsEngineClass *type) {
  auto *engine = IBUS_ENGINE_CLASS(type);
  engine->process_key_event = key;
  engine->reset = reset;
  engine->focus_out = focusOut;
  engine->focus_in = focusIn;
  engine->enable = enable;
  engine->disable = disable;
  engine->set_content_type = contentType;
  engine->candidate_clicked = clicked;
  IBUS_OBJECT_CLASS(type)->destroy = destroy;
  G_OBJECT_CLASS(type)->finalize = finalize;
}
static void snippets_engine_init(SnippetsEngine *e) {
  e->state = new State;
  auto *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  if (context) {
    auto *table = xkb_compose_table_new_from_locale(context, std::setlocale(LC_CTYPE, nullptr),
                                                   XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (table) {
      e->state->compose = xkb_compose_state_new(table, XKB_COMPOSE_STATE_NO_FLAGS);
      xkb_compose_table_unref(table);
    }
    xkb_context_unref(context);
  }
  engines.insert(IBUS_ENGINE(e));
}

int main(int argc, char **argv) {
  bool launchedByIBus = argc == 2 && std::strcmp(argv[1], "--ibus") == 0;
  if (argc > 1 && !launchedByIBus) return 2;
  std::setlocale(LC_CTYPE, "");
  ibus_init();
  sessionBus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (!sessionBus) return 1;
  g_dbus_connection_set_exit_on_close(sessionBus, FALSE);
  auto revoke = +[](GDBusConnection *, const gchar *, const gchar *, const gchar *,
                    const gchar *, GVariant *, gpointer) {
    for (auto *engine : engines) clear(engine);
  };
  g_dbus_connection_signal_subscribe(sessionBus, "org.gnome.Shell", "org.gnome.ScreenSaver",
      "ActiveChanged", "/org/gnome/ScreenSaver", nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      revoke, nullptr, nullptr);
  g_dbus_connection_signal_subscribe(sessionBus, "org.freedesktop.DBus", "org.freedesktop.DBus",
      "NameOwnerChanged", "/org/freedesktop/DBus", "org.gnome.Shell", G_DBUS_SIGNAL_FLAGS_NONE,
      revoke, nullptr, nullptr);
  g_signal_connect(sessionBus, "closed", G_CALLBACK(+[](GDBusConnection *, gboolean, GError *, gpointer) {
    for (auto *engine : engines) clear(engine);
  }), nullptr);
  IBusBus *bus = ibus_bus_new();
  if (!ibus_bus_is_connected(bus)) return 1;
  g_signal_connect(bus, "disconnected", G_CALLBACK(+[](IBusBus *, gpointer) { ibus_quit(); }), nullptr);
  auto *factory = ibus_factory_new(ibus_bus_get_connection(bus));
  ibus_factory_add_engine(factory, "snippets", snippets_engine_get_type());
  if (launchedByIBus) {
    if (!ibus_bus_request_name(bus, "org.freedesktop.IBus.Snippets", 0)) return 1;
  } else {
    auto *component = ibus_component_new("org.freedesktop.IBus.Snippets", "Snippets", "0.1.0",
                                         "MIT", "Snippets", "", "", "");
    auto *description = ibus_engine_desc_new("snippets", "Snippets", "Snippets text expansion",
                                            "en", "MIT", "Snippets", "", "default");
    ibus_component_add_engine(component, description);
    if (!ibus_bus_register_component(bus, component)) return 1;
    g_object_unref(component);
  }
  ibus_main();
  g_object_unref(factory);
  g_object_unref(bus);
  g_object_unref(sessionBus);
  return 0;
}
