// Bounded SNI3 candidate metadata for the IBus engine, in C. The Fcitx addon
// parses the same reply with inline_rows.h; both accept and reject exactly the
// same bytes. Change them together. The includer supplies valid_utf8().
//
// Reply: row count (at most 8), dark flag (0 or 1), three RGB colours, then per
// row a 16-byte identity, the name and keyword (each a u16 length, UTF-8 bytes
// without NUL, a match count of at most 128 and that many u16 [start, end)
// byte ranges on UTF-8 boundaries, increasing and not overlapping), a shown tag
// count (at most 2), the total tag count (at most 999, not less than shown) and
// the shown tags (u8 length, at most 64 bytes). Integers are little-endian. The
// IBus panel shows only the identity, name and keyword; the rest is validated.

typedef struct {
  unsigned char identity[16];
  char *name;
  char *keyword;
} SnippetRow;

static void snippet_row_free(gpointer data) {
  SnippetRow *row = data;
  g_free(row->name);
  g_free(row->keyword);
  g_free(row);
}

typedef struct {
  const unsigned char *data;
  size_t size, offset;
} RowReader;

static bool row_byte(RowReader *r, unsigned *value) {
  if (r->offset >= r->size) return false;
  *value = r->data[r->offset++];
  return true;
}

static bool row_short(RowReader *r, uint16_t *value) {
  unsigned a = 0, b = 0;
  if (!row_byte(r, &a) || !row_byte(r, &b)) return false;
  *value = (uint16_t)(a | (b << 8));
  return true;
}

// Reads `size` bytes of UTF-8 without NUL, at most `bound`. `text` may be NULL
// when only validation is needed.
static bool row_string(RowReader *r, size_t size, size_t bound, char **text) {
  if (size > bound || r->offset + size > r->size) return false;
  const char *start = (const char *)r->data + r->offset;
  r->offset += size;
  if (!valid_utf8(start, size) || memchr(start, '\0', size)) return false;
  if (text) *text = g_strndup(start, size);
  return true;
}

static bool row_boundary(const char *text, size_t size, uint16_t index) {
  return index == size || (index < size && ((unsigned char)text[index] & 0xc0) != 0x80);
}

// A name or keyword and its match ranges.
static bool row_field(RowReader *r, size_t bound, char **text) {
  uint16_t size = 0;
  unsigned count = 0;
  if (!row_short(r, &size) || !row_string(r, size, bound, text) || !row_byte(r, &count) ||
      count > 128)
    return false;
  uint16_t previous = 0;
  for (unsigned j = 0; j < count; ++j) {
    uint16_t start = 0, end = 0;
    if (!row_short(r, &start) || !row_short(r, &end) || start < previous || start >= end ||
        end > size || !row_boundary(*text, size, start) || !row_boundary(*text, size, end))
      return false;
    previous = end;
  }
  return true;
}

// All offsets are UTF-8 byte boundaries. On success `rows` holds SnippetRow
// values; on failure it is left as it was.
static bool row_metadata(const unsigned char *reply, size_t size, GPtrArray *rows) {
  if (size < 11 || reply[0] > 8 || reply[1] > 1) return false;
  RowReader r = {reply, size, 11};
  GPtrArray *parsed = g_ptr_array_new_with_free_func(snippet_row_free);
  bool ok = true;
  for (unsigned i = 0; ok && i < reply[0]; ++i) {
    if (r.offset + 16 > r.size) { ok = false; break; }
    SnippetRow *row = g_new0(SnippetRow, 1);
    memcpy(row->identity, r.data + r.offset, 16);
    r.offset += 16;
    g_ptr_array_add(parsed, row);
    for (guint j = 0; j + 1 < parsed->len; ++j)
      if (!memcmp(((SnippetRow *)parsed->pdata[j])->identity, row->identity, 16)) ok = false;
    ok = ok && row_field(&r, 512, &row->name) && row_field(&r, 256, &row->keyword);
    unsigned shown = 0;
    uint16_t total = 0;
    ok = ok && row_byte(&r, &shown) && shown <= 2 && row_short(&r, &total) && total >= shown &&
         total <= 999;
    for (unsigned j = 0; ok && j < shown; ++j) {
      unsigned tag = 0;
      ok = row_byte(&r, &tag) && row_string(&r, tag, 64, NULL);
    }
  }
  if (!ok || r.offset != r.size) {
    g_ptr_array_unref(parsed);
    return false;
  }
  for (guint i = 0; i < parsed->len; ++i) g_ptr_array_add(rows, parsed->pdata[i]);
  g_ptr_array_set_free_func(parsed, NULL);
  g_ptr_array_unref(parsed);
  return true;
}
