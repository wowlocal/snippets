// Test-only numeric protocol trace. Never preload into a user browser.
// No argument text is written: only closed event codes and numeric flags.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int (*original_fputs)(const char *, FILE *);
static size_t (*original_fwrite)(const void *, size_t, size_t, FILE *);
static int (*original_vfprintf)(FILE *, const char *, va_list);
static int (*original_vfprintf_chk)(FILE *, int, const char *, va_list);
static unsigned char *records;
static unsigned role;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
struct Method {
  unsigned id, epoch, parent;
};
static struct Method methods[64];
static unsigned method_count;

static unsigned method(unsigned id) {
  for (unsigned i = 0; i < method_count; i++)
    if (methods[i].id == id)
      return i;
  if (method_count == 64)
    return 64;
  unsigned result = method_count++;
  methods[result].id = id;
  return result;
}
static int wayland_caller(void *return_address, FILE *stream) {
  if (stream != stderr)
    return 0;
  // Browser mode is permitted only for an owned fictional test process.
  // Chromium can call through internal logging trampolines, so dladdr does
  // not consistently identify the original protocol writer.
  if (role == 3)
    return 1;
  Dl_info info;
  if (!dladdr(return_address, &info) || !info.dli_fname)
    return 0;
  const char *base = strrchr(info.dli_fname, '/');
  base = base ? base + 1 : info.dli_fname;
  return strncmp(base, "libwayland-client.so", 20) == 0 ||
         (role == 3 && !strcmp(base, "chromium"));
}
static int fixture_letter(unsigned key) {
  return key == 49 || key == 30 || key == 20 || key == 23 || key == 47 ||
         key == 18 || key == 38;
}
static void record(unsigned code, unsigned context, unsigned flags,
                   unsigned value) {
  if (!records)
    return;
  unsigned index = __atomic_fetch_add((unsigned *)records, 1, __ATOMIC_RELAXED);
  if (index >= 2729) {
    __atomic_fetch_add((unsigned *)(records + 12), 1, __ATOMIC_RELAXED);
    return;
  }
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  uint64_t stamp =
      (uint64_t)now.tv_sec * 1000000 + (unsigned)now.tv_nsec / 1000;
  unsigned char *p = records + 16 + (size_t)index * 24;
  flags |= role << 16;
  memcpy(p, &code, 4);
  memcpy(p + 4, &context, 4);
  memcpy(p + 8, &flags, 4);
  memcpy(p + 12, &value, 4);
  __atomic_store_n((uint64_t *)(p + 16), stamp, __ATOMIC_RELEASE);
}
// Accept only the trusted protocol header. Never copy or persist argument text.
static void protocol(const char *text, size_t size) {
  if (!records)
    return;
  __atomic_fetch_add((unsigned *)(records + 8), 1, __ATOMIC_RELAXED);
  if (size < 18 || text[0] != '[')
    return;
  const char *close = memchr(text, ']', size < 32 ? size : 32);
  if (!close)
    return;
  const char *p = close + 1, *end = text + size;
  while (p < end && *p == ' ')
    p++;
  if (p < end && *p == '{') {
    const char *brace = memchr(p, '}', (size_t)(end - p));
    if (!brace)
      return;
    p = brace + 1;
    while (p < end && *p == ' ')
      p++;
  }
  if (end - p >= 10 && !memcmp(p, "discarded ", 10))
    p += 10;
  unsigned outgoing = 0;
  if (end - p >= 4 && !memcmp(p, " -> ", 4)) {
    outgoing = 1;
    p += 4;
  } else if (end - p >= 3 && !memcmp(p, "-> ", 3)) {
    outgoing = 1;
    p += 3;
  }
  const char *hash = memchr(p, '#', (size_t)(end - p));
  const char *at = memchr(p, '@', (size_t)(end - p));
  if (at && (!hash || at < hash))
    hash = at;
  if (!hash || hash - p > 48)
    return;
  unsigned kind = 0;
  if (hash - p == 19 && !memcmp(p, "zwp_input_method_v2", 19))
    kind = 1;
  if (hash - p == 33 && !memcmp(p, "zwp_input_method_keyboard_grab_v2", 33))
    kind = 2;
  if (hash - p == 23 && !memcmp(p, "zwp_virtual_keyboard_v1", 23))
    kind = 3;
  if (hash - p == 17 && (!memcmp(p, "zwp_text_input_v3", 17) ||
                         !memcmp(p, "zwp_text_input_v1", 17)))
    kind = 4;
  if (hash - p == 11 && !memcmp(p, "wl_keyboard", 11))
    kind = 5;
  if (!kind)
    return;
  char *after;
  unsigned long raw = strtoul(hash + 1, &after, 10);
  if (after == hash + 1 || raw > UINT32_MAX || after >= end || *after != '.')
    return;
  p = after + 1;
  const char *open = memchr(p, '(', (size_t)(end - p));
  if (!open || open - p > 32)
    return;
  size_t length = (size_t)(open - p);
  const char *args = open + 1;
  unsigned code = 0, flags = outgoing ? 8 : 0, value = 0, context = 0;
  pthread_mutex_lock(&lock);
  unsigned entry = method((unsigned)raw);
  if (entry == 64) {
    pthread_mutex_unlock(&lock);
    return;
  }
  if (kind == 1) {
    context = entry + 1;
    if (length == 8 && !memcmp(p, "activate", 8))
      code = 70;
    else if (length == 10 && !memcmp(p, "deactivate", 10))
      code = 71;
    else if (length == 4 && !memcmp(p, "done", 4)) {
      code = 72;
      methods[entry].epoch++;
    } else if (length == 13 && !memcmp(p, "grab_keyboard", 13)) {
      unsigned child;
      if (sscanf(args, "new id zwp_input_method_keyboard_grab_v2#%u", &child) ==
          1) {
        unsigned i = method(child);
        if (i < 64)
          methods[i].parent = entry + 1;
      }
      code = 74;
    } else if (length == 18 && !memcmp(p, "set_preedit_string", 18)) {
      code = 76;
      if (end - args >= 2 && !memcmp(args, "\"\"", 2))
        flags |= 16;
      if (end - args >= 3 && !memcmp(args, "\"\\\"", 3))
        flags |= 32;
    } else if (length == 6 && !memcmp(p, "commit", 6)) {
      code = 77;
      unsigned serial;
      if (sscanf(args, "%u", &serial) == 1 && serial == methods[entry].epoch)
        flags |= 64;
    } else if (length == 13 && !memcmp(p, "commit_string", 13))
      code = 78;
    value = methods[entry].epoch;
  } else if (kind == 4) {
    context = entry + 1;
    if (length == 16 && !memcmp(p, "set_content_type", 16)) {
      unsigned hint, purpose;
      if (sscanf(args, "%u, %u", &hint, &purpose) == 2 && hint <= 1023 &&
          purpose <= 13) {
        code = 87;
        flags |= hint << 5;
        value = purpose;
      }
    } else if (length == 6 && !memcmp(p, "enable", 6))
      code = 80;
    else if (length == 7 && !memcmp(p, "disable", 7))
      code = 81;
    else if (length == 6 && !memcmp(p, "commit", 6)) {
      code = 82;
      methods[entry].epoch++;
    } else if (length == 5 && !memcmp(p, "enter", 5))
      code = 83;
    else if (length == 5 && !memcmp(p, "leave", 5))
      code = 84;
    else if (length == 4 && !memcmp(p, "done", 4))
      code = 85;
    else if (length == 14 && !memcmp(p, "preedit_string", 14)) {
      code = 86;
      if (end - args >= 2 && !memcmp(args, "\"\"", 2))
        flags |= 16;
      if (end - args >= 3 && !memcmp(args, "\"\\\"", 3))
        flags |= 32;
    }
    if (code != 87)
      value = methods[entry].epoch;
  } else if (kind == 5 && length == 5 && !memcmp(p, "enter", 5)) {
    code = 90;
    context = entry + 1;
  } else if (kind == 5 && length == 5 && !memcmp(p, "leave", 5)) {
    code = 91;
    context = entry + 1;
  } else if (length == 3 && !memcmp(p, "key", 3)) {
    unsigned serial = 0, time = 0, key = 0, state = 0;
    int count =
        (kind == 2 || kind == 5)
            ? sscanf(args, "%u, %u, %u, %u", &serial, &time, &key, &state)
            : sscanf(args, "%u, %u, %u", &time, &key, &state);
    if (count == ((kind == 2 || kind == 5) ? 4 : 3)) {
      code = kind == 2 ? 75 : kind == 5 ? 92 : 79;
      flags |= state ? 1 : 0;
      flags |= key == 43 ? 2 : 0;
      flags |= fixture_letter(key) ? 4 : 0;
      context = kind == 2 ? methods[entry].parent : 0;
      value = context ? methods[context - 1].epoch : 0;
    }
  }
  if (code)
    record(code, context, flags, value);
  pthread_mutex_unlock(&lock);
}
__attribute__((constructor)) static void setup(void) {
  original_fputs = dlsym(RTLD_NEXT, "fputs");
  original_fwrite = dlsym(RTLD_NEXT, "fwrite");
  original_vfprintf = dlsym(RTLD_NEXT, "vfprintf");
  original_vfprintf_chk = dlsym(RTLD_NEXT, "__vfprintf_chk");
  const char *path = getenv("SNIPPETS_WIRE_TRACE_FILE"),
             *stream_role = getenv("SNIPPETS_WIRE_ROLE");
  role = stream_role && !strcmp(stream_role, "fixture")   ? 2
         : stream_role && !strcmp(stream_role, "browser") ? 3
                                                          : 1;
  if (!path)
    return;
  int fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0)
    return;
  struct stat s;
  if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_size != 65536 ||
      s.st_uid != getuid() || (s.st_mode & 077)) {
    close(fd);
    return;
  }
  void *p = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (p != MAP_FAILED)
    records = p;
}
int fputs(const char *text, FILE *stream) {
  if (wayland_caller(__builtin_return_address(0), stream)) {
    protocol(text, strnlen(text, 4096));
    return 0;
  }
  return original_fputs ? original_fputs(text, stream) : 0;
}
size_t fwrite(const void *data, size_t size, size_t count, FILE *stream) {
  if (wayland_caller(__builtin_return_address(0), stream)) {
    size_t length = size && count > 4096 / size ? 4096 : size * count;
    protocol(data, length);
    return count;
  }
  return original_fwrite ? original_fwrite(data, size, count, stream) : count;
}
int fprintf(FILE *stream, const char *format, ...) {
  va_list args;
  va_start(args, format);
  int result;
  if (wayland_caller(__builtin_return_address(0), stream) &&
      !strcmp(format, "%s")) {
    const char *text = va_arg(args, const char *);
    protocol(text, strnlen(text, 4096));
    result = 0;
  } else if (wayland_caller(__builtin_return_address(0), stream)) {
    char buffer[4096];
    int length = vsnprintf(buffer, sizeof(buffer), format, args);
    if (length > 0)
      protocol(buffer, (size_t)length < sizeof(buffer) ? (size_t)length
                                                       : sizeof(buffer) - 1);
    result = length;
  } else
    result = original_vfprintf ? original_vfprintf(stream, format, args) : 0;
  va_end(args);
  return result;
}
int __fprintf_chk(FILE *stream, int flag, const char *format, ...) {
  va_list args;
  va_start(args, format);
  int result;
  if (wayland_caller(__builtin_return_address(0), stream) &&
      !strcmp(format, "%s")) {
    const char *text = va_arg(args, const char *);
    protocol(text, strnlen(text, 4096));
    result = 0;
  } else if (wayland_caller(__builtin_return_address(0), stream)) {
    char buffer[4096];
    int length = vsnprintf(buffer, sizeof(buffer), format, args);
    if (length > 0)
      protocol(buffer, (size_t)length < sizeof(buffer) ? (size_t)length
                                                       : sizeof(buffer) - 1);
    result = length;
  } else if (original_vfprintf_chk)
    result = original_vfprintf_chk(stream, flag, format, args);
  else
    result = original_vfprintf ? original_vfprintf(stream, format, args) : 0;
  va_end(args);
  return result;
}

int __vfprintf_chk(FILE *stream, int flag, const char *format, va_list args) {
  if (wayland_caller(__builtin_return_address(0), stream)) {
    char buffer[4096];
    va_list copy;
    va_copy(copy, args);
    int length = vsnprintf(buffer, sizeof(buffer), format, copy);
    va_end(copy);
    if (length > 0)
      protocol(buffer, (size_t)length < sizeof(buffer) ? (size_t)length
                                                       : sizeof(buffer) - 1);
    return length;
  }
  return original_vfprintf_chk
             ? original_vfprintf_chk(stream, flag, format, args)
             : original_vfprintf(stream, format, args);
}

int vfprintf(FILE *stream, const char *format, va_list args) {
  if (wayland_caller(__builtin_return_address(0), stream)) {
    char b[4096];
    va_list c;
    va_copy(c, args);
    int n = vsnprintf(b, sizeof(b), format, c);
    va_end(c);
    if (n > 0)
      protocol(b, n < 4096 ? (size_t)n : 4095);
    return n;
  }
  return original_vfprintf(stream, format, args);
}
