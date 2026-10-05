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

protected:
  void commitStringImpl(const std::string &) override { ++commits; }
  void deleteSurroundingTextImpl(int, unsigned) override {}
  void forwardKeyImpl(const ForwardKeyEvent &) override {}
  void updatePreeditImpl() override {}
};
struct CoreFixture {
  static Row row(unsigned char identity, const char *name, const char *keyword) {
    Row result{name, keyword};
    result.identity.back() = identity;
    return result;
  }
  static std::string metadata(const std::vector<Row> &rows) {
    std::string reply(1, char(rows.size()));
    for (const auto &row : rows) {
      reply.append(reinterpret_cast<const char *>(row.identity.data()),
                   row.identity.size());
      for (const auto *field : {&row.name, &row.keyword}) {
        reply += char(field->size());
        reply += char(field->size() >> 8);
        reply += *field;
      }
    }
    return reply;
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
  std::puts("state fixture: 8 modifier, 6 capability and 6 selection/protocol checks passed");
}
