// SNI3 framing on Fcitx's event loop. The caller owns and authenticates the fd.
// No key handler waits for the application or dispatches Wayland recursively.
class AsyncChannel {
public:
  using Complete = std::function<void(bool, unsigned char, std::string &)>;
  explicit AsyncChannel(EventLoop &loop) : loop_(loop) {
    timeout_ =
        loop_.addTimeEvent(CLOCK_MONOTONIC, now(CLOCK_MONOTONIC), 1,
                           [this](EventSourceTime *, uint64_t) {
                             if (pending_ && now(CLOCK_MONOTONIC) >= deadline_)
                               finish(false);
                             return true;
                           });
    timeout_->setEnabled(false);
  }
  ~AsyncChannel() { cancel(); }
  bool pending() const { return pending_; }
  void cancel() {
    if (io_)
      io_->setEnabled(false);
    timeout_->setEnabled(false);
    pending_ = false;
    complete_ = {};
    erase(output_);
    erase(reply_);
    header_.fill(0);
    outputOffset_ = headerOffset_ = replyOffset_ = 0;
  }
  bool start(int fd, unsigned char kind, const std::string &data,
             Complete complete, bool receive = true,
             uint64_t timeout = 500000) {
    cancel();
    if (fd < 0 || data.size() > Limit || kind > 3)
      return false;
    output_ = "SNI3";
    output_ += char(kind);
    for (unsigned i = 0; i < 4; ++i)
      output_ += char(data.size() >> (8 * i));
    output_ += data;
    complete_ = std::move(complete);
    receive_ = receive;
    pending_ = true;
    deadline_ = now(CLOCK_MONOTONIC) + timeout;
    if (!io_) {
      io_ = loop_.addIOEvent(
          fd, IOEventFlag::Out,
          [this](EventSourceIO *, int currentFd, IOEventFlags flags) {
            if (pending_ && currentFd == io_->fd())
              pump(currentFd, flags);
            return true;
          });
    } else {
      io_->setFd(fd);
      io_->setEvents(IOEventFlag::Out);
      io_->setEnabled(true);
    }
    timeout_->setTime(deadline_);
    timeout_->setOneShot();
    return true;
  }

private:
  void finish(bool success) {
    io_->setEnabled(false);
    timeout_->setEnabled(false);
    pending_ = false;
    auto callback = std::move(complete_);
    std::string reply = reply_;
    auto kind = header_[4];
    erase(output_);
    erase(reply_);
    header_.fill(0);
    outputOffset_ = headerOffset_ = replyOffset_ = 0;
    if (callback)
      callback(success, kind, reply);
    erase(reply);
  }
  void pump(int fd, IOEventFlags flags) {
    // Bound work per dispatch even if signals repeatedly interrupt syscalls.
    for (unsigned work = 0; work < 32 && pending_; ++work) {
      if (outputOffset_ < output_.size()) {
        auto n =
            send(fd, output_.data() + outputOffset_,
                 output_.size() - outputOffset_, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (n > 0) {
          outputOffset_ += size_t(n);
          continue;
        }
        if (n < 0 && errno == EINTR)
          continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
          return;
        finish(false);
        return;
      }
      if (!receive_) {
        finish(true);
        return;
      }
      io_->setEvents(IOEventFlag::In);
      bool header = headerOffset_ < header_.size();
      char *target =
          header ? reinterpret_cast<char *>(header_.data()) : reply_.data();
      auto &offset = header ? headerOffset_ : replyOffset_;
      size_t size = header ? header_.size() : reply_.size();
      if (!header && offset == size) {
        finish(true);
        return;
      }
      auto n = recv(fd, target + offset, size - offset, MSG_DONTWAIT);
      if (n > 0) {
        offset += size_t(n);
        if (header && headerOffset_ == header_.size()) {
          if (std::memcmp(header_.data(), "SNI3", 4) || header_[4] > 3 ||
              number(header_.data() + 5) > Limit) {
            finish(false);
            return;
          }
          reply_.assign(number(header_.data() + 5), '\0');
        }
        continue;
      }
      if (n < 0 && errno == EINTR)
        continue;
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) &&
          !(flags & (IOEventFlags(IOEventFlag::Err) | IOEventFlag::Hup))
               .toInteger())
        return;
      finish(false);
      return;
    }
  }
  EventLoop &loop_;
  std::unique_ptr<EventSourceIO> io_;
  std::unique_ptr<EventSourceTime> timeout_;
  Complete complete_;
  bool pending_ = false;
  bool receive_ = true;
  uint64_t deadline_ = 0;
  std::string output_, reply_;
  std::array<unsigned char, 9> header_{};
  size_t outputOffset_ = 0, headerOffset_ = 0, replyOffset_ = 0;
};
