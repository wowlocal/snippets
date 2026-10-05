// Snippets-owned popup on Fcitx's existing Wayland connection/input method.
// Included inside inline_fcitx.cpp's anonymous namespace after row metadata.
class MacPopupManager {
public:
  using Identity = std::array<unsigned char, 16>;
  using Select = std::function<void(const Identity &)>;
  struct Hit {
    int top, height;
    Identity identity;
  };
  struct Raster {
    cairo_surface_t *image = nullptr;
    int width = 336, height = 0, scale = 1;
    std::vector<Hit> hits;
    ~Raster() {
      if (image)
        cairo_surface_destroy(image);
    }
  };
  static bool supportsRuntime(const char *version) {
    return version && !std::strcmp(version, "5.1.22");
  }

private:
  using RGB = std::array<double, 3>;
  static RGB rgb(const std::array<unsigned char, 3> &value) {
    return {value[0] / 255., value[1] / 255., value[2] / 255.};
  }
  static RGB mix(RGB a, RGB b, double amount) {
    for (size_t i = 0; i < 3; ++i)
      a[i] += amount * (b[i] - a[i]);
    return a;
  }
  static double level(RGB color) {
    for (auto &v : color)
      v = v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4);
    return color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722;
  }
  static double contrast(RGB a, RGB b) {
    double x = level(a), y = level(b);
    return (std::max(x, y) + 0.05) / (std::min(x, y) + 0.05);
  }
  static RGB matchColor(const PanelPalette &palette) {
    RGB reference = rgb(palette.background);
    for (auto &v : reference)
      v = palette.dark ? std::max(v, 0.30) : std::min(v, 0.72);
    RGB accent = rgb(palette.accent), black{0, 0, 0}, white{1, 1, 1};
    RGB destination =
        contrast(white, reference) > contrast(black, reference) ? white : black;
    if (contrast(accent, reference) >= 4.5)
      return accent;
    double low = 0, high = 1;
    for (int i = 0; i < 20; ++i) {
      double amount = (low + high) / 2;
      if (contrast(mix(accent, destination, amount), reference) >= 4.5)
        high = amount;
      else
        low = amount;
    }
    return mix(accent, destination, high);
  }
  static void source(cairo_t *cr, RGB color, double alpha = 1) {
    cairo_set_source_rgba(cr, color[0], color[1], color[2], alpha);
  }
  static void rounded(cairo_t *cr, double x, double y, double width,
                      double height, double radius) {
    constexpr double pi = 3.141592653589793;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + width - radius, y + radius, radius, -pi / 2, 0);
    cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, pi / 2);
    cairo_arc(cr, x + radius, y + height - radius, radius, pi / 2, pi);
    cairo_arc(cr, x + radius, y + radius, radius, pi, 3 * pi / 2);
    cairo_close_path(cr);
  }
  static PangoLayout *layout(cairo_t *cr, const std::string &text, int size,
                             bool mono, int width, bool wrap = false) {
    auto *result = pango_cairo_create_layout(cr);
    auto *font = pango_font_description_new();
    pango_font_description_set_family(font, mono ? "monospace" : "sans");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_layout_set_font_description(result, font);
    pango_font_description_free(font);
    pango_layout_set_text(result, text.data(), int(text.size()));
    if (width > 0)
      pango_layout_set_width(result, width * PANGO_SCALE);
    pango_layout_set_wrap(result, PANGO_WRAP_WORD_CHAR);
    pango_layout_set_ellipsize(result, PANGO_ELLIPSIZE_END);
    pango_layout_set_single_paragraph_mode(result, TRUE);
    pango_layout_set_height(result, wrap ? -2 : -1);
    return result;
  }
  static void
  highlights(PangoLayout *text,
             const std::vector<std::pair<uint16_t, uint16_t>> &ranges,
             RGB color) {
    auto *attributes = pango_attr_list_new();
    for (auto [start, end] : ranges) {
      for (auto *attribute :
           {pango_attr_foreground_new(uint16_t(color[0] * 65535),
                                      uint16_t(color[1] * 65535),
                                      uint16_t(color[2] * 65535)),
            pango_attr_weight_new(PANGO_WEIGHT_SEMIBOLD)}) {
        attribute->start_index = start;
        attribute->end_index = end;
        pango_attr_list_insert(attributes, attribute);
      }
    }
    pango_layout_set_attributes(text, attributes);
    pango_attr_list_unref(attributes);
  }
  static void label(cairo_t *cr, PangoLayout *text, int x, int y, RGB color,
                    double alpha = 1) {
    source(cr, color, alpha);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, text);
  }

