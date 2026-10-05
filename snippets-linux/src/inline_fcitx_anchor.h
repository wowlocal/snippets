// Omarchy's read-only IPC supplies a mouse anchor only when the receiving
// toolkit supplies no caret rectangle. Nothing from the replies is logged or
// retained beyond this presentation. Both requests share a 75 ms deadline.
struct MouseAnchor {
  std::string output;
  int x, y, left, top, right, bottom;
  static std::optional<MouseAnchor> decode(json_object *pointer,
                                           json_object *monitors) {
    auto numeric = [](json_object *object,
                      const char *key) -> std::optional<double> {
      json_object *value = nullptr;
      if (!json_object_object_get_ex(object, key, &value) ||
          !(json_object_is_type(value, json_type_int) ||
            json_object_is_type(value, json_type_double)))
        return {};
      double number = json_object_get_double(value);
      return std::isfinite(number) && std::abs(number) <= 1000000
                 ? std::optional<double>(number)
                 : std::nullopt;
    };
    if (!pointer || !monitors ||
        !json_object_is_type(pointer, json_type_object) ||
        !json_object_is_type(monitors, json_type_array) ||
        json_object_array_length(monitors) > 64)
      return {};
    auto px = numeric(pointer, "x"), py = numeric(pointer, "y");
    if (!px || !py)
      return {};
    for (size_t i = 0; i < json_object_array_length(monitors); ++i) {
      auto *monitor = json_object_array_get_idx(monitors, i);
      if (!json_object_is_type(monitor, json_type_object))
        return {};
      auto x = numeric(monitor, "x"), y = numeric(monitor, "y"),
           width = numeric(monitor, "width"),
           height = numeric(monitor, "height"),
           scale = numeric(monitor, "scale"),
           transform = numeric(monitor, "transform");
      json_object *name = nullptr, *reserved = nullptr, *disabled = nullptr;
      if (!x || !y || !width || !height || !scale || !transform || *width < 1 ||
          *width > 32768 || *height < 1 || *height > 32768 || *scale < .25 ||
          *scale > 8 || *transform < 0 || *transform > 7 ||
          std::floor(*transform) != *transform ||
          !json_object_object_get_ex(monitor, "name", &name) ||
          !json_object_is_type(name, json_type_string) ||
          !json_object_object_get_ex(monitor, "reserved", &reserved) ||
          !json_object_is_type(reserved, json_type_array) ||
          json_object_array_length(reserved) != 4)
        return {};
      if (json_object_object_get_ex(monitor, "disabled", &disabled) &&
          (!json_object_is_type(disabled, json_type_boolean) ||
           json_object_get_boolean(disabled)))
        continue;
      std::string output(json_object_get_string(name),
                         json_object_get_string_len(name));
      if (output.empty() || output.size() > 128 ||
          !std::all_of(output.begin(), output.end(),
                       [](unsigned char c) { return c >= 0x21 && c <= 0x7e; }))
        return {};
      int w =
          int(std::lround((int(*transform) % 2 ? *height : *width) / *scale));
      int h =
          int(std::lround((int(*transform) % 2 ? *width : *height) / *scale));
      if (*px < *x || *py < *y || *px >= *x + w || *py >= *y + h)
        continue;
      std::array<int, 4> edges{};
      for (size_t n = 0; n < edges.size(); ++n) {
        auto *v = json_object_array_get_idx(reserved, n);
        if (!json_object_is_type(v, json_type_int) ||
            json_object_get_int64(v) < 0 || json_object_get_int64(v) > 32768)
          return {};
        edges[n] = int(json_object_get_int64(v));
      }
      if (edges[0] + edges[2] >= w || edges[1] + edges[3] >= h)
        return {};
      return MouseAnchor{output,
                         int(std::lround(*px - *x)),
                         int(std::lround(*py - *y)),
                         edges[0],
                         edges[1],
                         w - edges[2],
                         h - edges[3]};
    }
    return {};
  }
  std::optional<std::pair<int, int>> origin(int width, int height) const {
    if (width <= 0 || height <= 0 || width > right - left ||
        height > bottom - top)
      return {};
    int below = y + 4;
    int vertical = below + height <= bottom ? below : y - height - 4;
    return std::pair{std::clamp(x, left, right - width),
                     std::clamp(vertical, top, bottom - height)};
  }
  static std::optional<MouseAnchor> capture() {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    const char *signature = getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if (!runtime || !signature || !*signature || std::strlen(signature) > 200 ||
        !std::all_of(signature, signature + std::strlen(signature),
                     [](unsigned char c) {
                       return std::isalnum(c) || c == '_' || c == '-';
                     }))
      return {};
    std::string path =
        std::string(runtime) + "/hypr/" + signature + "/.socket.sock";
    sockaddr_un address{};
    struct stat info{};
    if (path.size() >= sizeof(address.sun_path) || lstat(path.c_str(), &info) ||
        !S_ISSOCK(info.st_mode) || info.st_uid != geteuid())
      return {};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    using Json = std::unique_ptr<json_object, decltype(&json_object_put)>;
    auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(75);
    auto query = [&](const char *request) -> Json {
      Json result(nullptr, json_object_put);
      int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
      if (fd < 0)
        return result;
      struct Owner {
        int fd;
        ~Owner() { close(fd); }
      } owner{fd};
      if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)))
        return result;
      ucred peer{};
      socklen_t length = sizeof(peer);
      if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &length) ||
          length != sizeof(peer) || peer.uid != geteuid() ||
          !transfer(fd, const_cast<char *>(request), std::strlen(request), true,
                    deadline))
        return result;
      std::string bytes;
      for (;;) {
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                             deadline - std::chrono::steady_clock::now())
                             .count();
        if (remaining <= 0)
          return result;
        pollfd poller{fd, POLLIN, 0};
        if (poll(&poller, 1, int(remaining)) <= 0)
          return result;
        char block[4096];
        auto count = recv(fd, block, sizeof(block), MSG_DONTWAIT);
        if (count < 0 || bytes.size() + size_t(count) > 65536)
          return result;
        if (!count)
          break;
        bytes.append(block, size_t(count));
      }
      auto *parser = json_tokener_new_ex(12);
      if (!parser)
        return result;
      json_tokener_set_flags(parser, JSON_TOKENER_STRICT);
      result.reset(
          json_tokener_parse_ex(parser, bytes.c_str(), int(bytes.size() + 1)));
      bool valid = json_tokener_get_error(parser) == json_tokener_success;
      json_tokener_free(parser);
      if (!valid)
        result.reset();
      return result;
    };
    auto pointer = query("j/cursorpos");
    if (!pointer)
      return {};
    auto monitors = query("j/monitors");
    return decode(pointer.get(), monitors.get());
  }
};
