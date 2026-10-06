#pragma once

#include "fcitx-5.1.22/wl_surface.h"
#include <map>

// ClassicUI receives pointer/touch events for every surface on the shared
// Fcitx connection. Its WlPointer converts proxy user data to WlSurface, then
// checks WlSurface::userData() for a ClassicUI window. Keep the pinned wrapper
// in proxy user data and leave its window user data null. A native Window* here
// crashes ClassicUI before our pointer button handler can run.
// These local definitions stay hidden; other Fcitx modules retain their own
// generated wrapper implementation. Runtime/SDK version checks gate their use.
namespace snippets_surface {
static std::map<wl_surface *, bool> connected;
}

namespace fcitx::wayland {
__attribute__((visibility("hidden")))
WlSurface::WlSurface(wl_surface *data)
    : version_(wl_surface_get_version(data)), data_(data) {
  snippets_surface::connected.emplace(data, true);
  static const wl_surface_listener callbacks = {
      [](void *, wl_surface *, wl_output *) {},
      [](void *, wl_surface *, wl_output *) {},
      [](void *value, wl_surface *, int32_t scale) {
        static_cast<WlSurface *>(value)->preferredBufferScale()(scale);
      },
      [](void *value, wl_surface *, uint32_t transform) {
        static_cast<WlSurface *>(value)->preferredBufferTransform()(transform);
      }};
  wl_surface_add_listener(data, &callbacks, this);
}

__attribute__((visibility("hidden")))
void WlSurface::destructor(wl_surface *data) {
  auto found = snippets_surface::connected.find(data);
  bool live = found != snippets_surface::connected.end() && found->second;
  snippets_surface::connected.erase(data);
  if (live)
    wl_surface_destroy(data);
  else
    wl_proxy_destroy(reinterpret_cast<wl_proxy *>(data));
}
} // namespace fcitx::wayland
