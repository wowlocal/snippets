// Fcitx transport only. Rust owns library access, matching and consent.
// No surrounding text or general key stream is sent to Snippets.
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <dlfcn.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>
#include <functional>
#include <memory>
#include <poll.h>
#include <set>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

using namespace fcitx;
namespace {
constexpr size_t Limit = 256 * 1024;
void erase(std::string &text) {
  volatile char *p = text.data();
  for (size_t i = 0; i < text.size(); ++i)
    p[i] = 0;
  text.clear();
}
uint32_t number(const unsigned char *p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
         (uint32_t(p[3]) << 24);
}
bool transfer(int fd, void *data, size_t size, bool sending,
              std::chrono::steady_clock::time_point deadline) {
  auto *p = static_cast<unsigned char *>(data);
  while (size) {
    auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                         deadline - std::chrono::steady_clock::now())
                         .count();
    if (remaining <= 0)
      return false;
    pollfd poller{fd, short(sending ? POLLOUT : POLLIN), 0};
    if (poll(&poller, 1, int(remaining)) <= 0)
      return false;
    auto n = sending ? send(fd, p, size, MSG_NOSIGNAL | MSG_DONTWAIT)
                     : recv(fd, p, size, MSG_DONTWAIT);
    if (n <= 0)
      return false;
    p += n;
    size -= size_t(n);
  }
  return true;
}
bool packet(int fd, unsigned char kind, const std::string &payload,
            unsigned char &replyKind, std::string &reply) {
  auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  std::array<unsigned char, 9> header{'S', 'N', 'I', '1', kind, 0, 0, 0, 0};
  for (size_t i = 0; i < 4; ++i)
    header[5 + i] = static_cast<unsigned char>(payload.size() >> (8 * i));
  if (!transfer(fd, header.data(), header.size(), true, deadline) ||
      (!payload.empty() && !transfer(fd, const_cast<char *>(payload.data()),
                                     payload.size(), true, deadline)) ||
      !transfer(fd, header.data(), header.size(), false, deadline) ||
      std::memcmp(header.data(), "SNI1", 4) || header[4] > 3 ||
      number(header.data() + 5) > Limit)
    return false;
  replyKind = header[4];
  reply.resize(number(header.data() + 5));
  return reply.empty() ||
         transfer(fd, reply.data(), reply.size(), false, deadline);
}
int connectApp() {
  const char *runtime = getenv("XDG_RUNTIME_DIR");
  if (!runtime)
    return -1;
  struct stat directory{}, file{};
  if (lstat(runtime, &directory) || !S_ISDIR(directory.st_mode) ||
      directory.st_uid != geteuid() || (directory.st_mode & 0077))
    return -1;
  std::string path = std::string(runtime) + "/snippets-inline.sock";
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (path.size() >= sizeof(address.sun_path) || lstat(path.c_str(), &file) ||
      !S_ISSOCK(file.st_mode) || file.st_uid != geteuid() ||
      (file.st_mode & 0777) != 0600)
    return -1;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  if (fd < 0)
    return -1;
  if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address))) {
    close(fd);
    return -1;
  }
  ucred peer{};
  socklen_t length = sizeof(peer);
  Dl_info addon{};
  // Authenticate the GUI next to this installed addon by inode, not a process
  // name.
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &length) ||
      length != sizeof(peer) || peer.uid != geteuid() || peer.pid <= 0 ||
      !dladdr(reinterpret_cast<void *>(&connectApp), &addon) ||
      !addon.dli_fname) {
    close(fd);
    return -1;
  }
  std::string expected = addon.dli_fname;
  expected = expected.substr(0, expected.find_last_of('/')) + "/snippets";
  std::string actual = "/proc/" + std::to_string(peer.pid) + "/exe";
  struct stat a{}, b{};
  if (stat(expected.c_str(), &a) || stat(actual.c_str(), &b) ||
      !S_ISREG(a.st_mode) || a.st_dev != b.st_dev || a.st_ino != b.st_ino) {
    close(fd);
    return -1;
  }
  return fd;
}
bool publicField(InputContext *ic) {
  return ic && ic->hasFocus() &&
         !(ic->capabilityFlags() &
           (CapabilityFlags(CapabilityFlag::PasswordOrSensitive) |
            CapabilityFlag::Disable))
              .toInteger();
}
struct Row {
  std::string name, keyword;
};
class Word : public CandidateWord {
public:
  Word(const Row &row, std::function<void(InputContext *)> select)
      : CandidateWord(Text(row.name, TextFormatFlag::Bold)),
        select_(std::move(select)) {
    Text title(row.name, TextFormatFlag::Bold);
    title.append("\n\\" + row.keyword);
    setText(title);
    setCustomLabel(Text(""));
  }
  void select(InputContext *ic) const override {
    // Selection resets the candidate list; retain the callback across that
    // reset.
    auto callback = select_;
    callback(ic);
  }

private:
  std::function<void(InputContext *)> select_;
};
class Snippets : public AddonInstance {
public:
  explicit Snippets(Instance *instance) : instance_(instance) {
    watchers_.push_back(instance_->watchEvent(
        EventType::InputContextKeyEvent, EventWatcherPhase::PreInputMethod,
        [this](Event &event) { key(static_cast<KeyEvent &>(event)); }));
    for (auto type :
         {EventType::InputContextFocusOut, EventType::InputContextReset,
          EventType::InputContextDestroyed,
          EventType::InputContextCapabilityChanged,
          EventType::InputContextSwitchInputMethod}) {
      watchers_.push_back(instance_->watchEvent(
          type, EventWatcherPhase::PreInputMethod, [this](Event &event) {
            auto *ic = static_cast<InputContextEvent &>(event).inputContext();
            if (ic == active_)
              clear(ic, event.type() != EventType::InputContextDestroyed);
          }));
    }
    timer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 250000, 0,
        [this](EventSourceTime *timer, uint64_t) {
          if (active_) {
            pollfd p{fd_, POLLIN, 0};
            if (!publicField(active_))
              clear(active_);
            else if (poll(&p, 1, 0) > 0 &&
                     (p.revents & (POLLIN | POLLHUP | POLLERR)))
              literal(active_);
          } else {
            int fd = connectApp();
            if (fd >= 0) {
              unsigned char kind = 0;
              std::string reply;
              packet(fd, 0, "", kind, reply);
              erase(reply);
              close(fd);
            }
          }
          timer->setNextInterval(250000);
          timer->setOneShot();
          return true;
        });
  }
  ~Snippets() override {
    if (fd_ >= 0)
      close(fd_);
    erase(query_);
  }

