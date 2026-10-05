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

protected:
  void commitStringImpl(const std::string &) override {}
  void deleteSurroundingTextImpl(int, unsigned) override {}
  void forwardKeyImpl(const ForwardKeyEvent &) override {}
  void updatePreeditImpl() override {}
};
struct CoreFixture {
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
  std::puts("modifier chords: 8 passed");
}
