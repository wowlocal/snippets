// Exercise the production addon handler with real Fcitx key/context objects.
// No graphical display, bus, user library or IPC peer is used.
#define SNIPPETS_FCITX_TESTING
#include "../../src/inline_fcitx.cpp"
#include <cassert>
#include <cstdio>

namespace {
class PublicContext : public InputContext {
public:
  explicit PublicContext(InputContextManager &manager)
      : InputContext(manager) {}
  ~PublicContext() override { destroy(); }
  const char *frontend() const override { return "public-snippets-fixture"; }
  size_t commits = 0;
  std::string lastCommit;

protected:
  void commitStringImpl(const std::string &text) override {
    ++commits;
    lastCommit = text;
  }
  void deleteSurroundingTextImpl(int, unsigned) override {}
  void forwardKeyImpl(const ForwardKeyEvent &) override {}
  void updatePreeditImpl() override {}
};
struct CoreFixture {
  static void asyncFraming() {
    EventLoop loop;
    AsyncChannel channel(loop);
    int sockets[2];
    assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets));
    bool completed = false, responsive = false;
    auto pulse = loop.addTimeEvent(CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 1000,
                                   1, [&](EventSourceTime *source, uint64_t) {
                                     source->setEnabled(false);
                                     responsive = true;
                                     return true;
                                   });
    pulse->setOneShot();
    auto first = loop.addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 5000, 1,
        [&](EventSourceTime *source, uint64_t) {
          source->setEnabled(false);
          assert(send(sockets[1], "SNI", 3, MSG_NOSIGNAL) == 3);
          return true;
        });
    first->setOneShot();
    auto rest = loop.addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 10000, 1,
        [&](EventSourceTime *source, uint64_t) {
          source->setEnabled(false);
          const unsigned char bytes[]{'3', 1, 3, 0, 0, 0, 'a', 'b', 'c'};
          assert(send(sockets[1], bytes, sizeof(bytes), MSG_NOSIGNAL) ==
                 ssize_t(sizeof(bytes)));
          return true;
        });
    rest->setOneShot();
    assert(channel.start(
        sockets[0], 1, "",
        [&](bool success, unsigned char kind, std::string &reply) {
          assert(success && kind == 1 && reply == "abc" && responsive);
          completed = true;
          loop.exit();
        }));
    assert(loop.exec() && completed && !channel.pending());
    close(sockets[0]);
    close(sockets[1]);
  }
  static void asyncTimeout() {
    EventLoop loop;
    AsyncChannel channel(loop);
    int sockets[2];
    assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets));
    bool completed = false;
    assert(channel.start(
        sockets[0], 1, "",
        [&](bool success, unsigned char, std::string &reply) {
          assert(!success && reply.empty());
          completed = true;
          loop.exit();
        },
        true, 10000));
    assert(loop.exec() && completed && !channel.pending());
    close(sockets[0]);
    close(sockets[1]);
  }
  static void asyncCancellation() {
    EventLoop loop;
    AsyncChannel channel(loop);
    int old[2], fresh[2];
    assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, old));
    assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, fresh));
    bool stale = false, completed = false;
    assert(
        channel.start(old[0], 1, "", [&](bool, unsigned char, std::string &) {
          stale = true;
        }));
    channel.cancel();
    const unsigned char invalid[]{'S', 'N', 'I', '3', 1, 1, 0, 4, 0};
    assert(send(fresh[1], invalid, sizeof(invalid), MSG_NOSIGNAL) ==
           ssize_t(sizeof(invalid)));
    assert(channel.start(fresh[0], 1, "",
                         [&](bool success, unsigned char, std::string &) {
                           assert(!success && !stale);
                           completed = true;
                           loop.exit();
                         }));
    assert(loop.exec() && completed && !stale);
    close(old[0]);
    close(old[1]);
    close(fresh[0]);
    close(fresh[1]);
  }
  static void delayedBody(bool cancel) {
    char name[] = "public-fcitx-async-context";
    char disabled[] = "--disable=all";
    char *arguments[]{name, disabled, nullptr};
    Instance instance(2, arguments);
    instance.initialize();
    PublicContext context(instance.inputContextManager());
    context.focusIn();
    Snippets addon(&instance);
    int sockets[2];
    assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets));
    addon.active_ = &context;
    addon.fd_ = sockets[0];
    addon.query_ = "n";
    assert(addon.update(&context, 1, "n"));
    assert(context.commits == 0 && addon.channel_.pending());
    auto edit = instance.eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 1000, 1,
        [&](EventSourceTime *source, uint64_t) {
          source->setEnabled(false);
          assert(addon.channel_.pending());
          if (cancel) {
            context.setCapabilityFlags(CapabilityFlag::Sensitive);
            assert(!addon.active_ && !addon.channel_.pending());
          } else {
            KeyEvent space(&context, Key(FcitxKey_space, KeyStates(), 65),
                           false);
            addon.key(space);
            assert(space.filtered() && addon.terminalTail_ == " ");
          }
          return true;
        });
    edit->setOneShot();
    auto reply = instance.eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 10000, 1,
        [&](EventSourceTime *source, uint64_t) {
          source->setEnabled(false);
          const unsigned char frame[]{'S', 'N', 'I', '3', 2,   6,   0,  0,
                                      0,   'P', 'U', 'B', 'L', 'I', 'C'};
          auto n = send(sockets[1], frame, sizeof(frame), MSG_NOSIGNAL);
          if (cancel) {
            assert(n < 0 && errno == EPIPE && context.commits == 0);
            instance.eventLoop().exit();
          } else
            assert(n == ssize_t(sizeof(frame)));
          return true;
        });
    reply->setOneShot();
    auto done = instance.eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 30000, 1,
        [&](EventSourceTime *source, uint64_t) {
          source->setEnabled(false);
          assert(!cancel && context.commits == 1 &&
                 context.lastCommit == "PUBLIC ");
          instance.eventLoop().exit();
          return true;
        });
    done->setOneShot();
    assert(instance.eventLoop().exec());
    close(sockets[1]);
  }
  static void inputMethodSwitch(Instance &instance,
                                InputMethodSwitchedReason reason,
                                const char *query, bool preserve) {
    PublicContext context(instance.inputContextManager());
    context.focusIn();
    Snippets addon(&instance);
    addon.active_ = &context;
    addon.query_ = query;
    addon.render(&context);
    InputContextSwitchInputMethodEvent event(reason, "", &context);
    instance.postEvent(event);
    assert(context.hasFocus());
    assert(!addon.active_ && addon.query_.empty() && addon.rows_.empty());
    assert(context.inputPanel().clientPreedit().empty());
    assert(context.commits == (preserve ? 1u : 0u));
    if (preserve)
      assert(context.lastCommit == std::string("\\") + query);
    instance.postEvent(event);
    assert(context.commits == (preserve ? 1u : 0u));
  }
  static Row row(unsigned char identity, const char *name,
                 const char *keyword) {
    Row result{name, keyword};
    result.identity.back() = identity;
    return result;
  }
  static std::string metadata(const std::vector<Row> &rows) {
    std::string reply(1, char(rows.size()));
    PanelPalette palette;
    reply += char(palette.dark);
    for (const auto *color :
         {&palette.background, &palette.foreground, &palette.accent})
      reply.append(reinterpret_cast<const char *>(color->data()),
                   color->size());
    auto shortValue = [&](uint16_t value) {
      reply += char(value);
      reply += char(value >> 8);
    };
    for (const auto &row : rows) {
      reply.append(reinterpret_cast<const char *>(row.identity.data()),
                   row.identity.size());
      for (auto field : {std::pair{&row.name, &row.nameMatches},
                         std::pair{&row.keyword, &row.keywordMatches}}) {
        shortValue(uint16_t(field.first->size()));
        reply += *field.first;
        reply += char(field.second->size());
        for (auto [start, end] : *field.second) {
          shortValue(start);
          shortValue(end);
        }
      }
      reply += char(row.tags.size());
      shortValue(row.tagCount);
      for (const auto &tag : row.tags) {
        reply += char(tag.size());
        reply += tag;
      }
    }
    return reply;
  }
  static void presentation() {
    Row publicRow = row(1, "Public Unicode café", "public");
    publicRow.nameMatches = {{15, 20}};
    publicRow.keywordMatches = {{0, 3}};
    publicRow.tags = {"Tag one", "Tag two"};
    publicRow.tagCount = 3;
    auto encoded = metadata({publicRow});
    std::vector<Row> decoded;
    PanelPalette palette;
    assert(rowMetadata(encoded, decoded, palette) && decoded.size() == 1);
    assert(decoded[0] == publicRow);
    auto ordinary = MacPopupManager::raster(decoded, 0, palette, 1);
    auto retina = MacPopupManager::raster(decoded, 0, palette, 2);
    assert(ordinary && retina);
    assert(ordinary->width == 336 && ordinary->height == 70);
    assert(retina->width == ordinary->width &&
           retina->height == ordinary->height);
    assert(cairo_image_surface_get_width(retina->image) == 672);
    assert(cairo_image_surface_get_height(retina->image) == 140);
    assert(MacPopupManager::hit(retina->hits, 22, 20) == 0);
    assert(MacPopupManager::hit(retina->hits, 4, 20) == -1);
    assert(MacPopupManager::hit(retina->hits, 22, 67) == -1);
    decoded[0].name = std::string(80, 'W');
    decoded[0].nameMatches.clear();
    auto wrapped = MacPopupManager::raster(decoded, 0, palette, 2);
    assert(wrapped && wrapped->hits[0].height == 62 && wrapped->height == 86);
    assert(!MacPopupManager::raster(decoded, 0, palette, 5));
    assert(MacPopupManager::supportsRuntime("5.1.22"));
    assert(MacPopupManager::supportsRuntime("5.1.23"));
    assert(!MacPopupManager::supportsRuntime(nullptr));
    assert(!MacPopupManager::supportsRuntime("5.1.24"));
    assert(!MacPopupManager::supportsRuntime("5.2.0"));
    publicRow.nameMatches = {
        {19, 20}}; // Starts inside the final UTF-8 character.
    encoded = metadata({publicRow});
    decoded.clear();
    assert(!rowMetadata(encoded, decoded, palette));
  }
  static void mousePlacement() {
    auto *pointer = json_tokener_parse(R"({"x":-10,"y":900})");
    auto *monitors = json_tokener_parse(
        R"([{"name":"PUBLIC-1","x":-1920,"y":0,"width":3840,"height":2160,"scale":2,"transform":0,"reserved":[10,30,20,40]}])");
    auto anchor = MouseAnchor::decode(pointer, monitors);
    assert(anchor && anchor->x == 1910 && anchor->y == 900);
    auto origin = anchor->origin(336, 200);
    assert(origin && origin->first == 1564 && origin->second == 696);
    assert(!anchor->origin(2000, 200));
    // Filtering changes the panel height, never the captured mouse position.
    origin = anchor->origin(336, 70);
    assert(origin && origin->first == 1564 && origin->second == 904);
    json_object_put(pointer);
    json_object_put(monitors);
    pointer = json_tokener_parse(R"({"x":300,"y":100})");
    monitors = json_tokener_parse(
        R"([{"name":"PUBLIC-2","x":0,"y":0,"width":1920,"height":1080,"scale":1.5,"transform":1,"reserved":[0,0,0,0]}])");
    anchor = MouseAnchor::decode(pointer, monitors);
    assert(anchor && anchor->right == 720 && anchor->bottom == 1280);
    json_object_object_add(pointer, "x", json_object_new_string("invalid"));
    assert(!MouseAnchor::decode(pointer, monitors));
    json_object_put(pointer);
    json_object_put(monitors);
  }
  static void selection(Instance &instance) {
    PublicContext context(instance.inputContextManager());
    context.focusIn();
    Snippets addon(&instance);
    addon.active_ = &context;
    addon.query_ = "na";
    addon.rows_ = {row(1, "First public", "native1"),
                   row(2, "Second public", "native2"),
                   row(3, "Chosen public", "native3")};
    addon.render(&context);
    for (unsigned i = 0; i < 2; ++i) {
      KeyEvent down(&context, Key(FcitxKey_Down, KeyStates(), 108), false);
      addon.key(down);
      assert(down.filtered());
    }
    assert(addon.selected_ == 2 && addon.selectionWasUserDriven_);
    auto reply = metadata({row(1, "First public", "native1"),
                           row(3, "Edited chosen", "native-edited")});
    assert(addon.apply(&context, 1, reply));
    assert(addon.selected_ == 1 && addon.selectionWasUserDriven_);
    assert(addon.rows_[1].identity.back() == 3);
    assert(addon.query_ == "na" && context.commits == 0);

    reply = metadata({row(2, "Remaining public", "native2")});
    assert(addon.apply(&context, 1, reply));
    assert(addon.selected_ == 0 && !addon.selectionWasUserDriven_);
    reply = metadata({row(1, "New top public", "native1"),
                      row(2, "Remaining public", "native2")});
    assert(addon.apply(&context, 1, reply));
    assert(addon.selected_ == 0 && !addon.selectionWasUserDriven_);
    KeyEvent down(&context, Key(FcitxKey_Down, KeyStates(), 108), false);
    addon.key(down);
    assert(addon.selectionWasUserDriven_);
    context.setCapabilityFlags(CapabilityFlag::Sensitive);
    assert(!addon.active_ && !addon.selectionWasUserDriven_);
    assert(context.commits == 0);
  }
  static void invalidMetadata(Instance &instance, bool duplicate) {
    PublicContext context(instance.inputContextManager());
    context.focusIn();
    Snippets addon(&instance);
    addon.active_ = &context;
    addon.query_ = "public";
    addon.rows_ = {row(1, "Original public", "public1")};
    addon.selectionWasUserDriven_ = true;
    addon.render(&context);
    auto reply = metadata({row(2, "First public", "public2"),
                           row(2, "Duplicate public", "public3")});
    if (!duplicate)
      reply.resize(8);
    assert(!addon.apply(&context, 1, reply));
    assert(!addon.active_ && addon.rows_.empty());
    assert(!addon.selectionWasUserDriven_ && context.commits == 1);
  }
  static void capability(Instance &instance, CapabilityFlags flags,
                         bool retained) {
    PublicContext context(instance.inputContextManager());
    context.focusIn();
    Snippets addon(&instance);
    addon.active_ = &context;
    addon.query_ = "public";
    addon.rows_ = {{"First public", "public1"}, {"Second public", "public2"}};
    addon.selected_ = 1;
    addon.render(&context);
    // Deliver the real Fcitx capability event, rather than calling our watcher.
    context.setCapabilityFlags(flags);
    assert(context.hasFocus());
    assert(context.commits == 0);
    if (retained) {
      assert(publicField(&context));
      assert(addon.active_ == &context && addon.query_ == "public");
      assert(addon.rows_.size() == 2 && addon.selected_ == 1);
      assert(context.inputPanel().candidateList());
      assert(context.inputPanel().clientPreedit().toString() == "\\public");
    } else {
      assert(!publicField(&context));
      assert(!addon.active_ && addon.query_.empty() && addon.rows_.empty());
      assert(!context.inputPanel().candidateList());
      assert(context.inputPanel().clientPreedit().empty());
    }
  }
  static void check(Instance &instance, KeySym modifier, KeyStates states,
                    KeySym symbol, size_t expected) {
    PublicContext context(instance.inputContextManager());
    context.focusIn();
    assert(publicField(&context));
    Snippets addon(&instance);
    addon.active_ = &context;
    addon.query_ = "public";
    addon.rows_ = {{"First public", "public1"},
                   {"Second public", "public2"},
                   {"Third public", "public3"}};
    addon.render(&context);
    KeyEvent press(&context, Key(modifier, states, 37), false);
    addon.key(press);
    assert(!press.filtered());
    assert(addon.active_ == &context && addon.query_ == "public");
    if (symbol != FcitxKey_None) {
      KeyEvent select(&context, Key(symbol, states, 57), false);
      addon.key(select);
      assert(select.filtered() && addon.selected_ == expected);
      KeyEvent release(&context, Key(symbol, states, 57), true);
      addon.key(release);
      assert(release.filtered());
    }
    KeyEvent releaseModifier(&context, Key(modifier, KeyStates(), 37), true);
    addon.key(releaseModifier);
    assert(!releaseModifier.filtered());
    assert(addon.active_ == &context && addon.query_ == "public");
    assert(context.inputPanel().clientPreedit().toString() == "\\public");
  }
};
} // namespace
int main() {
  char name[] = "public-fcitx-state-fixture";
  char disabled[] = "--disable=all";
  char *arguments[] = {name, disabled, nullptr};
  Instance instance(2, arguments);
  // Register Fcitx's context properties with all addon/frontends disabled.
  // The test drives the production handler directly, without an input engine.
  instance.initialize();
  CoreFixture::check(instance, FcitxKey_Control_L, KeyState::Ctrl, FcitxKey_n,
                     1);
  CoreFixture::check(instance, FcitxKey_Control_R, KeyState::Ctrl, FcitxKey_p,
                     2);
  CoreFixture::check(instance, FcitxKey_Shift_L, KeyState::Shift, FcitxKey_Tab,
                     2);
  CoreFixture::check(instance, FcitxKey_Shift_R, KeyState::Shift,
                     FcitxKey_ISO_Left_Tab, 2);
  CoreFixture::check(instance, FcitxKey_Shift_L, KeyState::Shift, FcitxKey_None,
                     0);
  CoreFixture::check(instance, FcitxKey_Alt_L, KeyState::Alt, FcitxKey_None, 0);
  CoreFixture::check(instance, FcitxKey_Super_L, KeyState::Super, FcitxKey_None,
                     0);
  CoreFixture::check(instance, FcitxKey_Control_L, KeyState::Ctrl,
                     FcitxKey_None, 0);
  CoreFixture::capability(instance, CapabilityFlag::Preedit, true);
  CoreFixture::capability(instance, CapabilityFlag::ClientSideInputPanel, true);
  CoreFixture::capability(instance, CapabilityFlag::SurroundingText, true);
  CoreFixture::capability(instance, CapabilityFlag::Password, false);
  CoreFixture::capability(instance, CapabilityFlag::Sensitive, false);
  CoreFixture::capability(instance, CapabilityFlag::Disable, false);
  CoreFixture::selection(instance);
  CoreFixture::invalidMetadata(instance, false);
  CoreFixture::invalidMetadata(instance, true);
  CoreFixture::presentation();
  CoreFixture::mousePlacement();
  CoreFixture::inputMethodSwitch(instance, InputMethodSwitchedReason::Other,
                                 "nat", true);
  CoreFixture::inputMethodSwitch(instance, InputMethodSwitchedReason::Enumerate,
                                 "", true);
  CoreFixture::inputMethodSwitch(
      instance, InputMethodSwitchedReason::CapabilityChanged, "nat", false);
  CoreFixture::asyncFraming();
  CoreFixture::asyncTimeout();
  CoreFixture::asyncCancellation();
  CoreFixture::delayedBody(false);
  CoreFixture::delayedBody(true);
  std::puts("state fixture: 8 modifier, 6 capability, 6 selection/protocol and "
            "2 panel, 4 mouse placement, 3 input method switch and 5 async IPC "
            "checks passed");
}