public:
  // A real Cairo/Pango raster also supplies the pointer's exact row geometry.
  static std::unique_ptr<Raster> raster(const std::vector<Row> &rows,
                                        size_t selected,
                                        const PanelPalette &palette, int scale,
                                        int hover = -1) {
    if (rows.empty() || rows.size() > 8 || selected >= rows.size() ||
        scale < 1 || scale > 4)
      return nullptr;
    auto result = std::make_unique<Raster>();
    result->scale = scale;
    auto *measureImage = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    auto *measure = cairo_create(measureImage);
    int top = 12;
    for (const auto &row : rows) {
      auto *title = layout(measure, row.name, 13, false, 292, true);
      highlights(title, row.nameMatches, matchColor(palette));
      int height = pango_layout_get_line_count(title) > 1 ? 62 : 46;
      g_object_unref(title);
      result->hits.push_back({top, height, row.identity});
      top += height + 4;
    }
    cairo_destroy(measure);
    cairo_surface_destroy(measureImage);
    result->height =
        top + 8; // Bottom inset and shadow, minus the last inter-row gap.
    result->image = cairo_image_surface_create(
        CAIRO_FORMAT_ARGB32, result->width * scale, result->height * scale);
    auto *cr = cairo_create(result->image);
    cairo_scale(cr, scale, scale);
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    for (int layer = 8; layer > 0; --layer) {
      rounded(cr, 8 - layer / 2., 10 - layer / 2., 320 + layer,
              result->height - 16 + layer, 18 + layer / 2.);
      cairo_set_source_rgba(cr, 0, 0, 0, 0.022);
      cairo_fill(cr);
    }
    rounded(cr, 8, 8, 320, result->height - 16, 18);
    source(cr, rgb(palette.background), 0.97);
    cairo_fill_preserve(cr);
    source(cr, palette.dark ? RGB{1, 1, 1} : RGB{0, 0, 0}, 0.14);
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);
    auto foreground = rgb(palette.foreground), accent = matchColor(palette);
    for (size_t i = 0; i < rows.size(); ++i) {
      const auto &row = rows[i];
      const auto &hit = result->hits[i];
      if (i == selected || int(i) == hover) {
        rounded(cr, 14, hit.top + 2, 308, hit.height - 4, 12);
        if (i == selected) {
          source(cr, palette.dark ? RGB{1, 1, 1} : rgb(palette.accent),
                 palette.dark ? 0.13 : 0.11);
          cairo_fill_preserve(cr);
          source(cr, palette.dark ? RGB{1, 1, 1} : RGB{0, 0, 0},
                 palette.dark ? 0.20 : 0.16);
          cairo_stroke(cr);
        } else {
          source(cr, palette.dark ? RGB{1, 1, 1} : RGB{0, 0, 0},
                 palette.dark ? 0.055 : 0.035);
          cairo_fill(cr);
        }
      }
      auto *title = layout(cr, row.name, 13, false, 292, true);
      auto *keyword = layout(cr, row.keyword, 11, true, 292);
      highlights(title, row.nameMatches, accent);
      highlights(keyword, row.keywordMatches, accent);
      int titleHeight = 0, keywordHeight = 0, unused = 0;
      pango_layout_get_pixel_size(title, &unused, &titleHeight);
      pango_layout_get_pixel_size(keyword, &unused, &keywordHeight);
      int y = hit.top + (hit.height - titleHeight - keywordHeight - 1) / 2;
      label(cr, title, 22, y, foreground);
      label(cr, keyword, 22, y + titleHeight + 1, foreground, 0.78);
      // Chips yield to the full natural keyword width, as in the Mac
      // controller.
      auto *natural = layout(cr, row.keyword, 11, true, 0);
      int keywordWidth = 0;
      pango_layout_get_pixel_size(natural, &keywordWidth, &unused);
      g_object_unref(natural);
      int x = 22 + keywordWidth + 6, shown = 0;
      auto chip = [&](const std::string &value) {
        auto *text = layout(cr, value, 10, false, 0);
        int width = 0;
        pango_layout_get_pixel_size(text, &width, &unused);
        width += 12;
        bool fits = x + width <= 314;
        if (fits) {
          rounded(cr, x, y + titleHeight, width, 17, 6);
          source(cr, rgb(palette.accent), 0.14);
          cairo_fill(cr);
          label(cr, text, x + 6, y + titleHeight + 1, accent);
          x += width + 4;
        }
        g_object_unref(text);
        return fits;
      };
      for (const auto &tag : row.tags) {
        if (!chip(tag))
          break;
        ++shown;
      }
      if (shown > 0 && row.tagCount > shown)
        chip("+" + std::to_string(row.tagCount - shown));
      g_object_unref(title);
      g_object_unref(keyword);
    }
    cairo_surface_flush(result->image);
    bool good = cairo_status(cr) == CAIRO_STATUS_SUCCESS &&
                cairo_surface_status(result->image) == CAIRO_STATUS_SUCCESS;
    cairo_destroy(cr);
    return good ? std::move(result) : nullptr;
  }
  static int hit(const std::vector<Hit> &rows, double x, double y) {
    if (x < 14 || x >= 322)
      return -1;
    for (size_t i = 0; i < rows.size(); ++i)
      if (y >= rows[i].top + 2 && y < rows[i].top + rows[i].height - 2)
        return int(i);
    return -1;
  }