private:
  void clear(InputContext *ic, bool update = true) {
    if (fd_ >= 0)
      close(fd_);
    fd_ = -1;
    erase(query_);
    rows_.clear();
    active_ = nullptr;
    selected_ = 0;
    if (update) {
      ic->inputPanel().reset();
      ic->updatePreedit();
      ic->updateUserInterface(UserInterfaceComponent::InputPanel, true);
    }
  }
  void literal(InputContext *ic) {
    std::string original = "\\" + query_;
    bool permitted = publicField(ic);
    clear(ic);
    if (permitted)
      ic->commitString(original);
    erase(original);
  }
  void render(InputContext *ic) {
    Text preedit("\\" + query_);
    preedit.setCursor(int(query_.size() + 1));
    ic->inputPanel().setClientPreedit(preedit);
    auto list = std::make_unique<CommonCandidateList>();
    list->setPageSize(8);
    list->setLayoutHint(CandidateLayoutHint::Vertical);
    for (size_t i = 0; i < rows_.size(); ++i)
      list->append(std::make_unique<Word>(
          rows_[i], [this, i](InputContext *context) { select(context, i); }));
    if (!rows_.empty())
      list->setGlobalCursorIndex(int(selected_));
    ic->inputPanel().setCandidateList(std::move(list));
    ic->inputPanel().setAuxDown(Text());
    ic->updatePreedit();
    ic->updateUserInterface(UserInterfaceComponent::InputPanel, true);
  }
  bool update(InputContext *ic, unsigned char request,
              const std::string &data) {
    unsigned char kind = 0;
    std::string reply;
    if (!packet(fd_, request, data, kind, reply)) {
      erase(reply);
      literal(ic);
      return false;
    }
    return apply(ic, kind, reply);
  }
  bool apply(InputContext *ic, unsigned char kind, std::string &reply) {
    if (!publicField(ic) || ic != active_) {
      erase(reply);
      literal(ic);
      return false;
    }
    if (kind == 2 && utf8::validate(reply) &&
        reply.find('\0') == std::string::npos) {
      // Keep the authenticated connection alive just long enough to acknowledge
      // commit.
      int fd = fd_;
      fd_ = -1;
      clear(ic);
      ic->commitString(reply);
      erase(reply);
      std::array<unsigned char, 9> ack{'S', 'N', 'I', '1', 3, 0, 0, 0, 0};
      transfer(fd, ack.data(), ack.size(), true,
               std::chrono::steady_clock::now() +
                   std::chrono::milliseconds(50));
      close(fd);
      return true;
    }
    if (kind != 1 || reply.empty() ||
        static_cast<unsigned char>(reply[0]) > 8) {
      erase(reply);
      literal(ic);
      return false;
    }
    std::vector<Row> rows;
    size_t offset = 1;
    for (unsigned i = 0; i < static_cast<unsigned char>(reply[0]); ++i) {
      Row row;
      for (auto *text : {&row.name, &row.keyword}) {
        if (offset + 2 > reply.size()) {
          erase(reply);
          literal(ic);
          return false;
        }
        size_t n = static_cast<unsigned char>(reply[offset]) +
                   (size_t(static_cast<unsigned char>(reply[offset + 1])) << 8);
        offset += 2;
        if (n > 512 || offset + n > reply.size()) {
          erase(reply);
          literal(ic);
          return false;
        }
        *text = reply.substr(offset, n);
        offset += n;
        if (!utf8::validate(*text) || text->find('\0') != std::string::npos) {
          erase(reply);
          literal(ic);
          return false;
        }
      }
      rows.push_back(std::move(row));
    }
    if (offset != reply.size()) {
      erase(reply);
      literal(ic);
      return false;
    }
    erase(reply);
    rows_ = std::move(rows);
    selected_ = 0;
    render(ic);
    return true;
  }
  void select(InputContext *ic, size_t index) {
    if (ic == active_ && publicField(ic) && index < rows_.size())
      update(ic, 2, std::string(1, char(index)));
  }
  void consume(KeyEvent &event) {
    if (consumed_.size() < 64)
      consumed_.insert(event.rawKey().code() ? event.rawKey().code()
                                             : int(event.rawKey().sym()));
    event.filterAndAccept();
  }
  void key(KeyEvent &event) {
    auto *ic = event.inputContext();
    auto key = event.key().normalize();
    if (event.filtered())
      return;
    int identity = event.rawKey().code() ? event.rawKey().code()
                                         : int(event.rawKey().sym());
    if (event.isRelease()) {
      if (consumed_.erase(identity))
        event.filterAndAccept();
      return;
    }
    if (!publicField(ic)) {
      if (ic == active_)
        clear(ic);
      return;
    }
    if (active_ && active_ != ic) {
      clear(active_);
      return;
    }
    if (!active_) {
      if (!key.check(FcitxKey_backslash) ||
          !ic->inputPanel().preedit().empty() ||
          !ic->inputPanel().clientPreedit().empty())
        return;
      fd_ = connectApp();
      if (fd_ < 0)
        return;
      active_ = ic;
      query_.clear();
      // Only take ownership after the opted-in app admits this public field.
      unsigned char kind = 0;
      std::string reply;
      if (!packet(fd_, 1, "", kind, reply) || kind != 1) {
        erase(reply);
        clear(ic);
        return;
      }
      consume(event);
      apply(ic, kind, reply);
      return;
    }
    if (key.check(FcitxKey_Escape)) {
      consume(event);
      literal(ic);
      return;
    }
    if (key.check(FcitxKey_BackSpace)) {
      consume(event);
      if (query_.empty())
        clear(ic);
      else {
        size_t i = query_.size() - 1;
        while (i && (static_cast<unsigned char>(query_[i]) & 0xc0) == 0x80)
          --i;
        query_.resize(i);
        update(ic, 1, query_);
      }
      return;
    }
    bool next =
        key.check(FcitxKey_Down) || key.check(Key(FcitxKey_n, KeyState::Ctrl));
    bool previous = key.check(FcitxKey_Up) ||
                    key.check(Key(FcitxKey_p, KeyState::Ctrl)) ||
                    key.check(Key(FcitxKey_Tab, KeyState::Shift));
    if (!rows_.empty() && (next || previous)) {
      consume(event);
      selected_ = (selected_ + rows_.size() + (next ? 1 : -1)) % rows_.size();
      render(ic);
      return;
    }
    if (!rows_.empty() &&
        (key.check(FcitxKey_Return) || key.check(FcitxKey_KP_Enter) ||
         key.check(FcitxKey_Tab))) {
      consume(event);
      select(ic, selected_);
      return;
    }
    std::string character = Key::keySymToUTF8(key.sym());
    auto modifiers =
        key.states() & (KeyStates(KeyState::Ctrl) | KeyState::Alt |
                        KeyState::Super | KeyState::Meta | KeyState::Hyper);
    if (modifiers.toInteger() || character.empty() || key.isModifier() ||
        character.find_first_of("\\ \t\r\n") != std::string::npos ||
        std::any_of(character.begin(), character.end(),
                    [](unsigned char c) { return c < 0x20 || c == 0x7f; }) ||
        query_.size() + character.size() > 480 || utf8::length(query_) >= 120) {
      literal(ic);
      return;
    }
    consume(event);
    query_ += character;
    erase(character);
    update(ic, 1, query_);
  }
  Instance *instance_;
  InputContext *active_ = nullptr;
  int fd_ = -1;
  std::string query_;
  std::vector<Row> rows_;
  size_t selected_ = 0;
  std::set<int> consumed_;
  std::vector<std::unique_ptr<HandlerTableEntry<EventHandler>>> watchers_;
  std::unique_ptr<EventSourceTime> timer_;
};
class Factory : public AddonFactory {
public:
  AddonInstance *create(AddonManager *manager) override {
    return new Snippets(manager->instance());
  }
};
} // namespace
FCITX_ADDON_FACTORY_V2(snippets, Factory)
