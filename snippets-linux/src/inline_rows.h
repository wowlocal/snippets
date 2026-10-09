// Shared bounded SNI3 candidate metadata. The includer supplies validUtf8.
struct Row {
  std::string name, keyword;
  std::array<unsigned char, 16> identity{};
  std::vector<std::pair<uint16_t, uint16_t>> nameMatches{}, keywordMatches{};
  std::vector<std::string> tags{};
  uint16_t tagCount = 0;
  bool operator==(const Row &) const = default;
};
struct PanelPalette {
  bool dark = true;
  std::array<unsigned char, 3> background{43, 43, 43},
      foreground{245, 245, 245}, accent{0, 122, 255};
  bool operator==(const PanelPalette &) const = default;
};
// All offsets are UTF-8 byte boundaries, not Pango character positions.
bool rowMetadata(const std::string &reply, std::vector<Row> &rows,
                 PanelPalette &palette) {
  if (reply.size() < 11 || static_cast<unsigned char>(reply[0]) > 8 ||
      static_cast<unsigned char>(reply[1]) > 1)
    return false;
  palette.dark = reply[1] != 0;
  size_t offset = 2;
  for (auto *color :
       {&palette.background, &palette.foreground, &palette.accent}) {
    std::memcpy(color->data(), reply.data() + offset, 3);
    offset += 3;
  }
  auto byte = [&](unsigned &value) {
    if (offset >= reply.size())
      return false;
    value = static_cast<unsigned char>(reply[offset++]);
    return true;
  };
  auto shortValue = [&](uint16_t &value) {
    unsigned a = 0, b = 0;
    if (!byte(a) || !byte(b))
      return false;
    value = uint16_t(a | (b << 8));
    return true;
  };
  auto string = [&](std::string &text, size_t size, size_t bound) {
    if (size > bound || offset + size > reply.size())
      return false;
    text = reply.substr(offset, size);
    offset += size;
    return validUtf8(text) && text.find('\0') == std::string::npos;
  };
  std::set<std::array<unsigned char, 16>> identities;
  for (unsigned i = 0; i < static_cast<unsigned char>(reply[0]); ++i) {
    Row row;
    if (offset + 16 > reply.size())
      return false;
    std::memcpy(row.identity.data(), reply.data() + offset, 16);
    offset += 16;
    if (!identities.insert(row.identity).second)
      return false;
    for (auto field : {std::pair{&row.name, &row.nameMatches},
                       std::pair{&row.keyword, &row.keywordMatches}}) {
      uint16_t size = 0;
      unsigned count = 0;
      if (!shortValue(size) ||
          !string(*field.first, size, field.first == &row.name ? 512 : 256) ||
          !byte(count) || count > 128)
        return false;
      uint16_t previous = 0;
      auto boundary = [&](uint16_t index) {
        return index == field.first->size() ||
               (index < field.first->size() &&
                (static_cast<unsigned char>((*field.first)[index]) & 0xc0) !=
                    0x80);
      };
      for (unsigned j = 0; j < count; ++j) {
        uint16_t start = 0, end = 0;
        if (!shortValue(start) || !shortValue(end) || start < previous ||
            start >= end || end > size || !boundary(start) || !boundary(end))
          return false;
        field.second->emplace_back(start, end);
        previous = end;
      }
    }
    unsigned count = 0;
    if (!byte(count) || count > 2 || !shortValue(row.tagCount) ||
        row.tagCount < count || row.tagCount > 999)
      return false;
    for (unsigned j = 0; j < count; ++j) {
      unsigned size = 0;
      std::string tag;
      if (!byte(size) || !string(tag, size, 64))
        return false;
      row.tags.push_back(std::move(tag));
    }
    rows.push_back(std::move(row));
  }
  return offset == reply.size();
}