private:
  // On connection closure, destroy only local proxies before Fcitx frees
  // display.
  template <class T, auto Destroy>
  static void dispose(T *&value, bool connected) {
    if (!value)
      return;
    if (connected)
      Destroy(value);
    else
      wl_proxy_destroy(reinterpret_cast<wl_proxy *>(value));
    value = nullptr;
  }
  struct Buffer {
    bool &connected;
    wl_buffer *proxy = nullptr;
    void *pixels = MAP_FAILED;
    size_t bytes = 0;
    bool released = false;
    std::function<void()> available;
    explicit Buffer(bool &live) : connected(live) {}
    ~Buffer() {
      dispose<wl_buffer, wl_buffer_destroy>(proxy, connected);
      if (pixels != MAP_FAILED)
        munmap(pixels, bytes);
    }
    static void release(void *data, wl_buffer *) {
      auto *self = static_cast<Buffer *>(data);
      self->released = true;
      auto available = self->available;
      if (available)
        available();
    }
  };
  struct Window {
    struct Output {
      Window *window;
      wl_output *proxy;
      int scale = 1;
      std::string name;
      Output(Window *parent, wl_registry *registry, uint32_t name,
             uint32_t version)
          : window(parent),
            proxy(static_cast<wl_output *>(wl_registry_bind(
                registry, name, &wl_output_interface, std::min(version, 4u)))) {
        static const wl_output_listener listener = {
            geometry, mode, done, scaling, outputName, description};
        wl_output_add_listener(proxy, &listener, this);
      }
      ~Output() {
        dispose<wl_output, wl_output_destroy>(proxy, window->connected);
      }
      static void geometry(void *, wl_output *, int32_t, int32_t, int32_t,
                           int32_t, int32_t, const char *, const char *,
                           int32_t) {}
      static void mode(void *, wl_output *, uint32_t, int32_t, int32_t,
                       int32_t) {}
      static void done(void *, wl_output *) {}
      static void outputName(void *data, wl_output *, const char *name) {
        if (name && std::strlen(name) <= 128)
          static_cast<Output *>(data)->name = name;
      }
      static void description(void *, wl_output *, const char *) {}
      static void scaling(void *data, wl_output *, int32_t value) {
        auto *self = static_cast<Output *>(data);
        self->scale = std::clamp(value, 1, 4);
        self->window->updateScale();
      }
    };
    struct Seat {
      Window *window;
      wl_seat *proxy;
      wl_pointer *pointer = nullptr;
      bool entered = false;
      double x = 0, y = 0;
      Seat(Window *parent, wl_registry *registry, uint32_t name)
          : window(parent), proxy(static_cast<wl_seat *>(wl_registry_bind(
                                registry, name, &wl_seat_interface, 1))) {
        static const wl_seat_listener listener = {capabilities, seatName};
        wl_seat_add_listener(proxy, &listener, this);
      }
      ~Seat() {
        dispose<wl_pointer, wl_pointer_destroy>(pointer, window->connected);
        dispose<wl_seat, wl_seat_destroy>(proxy, window->connected);
      }
      static void seatName(void *, wl_seat *, const char *) {}
      static void capabilities(void *data, wl_seat *, uint32_t flags) {
        auto *self = static_cast<Seat *>(data);
        if (!(flags & WL_SEAT_CAPABILITY_POINTER)) {
          dispose<wl_pointer, wl_pointer_destroy>(self->pointer,
                                                  self->window->connected);
          self->entered = false;
          return;
        }
        if (!self->pointer) {
          self->pointer = wl_seat_get_pointer(self->proxy);
          static const wl_pointer_listener listener = [] {
            wl_pointer_listener value{};
            value.enter = enter;
            value.leave = leave;
            value.motion = motion;
            value.button = button;
            value.axis = axis;
            return value;
          }();
          wl_pointer_add_listener(self->pointer, &listener, self);
        }
      }
      static void enter(void *data, wl_pointer *, uint32_t, wl_surface *surface,
                        wl_fixed_t x, wl_fixed_t y) {
        auto *self = static_cast<Seat *>(data);
        self->entered = surface == self->window->surface;
        self->x = wl_fixed_to_double(x);
        self->y = wl_fixed_to_double(y);
        if (self->entered)
          self->hover();
      }
      static void leave(void *data, wl_pointer *, uint32_t, wl_surface *) {
        auto *self = static_cast<Seat *>(data);
        if (self->entered) {
          self->entered = false;
          self->window->hover(-1);
        }
      }
      void hover() { window->hover(MacPopupManager::hit(window->hits, x, y)); }
      static void motion(void *data, wl_pointer *, uint32_t, wl_fixed_t x,
                         wl_fixed_t y) {
        auto *self = static_cast<Seat *>(data);
        self->x = wl_fixed_to_double(x);
        self->y = wl_fixed_to_double(y);
        if (self->entered)
          self->hover();
      }
      static void button(void *data, wl_pointer *, uint32_t, uint32_t,
                         uint32_t button, uint32_t state) {
        auto *self = static_cast<Seat *>(data);
        if (self->entered && button == 0x110 &&
            state == WL_POINTER_BUTTON_STATE_PRESSED)
          self->window->choose(
              MacPopupManager::hit(self->window->hits, self->x, self->y));
      }
      static void axis(void *, wl_pointer *, uint32_t, uint32_t, wl_fixed_t) {}
      static void frame(void *, wl_pointer *) {}
      static void axisSource(void *, wl_pointer *, uint32_t) {}
      static void axisStop(void *, wl_pointer *, uint32_t, uint32_t) {}
      static void axisDiscrete(void *, wl_pointer *, uint32_t, int32_t) {}
      static void axisValue120(void *, wl_pointer *, uint32_t, int32_t) {}
      static void axisDirection(void *, wl_pointer *, uint32_t, uint32_t) {}
    };
    struct Frame {
      Window *window;
      wl_callback *proxy = nullptr;
      uint64_t generation;
      bool done = false;
      Frame(Window *parent, uint64_t value)
          : window(parent), generation(value) {}
      ~Frame() {
        dispose<wl_callback, wl_callback_destroy>(proxy, window->connected);
      }
      static void complete(void *data, wl_callback *, uint32_t) {
        auto *self = static_cast<Frame *>(data);
        self->done = true;
        self->window->presented =
            std::max(self->window->presented, self->generation);
        auto *window = self->window;
        if (window->pending)
          window->redraw();
      }
    };
    bool connected = true;
    wl_display *display;
    wl_registry *registry = nullptr;
    wl_compositor *compositor = nullptr;
    wl_shm *shm = nullptr;
    uint32_t compositorName = 0, shmName = 0;
    wl_surface *surface = nullptr;
    zwp_input_popup_surface_v2 *role = nullptr;
    zwlr_layer_shell_v1 *layerShell = nullptr;
    zwlr_layer_surface_v1 *layer = nullptr;
    uint32_t layerShellName = 0;
    bool layerReady = false;
    std::optional<MouseAnchor> mouseAnchor;
    std::map<uint32_t, std::unique_ptr<Output>> outputs;
    std::map<uint32_t, std::unique_ptr<Seat>> seats;
    std::vector<std::unique_ptr<Buffer>> buffers;
    std::vector<std::unique_ptr<Frame>> frames;
    TrackableObjectReference<InputContext> context;
    std::vector<Row> rows;
    std::vector<Hit> hits;
    PanelPalette palette;
    Select select;
    size_t selected = 0;
    int scale = 1, preferred = 0, hovered = -1;
    uint64_t generation = 0, presented = 0;
    bool pending = false;
    explicit Window(wl_display *value) : display(value) {
      registry = wl_display_get_registry(display);
      static const wl_registry_listener listener = {global, removed};
      wl_registry_add_listener(registry, &listener, this);
    }
    ~Window() {
      hide();
      seats.clear();
      outputs.clear();
      dispose<zwlr_layer_shell_v1, zwlr_layer_shell_v1_destroy>(layerShell,
                                                                connected);
      dispose<wl_shm, wl_shm_destroy>(shm, connected);
      dispose<wl_compositor, wl_compositor_destroy>(compositor, connected);
      dispose<wl_registry, wl_registry_destroy>(registry, connected);
    }
    static void global(void *data, wl_registry *registry, uint32_t name,
                       const char *interface, uint32_t version) {
      auto *self = static_cast<Window *>(data);
      if (!std::strcmp(interface, "wl_compositor") && !self->compositor) {
        self->compositor = static_cast<wl_compositor *>(wl_registry_bind(
            registry, name, &wl_compositor_interface, std::min(version, 6u)));
        self->compositorName = name;
      } else if (!std::strcmp(interface, "wl_shm") && !self->shm) {
        self->shm = static_cast<wl_shm *>(
            wl_registry_bind(registry, name, &wl_shm_interface, 1));
        self->shmName = name;
      } else if (!std::strcmp(interface, "zwlr_layer_shell_v1") &&
                 !self->layerShell && version >= 3) {
        self->layerShell = static_cast<zwlr_layer_shell_v1 *>(wl_registry_bind(
            registry, name, &zwlr_layer_shell_v1_interface, 3));
        self->layerShellName = name;
      } else if (!std::strcmp(interface, "wl_output"))
        self->outputs[name] =
            std::make_unique<Output>(self, registry, name, version);
      else if (!std::strcmp(interface, "wl_seat"))
        self->seats[name] = std::make_unique<Seat>(self, registry, name);
    }
    static void removed(void *data, wl_registry *, uint32_t name) {
      auto *self = static_cast<Window *>(data);
      auto output = self->outputs.find(name);
      if (self->mouseAnchor && output != self->outputs.end() &&
          output->second->name == self->mouseAnchor->output)
        self->fallback();
      self->outputs.erase(name);
      self->seats.erase(name);
      self->updateScale();
      if (name == self->compositorName || name == self->shmName ||
          name == self->layerShellName) {
        self->hide();
        if (name == self->compositorName)
          dispose<wl_compositor, wl_compositor_destroy>(self->compositor,
                                                        self->connected);
        else if (name == self->shmName)
          dispose<wl_shm, wl_shm_destroy>(self->shm, self->connected);
        else
          dispose<zwlr_layer_shell_v1, zwlr_layer_shell_v1_destroy>(
              self->layerShell, self->connected);
      }
    }
    void updateScale() {
      int value = preferred;
      if (!value && mouseAnchor) {
        for (const auto &[name, output] : outputs) {
          (void)name;
          if (output->name == mouseAnchor->output)
            value = output->scale;
        }
      }
      if (!value) {
        value = 1;
        for (const auto &[name, output] : outputs) {
          (void)name;
          value = std::max(value, output->scale);
        }
      }
      if (scale != value) {
        scale = value;
        redraw();
      }
    }
    void destroySurface() {
      if (surface && connected) {
        wl_surface_attach(surface, nullptr, 0, 0);
        wl_surface_commit(surface);
      }
      dispose<zwp_input_popup_surface_v2, zwp_input_popup_surface_v2_destroy>(
          role, connected);
      dispose<zwlr_layer_surface_v1, zwlr_layer_surface_v1_destroy>(layer,
                                                                    connected);
      dispose<wl_surface, wl_surface_destroy>(surface, connected);
      frames.clear();
      buffers.clear();
      layerReady = false;
      presented = 0;
      for (auto &[name, seat] : seats) {
        (void)name;
        seat->entered = false;
      }
    }
    void hide() {
      context.unwatch();
      select = {};
      rows.clear();
      hits.clear();
      hovered = -1;
      presented = 0;
      pending = false;
      ++generation;
      destroySurface();
      mouseAnchor.reset();
      preferred = 0;
    }
    static void rectangle(void *data, zwp_input_popup_surface_v2 *, int32_t,
                          int32_t, int32_t width, int32_t height) {
      auto *self = static_cast<Window *>(data);
      if (!width && !height && !self->layer &&
          publicField(self->context.get()) && !self->mouseFallback())
        self->fallback();
    }
    static void layerConfigured(void *data, zwlr_layer_surface_v1 *role,
                                uint32_t serial, uint32_t, uint32_t) {
      auto *self = static_cast<Window *>(data);
      zwlr_layer_surface_v1_ack_configure(role, serial);
      self->layerReady = true;
      self->redraw();
    }
    static void layerClosed(void *data, zwlr_layer_surface_v1 *) {
      static_cast<Window *>(data)->fallback();
    }
    bool mouseFallback() {
      if (!layerShell || !connected)
        return false;
      auto anchor = MouseAnchor::capture();
      if (!anchor)
        return false;
      auto found =
          std::find_if(outputs.begin(), outputs.end(), [&](const auto &entry) {
            return entry.second->name == anchor->output;
          });
      if (found == outputs.end())
        return false;
      auto image = MacPopupManager::raster(rows, selected, palette,
                                           found->second->scale, hovered);
      auto origin =
          image ? anchor->origin(image->width, image->height) : std::nullopt;
      if (!origin)
        return false;
      destroySurface();
      mouseAnchor = std::move(anchor);
      scale = found->second->scale;
      surface = wl_compositor_create_surface(compositor);
      static const wl_surface_listener listener = {
          entered, left, preferredScale, preferredTransform};
      wl_surface_add_listener(surface, &listener, this);
      layer = zwlr_layer_shell_v1_get_layer_surface(
          layerShell, surface, found->second->proxy,
          ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "snippets-suggestions");
      static const zwlr_layer_surface_v1_listener layerListener = {
          layerConfigured, layerClosed};
      zwlr_layer_surface_v1_add_listener(layer, &layerListener, this);
      zwlr_layer_surface_v1_set_keyboard_interactivity(
          layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
      zwlr_layer_surface_v1_set_exclusive_zone(layer, -1);
      zwlr_layer_surface_v1_set_anchor(layer,
                                       ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                                           ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
      zwlr_layer_surface_v1_set_size(layer, image->width, image->height);
      zwlr_layer_surface_v1_set_margin(layer, origin->second, 0, 0,
                                       origin->first);
      wl_surface_commit(surface);
      wl_display_flush(display);
      return true;
    }
    static void entered(void *, wl_surface *, wl_output *) {}
    static void left(void *, wl_surface *, wl_output *) {}
    static void preferredTransform(void *, wl_surface *, uint32_t) {}
    static void preferredScale(void *data, wl_surface *, int32_t value) {
      auto *self = static_cast<Window *>(data);
      self->preferred = std::clamp(value, 1, 4);
      self->updateScale();
    }
    bool prepare(zwp_input_method_v2 *im, InputContext *ic) {
      if (!connected || !compositor || !shm || !im ||
          wl_compositor_get_version(compositor) < 3)
        return false;
      if (context.get() != ic) {
        hide();
        context = ic->watch();
        updateScale();
      }
      if (!surface) {
        surface = wl_compositor_create_surface(compositor);
        static const wl_surface_listener listener = {
            entered, left, preferredScale, preferredTransform};
        wl_surface_add_listener(surface, &listener, this);
        role = zwp_input_method_v2_get_input_popup_surface(im, surface);
        static const zwp_input_popup_surface_v2_listener popupListener = {
            rectangle};
        zwp_input_popup_surface_v2_add_listener(role, &popupListener, this);
      }
      return surface && (role || layer);
    }
    void hover(int index) {
      if (hovered != index) {
        hovered = index;
        redraw();
      }
    }
    void choose(int index) {
      if (index < 0 || size_t(index) >= hits.size() ||
          size_t(index) >= rows.size() || presented != generation ||
          !publicField(context.get()) || !select ||
          hits[size_t(index)].identity != rows[size_t(index)].identity)
        return;
      auto callback = select;
      auto identity = hits[size_t(index)].identity;
      callback(identity);
    }
    void redraw() {
      if (!rows.empty() && publicField(context.get()) && !draw())
        fallback();
    }
    void fallback() {
      auto *ic = context.get();
      hide();
      if (ic) {
        ic->inputPanel().setCustomInputPanelCallback({});
        ic->updateUserInterface(UserInterfaceComponent::InputPanel);
      }
    }
    bool paint(const std::vector<Row> &value, size_t selection,
               const PanelPalette &colors, Select callback) {
      if (!publicField(context.get()))
        return false;
      if (rows != value) {
        ++generation;
        hovered = -1;
      }
      rows = value;
      selected = selection;
      palette = colors;
      select = std::move(callback);
      return draw();
    }
    bool draw() {
      if (!surface || !connected)
        return false;
      if (layer && !layerReady)
        return true;
      std::erase_if(buffers,
                    [](const auto &buffer) { return buffer->released; });
      std::erase_if(frames, [](const auto &frame) { return frame->done; });
      if (buffers.size() >= 4 || frames.size() >= 4) {
        // Keep only the latest desired frame. Release/frame events drive
        // repaint; no timer, blocking roundtrip or additional input latency is
        // introduced.
        pending = true;
        return true;
      }
      pending = false;
      auto image =
          MacPopupManager::raster(rows, selected, palette, scale, hovered);
      if (!image)
        return false;
      if (layer) {
        auto origin = mouseAnchor
                          ? mouseAnchor->origin(image->width, image->height)
                          : std::nullopt;
        if (!origin)
          return false;
        zwlr_layer_surface_v1_set_size(layer, image->width, image->height);
        zwlr_layer_surface_v1_set_margin(layer, origin->second, 0, 0,
                                         origin->first);
      }
      auto buffer = std::make_unique<Buffer>(connected);
      buffer->available = [this] {
        if (pending)
          redraw();
      };
      int width = image->width * scale, height = image->height * scale;
      int stride = cairo_image_surface_get_stride(image->image);
      buffer->bytes = size_t(stride) * height;
      int fd = memfd_create("snippets-panel", MFD_CLOEXEC);
      if (fd < 0)
        return false;
      if (ftruncate(fd, off_t(buffer->bytes))) {
        close(fd);
        return false;
      }
      buffer->pixels = mmap(nullptr, buffer->bytes, PROT_READ | PROT_WRITE,
                            MAP_SHARED, fd, 0);
      if (buffer->pixels == MAP_FAILED) {
        close(fd);
        return false;
      }
      std::memcpy(buffer->pixels, cairo_image_surface_get_data(image->image),
                  buffer->bytes);
      auto *pool = wl_shm_create_pool(shm, fd, int32_t(buffer->bytes));
      close(fd);
      if (!pool)
        return false;
      buffer->proxy = wl_shm_pool_create_buffer(pool, 0, width, height, stride,
                                                WL_SHM_FORMAT_ARGB8888);
      wl_shm_pool_destroy(pool);
      if (!buffer->proxy)
        return false;
      static const wl_buffer_listener bufferListener = {Buffer::release};
      wl_buffer_add_listener(buffer->proxy, &bufferListener, buffer.get());
      auto frame = std::make_unique<Frame>(this, generation);
      frame->proxy = wl_surface_frame(surface);
      if (!frame->proxy)
        return false;
      static const wl_callback_listener frameListener = {Frame::complete};
      wl_callback_add_listener(frame->proxy, &frameListener, frame.get());
      auto *region = wl_compositor_create_region(compositor);
      if (!region)
        return false;
      wl_region_add(region, 8, 8, 320, image->height - 16);
      wl_surface_set_input_region(surface, region);
      wl_region_destroy(region);
      wl_surface_set_buffer_scale(surface, scale);
      wl_surface_attach(surface, buffer->proxy, 0, 0);
      wl_surface_damage(surface, 0, 0, image->width, image->height);
      wl_surface_commit(surface);
      hits = image->hits;
      buffers.push_back(std::move(buffer));
      frames.push_back(std::move(frame));
      wl_display_flush(display);
      return true;
    }
  };
  Instance *instance_;
  AddonInstance *waylandim_ = nullptr;
  std::map<std::string, std::unique_ptr<Window>> windows_;
  std::unique_ptr<HandlerTableEntry<WaylandConnectionCreated>> created_;
  std::unique_ptr<HandlerTableEntry<WaylandConnectionClosed>> closed_;

public:
  explicit MacPopupManager(Instance *instance) : instance_(instance) {
#ifdef SNIPPETS_FCITX_TESTING
    // The real-context fixture disables every frontend and must remain offline.
    return;
#endif
// The pinned wrapper declaration also depends on the build-time Utils layout.
#ifdef SNIPPETS_FCITX_INTERFACE_SDK
    if (!supportsRuntime(SNIPPETS_FCITX_INTERFACE_SDK))
      return;
#else
    return;
#endif
    if (!supportsRuntime(Instance::version()))
      return;
    auto *wayland = instance_->addonManager().addon("wayland", true);
    if (!wayland)
      return;
    closed_ = wayland->call<IWaylandModule::addConnectionClosedCallback>(
        [this](const std::string &, wl_display *display) {
          std::erase_if(windows_, [display](auto &entry) {
            if (entry.second->display != display)
              return false;
            entry.second->connected = false;
            return true;
          });
        });
    created_ = wayland->call<IWaylandModule::addConnectionCreatedCallback>(
        [this](const std::string &, wl_display *display, FocusGroup *group) {
          windows_[group->display()] = std::make_unique<Window>(display);
        });
  }
  ~MacPopupManager() {
    created_.reset();
    closed_.reset();
    hide();
  }
  void hide() {
    for (auto &[name, window] : windows_) {
      (void)name;
      window->hide();
    }
  }
  bool prepare(InputContext *ic) {
    if (!publicField(ic) || ic->frontendName() != "wayland_v2")
      return false;
    auto found = windows_.find(ic->display());
    if (found == windows_.end())
      return false;
    if (!waylandim_)
      waylandim_ = instance_->addonManager().addon("waylandim", true);
    if (!waylandim_)
      return false;
    auto *wrapper = waylandim_->call<IWaylandIMModule::getInputMethodV2>(ic);
    auto *im = fcitx::wayland::rawPointer(wrapper);
    if (!im || std::strcmp(wl_proxy_get_class(reinterpret_cast<wl_proxy *>(im)),
                           "zwp_input_method_v2"))
      return false;
    return found->second->prepare(im, ic);
  }
  bool paint(InputContext *ic, const std::vector<Row> &rows, size_t selected,
             const PanelPalette &palette, Select select) {
    auto found = windows_.find(ic->display());
    return found != windows_.end() &&
           found->second->paint(rows, selected, palette, std::move(select));
  }
};
