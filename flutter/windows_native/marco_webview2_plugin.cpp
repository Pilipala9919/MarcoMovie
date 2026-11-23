#include "marco_webview2_plugin.h"

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <objbase.h>
#include <shlobj.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace marco {
namespace {

// ============================================================================
// UTF-8 / UTF-16 & String Helpers (no C++ exceptions; _HAS_EXCEPTIONS=0 safe)
// ============================================================================

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        out.data(), needed);
  return out;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  const int needed = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) return std::string();
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        out.data(), needed, nullptr, nullptr);
  return out;
}

std::string WidePtrToUtf8(LPCWSTR ptr) {
  if (!ptr) return std::string();
  return WideToUtf8(std::wstring(ptr));
}

std::string ToLowerAscii(const std::string& s) {
  std::string out = s;
  for (char& ch : out) {
    if (ch >= 'A' && ch <= 'Z') {
      ch = static_cast<char>(ch - 'A' + 'a');
    }
  }
  return out;
}

std::string TrimAscii(const std::string& s) {
  size_t start = 0;
  while (start < s.size() &&
         (s[start] == ' ' || s[start] == '\t' || s[start] == '\r' ||
          s[start] == '\n')) {
    ++start;
  }
  size_t end = s.size();
  while (end > start &&
         (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\r' ||
          s[end - 1] == '\n')) {
    --end;
  }
  return s.substr(start, end - start);
}

bool ContainsInsensitive(const std::string& haystack,
                         const std::string& needle) {
  if (needle.empty()) return false;
  const std::string h = ToLowerAscii(haystack);
  const std::string n = ToLowerAscii(needle);
  return h.find(n) != std::string::npos;
}

bool StartsWithInsensitive(const std::string& text,
                           const std::string& prefix) {
  if (text.size() < prefix.size()) return false;
  for (size_t i = 0; i < prefix.size(); ++i) {
    char a = text[i];
    char b = prefix[i];
    if (a >= 'A' && a <= 'Z') a = static_cast<char>(a - 'A' + 'a');
    if (b >= 'A' && b <= 'Z') b = static_cast<char>(b - 'A' + 'a');
    if (a != b) return false;
  }
  return true;
}

std::string ExtractHostLower(const std::string& url) {
  const size_t scheme_pos = url.find("://");
  if (scheme_pos == std::string::npos) return std::string();
  size_t host_start = scheme_pos + 3;
  const size_t slash_pos = url.find_first_of("/?#", host_start);
  std::string authority = (slash_pos == std::string::npos)
                              ? url.substr(host_start)
                              : url.substr(host_start, slash_pos - host_start);
  const size_t at_pos = authority.rfind('@');
  if (at_pos != std::string::npos) {
    authority = authority.substr(at_pos + 1);
  }
  if (!authority.empty() && authority[0] == '[') {
    const size_t close_bracket = authority.find(']');
    if (close_bracket != std::string::npos) {
      return ToLowerAscii(authority.substr(0, close_bracket + 1));
    }
  }
  const size_t colon_pos = authority.find(':');
  if (colon_pos != std::string::npos) {
    authority = authority.substr(0, colon_pos);
  }
  return ToLowerAscii(authority);
}

bool HostMatchesRule(const std::string& host, const std::string& pattern) {
  std::string p = ToLowerAscii(TrimAscii(pattern));
  while (!p.empty() && p[0] == '.') {
    p.erase(p.begin());
  }
  if (p.empty() || host.empty()) return false;
  if (host == p) return true;
  if (host.size() > p.size() + 1 &&
      host.compare(host.size() - p.size(), p.size(), p) == 0 &&
      host[host.size() - p.size() - 1] == '.') {
    return true;
  }
  return false;
}

std::string StripFragment(const std::string& url) {
  const size_t hash_pos = url.find('#');
  return (hash_pos == std::string::npos) ? url : url.substr(0, hash_pos);
}

// ============================================================================
// Lightweight Non-Throwing Regex Matcher (supports common URL / TVBox regexes)
// ============================================================================

class SimpleRegex {
 public:
  static bool Search(const std::string& pattern, const std::string& text) {
    if (pattern.empty() || pattern.size() > 512) return false;
    SimpleRegex re(pattern, text);
    if (!re.valid_) return false;
    const bool anchored_start = (!pattern.empty() && pattern[0] == '^');
    if (anchored_start) {
      return re.MatchFrom(0, 0);
    }
    for (size_t start = 0; start <= text.size(); ++start) {
      if (re.MatchFrom(0, start)) return true;
      if (re.steps_ >= kMaxSteps) return false;
    }
    return false;
  }

 private:
  static constexpr int kMaxSteps = 60000;

  struct Atom {
    enum Kind {
      kLiteral,
      kAny,
      kClass,
      kDigit,
      kNonDigit,
      kWord,
      kNonWord,
      kSpace,
      kNonSpace,
      kAnchorStart,
      kAnchorEnd,
      kGroup,
    };
    Kind kind = kLiteral;
    char ch = 0;
    bool negated = false;
    bool lazy = false;
    int min_rep = 1;
    int max_rep = 1;  // -1 = unbounded
    std::vector<std::pair<char, char>> ranges;
    std::vector<std::vector<Atom>> branches;  // for kGroup
  };

  const std::string& text_;
  std::vector<std::vector<Atom>> root_branches_;
  bool valid_ = false;
  int steps_ = 0;

  SimpleRegex(const std::string& pattern, const std::string& text)
      : text_(text) {
    size_t pos = 0;
    valid_ = ParseAlternation(pattern, pos, false, &root_branches_) &&
             pos == pattern.size();
  }

  static char Lower(char c) {
    return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
  }

  static bool IsWordChar(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
  }

  static bool IsSpaceChar(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' ||
           c == '\v';
  }

  bool ParseAlternation(const std::string& pat,
                        size_t& pos,
                        bool stop_on_paren,
                        std::vector<std::vector<Atom>>* out_branches) {
    std::vector<Atom> current;
    while (pos < pat.size()) {
      const char c = pat[pos];
      if (stop_on_paren && c == ')') {
        out_branches->push_back(std::move(current));
        return true;
      }
      if (c == '|') {
        out_branches->push_back(std::move(current));
        current.clear();
        ++pos;
        continue;
      }
      Atom atom;
      if (!ParseAtom(pat, pos, &atom)) return false;
      ParseQuantifier(pat, pos, &atom);
      current.push_back(std::move(atom));
    }
    if (stop_on_paren) return false;
    out_branches->push_back(std::move(current));
    return true;
  }

  bool ParseAtom(const std::string& pat, size_t& pos, Atom* atom) {
    const char c = pat[pos];
    if (c == '^') {
      atom->kind = Atom::kAnchorStart;
      ++pos;
      return true;
    }
    if (c == '$') {
      atom->kind = Atom::kAnchorEnd;
      ++pos;
      return true;
    }
    if (c == '.') {
      atom->kind = Atom::kAny;
      ++pos;
      return true;
    }
    if (c == '(') {
      ++pos;
      if (pos + 1 < pat.size() && pat[pos] == '?' &&
          (pat[pos + 1] == ':' || pat[pos + 1] == '=' || pat[pos + 1] == '!')) {
        if (pat[pos + 1] != ':') return false;
        pos += 2;
      }
      atom->kind = Atom::kGroup;
      if (!ParseAlternation(pat, pos, true, &atom->branches)) return false;
      if (pos >= pat.size() || pat[pos] != ')') return false;
      ++pos;
      return true;
    }
    if (c == '[') {
      return ParseClass(pat, pos, atom);
    }
    if (c == '\\') {
      ++pos;
      if (pos >= pat.size()) return false;
      const char esc = pat[pos++];
      switch (esc) {
        case 'd':
          atom->kind = Atom::kDigit;
          return true;
        case 'D':
          atom->kind = Atom::kNonDigit;
          return true;
        case 'w':
          atom->kind = Atom::kWord;
          return true;
        case 'W':
          atom->kind = Atom::kNonWord;
          return true;
        case 's':
          atom->kind = Atom::kSpace;
          return true;
        case 'S':
          atom->kind = Atom::kNonSpace;
          return true;
        case 'n':
          atom->kind = Atom::kLiteral;
          atom->ch = '\n';
          return true;
        case 'r':
          atom->kind = Atom::kLiteral;
          atom->ch = '\r';
          return true;
        case 't':
          atom->kind = Atom::kLiteral;
          atom->ch = '\t';
          return true;
        default:
          atom->kind = Atom::kLiteral;
          atom->ch = esc;
          return true;
      }
    }
    if (c == '*' || c == '+' || c == '?') return false;
    atom->kind = Atom::kLiteral;
    atom->ch = c;
    ++pos;
    return true;
  }

  bool ParseClass(const std::string& pat, size_t& pos, Atom* atom) {
    ++pos;  // skip '['
    atom->kind = Atom::kClass;
    if (pos < pat.size() && pat[pos] == '^') {
      atom->negated = true;
      ++pos;
    }
    bool first = true;
    while (pos < pat.size()) {
      char c = pat[pos];
      if (c == ']' && !first) {
        ++pos;
        return true;
      }
      first = false;
      char start_ch = 0;
      if (!ReadClassChar(pat, pos, &start_ch, atom)) {
        // Class shortcut like \d added directly
        continue;
      }
      if (pos + 1 < pat.size() && pat[pos] == '-' && pat[pos + 1] != ']') {
        ++pos;  // '-'
        char end_ch = 0;
        if (!ReadClassChar(pat, pos, &end_ch, atom)) return false;
        if (static_cast<unsigned char>(start_ch) >
            static_cast<unsigned char>(end_ch)) {
          std::swap(start_ch, end_ch);
        }
        atom->ranges.emplace_back(start_ch, end_ch);
      } else {
        atom->ranges.emplace_back(start_ch, start_ch);
      }
    }
    return false;
  }

  bool ReadClassChar(const std::string& pat,
                     size_t& pos,
                     char* out,
                     Atom* atom) {
    char c = pat[pos++];
    if (c == '\\' && pos < pat.size()) {
      char esc = pat[pos++];
      if (esc == 'd') {
        atom->ranges.emplace_back('0', '9');
        return false;
      }
      if (esc == 'w') {
        atom->ranges.emplace_back('a', 'z');
        atom->ranges.emplace_back('A', 'Z');
        atom->ranges.emplace_back('0', '9');
        atom->ranges.emplace_back('_', '_');
        return false;
      }
      if (esc == 's') {
        atom->ranges.emplace_back(' ', ' ');
        atom->ranges.emplace_back('\t', '\r');
        return false;
      }
      *out = esc;
      return true;
    }
    *out = c;
    return true;
  }

  void ParseQuantifier(const std::string& pat, size_t& pos, Atom* atom) {
    if (pos >= pat.size()) return;
    if (atom->kind == Atom::kAnchorStart || atom->kind == Atom::kAnchorEnd) {
      return;
    }
    const char q = pat[pos];
    if (q == '*') {
      atom->min_rep = 0;
      atom->max_rep = -1;
      ++pos;
    } else if (q == '+') {
      atom->min_rep = 1;
      atom->max_rep = -1;
      ++pos;
    } else if (q == '?') {
      atom->min_rep = 0;
      atom->max_rep = 1;
      ++pos;
    } else if (q == '{') {
      size_t save = pos + 1;
      int m = 0;
      bool has_m = false;
      while (save < pat.size() && pat[save] >= '0' && pat[save] <= '9') {
        m = m * 10 + (pat[save] - '0');
        has_m = true;
        ++save;
      }
      if (has_m && save < pat.size() && pat[save] == '}') {
        atom->min_rep = m;
        atom->max_rep = m;
        pos = save + 1;
      } else if (has_m && save < pat.size() && pat[save] == ',') {
        ++save;
        if (save < pat.size() && pat[save] == '}') {
          atom->min_rep = m;
          atom->max_rep = -1;
          pos = save + 1;
        } else {
          int n = 0;
          bool has_n = false;
          while (save < pat.size() && pat[save] >= '0' && pat[save] <= '9') {
            n = n * 10 + (pat[save] - '0');
            has_n = true;
            ++save;
          }
          if (has_n && save < pat.size() && pat[save] == '}') {
            atom->min_rep = m;
            atom->max_rep = (n < m) ? m : n;
            pos = save + 1;
          }
        }
      }
    }
    if (pos < pat.size() && pat[pos] == '?') {
      atom->lazy = true;
      ++pos;
    }
  }

  bool MatchChar(const Atom& atom, char c) const {
    const unsigned char uc = static_cast<unsigned char>(c);
    switch (atom.kind) {
      case Atom::kAny:
        return c != '\n' && c != '\r';
      case Atom::kLiteral:
        return Lower(c) == Lower(atom.ch);
      case Atom::kDigit:
        return uc >= '0' && uc <= '9';
      case Atom::kNonDigit:
        return !(uc >= '0' && uc <= '9');
      case Atom::kWord:
        return IsWordChar(uc);
      case Atom::kNonWord:
        return !IsWordChar(uc);
      case Atom::kSpace:
        return IsSpaceChar(uc);
      case Atom::kNonSpace:
        return !IsSpaceChar(uc);
      case Atom::kClass: {
        bool hit = false;
        const char lc = Lower(c);
        for (const auto& range : atom.ranges) {
          const char a = Lower(range.first);
          const char b = Lower(range.second);
          if (lc >= a && lc <= b) {
            hit = true;
            break;
          }
        }
        return atom.negated ? !hit : hit;
      }
      default:
        return false;
    }
  }

  bool MatchFrom(size_t branch_root_dummy, size_t text_pos) {
    (void)branch_root_dummy;
    for (const auto& branch : root_branches_) {
      if (MatchSeq(branch, 0, text_pos, nullptr)) return true;
      if (steps_ >= kMaxSteps) return false;
    }
    return false;
  }

  bool MatchSeq(const std::vector<Atom>& seq,
                size_t idx,
                size_t text_pos,
                size_t* out_end) {
    if (++steps_ >= kMaxSteps) return false;
    if (idx == seq.size()) {
      if (out_end) *out_end = text_pos;
      return true;
    }
    const Atom& atom = seq[idx];
    if (atom.kind == Atom::kAnchorStart) {
      if (text_pos != 0) return false;
      return MatchSeq(seq, idx + 1, text_pos, out_end);
    }
    if (atom.kind == Atom::kAnchorEnd) {
      if (text_pos != text_.size()) return false;
      return MatchSeq(seq, idx + 1, text_pos, out_end);
    }
    if (atom.kind == Atom::kGroup) {
      return MatchGroupAtom(seq, idx, 0, text_pos, out_end);
    }

    // Simple character atom with repetition
    std::vector<size_t> positions;
    positions.push_back(text_pos);
    size_t cur = text_pos;
    int count = 0;
    while ((atom.max_rep < 0 || count < atom.max_rep) && cur < text_.size()) {
      if (!MatchChar(atom, text_[cur])) break;
      ++cur;
      ++count;
      positions.push_back(cur);
    }
    if (count < atom.min_rep) return false;
    if (atom.lazy) {
      for (int i = atom.min_rep; i <= count; ++i) {
        if (MatchSeq(seq, idx + 1, positions[static_cast<size_t>(i)], out_end)) {
          return true;
        }
      }
    } else {
      for (int i = count; i >= atom.min_rep; --i) {
        if (MatchSeq(seq, idx + 1, positions[static_cast<size_t>(i)], out_end)) {
          return true;
        }
      }
    }
    return false;
  }

  bool MatchGroupAtom(const std::vector<Atom>& seq,
                      size_t idx,
                      int rep,
                      size_t text_pos,
                      size_t* out_end) {
    if (++steps_ >= kMaxSteps) return false;
    const Atom& atom = seq[idx];
    if (atom.lazy && rep >= atom.min_rep) {
      if (MatchSeq(seq, idx + 1, text_pos, out_end)) return true;
    }
    if (atom.max_rep < 0 || rep < atom.max_rep) {
      for (const auto& branch : atom.branches) {
        size_t branch_end = text_pos;
        if (MatchSeq(branch, 0, text_pos, &branch_end)) {
          // Guard zero-length infinite loop
          if (branch_end == text_pos && rep >= atom.min_rep) continue;
          if (MatchGroupAtom(seq, idx, rep + 1, branch_end, out_end)) {
            return true;
          }
        }
      }
    }
    if (!atom.lazy && rep >= atom.min_rep) {
      if (MatchSeq(seq, idx + 1, text_pos, out_end)) return true;
    }
    return false;
  }
};

// ============================================================================
// Lightweight Non-Throwing JSON <-> EncodableValue Parser & Serializer
// ============================================================================

void AppendJsonString(std::string* out, const std::string& s) {
  out->push_back('"');
  for (unsigned char c : s) {
    switch (c) {
      case '"':
        out->append("\\\"");
        break;
      case '\\':
        out->append("\\\\");
        break;
      case '\b':
        out->append("\\b");
        break;
      case '\f':
        out->append("\\f");
        break;
      case '\n':
        out->append("\\n");
        break;
      case '\r':
        out->append("\\r");
        break;
      case '\t':
        out->append("\\t");
        break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
          out->append(buf);
        } else {
          out->push_back(static_cast<char>(c));
        }
        break;
    }
  }
  out->push_back('"');
}

void SerializeEncodable(std::string* out, const flutter::EncodableValue& val) {
  if (val.IsNull()) {
    out->append("null");
    return;
  }
  if (const auto* b = std::get_if<bool>(&val)) {
    out->append(*b ? "true" : "false");
    return;
  }
  if (const auto* i32 = std::get_if<int32_t>(&val)) {
    out->append(std::to_string(*i32));
    return;
  }
  if (const auto* i64 = std::get_if<int64_t>(&val)) {
    out->append(std::to_string(*i64));
    return;
  }
  if (const auto* d = std::get_if<double>(&val)) {
    if (std::isfinite(*d)) {
      char buf[64];
      std::snprintf(buf, sizeof(buf), "%.17g", *d);
      out->append(buf);
    } else {
      out->append("null");
    }
    return;
  }
  if (const auto* s = std::get_if<std::string>(&val)) {
    AppendJsonString(out, *s);
    return;
  }
  if (const auto* list = std::get_if<flutter::EncodableList>(&val)) {
    out->push_back('[');
    for (size_t i = 0; i < list->size(); ++i) {
      if (i > 0) out->push_back(',');
      SerializeEncodable(out, (*list)[i]);
    }
    out->push_back(']');
    return;
  }
  if (const auto* map = std::get_if<flutter::EncodableMap>(&val)) {
    out->push_back('{');
    bool first = true;
    for (const auto& kv : *map) {
      const auto* key = std::get_if<std::string>(&kv.first);
      if (!key) continue;
      if (!first) out->push_back(',');
      first = false;
      AppendJsonString(out, *key);
      out->push_back(':');
      SerializeEncodable(out, kv.second);
    }
    out->push_back('}');
    return;
  }
  out->append("null");
}

std::string SerializeJson(const flutter::EncodableValue& val) {
  std::string out;
  out.reserve(256);
  SerializeEncodable(&out, val);
  return out;
}

class JsonParser {
 public:
  static bool Parse(const std::string& json, flutter::EncodableValue* out) {
    JsonParser p(json);
    p.SkipWs();
    if (!p.ParseValue(out, 0)) return false;
    p.SkipWs();
    return p.pos_ == p.src_.size();
  }

 private:
  const std::string& src_;
  size_t pos_ = 0;

  explicit JsonParser(const std::string& s) : src_(s) {}

  void SkipWs() {
    while (pos_ < src_.size()) {
      const char c = src_[pos_];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        ++pos_;
      } else {
        break;
      }
    }
  }

  static void AppendUtf8Codepoint(std::string* out, uint32_t cp) {
    if (cp <= 0x7F) {
      out->push_back(static_cast<char>(cp));
    } else if (cp <= 0x7FF) {
      out->push_back(static_cast<char>(0xC0 | ((cp >> 6) & 0x1F)));
      out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp <= 0xFFFF) {
      out->push_back(static_cast<char>(0xE0 | ((cp >> 12) & 0x0F)));
      out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp <= 0x10FFFF) {
      out->push_back(static_cast<char>(0xF0 | ((cp >> 18) & 0x07)));
      out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
  }

  bool ParseHex4(uint32_t* out) {
    if (pos_ + 4 > src_.size()) return false;
    uint32_t v = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = src_[pos_++];
      v <<= 4;
      if (c >= '0' && c <= '9') {
        v |= static_cast<uint32_t>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        v |= static_cast<uint32_t>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        v |= static_cast<uint32_t>(c - 'A' + 10);
      } else {
        return false;
      }
    }
    *out = v;
    return true;
  }

  bool ParseString(std::string* out) {
    if (pos_ >= src_.size() || src_[pos_] != '"') return false;
    ++pos_;
    out->clear();
    while (pos_ < src_.size()) {
      const char c = src_[pos_++];
      if (c == '"') return true;
      if (c == '\\') {
        if (pos_ >= src_.size()) return false;
        const char esc = src_[pos_++];
        switch (esc) {
          case '"':
          case '\\':
          case '/':
            out->push_back(esc);
            break;
          case 'b':
            out->push_back('\b');
            break;
          case 'f':
            out->push_back('\f');
            break;
          case 'n':
            out->push_back('\n');
            break;
          case 'r':
            out->push_back('\r');
            break;
          case 't':
            out->push_back('\t');
            break;
          case 'u': {
            uint32_t cp = 0;
            if (!ParseHex4(&cp)) return false;
            if (cp >= 0xD800 && cp <= 0xDBFF && pos_ + 6 <= src_.size() &&
                src_[pos_] == '\\' && src_[pos_ + 1] == 'u') {
              pos_ += 2;
              uint32_t low = 0;
              if (!ParseHex4(&low)) return false;
              if (low >= 0xDC00 && low <= 0xDFFF) {
                cp = 0x10000 + (((cp - 0xD800) << 10) | (low - 0xDC00));
              }
            }
            AppendUtf8Codepoint(out, cp);
            break;
          }
          default:
            return false;
        }
      } else {
        out->push_back(c);
      }
    }
    return false;
  }

  bool ParseNumber(flutter::EncodableValue* out) {
    const size_t start = pos_;
    if (src_[pos_] == '-') ++pos_;
    if (pos_ >= src_.size()) return false;
    if (src_[pos_] == '0') {
      ++pos_;
    } else if (src_[pos_] >= '1' && src_[pos_] <= '9') {
      while (pos_ < src_.size() && src_[pos_] >= '0' && src_[pos_] <= '9') {
        ++pos_;
      }
    } else {
      return false;
    }
    bool is_float = false;
    if (pos_ < src_.size() && src_[pos_] == '.') {
      is_float = true;
      ++pos_;
      if (pos_ >= src_.size() || src_[pos_] < '0' || src_[pos_] > '9') {
        return false;
      }
      while (pos_ < src_.size() && src_[pos_] >= '0' && src_[pos_] <= '9') {
        ++pos_;
      }
    }
    if (pos_ < src_.size() && (src_[pos_] == 'e' || src_[pos_] == 'E')) {
      is_float = true;
      ++pos_;
      if (pos_ < src_.size() && (src_[pos_] == '+' || src_[pos_] == '-')) {
        ++pos_;
      }
      if (pos_ >= src_.size() || src_[pos_] < '0' || src_[pos_] > '9') {
        return false;
      }
      while (pos_ < src_.size() && src_[pos_] >= '0' && src_[pos_] <= '9') {
        ++pos_;
      }
    }
    const std::string num_str = src_.substr(start, pos_ - start);
    if (is_float) {
      char* end_ptr = nullptr;
      const double d = std::strtod(num_str.c_str(), &end_ptr);
      if (end_ptr != num_str.c_str() + num_str.size()) return false;
      *out = flutter::EncodableValue(d);
    } else {
      char* end_ptr = nullptr;
      const long long v = std::strtoll(num_str.c_str(), &end_ptr, 10);
      if (end_ptr != num_str.c_str() + num_str.size()) return false;
      if (v >= INT32_MIN && v <= INT32_MAX) {
        *out = flutter::EncodableValue(static_cast<int32_t>(v));
      } else {
        *out = flutter::EncodableValue(static_cast<int64_t>(v));
      }
    }
    return true;
  }

  bool ParseValue(flutter::EncodableValue* out, int depth) {
    if (depth > 64) return false;
    SkipWs();
    if (pos_ >= src_.size()) return false;
    const char c = src_[pos_];
    if (c == '"') {
      std::string s;
      if (!ParseString(&s)) return false;
      *out = flutter::EncodableValue(std::move(s));
      return true;
    }
    if (c == '{') {
      ++pos_;
      SkipWs();
      flutter::EncodableMap map;
      if (pos_ < src_.size() && src_[pos_] == '}') {
        ++pos_;
        *out = flutter::EncodableValue(std::move(map));
        return true;
      }
      while (pos_ < src_.size()) {
        SkipWs();
        std::string key;
        if (!ParseString(&key)) return false;
        SkipWs();
        if (pos_ >= src_.size() || src_[pos_] != ':') return false;
        ++pos_;
        flutter::EncodableValue val;
        if (!ParseValue(&val, depth + 1)) return false;
        map[flutter::EncodableValue(std::move(key))] = std::move(val);
        SkipWs();
        if (pos_ < src_.size() && src_[pos_] == ',') {
          ++pos_;
          continue;
        }
        if (pos_ < src_.size() && src_[pos_] == '}') {
          ++pos_;
          *out = flutter::EncodableValue(std::move(map));
          return true;
        }
        return false;
      }
      return false;
    }
    if (c == '[') {
      ++pos_;
      SkipWs();
      flutter::EncodableList list;
      if (pos_ < src_.size() && src_[pos_] == ']') {
        ++pos_;
        *out = flutter::EncodableValue(std::move(list));
        return true;
      }
      while (pos_ < src_.size()) {
        flutter::EncodableValue item;
        if (!ParseValue(&item, depth + 1)) return false;
        list.push_back(std::move(item));
        SkipWs();
        if (pos_ < src_.size() && src_[pos_] == ',') {
          ++pos_;
          continue;
        }
        if (pos_ < src_.size() && src_[pos_] == ']') {
          ++pos_;
          *out = flutter::EncodableValue(std::move(list));
          return true;
        }
        return false;
      }
      return false;
    }
    if (c == 't' && src_.compare(pos_, 4, "true") == 0) {
      pos_ += 4;
      *out = flutter::EncodableValue(true);
      return true;
    }
    if (c == 'f' && src_.compare(pos_, 5, "false") == 0) {
      pos_ += 5;
      *out = flutter::EncodableValue(false);
      return true;
    }
    if (c == 'n' && src_.compare(pos_, 4, "null") == 0) {
      pos_ += 4;
      *out = flutter::EncodableValue();
      return true;
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
      return ParseNumber(out);
    }
    return false;
  }
};

// ============================================================================
// Self-Contained Evergreen Edge WebView2 COM ABI Definitions (No NuGet Needed)
// ============================================================================

namespace wv2 {

struct EventRegistrationToken {
  int64_t value;
};

enum COREWEBVIEW2_WEB_RESOURCE_CONTEXT {
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL = 0,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT = 1,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_STYLESHEET = 2,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_IMAGE = 3,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_MEDIA = 4,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_FONT = 5,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_SCRIPT = 6,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_XML_HTTP_REQUEST = 7,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_FETCH = 8,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_TEXT_TRACK = 9,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_EVENT_SOURCE = 10,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_WEBSOCKET = 11,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_MANIFEST = 12,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_SIGNED_EXCHANGE = 13,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_PING = 14,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_CSP_VIOLATION_REPORT = 15,
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_OTHER = 16
};

enum COREWEBVIEW2_MOVE_FOCUS_REASON {
  COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC = 0
};

enum COREWEBVIEW2_WEB_ERROR_STATUS {
  COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN = 0
};

enum COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT {
  COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG = 0
};

enum COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND {
  COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY = 0
};

enum COREWEBVIEW2_COOKIE_SAME_SITE_KIND {
  COREWEBVIEW2_COOKIE_SAME_SITE_KIND_NONE = 0
};

struct ICoreWebView2;
struct ICoreWebView2_2;
struct ICoreWebView2_8;
struct ICoreWebView2Controller;
struct ICoreWebView2Environment;
struct ICoreWebView2Environment2;
struct ICoreWebView2Settings;
struct ICoreWebView2Settings2;
struct ICoreWebView2Settings4;
struct ICoreWebView2HttpHeadersCollectionIterator;
struct ICoreWebView2HttpRequestHeaders;
struct ICoreWebView2HttpResponseHeaders;
struct ICoreWebView2WebResourceRequest;
struct ICoreWebView2WebResourceResponse;
struct ICoreWebView2WebResourceRequestedEventArgs;
struct ICoreWebView2NavigationCompletedEventArgs;
struct ICoreWebView2WebMessageReceivedEventArgs;
struct ICoreWebView2NewWindowRequestedEventArgs;
struct ICoreWebView2Cookie;
struct ICoreWebView2CookieList;
struct ICoreWebView2CookieManager;
struct ICoreWebView2Deferral;

// Forward handler interfaces
struct ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
struct ICoreWebView2CreateCoreWebView2ControllerCompletedHandler;
struct ICoreWebView2WebResourceRequestedEventHandler;
struct ICoreWebView2NavigationCompletedEventHandler;
struct ICoreWebView2ExecuteScriptCompletedHandler;
struct ICoreWebView2WebMessageReceivedEventHandler;
struct ICoreWebView2NewWindowRequestedEventHandler;
struct ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler;
struct ICoreWebView2GetCookiesCompletedHandler;

// Exact GUIDs from Microsoft Edge WebView2 SDK
constexpr GUID kIID_ICoreWebView2Environment = {
    0xb96d755e, 0x0319, 0x4e92, {0xa2, 0x96, 0x23, 0x43, 0x6f, 0x46, 0xa1, 0xfc}};
constexpr GUID kIID_ICoreWebView2Environment2 = {
    0x41f3632b, 0x5ef4, 0x404f, {0xad, 0x82, 0x2d, 0x60, 0x6c, 0x5a, 0x9a, 0x21}};
constexpr GUID kIID_ICoreWebView2Controller = {
    0x4d00c0d1, 0x9434, 0x4eb6, {0x80, 0x78, 0x86, 0x97, 0xa5, 0x60, 0x33, 0x4f}};
constexpr GUID kIID_ICoreWebView2 = {
    0x76eceacb, 0x0462, 0x4d94, {0xac, 0x83, 0x42, 0x3a, 0x67, 0x93, 0x77, 0x5e}};
constexpr GUID kIID_ICoreWebView2_2 = {
    0x9e8f0cf8, 0xe670, 0x4b5e, {0xb2, 0xbc, 0x73, 0xe0, 0x61, 0xe3, 0x18, 0x4c}};
constexpr GUID kIID_ICoreWebView2_8 = {
    0xe9632730, 0x6e1e, 0x43ab, {0xb7, 0xb8, 0x7b, 0x2c, 0x9e, 0x62, 0xe0, 0x94}};
constexpr GUID kIID_ICoreWebView2Settings2 = {
    0xee9a0f68, 0xf46c, 0x4e32, {0xac, 0x23, 0xef, 0x8c, 0xac, 0x22, 0x4d, 0x2a}};
constexpr GUID kIID_ICoreWebView2Settings4 = {
    0xcb56846c, 0x4168, 0x4d53, {0xb0, 0x4f, 0x03, 0xb6, 0xd6, 0x79, 0x6f, 0xf2}};
constexpr GUID kIID_ICoreWebView2CreateEnvironmentCompleted = {
    0x4e8a3389, 0xc9d8, 0x4bd2, {0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d}};
constexpr GUID kIID_ICoreWebView2CreateControllerCompleted = {
    0x6c4819f3, 0xc9b7, 0x4260, {0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c}};
constexpr GUID kIID_ICoreWebView2WebResourceRequested = {
    0xab00b74c, 0x15f1, 0x4646, {0x80, 0xe8, 0xe7, 0x63, 0x41, 0xd2, 0x5d, 0x71}};
constexpr GUID kIID_ICoreWebView2NavigationCompleted = {
    0xd33a35bf, 0x1c49, 0x4f98, {0x93, 0xab, 0x00, 0x6e, 0x05, 0x33, 0xfe, 0x1c}};
constexpr GUID kIID_ICoreWebView2ExecuteScriptCompleted = {
    0x49511172, 0xcc67, 0x4bca, {0x99, 0x23, 0x13, 0x71, 0x12, 0xf4, 0xc4, 0xcc}};
constexpr GUID kIID_ICoreWebView2WebMessageReceived = {
    0x57213f19, 0x00e6, 0x49fa, {0x8e, 0x07, 0x89, 0x8e, 0xa0, 0x1e, 0xcb, 0xd2}};
constexpr GUID kIID_ICoreWebView2NewWindowRequested = {
    0xd4c185fe, 0xc81c, 0x4989, {0x97, 0xaf, 0x2d, 0x3f, 0xa7, 0xab, 0x56, 0x51}};
constexpr GUID kIID_ICoreWebView2GetCookiesCompleted = {
    0x5a4f5069, 0x5c15, 0x47c3, {0x86, 0x46, 0xf4, 0xde, 0x1c, 0x11, 0x66, 0x70}};

struct ICoreWebView2Settings : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_IsScriptEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsScriptEnabled(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsWebMessageEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsWebMessageEnabled(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_AreDefaultScriptDialogsEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_AreDefaultScriptDialogsEnabled(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsStatusBarEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsStatusBarEnabled(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_AreDevToolsEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_AreDevToolsEnabled(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_AreDefaultContextMenusEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_AreDefaultContextMenusEnabled(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_AreHostObjectsAllowed(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_AreHostObjectsAllowed(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsZoomControlEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsZoomControlEnabled(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsBuiltInErrorPageEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsBuiltInErrorPageEnabled(BOOL v) = 0;
};

struct ICoreWebView2Settings2 : public ICoreWebView2Settings {
  virtual HRESULT STDMETHODCALLTYPE get_UserAgent(LPWSTR* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_UserAgent(LPCWSTR value) = 0;
};

struct ICoreWebView2Settings3 : public ICoreWebView2Settings2 {
  virtual HRESULT STDMETHODCALLTYPE get_AreBrowserAcceleratorKeysEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_AreBrowserAcceleratorKeysEnabled(BOOL v) = 0;
};

struct ICoreWebView2Settings4 : public ICoreWebView2Settings3 {
  virtual HRESULT STDMETHODCALLTYPE get_IsPasswordAutosaveEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsPasswordAutosaveEnabled(BOOL v) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsGeneralAutofillEnabled(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsGeneralAutofillEnabled(BOOL v) = 0;
};

struct ICoreWebView2HttpHeadersCollectionIterator : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE GetCurrentHeader(LPWSTR* name, LPWSTR* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_HasCurrentHeader(BOOL* hasCurrent) = 0;
  virtual HRESULT STDMETHODCALLTYPE MoveNext(BOOL* hasNext) = 0;
};

struct ICoreWebView2HttpRequestHeaders : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE GetHeader(LPCWSTR name, LPWSTR* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetHeaders(
      LPCWSTR name, ICoreWebView2HttpHeadersCollectionIterator** value) = 0;
  virtual HRESULT STDMETHODCALLTYPE Contains(LPCWSTR name, BOOL* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetHeader(LPCWSTR name, LPCWSTR value) = 0;
  virtual HRESULT STDMETHODCALLTYPE RemoveHeader(LPCWSTR name) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetIterator(
      ICoreWebView2HttpHeadersCollectionIterator** value) = 0;
};

struct ICoreWebView2WebResourceRequest : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_Uri(LPWSTR* uri) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Uri(LPCWSTR uri) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Method(LPWSTR* method) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Method(LPCWSTR method) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Content(IStream** content) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Content(IStream* content) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Headers(
      ICoreWebView2HttpRequestHeaders** headers) = 0;
};

struct ICoreWebView2WebResourceResponse : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_Content(IStream** content) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Content(IStream* content) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Headers(
      ICoreWebView2HttpResponseHeaders** headers) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_StatusCode(int* statusCode) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_StatusCode(int statusCode) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_ReasonPhrase(LPWSTR* reasonPhrase) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_ReasonPhrase(LPCWSTR reasonPhrase) = 0;
};

struct ICoreWebView2WebResourceRequestedEventArgs : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_Request(
      ICoreWebView2WebResourceRequest** request) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Response(
      ICoreWebView2WebResourceResponse** response) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Response(
      ICoreWebView2WebResourceResponse* response) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetDeferral(
      ICoreWebView2Deferral** deferral) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_ResourceContext(
      COREWEBVIEW2_WEB_RESOURCE_CONTEXT* context) = 0;
};

struct ICoreWebView2NavigationCompletedEventArgs : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_IsSuccess(BOOL* isSuccess) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_WebErrorStatus(
      COREWEBVIEW2_WEB_ERROR_STATUS* webErrorStatus) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_NavigationId(UINT64* navigationId) = 0;
};

struct ICoreWebView2WebMessageReceivedEventArgs : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_Source(LPWSTR* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_WebMessageAsJson(LPWSTR* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE TryGetWebMessageAsString(LPWSTR* value) = 0;
};

struct ICoreWebView2NewWindowRequestedEventArgs : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_Uri(LPWSTR* uri) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_NewWindow(ICoreWebView2* newWindow) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_NewWindow(ICoreWebView2** newWindow) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Handled(BOOL handled) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Handled(BOOL* handled) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsUserInitiated(BOOL* isUserInitiated) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetDeferral(ICoreWebView2Deferral** d) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_WindowFeatures(IUnknown** value) = 0;
};

struct ICoreWebView2Cookie : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_Name(LPWSTR* name) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Value(LPWSTR* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Value(LPCWSTR value) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Domain(LPWSTR* domain) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Path(LPWSTR* path) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Expires(double* expires) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Expires(double expires) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsHttpOnly(BOOL* isHttpOnly) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsHttpOnly(BOOL isHttpOnly) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_SameSite(
      COREWEBVIEW2_COOKIE_SAME_SITE_KIND* sameSite) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_SameSite(
      COREWEBVIEW2_COOKIE_SAME_SITE_KIND sameSite) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsSecure(BOOL* isSecure) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsSecure(BOOL isSecure) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsSession(BOOL* isSession) = 0;
};

struct ICoreWebView2CookieList : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_Count(UINT32* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetValueAtIndex(
      UINT32 index, ICoreWebView2Cookie** value) = 0;
};

struct ICoreWebView2CookieManager : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE CreateCookie(
      LPCWSTR name, LPCWSTR value, LPCWSTR domain, LPCWSTR path,
      ICoreWebView2Cookie** cookie) = 0;
  virtual HRESULT STDMETHODCALLTYPE CopyCookie(
      ICoreWebView2Cookie* cookieParam, ICoreWebView2Cookie** cookie) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetCookies(
      LPCWSTR uri, ICoreWebView2GetCookiesCompletedHandler* handler) = 0;
  virtual HRESULT STDMETHODCALLTYPE AddOrUpdateCookie(
      ICoreWebView2Cookie* cookie) = 0;
  virtual HRESULT STDMETHODCALLTYPE DeleteCookie(ICoreWebView2Cookie* cookie) = 0;
  virtual HRESULT STDMETHODCALLTYPE DeleteCookies(LPCWSTR name, LPCWSTR uri) = 0;
  virtual HRESULT STDMETHODCALLTYPE DeleteCookiesWithDomainAndPath(
      LPCWSTR name, LPCWSTR domain, LPCWSTR path) = 0;
  virtual HRESULT STDMETHODCALLTYPE DeleteAllCookies() = 0;
};

struct ICoreWebView2 : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_Settings(ICoreWebView2Settings** s) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Source(LPWSTR* uri) = 0;
  virtual HRESULT STDMETHODCALLTYPE Navigate(LPCWSTR uri) = 0;
  virtual HRESULT STDMETHODCALLTYPE NavigateToString(LPCWSTR htmlContent) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_NavigationStarting(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_NavigationStarting(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_ContentLoading(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_ContentLoading(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_SourceChanged(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_SourceChanged(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_HistoryChanged(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_HistoryChanged(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_NavigationCompleted(
      ICoreWebView2NavigationCompletedEventHandler* handler,
      EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_NavigationCompleted(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_FrameNavigationStarting(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_FrameNavigationStarting(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_FrameNavigationCompleted(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_FrameNavigationCompleted(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_ScriptDialogOpening(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_ScriptDialogOpening(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_PermissionRequested(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_PermissionRequested(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_ProcessFailed(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_ProcessFailed(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE AddScriptToExecuteOnDocumentCreated(
      LPCWSTR javaScript,
      ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler* handler) = 0;
  virtual HRESULT STDMETHODCALLTYPE RemoveScriptToExecuteOnDocumentCreated(
      LPCWSTR id) = 0;
  virtual HRESULT STDMETHODCALLTYPE ExecuteScript(
      LPCWSTR javaScript,
      ICoreWebView2ExecuteScriptCompletedHandler* handler) = 0;
  virtual HRESULT STDMETHODCALLTYPE CapturePreview(
      COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT imageFormat,
      IStream* imageStream, IUnknown* handler) = 0;
  virtual HRESULT STDMETHODCALLTYPE Reload() = 0;
  virtual HRESULT STDMETHODCALLTYPE PostWebMessageAsJson(
      LPCWSTR webMessageAsJson) = 0;
  virtual HRESULT STDMETHODCALLTYPE PostWebMessageAsString(
      LPCWSTR webMessageAsString) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_WebMessageReceived(
      ICoreWebView2WebMessageReceivedEventHandler* handler,
      EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_WebMessageReceived(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE CallDevToolsProtocolMethod(
      LPCWSTR methodName, LPCWSTR parametersAsJson, IUnknown* handler) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_BrowserProcessId(UINT32* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_CanGoBack(BOOL* canGoBack) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_CanGoForward(BOOL* canGoForward) = 0;
  virtual HRESULT STDMETHODCALLTYPE GoBack() = 0;
  virtual HRESULT STDMETHODCALLTYPE GoForward() = 0;
  virtual HRESULT STDMETHODCALLTYPE GetDevToolsProtocolEventReceiver(
      LPCWSTR eventName, IUnknown** receiver) = 0;
  virtual HRESULT STDMETHODCALLTYPE Stop() = 0;
  virtual HRESULT STDMETHODCALLTYPE add_NewWindowRequested(
      ICoreWebView2NewWindowRequestedEventHandler* handler,
      EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_NewWindowRequested(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_DocumentTitleChanged(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_DocumentTitleChanged(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_DocumentTitle(LPWSTR* title) = 0;
  virtual HRESULT STDMETHODCALLTYPE AddHostObjectToScript(
      LPCWSTR name, VARIANT* object) = 0;
  virtual HRESULT STDMETHODCALLTYPE RemoveHostObjectFromScript(LPCWSTR name) = 0;
  virtual HRESULT STDMETHODCALLTYPE OpenDevToolsWindow() = 0;
  virtual HRESULT STDMETHODCALLTYPE add_ContainsFullScreenElementChanged(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_ContainsFullScreenElementChanged(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_ContainsFullScreenElement(BOOL* v) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_WebResourceRequested(
      ICoreWebView2WebResourceRequestedEventHandler* handler,
      EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_WebResourceRequested(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE AddWebResourceRequestedFilter(
      LPCWSTR uri, COREWEBVIEW2_WEB_RESOURCE_CONTEXT resourceContext) = 0;
  virtual HRESULT STDMETHODCALLTYPE RemoveWebResourceRequestedFilter(
      LPCWSTR uri, COREWEBVIEW2_WEB_RESOURCE_CONTEXT resourceContext) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_WindowCloseRequested(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_WindowCloseRequested(
      EventRegistrationToken token) = 0;
};

struct ICoreWebView2_2 : public ICoreWebView2 {
  virtual HRESULT STDMETHODCALLTYPE add_WebResourceResponseReceived(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_WebResourceResponseReceived(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE NavigateWithWebResourceRequest(
      ICoreWebView2WebResourceRequest* request) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_DOMContentLoaded(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_DOMContentLoaded(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_CookieManager(
      ICoreWebView2CookieManager** cookieManager) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Environment(
      ICoreWebView2Environment** environment) = 0;
};

struct ICoreWebView2_3 : public ICoreWebView2_2 {
  virtual HRESULT STDMETHODCALLTYPE TrySuspend(IUnknown* handler) = 0;
  virtual HRESULT STDMETHODCALLTYPE Resume() = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsSuspended(BOOL* isSuspended) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetVirtualHostNameToFolderMapping(
      LPCWSTR hostName, LPCWSTR folderPath,
      COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND accessKind) = 0;
  virtual HRESULT STDMETHODCALLTYPE ClearVirtualHostNameToFolderMapping(
      LPCWSTR hostName) = 0;
};

struct ICoreWebView2_4 : public ICoreWebView2_3 {
  virtual HRESULT STDMETHODCALLTYPE add_FrameCreated(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_FrameCreated(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_DownloadStarting(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_DownloadStarting(
      EventRegistrationToken token) = 0;
};

struct ICoreWebView2_5 : public ICoreWebView2_4 {
  virtual HRESULT STDMETHODCALLTYPE add_ClientCertificateRequested(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_ClientCertificateRequested(
      EventRegistrationToken token) = 0;
};

struct ICoreWebView2_6 : public ICoreWebView2_5 {
  virtual HRESULT STDMETHODCALLTYPE OpenTaskManagerWindow() = 0;
};

struct ICoreWebView2_7 : public ICoreWebView2_6 {
  virtual HRESULT STDMETHODCALLTYPE PrintToPdf(
      LPCWSTR resultFilePath, IUnknown* printSettings, IUnknown* handler) = 0;
};

struct ICoreWebView2_8 : public ICoreWebView2_7 {
  virtual HRESULT STDMETHODCALLTYPE add_IsMutedChanged(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_IsMutedChanged(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsMuted(BOOL* value) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsMuted(BOOL value) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_IsDocumentPlayingAudioChanged(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_IsDocumentPlayingAudioChanged(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_IsDocumentPlayingAudio(BOOL* value) = 0;
};

struct ICoreWebView2Controller : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE get_IsVisible(BOOL* isVisible) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_IsVisible(BOOL isVisible) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_Bounds(RECT* bounds) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_Bounds(RECT bounds) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_ZoomFactor(double* zoomFactor) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_ZoomFactor(double zoomFactor) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_ZoomFactorChanged(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_ZoomFactorChanged(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetBoundsAndZoomFactor(
      RECT bounds, double zoomFactor) = 0;
  virtual HRESULT STDMETHODCALLTYPE MoveFocus(
      COREWEBVIEW2_MOVE_FOCUS_REASON reason) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_MoveFocusRequested(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_MoveFocusRequested(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_GotFocus(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_GotFocus(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_LostFocus(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_LostFocus(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_AcceleratorKeyPressed(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_AcceleratorKeyPressed(
      EventRegistrationToken token) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_ParentWindow(HWND* parentWindow) = 0;
  virtual HRESULT STDMETHODCALLTYPE put_ParentWindow(HWND parentWindow) = 0;
  virtual HRESULT STDMETHODCALLTYPE NotifyParentWindowPositionChanged() = 0;
  virtual HRESULT STDMETHODCALLTYPE Close() = 0;
  virtual HRESULT STDMETHODCALLTYPE get_CoreWebView2(
      ICoreWebView2** coreWebView2) = 0;
};

struct ICoreWebView2Environment : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE CreateCoreWebView2Controller(
      HWND parentWindow,
      ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* handler) = 0;
  virtual HRESULT STDMETHODCALLTYPE CreateWebResourceResponse(
      IStream* content, int statusCode, LPCWSTR reasonPhrase, LPCWSTR headers,
      ICoreWebView2WebResourceResponse** response) = 0;
  virtual HRESULT STDMETHODCALLTYPE get_BrowserVersionString(
      LPWSTR* versionInfo) = 0;
  virtual HRESULT STDMETHODCALLTYPE add_NewBrowserVersionAvailable(
      IUnknown* handler, EventRegistrationToken* token) = 0;
  virtual HRESULT STDMETHODCALLTYPE remove_NewBrowserVersionAvailable(
      EventRegistrationToken token) = 0;
};

struct ICoreWebView2Environment2 : public ICoreWebView2Environment {
  virtual HRESULT STDMETHODCALLTYPE CreateWebResourceRequest(
      LPCWSTR uri, LPCWSTR method, IStream* postData, LPCWSTR headers,
      ICoreWebView2WebResourceRequest** value) = 0;
};

struct ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
    : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(
      HRESULT errorCode, ICoreWebView2Environment* result) = 0;
};

struct ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
    : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(
      HRESULT errorCode, ICoreWebView2Controller* result) = 0;
};

struct ICoreWebView2WebResourceRequestedEventHandler : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(
      ICoreWebView2* sender,
      ICoreWebView2WebResourceRequestedEventArgs* args) = 0;
};

struct ICoreWebView2NavigationCompletedEventHandler : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(
      ICoreWebView2* sender,
      ICoreWebView2NavigationCompletedEventArgs* args) = 0;
};

struct ICoreWebView2ExecuteScriptCompletedHandler : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(HRESULT errorCode,
                                           LPCWSTR result) = 0;
};

struct ICoreWebView2WebMessageReceivedEventHandler : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(
      ICoreWebView2* sender,
      ICoreWebView2WebMessageReceivedEventArgs* args) = 0;
};

struct ICoreWebView2NewWindowRequestedEventHandler : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(
      ICoreWebView2* sender,
      ICoreWebView2NewWindowRequestedEventArgs* args) = 0;
};

struct ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler
    : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(HRESULT errorCode,
                                           LPCWSTR result) = 0;
};

struct ICoreWebView2GetCookiesCompletedHandler : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE Invoke(HRESULT errorCode,
                                           ICoreWebView2CookieList* result) = 0;
};

// Lightweight COM smart pointer (zero ATL/WinRT dependency)
template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ~ComPtr() { Reset(); }
  ComPtr(const ComPtr& other) : ptr_(other.ptr_) {
    if (ptr_) ptr_->AddRef();
  }
  ComPtr(ComPtr&& other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
  ComPtr& operator=(const ComPtr& other) {
    if (this != &other) {
      if (other.ptr_) other.ptr_->AddRef();
      if (ptr_) ptr_->Release();
      ptr_ = other.ptr_;
    }
    return *this;
  }
  ComPtr& operator=(ComPtr&& other) noexcept {
    if (this != &other) {
      if (ptr_) ptr_->Release();
      ptr_ = other.ptr_;
      other.ptr_ = nullptr;
    }
    return *this;
  }
  T* Get() const { return ptr_; }
  T** Put() {
    Reset();
    return &ptr_;
  }
  T* operator->() const { return ptr_; }
  explicit operator bool() const { return ptr_ != nullptr; }
  void Reset() {
    if (ptr_) {
      T* tmp = ptr_;
      ptr_ = nullptr;
      tmp->Release();
    }
  }
  void Attach(T* p) {
    Reset();
    ptr_ = p;
  }

 private:
  T* ptr_ = nullptr;
};

template <typename Interface, typename Fn>
class ComCallback final : public Interface {
 public:
  ComCallback(const GUID& iid, Fn fn) : iid_(iid), fn_(std::move(fn)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppvObject) override {
    if (!ppvObject) return E_POINTER;
    if (::IsEqualIID(riid, IID_IUnknown) || ::IsEqualIID(riid, iid_)) {
      *ppvObject = static_cast<Interface*>(this);
      AddRef();
      return S_OK;
    }
    *ppvObject = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(::InterlockedIncrement(&ref_count_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const LONG next = ::InterlockedDecrement(&ref_count_);
    if (next == 0) {
      delete this;
    }
    return static_cast<ULONG>(next);
  }

  template <typename... Args>
  HRESULT Call(Args&&... args) {
    return fn_(std::forward<Args>(args)...);
  }

 private:
  ~ComCallback() = default;
  GUID iid_;
  Fn fn_;
  LONG ref_count_ = 1;
};

// Concrete Invoke wrappers for 1-arg and 2-arg WebView2 callback interfaces.
template <typename Interface, typename A1, typename A2, typename Fn>
class ComCallback2 final : public Interface {
 public:
  ComCallback2(const GUID& iid, Fn fn) : iid_(iid), fn_(std::move(fn)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppvObject) override {
    if (!ppvObject) return E_POINTER;
    if (::IsEqualIID(riid, IID_IUnknown) || ::IsEqualIID(riid, iid_)) {
      *ppvObject = static_cast<Interface*>(this);
      AddRef();
      return S_OK;
    }
    *ppvObject = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(::InterlockedIncrement(&ref_count_));
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const LONG next = ::InterlockedDecrement(&ref_count_);
    if (next == 0) delete this;
    return static_cast<ULONG>(next);
  }
  HRESULT STDMETHODCALLTYPE Invoke(A1 a1, A2 a2) override {
    return fn_(a1, a2);
  }

 private:
  ~ComCallback2() = default;
  GUID iid_;
  Fn fn_;
  LONG ref_count_ = 1;
};

template <typename Interface, typename A1, typename A2, typename Fn>
ComPtr<Interface> MakeCallback2(const GUID& iid, Fn fn) {
  ComPtr<Interface> out;
  out.Attach(new ComCallback2<Interface, A1, A2, Fn>(iid, std::move(fn)));
  return out;
}

// Minimal read-only in-memory IStream (avoids shlwapi.lib dependency).
class MemoryStream final : public IStream {
 public:
  explicit MemoryStream(std::string data) : data_(std::move(data)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppvObject) override {
    if (!ppvObject) return E_POINTER;
    if (::IsEqualIID(riid, IID_IUnknown) ||
        ::IsEqualIID(riid, IID_ISequentialStream) ||
        ::IsEqualIID(riid, IID_IStream)) {
      *ppvObject = static_cast<IStream*>(this);
      AddRef();
      return S_OK;
    }
    *ppvObject = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(::InterlockedIncrement(&ref_count_));
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const LONG next = ::InterlockedDecrement(&ref_count_);
    if (next == 0) delete this;
    return static_cast<ULONG>(next);
  }
  HRESULT STDMETHODCALLTYPE Read(void* pv, ULONG cb, ULONG* pcbRead) override {
    if (!pv) return STG_E_INVALIDPOINTER;
    const size_t avail = (pos_ < data_.size()) ? (data_.size() - pos_) : 0;
    const size_t to_read = (cb < avail) ? static_cast<size_t>(cb) : avail;
    if (to_read > 0) {
      std::memcpy(pv, data_.data() + pos_, to_read);
      pos_ += to_read;
    }
    if (pcbRead) *pcbRead = static_cast<ULONG>(to_read);
    return (to_read < cb) ? S_FALSE : S_OK;
  }
  HRESULT STDMETHODCALLTYPE Write(const void*, ULONG, ULONG*) override {
    return STG_E_ACCESSDENIED;
  }
  HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER dlibMove,
                                 DWORD dwOrigin,
                                 ULARGE_INTEGER* plibNewPosition) override {
    int64_t next = 0;
    if (dwOrigin == STREAM_SEEK_SET) {
      next = dlibMove.QuadPart;
    } else if (dwOrigin == STREAM_SEEK_CUR) {
      next = static_cast<int64_t>(pos_) + dlibMove.QuadPart;
    } else if (dwOrigin == STREAM_SEEK_END) {
      next = static_cast<int64_t>(data_.size()) + dlibMove.QuadPart;
    } else {
      return STG_E_INVALIDFUNCTION;
    }
    if (next < 0) return STG_E_INVALIDFUNCTION;
    pos_ = static_cast<size_t>(next);
    if (plibNewPosition) {
      plibNewPosition->QuadPart = static_cast<ULONGLONG>(pos_);
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE CopyTo(IStream*,
                                   ULARGE_INTEGER,
                                   ULARGE_INTEGER*,
                                   ULARGE_INTEGER*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE Revert() override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER,
                                       ULARGE_INTEGER,
                                       DWORD) override {
    return STG_E_INVALIDFUNCTION;
  }
  HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER,
                                         ULARGE_INTEGER,
                                         DWORD) override {
    return STG_E_INVALIDFUNCTION;
  }
  HRESULT STDMETHODCALLTYPE Stat(STATSTG* pstatstg, DWORD) override {
    if (!pstatstg) return STG_E_INVALIDPOINTER;
    std::memset(pstatstg, 0, sizeof(*pstatstg));
    pstatstg->type = STGTY_STREAM;
    pstatstg->cbSize.QuadPart = static_cast<ULONGLONG>(data_.size());
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Clone(IStream**) override { return E_NOTIMPL; }

 private:
  ~MemoryStream() = default;
  std::string data_;
  size_t pos_ = 0;
  LONG ref_count_ = 1;
};

}  // namespace wv2

// ============================================================================
// Evergreen Edge WebView2 Runtime Discovery & Environment Loader
// ============================================================================

struct RuntimeInfo {
  bool available = false;
  std::wstring version;
  std::wstring browser_folder;  // e.g. ...\Application\<pv>
  std::wstring ebwebview_dir;   // e.g. ...\Application\<pv>\EBWebView
  std::wstring dll_path;        // e.g. ...\EBWebView\x64\EmbeddedBrowserWebView.dll
  std::wstring loader_path;     // optional WebView2Loader.dll if present
  std::string reason;
};

bool FileExistsW(const std::wstring& path) {
  const DWORD attrs = ::GetFileAttributesW(path.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES &&
         (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

bool DirExistsW(const std::wstring& path) {
  const DWORD attrs = ::GetFileAttributesW(path.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES &&
         (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool EnsureDirectoryRecursiveW(const std::wstring& path) {
  if (path.empty()) return false;
  if (DirExistsW(path)) return true;
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos && slash > 0) {
    // Handle drive root like "C:"
    if (!(slash == 2 && path[1] == L':')) {
      EnsureDirectoryRecursiveW(path.substr(0, slash));
    }
  }
  return ::CreateDirectoryW(path.c_str(), nullptr) != FALSE ||
         ::GetLastError() == ERROR_ALREADY_EXISTS;
}

std::wstring GetWebView2UserDataRoot() {
  std::wstring base;
  PWSTR known = nullptr;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                       &known)) &&
      known != nullptr) {
    base.assign(known);
    ::CoTaskMemFree(known);
  } else {
    wchar_t buf[MAX_PATH] = {};
    const DWORD len = ::GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
      base.assign(buf, len);
    }
  }
  if (base.empty()) {
    wchar_t tmp[MAX_PATH] = {};
    const DWORD len = ::GetTempPathW(MAX_PATH, tmp);
    if (len > 0 && len < MAX_PATH) {
      base.assign(tmp, len);
    }
  }
  while (!base.empty() && (base.back() == L'\\' || base.back() == L'/')) {
    base.pop_back();
  }
  std::wstring dir = base + L"\\MarcoMovie\\cache\\webview2";
  EnsureDirectoryRecursiveW(dir);
  return dir;
}

bool ReadRegString(HKEY root,
                   const wchar_t* subkey,
                   const wchar_t* value_name,
                   std::wstring* out) {
  HKEY hkey = nullptr;
  if (::RegOpenKeyExW(root, subkey, 0, KEY_READ | KEY_WOW64_32KEY, &hkey) !=
      ERROR_SUCCESS) {
    if (::RegOpenKeyExW(root, subkey, 0, KEY_READ, &hkey) != ERROR_SUCCESS) {
      return false;
    }
  }
  DWORD type = 0;
  DWORD size = 0;
  LONG rc =
      ::RegQueryValueExW(hkey, value_name, nullptr, &type, nullptr, &size);
  if (rc != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) ||
      size < sizeof(wchar_t)) {
    ::RegCloseKey(hkey);
    return false;
  }
  std::wstring buf(size / sizeof(wchar_t), L'\0');
  rc = ::RegQueryValueExW(hkey, value_name, nullptr, &type,
                          reinterpret_cast<LPBYTE>(buf.data()), &size);
  ::RegCloseKey(hkey);
  if (rc != ERROR_SUCCESS) return false;
  while (!buf.empty() && buf.back() == L'\0') {
    buf.pop_back();
  }
  *out = std::move(buf);
  return !out->empty();
}

const wchar_t* WebView2ArchFolder() {
#if defined(_M_ARM64)
  return L"arm64";
#elif defined(_M_IX86)
  return L"x86";
#else
  return L"x64";
#endif
}

bool TryPopulateFromVersionDir(const std::wstring& app_root,
                               const std::wstring& version,
                               RuntimeInfo* info) {
  if (app_root.empty() || version.empty()) return false;
  std::wstring root = app_root;
  while (!root.empty() && (root.back() == L'\\' || root.back() == L'/')) {
    root.pop_back();
  }
  const std::wstring ver_dir = root + L"\\" + version;
  const std::wstring ebwebview = ver_dir + L"\\EBWebView";
  const std::wstring dll =
      ebwebview + L"\\" + WebView2ArchFolder() + L"\\EmbeddedBrowserWebView.dll";
  const std::wstring exe = ver_dir + L"\\msedgewebview2.exe";
  if (!FileExistsW(dll) || !FileExistsW(exe)) return false;
  info->available = true;
  info->version = version;
  info->browser_folder = ver_dir;
  info->ebwebview_dir = ebwebview;
  info->dll_path = dll;
  info->reason = "ok";
  return true;
}

RuntimeInfo ProbeWebView2Runtime() {
  RuntimeInfo info;
  static const wchar_t* kClientKey =
      L"SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\"
      L"{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
  static const wchar_t* kWowClientKey =
      L"SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\"
      L"{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

  struct RegCandidate {
    HKEY root;
    const wchar_t* key;
  };
  const RegCandidate candidates[] = {
      {HKEY_LOCAL_MACHINE, kWowClientKey},
      {HKEY_LOCAL_MACHINE, kClientKey},
      {HKEY_CURRENT_USER, kClientKey},
  };

  for (const auto& c : candidates) {
    std::wstring pv;
    std::wstring loc;
    if (ReadRegString(c.root, c.key, L"pv", &pv) &&
        ReadRegString(c.root, c.key, L"location", &loc)) {
      if (TryPopulateFromVersionDir(loc, pv, &info)) {
        return info;
      }
    }
    if (!pv.empty() && loc.empty()) {
      wchar_t pf86[MAX_PATH] = {};
      if (::GetEnvironmentVariableW(L"ProgramFiles(x86)", pf86, MAX_PATH) > 0) {
        std::wstring default_loc =
            std::wstring(pf86) + L"\\Microsoft\\EdgeWebView\\Application";
        if (TryPopulateFromVersionDir(default_loc, pv, &info)) {
          return info;
        }
      }
    }
  }

  // Fallback scan in %ProgramFiles(x86)%\Microsoft\EdgeWebView\Application
  wchar_t pf86[MAX_PATH] = {};
  if (::GetEnvironmentVariableW(L"ProgramFiles(x86)", pf86, MAX_PATH) > 0) {
    const std::wstring app_dir =
        std::wstring(pf86) + L"\\Microsoft\\EdgeWebView\\Application";
    WIN32_FIND_DATAW fd{};
    HANDLE find = ::FindFirstFileW((app_dir + L"\\*").c_str(), &fd);
    if (find != INVALID_HANDLE_VALUE) {
      std::vector<std::wstring> versions;
      do {
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
            fd.cFileName[0] >= L'0' && fd.cFileName[0] <= L'9') {
          versions.emplace_back(fd.cFileName);
        }
      } while (::FindNextFileW(find, &fd));
      ::FindClose(find);
      std::sort(versions.rbegin(), versions.rend());
      for (const auto& v : versions) {
        if (TryPopulateFromVersionDir(app_dir, v, &info)) {
          return info;
        }
      }
    }
  }

  // Last fallback: optional WebView2Loader.dll alongside application executable.
  wchar_t exe_path[MAX_PATH] = {};
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) > 0) {
    std::wstring exe_dir(exe_path);
    const size_t slash = exe_dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
      const std::wstring loader =
          exe_dir.substr(0, slash + 1) + L"WebView2Loader.dll";
      if (FileExistsW(loader)) {
        info.loader_path = loader;
        info.available = true;
        info.reason = "loader_only";
        return info;
      }
    }
  }

  info.available = false;
  info.reason = "webview2_runtime_not_found";
  return info;
}

// Function pointers matching Evergreen EmbeddedBrowserWebView.dll and WebView2Loader.dll
using FnCreateCoreWebView2EnvironmentWithOptions = HRESULT(STDAPICALLTYPE*)(
    PCWSTR browserExecutableFolder,
    PCWSTR userDataFolder,
    IUnknown* environmentOptions,
    wv2::ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* handler);

using FnCreateWebViewEnvironmentWithOptionsInternal = HRESULT(STDAPICALLTYPE*)(
    bool checkRunningBrowserProcesses,
    int runtimeType,
    PCWSTR userDataFolder,
    IUnknown* environmentOptions,
    wv2::ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* handler);

class RuntimeLoader {
 public:
  RuntimeLoader() : info_(ProbeWebView2Runtime()) {}
  ~RuntimeLoader() {
    if (embedded_module_) {
      ::FreeLibrary(embedded_module_);
      embedded_module_ = nullptr;
    }
    if (loader_module_) {
      ::FreeLibrary(loader_module_);
      loader_module_ = nullptr;
    }
  }

  const RuntimeInfo& info() const { return info_; }

  bool EnsureLoaded() {
    if (!info_.available) return false;
    if (create_internal_ || create_loader_) return true;

    if (!info_.dll_path.empty()) {
      embedded_module_ = ::LoadLibraryExW(
          info_.dll_path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
      if (embedded_module_) {
        create_internal_ =
            reinterpret_cast<FnCreateWebViewEnvironmentWithOptionsInternal>(
                ::GetProcAddress(embedded_module_,
                                 "CreateWebViewEnvironmentWithOptionsInternal"));
        if (create_internal_) {
          return true;
        }
        ::FreeLibrary(embedded_module_);
        embedded_module_ = nullptr;
      }
    }

    if (!info_.loader_path.empty()) {
      loader_module_ = ::LoadLibraryW(info_.loader_path.c_str());
      if (loader_module_) {
        create_loader_ =
            reinterpret_cast<FnCreateCoreWebView2EnvironmentWithOptions>(
                ::GetProcAddress(loader_module_,
                                 "CreateCoreWebView2EnvironmentWithOptions"));
        if (create_loader_) {
          return true;
        }
        ::FreeLibrary(loader_module_);
        loader_module_ = nullptr;
      }
    }

    info_.available = false;
    info_.reason = "webview2_entrypoint_load_failed";
    return false;
  }

  HRESULT CreateEnvironment(
      const std::wstring& user_data_dir,
      wv2::ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*
          handler) {
    if (!EnsureLoaded() || !handler) return E_FAIL;
    if (create_internal_) {
      // runtimeType = 0 (Installed/Evergreen), checkRunningBrowserProcesses = true
      return create_internal_(true, 0, user_data_dir.c_str(), nullptr, handler);
    }
    if (create_loader_) {
      return create_loader_(nullptr, user_data_dir.c_str(), nullptr, handler);
    }
    return E_FAIL;
  }

 private:
  RuntimeInfo info_;
  HMODULE embedded_module_ = nullptr;
  HMODULE loader_module_ = nullptr;
  FnCreateWebViewEnvironmentWithOptionsInternal create_internal_ = nullptr;
  FnCreateCoreWebView2EnvironmentWithOptions create_loader_ = nullptr;
};

// ============================================================================
// Hidden Win32 Helper Window Registration
// ============================================================================

const wchar_t* kHiddenHostClassName = L"MarcoMovieWebView2HiddenHost";

LRESULT CALLBACK HiddenHostWndProc(HWND hwnd,
                                   UINT msg,
                                   WPARAM wparam,
                                   LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return TRUE;
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

bool EnsureHiddenClassRegistered() {
  HINSTANCE hinst = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW existing{};
  existing.cbSize = sizeof(existing);
  if (::GetClassInfoExW(hinst, kHiddenHostClassName, &existing)) {
    return true;
  }
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = HiddenHostWndProc;
  wc.hInstance = hinst;
  wc.lpszClassName = kHiddenHostClassName;
  return ::RegisterClassExW(&wc) != 0 ||
         ::GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

HWND CreateHiddenHostWindow() {
  if (!EnsureHiddenClassRegistered()) return nullptr;
  // Unowned offscreen WS_POPUP with WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE:
  // never steals focus, never appears in taskbar/Alt-Tab, and gives WebView2
  // a real HWND + 1280x720 viewport for responsive player/DOM scripts.
  return ::CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kHiddenHostClassName, L"", WS_POPUP,
      -32000, -32000, 1280, 720, nullptr, nullptr, ::GetModuleHandleW(nullptr),
      nullptr);
}

// ============================================================================
// Sniffer Rule / Ad Blocking / Media Classification
// ============================================================================

struct SniffRuleSpec {
  std::vector<std::string> hosts;
  std::vector<std::string> regexes;
  std::vector<std::string> excludes;
};

bool MatchesPattern(const std::string& pattern, const std::string& url) {
  const std::string trimmed = TrimAscii(pattern);
  if (trimmed.empty()) return false;
  const bool looks_regex =
      trimmed.find(".*") != std::string::npos ||
      trimmed.find("\\.") != std::string::npos ||
      trimmed.find('[') != std::string::npos ||
      trimmed.find('(') != std::string::npos ||
      trimmed.find('|') != std::string::npos ||
      trimmed.find('^') != std::string::npos ||
      trimmed.find('$') != std::string::npos ||
      trimmed.find('+') != std::string::npos ||
      trimmed.find('?') != std::string::npos;
  if (looks_regex) {
    return SimpleRegex::Search(trimmed, url);
  }
  return ContainsInsensitive(url, trimmed);
}

bool IsBuiltInTrackerOrAd(const std::string& url) {
  static const char* kTrackerHosts[] = {
      "doubleclick.net",
      "googlesyndication.com",
      "google-analytics.com",
      "googletagmanager.com",
      "adservice.google.",
      "pagead2.googlesyndication.com",
      "hm.baidu.com",
      "pos.baidu.com",
      "cpro.baidu.com",
      "cnzz.com",
      "umeng.com",
      "51.la",
      "taboola.com",
      "outbrain.com",
      "adnxs.com",
      "criteo.com",
      "pubmatic.com",
      "scorecardresearch.com",
  };
  const std::string host = ExtractHostLower(url);
  for (const char* tracker : kTrackerHosts) {
    if (HostMatchesRule(host, tracker) ||
        ContainsInsensitive(url, tracker)) {
      return true;
    }
  }
  const std::string lower = ToLowerAscii(url);
  if (lower.find("/ads/") != std::string::npos ||
      lower.find("/adserver") != std::string::npos) {
    return true;
  }
  return false;
}

bool HasExtensionInSet(const std::string& path_lower,
                       const char* const* exts,
                       size_t count) {
  for (size_t i = 0; i < count; ++i) {
    const std::string ext = exts[i];
    if (path_lower.size() >= ext.size() &&
        path_lower.compare(path_lower.size() - ext.size(), ext.size(), ext) ==
            0) {
      return true;
    }
  }
  return false;
}

std::string ExtractPathLower(const std::string& url) {
  const size_t scheme_pos = url.find("://");
  size_t start = 0;
  if (scheme_pos != std::string::npos) {
    const size_t slash = url.find('/', scheme_pos + 3);
    if (slash == std::string::npos) return std::string();
    start = slash;
  }
  const size_t end = url.find_first_of("?#", start);
  const std::string path =
      (end == std::string::npos) ? url.substr(start) : url.substr(start, end - start);
  return ToLowerAscii(path);
}

std::string ExtractQueryLower(const std::string& url) {
  const size_t q = url.find('?');
  if (q == std::string::npos) return std::string();
  const size_t h = url.find('#', q + 1);
  return ToLowerAscii((h == std::string::npos) ? url.substr(q + 1)
                                               : url.substr(q + 1, h - q - 1));
}

bool IsStaticNonMediaExtension(const std::string& path_lower) {
  static const char* kStaticExts[] = {
      ".js",   ".mjs",  ".css",  ".png",  ".jpg",  ".jpeg", ".gif",  ".webp",
      ".svg",  ".ico",  ".woff", ".woff2",".ttf",  ".eot",  ".otf",  ".json",
      ".xml",  ".vtt",  ".srt",  ".ass",  ".html", ".htm",  ".shtml",".php",
      ".asp",  ".aspx", ".jsp",
  };
  return HasExtensionInSet(path_lower, kStaticExts,
                           sizeof(kStaticExts) / sizeof(kStaticExts[0]));
}

bool IsStandardMediaStreamUrl(const std::string& url) {
  const std::string trimmed = TrimAscii(url);
  if (trimmed.empty()) return false;
  if (StartsWithInsensitive(trimmed, "blob:") ||
      StartsWithInsensitive(trimmed, "data:") ||
      StartsWithInsensitive(trimmed, "javascript:") ||
      StartsWithInsensitive(trimmed, "about:")) {
    return false;
  }
  if (StartsWithInsensitive(trimmed, "rtmp://") ||
      StartsWithInsensitive(trimmed, "rtsp://")) {
    return true;
  }
  if (!StartsWithInsensitive(trimmed, "http://") &&
      !StartsWithInsensitive(trimmed, "https://")) {
    return false;
  }
  const std::string path_lower = ExtractPathLower(trimmed);
  if (IsStaticNonMediaExtension(path_lower)) {
    return false;
  }
  static const char* kMediaExts[] = {
      ".m3u8", ".m3u", ".mp4", ".flv", ".mpd", ".mkv", ".webm", ".m4v", ".mov",
  };
  if (HasExtensionInSet(path_lower, kMediaExts,
                        sizeof(kMediaExts) / sizeof(kMediaExts[0]))) {
    return true;
  }
  const std::string query_lower = ExtractQueryLower(trimmed);
  if (!query_lower.empty() &&
      SimpleRegex::Search(
          "(?:^|&)(?:type|format|mime)=[^&#]*(?:m3u8|mp4|flv|mpegurl|video)",
          query_lower)) {
    return true;
  }
  return false;
}

// ============================================================================
// Stage-3 Sniffer Session (`marco_movie/web_sniffer` -> `sniffMedia`)
// ============================================================================

constexpr wchar_t kDefaultDesktopUa[] =
    L"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    L"(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0";

constexpr wchar_t kSnifferHookScript[] = LR"JS(
(function() {
  if (window.__marcoWinSnifferInstalled) return;
  window.__marcoWinSnifferInstalled = true;
  function post(url) {
    try {
      if (!url || typeof url !== 'string') return;
      var s = url.trim();
      if (!s || s.indexOf('blob:') === 0 || s.indexOf('data:') === 0 || s.indexOf('javascript:') === 0) return;
      var abs = s;
      try { abs = new URL(s, location.href).href; } catch (_) {}
      if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
        window.chrome.webview.postMessage({
          type: 'media',
          url: abs,
          pageUrl: String(location.href || '')
        });
      }
    } catch (_) {}
  }
  function muteVideos() {
    try {
      var vids = document.querySelectorAll('video, audio');
      for (var i = 0; i < vids.length; i++) {
        vids[i].muted = true;
        vids[i].volume = 0;
        if (vids[i].tagName === 'VIDEO') {
          if (vids[i].currentSrc) post(vids[i].currentSrc);
          if (vids[i].src) post(vids[i].src);
        }
      }
      var sources = document.querySelectorAll('source');
      for (var j = 0; j < sources.length; j++) {
        if (sources[j].src) post(sources[j].src);
      }
    } catch (_) {}
  }
  try {
    var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (desc && desc.set) {
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        configurable: true,
        get: desc.get,
        set: function(v) {
          try { this.muted = true; } catch (_) {}
          post(String(v || ''));
          return desc.set.call(this, v);
        }
      });
    }
  } catch (_) {}
  document.addEventListener('DOMContentLoaded', muteVideos, true);
  setInterval(muteVideos, 350);
})();
)JS";

struct SniffParams {
  std::string url;
  std::map<std::string, std::string> headers;
  int timeout_ms = 12000;
  std::vector<SniffRuleSpec> rules;
  std::vector<std::string> ads;
  std::string click_script;
};

class SniffSession : public std::enable_shared_from_this<SniffSession> {
 public:
  SniffSession(
      uint64_t id,
      SniffParams params,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      std::function<void(uint64_t)> on_finished)
      : id_(id),
        params_(std::move(params)),
        result_(std::move(result)),
        on_finished_(std::move(on_finished)) {
    effective_ua_ = WideToUtf8(kDefaultDesktopUa);
    for (const auto& kv : params_.headers) {
      if (ToLowerAscii(kv.first) == "user-agent" && !TrimAscii(kv.second).empty()) {
        effective_ua_ = TrimAscii(kv.second);
        break;
      }
    }
    page_host_ = ExtractHostLower(params_.url);
    normalized_target_ = StripFragment(params_.url);
  }

  ~SniffSession() { CleanupComAndWindow(); }

  void Start(RuntimeLoader* loader, const std::wstring& user_data_root) {
    hwnd_ = CreateHiddenHostWindow();
    if (!hwnd_) {
      FinishWithNull();
      return;
    }

    const int bounded_ms = std::min(std::max(params_.timeout_ms, 1500), 30000);
    // Use hwnd_ timer directly for timeout so it always fires on UI STA thread.
    ::SetWindowLongPtrW(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    timer_id_ = ::SetTimer(hwnd_, 1, static_cast<UINT>(bounded_ms), TimerProc);
    RegisterActiveTimer(hwnd_, shared_from_this());

    auto self = shared_from_this();
    auto env_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
        HRESULT, wv2::ICoreWebView2Environment*>(
        wv2::kIID_ICoreWebView2CreateEnvironmentCompleted,
        [self](HRESULT hr, wv2::ICoreWebView2Environment* env) -> HRESULT {
          self->OnEnvironmentCreated(hr, env);
          return S_OK;
        });

    const std::wstring sniffer_data_dir = user_data_root + L"\\sniffer";
    EnsureDirectoryRecursiveW(sniffer_data_dir);
    const HRESULT hr =
        loader->CreateEnvironment(sniffer_data_dir, env_cb.Get());
    if (FAILED(hr)) {
      FinishWithNull();
    }
  }

  void ForceCancel() { FinishWithNull(); }

 private:
  uint64_t id_;
  SniffParams params_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result_;
  std::function<void(uint64_t)> on_finished_;
  std::string effective_ua_;
  std::string page_host_;
  std::string normalized_target_;
  HWND hwnd_ = nullptr;
  UINT_PTR timer_id_ = 0;
  bool completed_ = false;
  bool matching_in_progress_ = false;

  wv2::ComPtr<wv2::ICoreWebView2Environment> env_;
  wv2::ComPtr<wv2::ICoreWebView2Controller> controller_;
  wv2::ComPtr<wv2::ICoreWebView2> webview_;
  wv2::EventRegistrationToken web_resource_token_{};
  wv2::EventRegistrationToken nav_completed_token_{};
  wv2::EventRegistrationToken web_message_token_{};
  wv2::EventRegistrationToken new_window_token_{};
  bool has_web_resource_token_ = false;
  bool has_nav_completed_token_ = false;
  bool has_web_message_token_ = false;
  bool has_new_window_token_ = false;

  static std::map<HWND, std::weak_ptr<SniffSession>>& TimerMap() {
    static auto* map = new std::map<HWND, std::weak_ptr<SniffSession>>();
    return *map;
  }

  static void RegisterActiveTimer(HWND hwnd,
                                  const std::shared_ptr<SniffSession>& s) {
    TimerMap()[hwnd] = s;
  }

  static void UnregisterActiveTimer(HWND hwnd) {
    if (hwnd) TimerMap().erase(hwnd);
  }

  static void CALLBACK TimerProc(HWND hwnd, UINT, UINT_PTR, DWORD) {
    auto it = TimerMap().find(hwnd);
    if (it != TimerMap().end()) {
      if (auto s = it->second.lock()) {
        s->FinishWithNull();
      }
    }
  }

  void OnEnvironmentCreated(HRESULT hr, wv2::ICoreWebView2Environment* env) {
    if (completed_ || FAILED(hr) || !env || !hwnd_) {
      FinishWithNull();
      return;
    }
    env->AddRef();
    env_.Attach(env);

    auto self = shared_from_this();
    auto ctrl_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
        HRESULT, wv2::ICoreWebView2Controller*>(
        wv2::kIID_ICoreWebView2CreateControllerCompleted,
        [self](HRESULT chr, wv2::ICoreWebView2Controller* ctrl) -> HRESULT {
          self->OnControllerCreated(chr, ctrl);
          return S_OK;
        });
    if (FAILED(env_->CreateCoreWebView2Controller(hwnd_, ctrl_cb.Get()))) {
      FinishWithNull();
    }
  }

  void OnControllerCreated(HRESULT hr, wv2::ICoreWebView2Controller* ctrl) {
    if (completed_ || FAILED(hr) || !ctrl) {
      FinishWithNull();
      return;
    }
    ctrl->AddRef();
    controller_.Attach(ctrl);

    controller_->put_IsVisible(FALSE);
    RECT bounds{0, 0, 1280, 720};
    controller_->put_Bounds(bounds);

    if (FAILED(controller_->get_CoreWebView2(webview_.Put())) || !webview_) {
      FinishWithNull();
      return;
    }

    // Mute audio immediately via ICoreWebView2_8::put_IsMuted(TRUE).
    wv2::ComPtr<wv2::ICoreWebView2_8> wv8;
    if (SUCCEEDED(webview_->QueryInterface(
            wv2::kIID_ICoreWebView2_8,
            reinterpret_cast<void**>(wv8.Put()))) &&
        wv8) {
      wv8->put_IsMuted(TRUE);
    }

    // Configure hardened headless settings.
    wv2::ComPtr<wv2::ICoreWebView2Settings> settings;
    if (SUCCEEDED(webview_->get_Settings(settings.Put())) && settings) {
      settings->put_IsScriptEnabled(TRUE);
      settings->put_IsWebMessageEnabled(TRUE);
      settings->put_AreDefaultScriptDialogsEnabled(FALSE);
      settings->put_AreDefaultContextMenusEnabled(FALSE);
      settings->put_AreDevToolsEnabled(FALSE);
      settings->put_IsStatusBarEnabled(FALSE);
      settings->put_IsBuiltInErrorPageEnabled(FALSE);
      settings->put_AreHostObjectsAllowed(FALSE);

      wv2::ComPtr<wv2::ICoreWebView2Settings2> s2;
      if (SUCCEEDED(settings->QueryInterface(
              wv2::kIID_ICoreWebView2Settings2,
              reinterpret_cast<void**>(s2.Put()))) &&
          s2) {
        s2->put_UserAgent(Utf8ToWide(effective_ua_).c_str());
      }
      wv2::ComPtr<wv2::ICoreWebView2Settings4> s4;
      if (SUCCEEDED(settings->QueryInterface(
              wv2::kIID_ICoreWebView2Settings4,
              reinterpret_cast<void**>(s4.Put()))) &&
          s4) {
        s4->put_IsPasswordAutosaveEnabled(FALSE);
        s4->put_IsGeneralAutofillEnabled(FALSE);
      }
    }

    auto self = shared_from_this();

    // Suppress popup windows.
    auto new_win_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2NewWindowRequestedEventHandler,
        wv2::ICoreWebView2*, wv2::ICoreWebView2NewWindowRequestedEventArgs*>(
        wv2::kIID_ICoreWebView2NewWindowRequested,
        [](wv2::ICoreWebView2*,
           wv2::ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
          if (args) args->put_Handled(TRUE);
          return S_OK;
        });
    if (SUCCEEDED(webview_->add_NewWindowRequested(new_win_cb.Get(),
                                                 &new_window_token_))) {
      has_new_window_token_ = true;
    }

    // Intercept all web requests for 204 ad blocking and media sniffing.
    webview_->AddWebResourceRequestedFilter(
        L"*", wv2::COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    auto req_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2WebResourceRequestedEventHandler,
        wv2::ICoreWebView2*, wv2::ICoreWebView2WebResourceRequestedEventArgs*>(
        wv2::kIID_ICoreWebView2WebResourceRequested,
        [self](wv2::ICoreWebView2* sender,
               wv2::ICoreWebView2WebResourceRequestedEventArgs* args)
            -> HRESULT {
          return self->OnWebResourceRequested(sender, args);
        });
    if (SUCCEEDED(webview_->add_WebResourceRequested(req_cb.Get(),
                                                   &web_resource_token_))) {
      has_web_resource_token_ = true;
    }

    // Inject DOM/video-mute & dynamic src hook.
    webview_->AddScriptToExecuteOnDocumentCreated(kSnifferHookScript, nullptr);
    auto msg_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2WebMessageReceivedEventHandler,
        wv2::ICoreWebView2*, wv2::ICoreWebView2WebMessageReceivedEventArgs*>(
        wv2::kIID_ICoreWebView2WebMessageReceived,
        [self](wv2::ICoreWebView2*,
               wv2::ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
          self->OnWebMessageReceived(args);
          return S_OK;
        });
    if (SUCCEEDED(webview_->add_WebMessageReceived(msg_cb.Get(),
                                                 &web_message_token_))) {
      has_web_message_token_ = true;
    }

    // Inject optional clickScript upon NavigationCompleted.
    auto nav_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2NavigationCompletedEventHandler,
        wv2::ICoreWebView2*, wv2::ICoreWebView2NavigationCompletedEventArgs*>(
        wv2::kIID_ICoreWebView2NavigationCompleted,
        [self](wv2::ICoreWebView2*,
               wv2::ICoreWebView2NavigationCompletedEventArgs*) -> HRESULT {
          self->OnNavigationCompleted();
          return S_OK;
        });
    if (SUCCEEDED(webview_->add_NavigationCompleted(nav_cb.Get(),
                                                    &nav_completed_token_))) {
      has_nav_completed_token_ = true;
    }

    // Navigate with custom initial headers if supported via ICoreWebView2Environment2.
    const std::wstring target_w = Utf8ToWide(params_.url);
    bool navigated = false;
    if (!params_.headers.empty()) {
      wv2::ComPtr<wv2::ICoreWebView2Environment2> env2;
      wv2::ComPtr<wv2::ICoreWebView2_2> wv2;
      if (SUCCEEDED(env_->QueryInterface(
              wv2::kIID_ICoreWebView2Environment2,
              reinterpret_cast<void**>(env2.Put()))) &&
          env2 &&
          SUCCEEDED(webview_->QueryInterface(
              wv2::kIID_ICoreWebView2_2,
              reinterpret_cast<void**>(wv2.Put()))) &&
          wv2) {
        std::string raw_hdrs;
        for (const auto& kv : params_.headers) {
          if (TrimAscii(kv.first).empty() || TrimAscii(kv.second).empty()) {
            continue;
          }
          raw_hdrs.append(kv.first).append(": ").append(kv.second).append("\r\n");
        }
        wv2::ComPtr<wv2::ICoreWebView2WebResourceRequest> req;
        if (SUCCEEDED(env2->CreateWebResourceRequest(
                target_w.c_str(), L"GET", nullptr,
                Utf8ToWide(raw_hdrs).c_str(), req.Put())) &&
            req) {
          if (SUCCEEDED(wv2->NavigateWithWebResourceRequest(req.Get()))) {
            navigated = true;
          }
        }
      }
    }
    if (!navigated) {
      if (FAILED(webview_->Navigate(target_w.c_str()))) {
        FinishWithNull();
      }
    }
  }

  bool MatchesAds(const std::string& url) const {
    if (StripFragment(url) == normalized_target_) return false;
    for (const auto& ad : params_.ads) {
      if (MatchesPattern(ad, url)) return true;
    }
    return IsBuiltInTrackerOrAd(url);
  }

  bool MatchesMedia(const std::string& url) const {
    if (url.empty() || StripFragment(url) == normalized_target_) return false;
    if (StartsWithInsensitive(url, "blob:") ||
        StartsWithInsensitive(url, "data:") ||
        StartsWithInsensitive(url, "javascript:") ||
        StartsWithInsensitive(url, "about:")) {
      return false;
    }
    const std::string req_host = ExtractHostLower(url);
    bool has_rules = !params_.rules.empty();
    for (const auto& rule : params_.rules) {
      bool host_ok = rule.hosts.empty();
      if (!host_ok) {
        for (const auto& h : rule.hosts) {
          if (HostMatchesRule(page_host_, h) || HostMatchesRule(req_host, h)) {
            host_ok = true;
            break;
          }
        }
      }
      if (!host_ok) continue;

      bool excluded = false;
      for (const auto& ex : rule.excludes) {
        if (MatchesPattern(ex, url)) {
          excluded = true;
          break;
        }
      }
      if (excluded) continue;

      for (const auto& rx : rule.regexes) {
        if (MatchesPattern(rx, url)) {
          return true;
        }
      }
    }
    // Also check top-level exclude lists even for standard stream fallback.
    if (has_rules) {
      for (const auto& rule : params_.rules) {
        for (const auto& ex : rule.excludes) {
          if (MatchesPattern(ex, url)) return false;
        }
      }
    }
    return IsStandardMediaStreamUrl(url);
  }

  HRESULT OnWebResourceRequested(
      wv2::ICoreWebView2* /*sender*/,
      wv2::ICoreWebView2WebResourceRequestedEventArgs* args) {
    if (completed_ || matching_in_progress_ || !args) return S_OK;
    wv2::ComPtr<wv2::ICoreWebView2WebResourceRequest> req;
    if (FAILED(args->get_Request(req.Put())) || !req) return S_OK;

    LPWSTR uri_w = nullptr;
    if (FAILED(req->get_Uri(&uri_w)) || !uri_w) return S_OK;
    const std::string url = WidePtrToUtf8(uri_w);
    ::CoTaskMemFree(uri_w);

    if (MatchesAds(url)) {
      wv2::ComPtr<wv2::ICoreWebView2WebResourceResponse> resp;
      if (env_ &&
          SUCCEEDED(env_->CreateWebResourceResponse(nullptr, 204, L"No Content",
                                                    L"", resp.Put())) &&
          resp) {
        args->put_Response(resp.Get());
      }
      return S_OK;
    }

    if (MatchesMedia(url)) {
      matching_in_progress_ = true;

      // Short-circuit the media download immediately.
      wv2::ComPtr<wv2::ICoreWebView2WebResourceResponse> resp;
      if (env_ &&
          SUCCEEDED(env_->CreateWebResourceResponse(nullptr, 204, L"No Content",
                                                    L"", resp.Put())) &&
          resp) {
        args->put_Response(resp.Get());
      }

      std::map<std::string, std::string> captured;
      wv2::ComPtr<wv2::ICoreWebView2HttpRequestHeaders> hdrs;
      if (SUCCEEDED(req->get_Headers(hdrs.Put())) && hdrs) {
        wv2::ComPtr<wv2::ICoreWebView2HttpHeadersCollectionIterator> it;
        if (SUCCEEDED(hdrs->GetIterator(it.Put())) && it) {
          BOOL has_cur = FALSE;
          while (SUCCEEDED(it->get_HasCurrentHeader(&has_cur)) && has_cur) {
            LPWSTR name_w = nullptr;
            LPWSTR val_w = nullptr;
            if (SUCCEEDED(it->GetCurrentHeader(&name_w, &val_w))) {
              const std::string name = WidePtrToUtf8(name_w);
              const std::string val = WidePtrToUtf8(val_w);
              if (name_w) ::CoTaskMemFree(name_w);
              if (val_w) ::CoTaskMemFree(val_w);
              const std::string lower_name = ToLowerAscii(name);
              if (!val.empty() &&
                  (lower_name == "cookie" || lower_name == "referer" ||
                   lower_name == "user-agent" || lower_name == "origin" ||
                   lower_name == "authorization")) {
                captured[name] = val;
              }
            }
            BOOL has_next = FALSE;
            if (FAILED(it->MoveNext(&has_next)) || !has_next) break;
          }
        }
      }

      CompleteWithCapturedHeaders(url, std::move(captured));
    }
    return S_OK;
  }

  void OnWebMessageReceived(
      wv2::ICoreWebView2WebMessageReceivedEventArgs* args) {
    if (completed_ || matching_in_progress_ || !args) return;
    LPWSTR json_w = nullptr;
    if (FAILED(args->get_WebMessageAsJson(&json_w)) || !json_w) return;
    const std::string json = WidePtrToUtf8(json_w);
    ::CoTaskMemFree(json_w);

    flutter::EncodableValue decoded;
    if (!JsonParser::Parse(json, &decoded)) return;
    const auto* map = std::get_if<flutter::EncodableMap>(&decoded);
    if (!map) return;

    auto type_it = map->find(flutter::EncodableValue("type"));
    if (type_it == map->end()) return;
    const auto* type_str = std::get_if<std::string>(&type_it->second);
    if (!type_str || *type_str != "media") return;

    auto url_it = map->find(flutter::EncodableValue("url"));
    if (url_it == map->end()) return;
    const auto* url_str = std::get_if<std::string>(&url_it->second);
    if (!url_str || !MatchesMedia(*url_str) || MatchesAds(*url_str)) return;

    matching_in_progress_ = true;
    std::map<std::string, std::string> captured;
    auto page_it = map->find(flutter::EncodableValue("pageUrl"));
    if (page_it != map->end()) {
      if (const auto* page_url = std::get_if<std::string>(&page_it->second);
          page_url && (StartsWithInsensitive(*page_url, "http://") ||
                       StartsWithInsensitive(*page_url, "https://"))) {
        captured["Referer"] = *page_url;
      }
    }
    CompleteWithCapturedHeaders(*url_str, std::move(captured));
  }

  void OnNavigationCompleted() {
    if (completed_ || matching_in_progress_ || !webview_) return;
    if (!TrimAscii(params_.click_script).empty()) {
      webview_->ExecuteScript(Utf8ToWide(params_.click_script).c_str(), nullptr);
    }
  }

  static bool HasHeaderCaseInsensitive(
      const std::map<std::string, std::string>& hdrs,
      const std::string& target) {
    for (const auto& kv : hdrs) {
      if (ToLowerAscii(kv.first) == target && !kv.second.empty()) return true;
    }
    return false;
  }

  void CompleteWithCapturedHeaders(
      const std::string& matched_url,
      std::map<std::string, std::string> captured) {
    if (!HasHeaderCaseInsensitive(captured, "user-agent")) {
      captured["User-Agent"] = effective_ua_;
    }
    if (!HasHeaderCaseInsensitive(captured, "referer")) {
      std::string ref = params_.url;
      if (webview_) {
        LPWSTR src_w = nullptr;
        if (SUCCEEDED(webview_->get_Source(&src_w)) && src_w) {
          const std::string src = WidePtrToUtf8(src_w);
          ::CoTaskMemFree(src_w);
          if (StartsWithInsensitive(src, "http://") ||
              StartsWithInsensitive(src, "https://")) {
            ref = src;
          }
        }
      }
      captured["Referer"] = ref;
    }

    // If Cookie was not yet visible in WebResourceRequested, query CookieManager.
    if (!HasHeaderCaseInsensitive(captured, "cookie") && webview_ &&
        (StartsWithInsensitive(matched_url, "http://") ||
         StartsWithInsensitive(matched_url, "https://"))) {
      wv2::ComPtr<wv2::ICoreWebView2_2> wv2;
      wv2::ComPtr<wv2::ICoreWebView2CookieManager> cm;
      if (SUCCEEDED(webview_->QueryInterface(
              wv2::kIID_ICoreWebView2_2,
              reinterpret_cast<void**>(wv2.Put()))) &&
          wv2 && SUCCEEDED(wv2->get_CookieManager(cm.Put())) && cm) {
        auto self = shared_from_this();
        auto cookie_cb = wv2::MakeCallback2<
            wv2::ICoreWebView2GetCookiesCompletedHandler, HRESULT,
            wv2::ICoreWebView2CookieList*>(
            wv2::kIID_ICoreWebView2GetCookiesCompleted,
            [self, matched_url, captured](
                HRESULT chr, wv2::ICoreWebView2CookieList* list) mutable
            -> HRESULT {
              if (self->completed_) return S_OK;
              if (SUCCEEDED(chr) && list) {
                UINT32 count = 0;
                list->get_Count(&count);
                std::string cookie_header;
                for (UINT32 i = 0; i < count; ++i) {
                  wv2::ComPtr<wv2::ICoreWebView2Cookie> c;
                  if (SUCCEEDED(list->GetValueAtIndex(i, c.Put())) && c) {
                    LPWSTR n_w = nullptr;
                    LPWSTR v_w = nullptr;
                    c->get_Name(&n_w);
                    c->get_Value(&v_w);
                    const std::string n = WidePtrToUtf8(n_w);
                    const std::string v = WidePtrToUtf8(v_w);
                    if (n_w) ::CoTaskMemFree(n_w);
                    if (v_w) ::CoTaskMemFree(v_w);
                    if (!n.empty() && !v.empty()) {
                      if (!cookie_header.empty()) cookie_header.append("; ");
                      cookie_header.append(n).append("=").append(v);
                    }
                  }
                }
                if (!cookie_header.empty()) {
                  captured["Cookie"] = std::move(cookie_header);
                }
              }
              self->FinishWithResult(matched_url, captured);
              return S_OK;
            });
        if (SUCCEEDED(
                cm->GetCookies(Utf8ToWide(matched_url).c_str(), cookie_cb.Get()))) {
          return;
        }
      }
    }

    FinishWithResult(matched_url, captured);
  }

  void FinishWithResult(const std::string& matched_url,
                        const std::map<std::string, std::string>& headers) {
    if (completed_) return;
    completed_ = true;
    CleanupComAndWindow();

    flutter::EncodableMap hdr_map;
    for (const auto& kv : headers) {
      if (!kv.second.empty()) {
        hdr_map[flutter::EncodableValue(kv.first)] =
            flutter::EncodableValue(kv.second);
      }
    }
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("url")] = flutter::EncodableValue(matched_url);
    payload[flutter::EncodableValue("headers")] =
        flutter::EncodableValue(std::move(hdr_map));

    auto res = std::move(result_);
    auto on_done = std::move(on_finished_);
    const uint64_t id = id_;
    if (res) {
      res->Success(flutter::EncodableValue(std::move(payload)));
    }
    if (on_done) on_done(id);
  }

  void FinishWithNull() {
    if (completed_) return;
    completed_ = true;
    CleanupComAndWindow();

    auto res = std::move(result_);
    auto on_done = std::move(on_finished_);
    const uint64_t id = id_;
    if (res) {
      res->Success();
    }
    if (on_done) on_done(id);
  }

  void CleanupComAndWindow() {
    if (hwnd_) {
      if (timer_id_ != 0) {
        ::KillTimer(hwnd_, timer_id_);
        timer_id_ = 0;
      }
      UnregisterActiveTimer(hwnd_);
    }
    if (webview_) {
      if (has_web_resource_token_) {
        webview_->remove_WebResourceRequested(web_resource_token_);
        has_web_resource_token_ = false;
      }
      if (has_nav_completed_token_) {
        webview_->remove_NavigationCompleted(nav_completed_token_);
        has_nav_completed_token_ = false;
      }
      if (has_web_message_token_) {
        webview_->remove_WebMessageReceived(web_message_token_);
        has_web_message_token_ = false;
      }
      if (has_new_window_token_) {
        webview_->remove_NewWindowRequested(new_window_token_);
        has_new_window_token_ = false;
      }
      webview_->Stop();
      webview_.Reset();
    }
    if (controller_) {
      controller_->Close();
      controller_.Reset();
    }
    env_.Reset();
    if (hwnd_) {
      ::DestroyWindow(hwnd_);
      hwnd_ = nullptr;
    }
  }
};

// ============================================================================
// Off-Screen Lazy Async JS/DRPY2 Host (`marco_movie/webview_js`)
// ============================================================================

constexpr wchar_t kJsHostVirtualUrl[] = L"https://marco.localhost/__host.html";

constexpr char kJsHostBootstrapHtml[] =
    "<!doctype html><html><head><meta charset=\"utf-8\"></head>"
    "<body></body></html>";

class JsHostManager : public std::enable_shared_from_this<JsHostManager> {
 public:
  JsHostManager(
      RuntimeLoader* loader,
      flutter::MethodChannel<flutter::EncodableValue>* channel)
      : loader_(loader), channel_(channel) {}

  ~JsHostManager() { Shutdown(); }

  bool is_active() const { return static_cast<bool>(controller_) && !sleeping_; }
  bool is_sleeping() const { return sleeping_; }

  void SetIdleTimeoutMs(int64_t ms) {
    idle_timeout_ms_ = (ms < 5000) ? 5000 : ms;
  }

  void HandleEnsureReady(
      const flutter::EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (!loader_->info().available) {
      flutter::EncodableMap res;
      res[flutter::EncodableValue("available")] = flutter::EncodableValue(false);
      res[flutter::EncodableValue("ready")] = flutter::EncodableValue(false);
      result->Success(flutter::EncodableValue(std::move(res)));
      return;
    }
    UpdateScriptsFromArgs(args);
    if (ready_ && webview_) {
      last_activity_ms_ = ::GetTickCount64();
      flutter::EncodableMap res;
      res[flutter::EncodableValue("available")] = flutter::EncodableValue(true);
      res[flutter::EncodableValue("ready")] = flutter::EncodableValue(true);
      result->Success(flutter::EncodableValue(std::move(res)));
      return;
    }
    ready_waiters_.push_back(std::move(result));
    StartInitIfNeeded();
  }

  void HandleEvalSpider(
      const flutter::EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (!loader_->info().available || !args) {
      flutter::EncodableMap res;
      res[flutter::EncodableValue("available")] =
          flutter::EncodableValue(loader_->info().available);
      res[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
      res[flutter::EncodableValue("error")] =
          flutter::EncodableValue("webview2_unavailable");
      result->Success(flutter::EncodableValue(std::move(res)));
      return;
    }

    UpdateScriptsFromArgs(args);
    last_activity_ms_ = ::GetTickCount64();

    std::string call_id;
    if (auto it = args->find(flutter::EncodableValue("callId"));
        it != args->end()) {
      if (const auto* s = std::get_if<std::string>(&it->second)) {
        call_id = *s;
      }
    }
    if (call_id.empty()) {
      call_id = "wv_" + std::to_string(++next_call_id_);
    }

    int timeout_ms = 25000;
    if (auto it = args->find(flutter::EncodableValue("timeoutMs"));
        it != args->end()) {
      if (const auto* i32 = std::get_if<int32_t>(&it->second)) {
        timeout_ms = *i32;
      } else if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
        timeout_ms = static_cast<int>(*i64);
      }
    }
    timeout_ms = std::min(std::max(timeout_ms, 500), 120000);

    // Strip hostScript / cryptoJs from per-call message payload for compactness.
    flutter::EncodableMap msg_map;
    for (const auto& kv : *args) {
      const auto* k = std::get_if<std::string>(&kv.first);
      if (!k) continue;
      if (*k == "hostScript" || *k == "cryptoJs") continue;
      msg_map[kv.first] = kv.second;
    }
    msg_map[flutter::EncodableValue("type")] =
        flutter::EncodableValue("evalSpider");
    msg_map[flutter::EncodableValue("callId")] =
        flutter::EncodableValue(call_id);

    const std::string msg_json = SerializeJson(flutter::EncodableValue(msg_map));

    auto call = std::make_shared<PendingEval>();
    call->call_id = call_id;
    call->payload_json = msg_json;
    call->deadline_ms = ::GetTickCount64() + static_cast<uint64_t>(timeout_ms);
    call->result = std::move(result);
    pending_evals_[call_id] = call;

    if (ready_ && webview_) {
      DispatchPendingEval(call);
    } else {
      queued_call_ids_.push_back(call_id);
      StartInitIfNeeded();
    }
  }

  void Sleep() {
    sleeping_ = true;
    ready_ = false;
    initializing_ = false;
    injected_host_ = false;

    // Fail any in-flight evals cleanly.
    FailAllPending("webview2_sleeping");
    CleanupControllerOnly();
  }

  void Shutdown() {
    shutdown_ = true;
    FailAllPending("webview2_shutdown");
    CleanupControllerOnly();
    env_.Reset();
    if (timer_hwnd_) {
      if (tick_timer_id_ != 0) {
        ::KillTimer(timer_hwnd_, tick_timer_id_);
        tick_timer_id_ = 0;
      }
      TimerHostMap().erase(timer_hwnd_);
      ::DestroyWindow(timer_hwnd_);
      timer_hwnd_ = nullptr;
    }
  }

 private:
  struct PendingEval {
    std::string call_id;
    std::string payload_json;
    uint64_t deadline_ms = 0;
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  };

  RuntimeLoader* loader_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  HWND timer_hwnd_ = nullptr;
  HWND web_hwnd_ = nullptr;
  UINT_PTR tick_timer_id_ = 0;
  bool shutdown_ = false;
  bool initializing_ = false;
  bool ready_ = false;
  bool sleeping_ = false;
  bool injected_host_ = false;
  uint64_t next_call_id_ = 0;
  uint64_t last_activity_ms_ = 0;
  int64_t idle_timeout_ms_ = 60000;

  std::string crypto_js_;
  std::string host_script_;

  wv2::ComPtr<wv2::ICoreWebView2Environment> env_;
  wv2::ComPtr<wv2::ICoreWebView2Controller> controller_;
  wv2::ComPtr<wv2::ICoreWebView2> webview_;
  wv2::EventRegistrationToken web_resource_token_{};
  wv2::EventRegistrationToken nav_completed_token_{};
  wv2::EventRegistrationToken web_message_token_{};
  wv2::EventRegistrationToken new_window_token_{};
  bool has_web_resource_token_ = false;
  bool has_nav_completed_token_ = false;
  bool has_web_message_token_ = false;
  bool has_new_window_token_ = false;

  std::vector<std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>
      ready_waiters_;
  std::map<std::string, std::shared_ptr<PendingEval>> pending_evals_;
  std::vector<std::string> queued_call_ids_;

  static std::map<HWND, std::weak_ptr<JsHostManager>>& TimerHostMap() {
    static auto* map = new std::map<HWND, std::weak_ptr<JsHostManager>>();
    return *map;
  }

  static void CALLBACK TickTimerProc(HWND hwnd, UINT, UINT_PTR, DWORD) {
    auto it = TimerHostMap().find(hwnd);
    if (it != TimerHostMap().end()) {
      if (auto mgr = it->second.lock()) {
        mgr->OnTick();
      }
    }
  }

  void EnsureTickTimer() {
    if (!timer_hwnd_) {
      timer_hwnd_ = CreateHiddenHostWindow();
      if (timer_hwnd_) {
        TimerHostMap()[timer_hwnd_] = shared_from_this();
        tick_timer_id_ = ::SetTimer(timer_hwnd_, 2, 250, TickTimerProc);
      }
    }
  }

  void OnTick() {
    if (shutdown_) return;
    const uint64_t now = ::GetTickCount64();

    // Check per-eval timeouts.
    std::vector<std::string> expired;
    for (const auto& kv : pending_evals_) {
      if (now >= kv.second->deadline_ms) {
        expired.push_back(kv.first);
      }
    }
    for (const auto& id : expired) {
      auto it = pending_evals_.find(id);
      if (it != pending_evals_.end()) {
        auto call = std::move(it->second);
        pending_evals_.erase(it);
        if (call->result) {
          flutter::EncodableMap res;
          res[flutter::EncodableValue("available")] =
              flutter::EncodableValue(true);
          res[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
          res[flutter::EncodableValue("error")] =
              flutter::EncodableValue("webview2_eval_timeout");
          call->result->Success(flutter::EncodableValue(std::move(res)));
        }
      }
    }

    // Idle auto-sleep reclamation when no eval is active.
    if (controller_ && pending_evals_.empty() && ready_waiters_.empty() &&
        !initializing_ && last_activity_ms_ > 0 &&
        (now - last_activity_ms_) >= static_cast<uint64_t>(idle_timeout_ms_)) {
      Sleep();
    }
  }

  void UpdateScriptsFromArgs(const flutter::EncodableMap* args) {
    if (!args) return;
    if (auto it = args->find(flutter::EncodableValue("cryptoJs"));
        it != args->end()) {
      if (const auto* s = std::get_if<std::string>(&it->second);
          s && !s->empty()) {
        crypto_js_ = *s;
      }
    }
    if (auto it = args->find(flutter::EncodableValue("hostScript"));
        it != args->end()) {
      if (const auto* s = std::get_if<std::string>(&it->second);
          s && !s->empty()) {
        host_script_ = *s;
      }
    }
  }

  void StartInitIfNeeded() {
    if (shutdown_ || initializing_ || ready_) return;
    EnsureTickTimer();
    sleeping_ = false;
    initializing_ = true;
    last_activity_ms_ = ::GetTickCount64();

    web_hwnd_ = CreateHiddenHostWindow();
    if (!web_hwnd_) {
      FailInit("hwnd_create_failed");
      return;
    }

    if (env_) {
      CreateController();
      return;
    }

    auto self = shared_from_this();
    auto env_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
        HRESULT, wv2::ICoreWebView2Environment*>(
        wv2::kIID_ICoreWebView2CreateEnvironmentCompleted,
        [self](HRESULT hr, wv2::ICoreWebView2Environment* env) -> HRESULT {
          if (self->shutdown_) return S_OK;
          if (FAILED(hr) || !env) {
            self->FailInit("webview2_env_failed");
            return S_OK;
          }
          env->AddRef();
          self->env_.Attach(env);
          self->CreateController();
          return S_OK;
        });

    const std::wstring jshost_dir = GetWebView2UserDataRoot() + L"\\jshost";
    EnsureDirectoryRecursiveW(jshost_dir);
    if (FAILED(loader_->CreateEnvironment(jshost_dir, env_cb.Get()))) {
      FailInit("webview2_env_create_failed");
    }
  }

  void CreateController() {
    if (shutdown_ || !env_ || !web_hwnd_) {
      FailInit("webview2_controller_precondition_failed");
      return;
    }
    auto self = shared_from_this();
    auto ctrl_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
        HRESULT, wv2::ICoreWebView2Controller*>(
        wv2::kIID_ICoreWebView2CreateControllerCompleted,
        [self](HRESULT hr, wv2::ICoreWebView2Controller* ctrl) -> HRESULT {
          self->OnControllerCreated(hr, ctrl);
          return S_OK;
        });
    if (FAILED(env_->CreateCoreWebView2Controller(web_hwnd_, ctrl_cb.Get()))) {
      FailInit("webview2_controller_create_failed");
    }
  }

  void OnControllerCreated(HRESULT hr, wv2::ICoreWebView2Controller* ctrl) {
    if (shutdown_ || FAILED(hr) || !ctrl) {
      FailInit("webview2_controller_failed");
      return;
    }
    ctrl->AddRef();
    controller_.Attach(ctrl);
    controller_->put_IsVisible(FALSE);
    RECT bounds{0, 0, 1280, 720};
    controller_->put_Bounds(bounds);

    if (FAILED(controller_->get_CoreWebView2(webview_.Put())) || !webview_) {
      FailInit("webview2_get_core_failed");
      return;
    }

    wv2::ComPtr<wv2::ICoreWebView2_8> wv8;
    if (SUCCEEDED(webview_->QueryInterface(
            wv2::kIID_ICoreWebView2_8,
            reinterpret_cast<void**>(wv8.Put()))) &&
        wv8) {
      wv8->put_IsMuted(TRUE);
    }

    wv2::ComPtr<wv2::ICoreWebView2Settings> settings;
    if (SUCCEEDED(webview_->get_Settings(settings.Put())) && settings) {
      settings->put_IsScriptEnabled(TRUE);
      settings->put_IsWebMessageEnabled(TRUE);
      settings->put_AreDefaultScriptDialogsEnabled(FALSE);
      settings->put_AreDefaultContextMenusEnabled(FALSE);
      settings->put_AreDevToolsEnabled(FALSE);
      settings->put_IsStatusBarEnabled(FALSE);
      settings->put_IsBuiltInErrorPageEnabled(FALSE);
      settings->put_AreHostObjectsAllowed(FALSE);
    }

    auto self = shared_from_this();
    auto new_win_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2NewWindowRequestedEventHandler,
        wv2::ICoreWebView2*, wv2::ICoreWebView2NewWindowRequestedEventArgs*>(
        wv2::kIID_ICoreWebView2NewWindowRequested,
        [](wv2::ICoreWebView2*,
           wv2::ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
          if (args) args->put_Handled(TRUE);
          return S_OK;
        });
    if (SUCCEEDED(webview_->add_NewWindowRequested(new_win_cb.Get(),
                                                 &new_window_token_))) {
      has_new_window_token_ = true;
    }

    // Serve virtual https://marco.localhost/__host.html so Secure Context APIs
    // (crypto.subtle, TextEncoder, DOMParser, Blob import) work cleanly.
    webview_->AddWebResourceRequestedFilter(
        L"https://marco.localhost/*",
        wv2::COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    auto req_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2WebResourceRequestedEventHandler,
        wv2::ICoreWebView2*, wv2::ICoreWebView2WebResourceRequestedEventArgs*>(
        wv2::kIID_ICoreWebView2WebResourceRequested,
        [self](wv2::ICoreWebView2*,
               wv2::ICoreWebView2WebResourceRequestedEventArgs* args)
            -> HRESULT {
          if (!args || !self->env_) return S_OK;
          wv2::ComPtr<wv2::ICoreWebView2WebResourceRequest> req;
          if (FAILED(args->get_Request(req.Put())) || !req) return S_OK;
          LPWSTR uri_w = nullptr;
          if (FAILED(req->get_Uri(&uri_w)) || !uri_w) return S_OK;
          const std::string uri = WidePtrToUtf8(uri_w);
          ::CoTaskMemFree(uri_w);
          if (uri == "https://marco.localhost/__host.html") {
            wv2::ComPtr<IStream> stream;
            stream.Attach(new wv2::MemoryStream(kJsHostBootstrapHtml));
            wv2::ComPtr<wv2::ICoreWebView2WebResourceResponse> resp;
            if (SUCCEEDED(self->env_->CreateWebResourceResponse(
                    stream.Get(), 200, L"OK",
                    L"Content-Type: text/html; charset=utf-8\r\n", resp.Put())) &&
                resp) {
              args->put_Response(resp.Get());
            }
          }
          return S_OK;
        });
    if (SUCCEEDED(webview_->add_WebResourceRequested(req_cb.Get(),
                                                   &web_resource_token_))) {
      has_web_resource_token_ = true;
    }

    auto msg_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2WebMessageReceivedEventHandler,
        wv2::ICoreWebView2*, wv2::ICoreWebView2WebMessageReceivedEventArgs*>(
        wv2::kIID_ICoreWebView2WebMessageReceived,
        [self](wv2::ICoreWebView2*,
               wv2::ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
          self->OnWebMessageReceived(args);
          return S_OK;
        });
    if (SUCCEEDED(webview_->add_WebMessageReceived(msg_cb.Get(),
                                                 &web_message_token_))) {
      has_web_message_token_ = true;
    }

    auto nav_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2NavigationCompletedEventHandler,
        wv2::ICoreWebView2*, wv2::ICoreWebView2NavigationCompletedEventArgs*>(
        wv2::kIID_ICoreWebView2NavigationCompleted,
        [self](wv2::ICoreWebView2*,
               wv2::ICoreWebView2NavigationCompletedEventArgs* args)
            -> HRESULT {
          self->OnHostPageLoaded(args);
          return S_OK;
        });
    if (SUCCEEDED(webview_->add_NavigationCompleted(nav_cb.Get(),
                                                    &nav_completed_token_))) {
      has_nav_completed_token_ = true;
    }

    if (FAILED(webview_->Navigate(kJsHostVirtualUrl))) {
      FailInit("webview2_navigate_host_failed");
    }
  }

  void OnHostPageLoaded(wv2::ICoreWebView2NavigationCompletedEventArgs* args) {
    if (shutdown_ || !webview_ || injected_host_) return;
    BOOL ok = FALSE;
    if (args) args->get_IsSuccess(&ok);
    if (!ok) {
      FailInit("webview2_host_page_failed");
      return;
    }
    injected_host_ = true;
    std::string combined;
    if (!crypto_js_.empty()) {
      combined.append(crypto_js_).append("\n;");
    }
    if (!host_script_.empty()) {
      combined.append(host_script_).append("\n;");
    }
    combined.append("void 0;");

    auto self = shared_from_this();
    auto exec_cb = wv2::MakeCallback2<
        wv2::ICoreWebView2ExecuteScriptCompletedHandler, HRESULT, LPCWSTR>(
        wv2::kIID_ICoreWebView2ExecuteScriptCompleted,
        [self](HRESULT ehr, LPCWSTR) -> HRESULT {
          if (self->shutdown_) return S_OK;
          if (FAILED(ehr)) {
            self->FailInit("webview2_bootstrap_script_failed");
            return S_OK;
          }
          self->initializing_ = false;
          self->ready_ = true;
          self->last_activity_ms_ = ::GetTickCount64();
          self->FlushReadyAndQueued();
          return S_OK;
        });
    if (FAILED(webview_->ExecuteScript(Utf8ToWide(combined).c_str(),
                                       exec_cb.Get()))) {
      FailInit("webview2_exec_bootstrap_failed");
    }
  }

  void FlushReadyAndQueued() {
    auto waiters = std::move(ready_waiters_);
    ready_waiters_.clear();
    for (auto& w : waiters) {
      if (!w) continue;
      flutter::EncodableMap res;
      res[flutter::EncodableValue("available")] = flutter::EncodableValue(true);
      res[flutter::EncodableValue("ready")] = flutter::EncodableValue(true);
      w->Success(flutter::EncodableValue(std::move(res)));
    }
    auto queued = std::move(queued_call_ids_);
    queued_call_ids_.clear();
    for (const auto& id : queued) {
      auto it = pending_evals_.find(id);
      if (it != pending_evals_.end()) {
        DispatchPendingEval(it->second);
      }
    }
  }

  void DispatchPendingEval(const std::shared_ptr<PendingEval>& call) {
    if (!webview_ || !call) return;
    last_activity_ms_ = ::GetTickCount64();
    if (FAILED(webview_->PostWebMessageAsJson(
            Utf8ToWide(call->payload_json).c_str()))) {
      pending_evals_.erase(call->call_id);
      if (call->result) {
        flutter::EncodableMap res;
        res[flutter::EncodableValue("available")] =
            flutter::EncodableValue(true);
        res[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
        res[flutter::EncodableValue("error")] =
            flutter::EncodableValue("webview2_post_message_failed");
        call->result->Success(flutter::EncodableValue(std::move(res)));
      }
    }
  }

  void OnWebMessageReceived(
      wv2::ICoreWebView2WebMessageReceivedEventArgs* args) {
    if (shutdown_ || !args) return;
    LPWSTR json_w = nullptr;
    if (FAILED(args->get_WebMessageAsJson(&json_w)) || !json_w) return;
    const std::string json = WidePtrToUtf8(json_w);
    ::CoTaskMemFree(json_w);

    flutter::EncodableValue decoded;
    if (!JsonParser::Parse(json, &decoded)) return;
    const auto* map = std::get_if<flutter::EncodableMap>(&decoded);
    if (!map) return;

    auto type_it = map->find(flutter::EncodableValue("type"));
    if (type_it == map->end()) return;
    const auto* type_str = std::get_if<std::string>(&type_it->second);
    if (!type_str) return;

    last_activity_ms_ = ::GetTickCount64();

    if (*type_str == "result") {
      auto id_it = map->find(flutter::EncodableValue("callId"));
      if (id_it == map->end()) return;
      const auto* id_str = std::get_if<std::string>(&id_it->second);
      if (!id_str) return;

      auto eval_it = pending_evals_.find(*id_str);
      if (eval_it == pending_evals_.end()) return;
      auto call = std::move(eval_it->second);
      pending_evals_.erase(eval_it);

      if (call->result) {
        flutter::EncodableMap res = *map;
        res[flutter::EncodableValue("available")] =
            flutter::EncodableValue(true);
        call->result->Success(flutter::EncodableValue(std::move(res)));
      }
      return;
    }

    if (*type_str == "httpRequest" && channel_) {
      std::string req_id;
      if (auto rid_it = map->find(flutter::EncodableValue("reqId"));
          rid_it != map->end()) {
        if (const auto* s = std::get_if<std::string>(&rid_it->second)) {
          req_id = *s;
        }
      }
      if (req_id.empty()) return;

      auto self = shared_from_this();
      auto arg = std::make_unique<flutter::EncodableValue>(*map);
      auto result_handler =
          std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
              [self, req_id](const flutter::EncodableValue* result) {
                if (self->shutdown_ || !self->webview_) return;
                flutter::EncodableMap reply;
                reply[flutter::EncodableValue("type")] =
                    flutter::EncodableValue("httpResponse");
                reply[flutter::EncodableValue("reqId")] =
                    flutter::EncodableValue(req_id);
                reply[flutter::EncodableValue("ok")] =
                    flutter::EncodableValue(true);
                reply[flutter::EncodableValue("data")] =
                    result ? *result : flutter::EncodableValue();
                self->webview_->PostWebMessageAsJson(
                    Utf8ToWide(SerializeJson(flutter::EncodableValue(reply)))
                        .c_str());
              },
              [self, req_id](const std::string& /*code*/,
                             const std::string& message,
                             const flutter::EncodableValue* /*details*/) {
                if (self->shutdown_ || !self->webview_) return;
                flutter::EncodableMap reply;
                reply[flutter::EncodableValue("type")] =
                    flutter::EncodableValue("httpResponse");
                reply[flutter::EncodableValue("reqId")] =
                    flutter::EncodableValue(req_id);
                reply[flutter::EncodableValue("ok")] =
                    flutter::EncodableValue(false);
                reply[flutter::EncodableValue("error")] =
                    flutter::EncodableValue(message);
                self->webview_->PostWebMessageAsJson(
                    Utf8ToWide(SerializeJson(flutter::EncodableValue(reply)))
                        .c_str());
              },
              [self, req_id]() {
                if (self->shutdown_ || !self->webview_) return;
                flutter::EncodableMap reply;
                reply[flutter::EncodableValue("type")] =
                    flutter::EncodableValue("httpResponse");
                reply[flutter::EncodableValue("reqId")] =
                    flutter::EncodableValue(req_id);
                reply[flutter::EncodableValue("ok")] =
                    flutter::EncodableValue(false);
                reply[flutter::EncodableValue("error")] =
                    flutter::EncodableValue("httpRequest not implemented");
                self->webview_->PostWebMessageAsJson(
                    Utf8ToWide(SerializeJson(flutter::EncodableValue(reply)))
                        .c_str());
              });
      channel_->InvokeMethod("httpRequest", std::move(arg),
                             std::move(result_handler));
    }
  }

  void FailInit(const std::string& error) {
    initializing_ = false;
    ready_ = false;
    auto waiters = std::move(ready_waiters_);
    ready_waiters_.clear();
    for (auto& w : waiters) {
      if (!w) continue;
      flutter::EncodableMap res;
      res[flutter::EncodableValue("available")] =
          flutter::EncodableValue(loader_->info().available);
      res[flutter::EncodableValue("ready")] = flutter::EncodableValue(false);
      res[flutter::EncodableValue("error")] = flutter::EncodableValue(error);
      w->Success(flutter::EncodableValue(std::move(res)));
    }
    FailAllPending(error);
    CleanupControllerOnly();
  }

  void FailAllPending(const std::string& error) {
    queued_call_ids_.clear();
    auto pending = std::move(pending_evals_);
    pending_evals_.clear();
    for (auto& kv : pending) {
      if (kv.second && kv.second->result) {
        flutter::EncodableMap res;
        res[flutter::EncodableValue("available")] =
            flutter::EncodableValue(loader_->info().available);
        res[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
        res[flutter::EncodableValue("error")] = flutter::EncodableValue(error);
        kv.second->result->Success(flutter::EncodableValue(std::move(res)));
      }
    }
  }

  void CleanupControllerOnly() {
    if (webview_) {
      if (has_web_resource_token_) {
        webview_->remove_WebResourceRequested(web_resource_token_);
        has_web_resource_token_ = false;
      }
      if (has_nav_completed_token_) {
        webview_->remove_NavigationCompleted(nav_completed_token_);
        has_nav_completed_token_ = false;
      }
      if (has_web_message_token_) {
        webview_->remove_WebMessageReceived(web_message_token_);
        has_web_message_token_ = false;
      }
      if (has_new_window_token_) {
        webview_->remove_NewWindowRequested(new_window_token_);
        has_new_window_token_ = false;
      }
      webview_->Stop();
      webview_.Reset();
    }
    if (controller_) {
      controller_->Close();
      controller_.Reset();
    }
    if (web_hwnd_) {
      ::DestroyWindow(web_hwnd_);
      web_hwnd_ = nullptr;
    }
  }
};

// ============================================================================
// Argument Parsing Helpers
// ============================================================================

std::vector<std::string> ReadStringList(const flutter::EncodableMap& map,
                                        const char* key) {
  std::vector<std::string> out;
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return out;
  if (const auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
    for (const auto& item : *list) {
      if (const auto* s = std::get_if<std::string>(&item)) {
        if (!TrimAscii(*s).empty()) out.push_back(*s);
      }
    }
  } else if (const auto* single = std::get_if<std::string>(&it->second)) {
    if (!TrimAscii(*single).empty()) out.push_back(*single);
  }
  return out;
}

SniffParams ParseSniffParams(const flutter::EncodableMap& args) {
  SniffParams p;
  if (auto it = args.find(flutter::EncodableValue("url")); it != args.end()) {
    if (const auto* s = std::get_if<std::string>(&it->second)) {
      p.url = TrimAscii(*s);
    }
  }
  if (auto it = args.find(flutter::EncodableValue("headers"));
      it != args.end()) {
    if (const auto* hmap = std::get_if<flutter::EncodableMap>(&it->second)) {
      for (const auto& kv : *hmap) {
        const auto* k = std::get_if<std::string>(&kv.first);
        const auto* v = std::get_if<std::string>(&kv.second);
        if (k && v && !TrimAscii(*k).empty() && !TrimAscii(*v).empty()) {
          p.headers[*k] = *v;
        }
      }
    }
  }
  if (auto it = args.find(flutter::EncodableValue("timeoutMs"));
      it != args.end()) {
    if (const auto* i32 = std::get_if<int32_t>(&it->second)) {
      p.timeout_ms = *i32;
    } else if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
      p.timeout_ms = static_cast<int>(*i64);
    }
  }
  p.ads = ReadStringList(args, "ads");
  if (auto it = args.find(flutter::EncodableValue("clickScript"));
      it != args.end()) {
    if (const auto* s = std::get_if<std::string>(&it->second)) {
      p.click_script = *s;
    }
  }
  if (auto it = args.find(flutter::EncodableValue("rules"));
      it != args.end()) {
    if (const auto* rlist = std::get_if<flutter::EncodableList>(&it->second)) {
      for (const auto& item : *rlist) {
        const auto* rmap = std::get_if<flutter::EncodableMap>(&item);
        if (!rmap) continue;
        SniffRuleSpec spec;
        spec.hosts = ReadStringList(*rmap, "hosts");
        spec.regexes = ReadStringList(*rmap, "regex");
        spec.excludes = ReadStringList(*rmap, "exclude");
        if (p.click_script.empty()) {
          auto sit = rmap->find(flutter::EncodableValue("script"));
          if (sit != rmap->end()) {
            if (const auto* s = std::get_if<std::string>(&sit->second)) {
              p.click_script = *s;
            }
          }
        }
        if (p.click_script.empty()) {
          auto cit = rmap->find(flutter::EncodableValue("click"));
          if (cit != rmap->end()) {
            if (const auto* s = std::get_if<std::string>(&cit->second)) {
              p.click_script = *s;
            }
          }
        }
        if (!spec.regexes.empty() || !spec.excludes.empty()) {
          p.rules.push_back(std::move(spec));
        }
      }
    }
  }
  return p;
}

}  // namespace

// ============================================================================
// MarcoWebview2Plugin::Impl
// ============================================================================

class MarcoWebview2Plugin::Impl {
 public:
  Impl(flutter::BinaryMessenger* messenger, HWND parent_window)
      : parent_window_(parent_window) {
    if (!messenger) return;

    sniffer_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, "marco_movie/web_sniffer",
            &flutter::StandardMethodCodec::GetInstance());
    sniffer_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
          HandleSnifferMethod(call, std::move(result));
        });

    js_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, "marco_movie/webview_js",
            &flutter::StandardMethodCodec::GetInstance());
    js_host_ = std::make_shared<JsHostManager>(&loader_, js_channel_.get());
    js_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleJsMethod(call, std::move(result)); });
  }

  ~Impl() { Shutdown(); }

  bool IsAvailable() const { return loader_.info().available; }

  void Shutdown() {
    if (shutting_down_) return;
    shutting_down_ = true;

    auto active = std::move(active_sniffers_);
    active_sniffers_.clear();
    for (auto& kv : active) {
      if (kv.second) kv.second->ForceCancel();
    }
    if (js_host_) {
      js_host_->Shutdown();
      js_host_.reset();
    }
    sniffer_channel_.reset();
    js_channel_.reset();
  }

 private:
  HWND parent_window_ = nullptr;
  RuntimeLoader loader_;
  bool shutting_down_ = false;
  uint64_t next_sniff_id_ = 0;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      sniffer_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> js_channel_;
  std::shared_ptr<JsHostManager> js_host_;
  std::map<uint64_t, std::shared_ptr<SniffSession>> active_sniffers_;

  flutter::EncodableMap BuildStatusMap(bool include_js_state) const {
    const RuntimeInfo& info = loader_.info();
    flutter::EncodableMap map;
    map[flutter::EncodableValue("available")] =
        flutter::EncodableValue(info.available);
    map[flutter::EncodableValue("version")] =
        flutter::EncodableValue(WideToUtf8(info.version));
    map[flutter::EncodableValue("runtimePath")] =
        flutter::EncodableValue(WideToUtf8(info.browser_folder));
    map[flutter::EncodableValue("userDataDir")] =
        flutter::EncodableValue(WideToUtf8(GetWebView2UserDataRoot()));
    map[flutter::EncodableValue("reason")] =
        flutter::EncodableValue(info.reason);
    if (include_js_state && js_host_) {
      map[flutter::EncodableValue("active")] =
          flutter::EncodableValue(js_host_->is_active());
      map[flutter::EncodableValue("sleeping")] =
          flutter::EncodableValue(js_host_->is_sleeping());
    }
    return map;
  }

  void HandleSnifferMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (shutting_down_) {
      result->Success();
      return;
    }
    const std::string& method = call.method_name();
    if (method == "isAvailable") {
      result->Success(flutter::EncodableValue(loader_.info().available));
      return;
    }
    if (method == "getStatus") {
      result->Success(flutter::EncodableValue(BuildStatusMap(false)));
      return;
    }
    if (method == "sniffMedia") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!args || !loader_.info().available) {
        result->Success();
        return;
      }
      SniffParams params = ParseSniffParams(*args);
      if (!StartsWithInsensitive(params.url, "http://") &&
          !StartsWithInsensitive(params.url, "https://")) {
        result->Success();
        return;
      }
      const uint64_t sid = ++next_sniff_id_;
      auto session = std::make_shared<SniffSession>(
          sid, std::move(params), std::move(result),
          [this](uint64_t finished_id) {
            if (!shutting_down_) active_sniffers_.erase(finished_id);
          });
      active_sniffers_[sid] = session;
      session->Start(&loader_, GetWebView2UserDataRoot());
      return;
    }
    result->NotImplemented();
  }

  void HandleJsMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (shutting_down_) {
      flutter::EncodableMap res;
      res[flutter::EncodableValue("available")] = flutter::EncodableValue(false);
      result->Success(flutter::EncodableValue(std::move(res)));
      return;
    }
    const std::string& method = call.method_name();
    if (method == "isAvailable") {
      result->Success(flutter::EncodableValue(loader_.info().available));
      return;
    }
    if (method == "getStatus") {
      result->Success(flutter::EncodableValue(BuildStatusMap(true)));
      return;
    }
    if (method == "ensureReady") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      js_host_->HandleEnsureReady(args, std::move(result));
      return;
    }
    if (method == "evalSpider") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      js_host_->HandleEvalSpider(args, std::move(result));
      return;
    }
    if (method == "sleep" || method == "dispose") {
      if (js_host_) js_host_->Sleep();
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (method == "setIdleTimeout") {
      if (const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments())) {
        if (auto it = args->find(flutter::EncodableValue("idleTimeoutMs"));
            it != args->end()) {
          if (const auto* i32 = std::get_if<int32_t>(&it->second)) {
            js_host_->SetIdleTimeoutMs(*i32);
          } else if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
            js_host_->SetIdleTimeoutMs(*i64);
          }
        }
      }
      result->Success(flutter::EncodableValue(true));
      return;
    }
    result->NotImplemented();
  }
};

MarcoWebview2Plugin::MarcoWebview2Plugin(flutter::BinaryMessenger* messenger,
                                         HWND parent_window)
    : impl_(std::make_unique<Impl>(messenger, parent_window)) {}

MarcoWebview2Plugin::~MarcoWebview2Plugin() = default;

void MarcoWebview2Plugin::Shutdown() {
  if (impl_) impl_->Shutdown();
}

bool MarcoWebview2Plugin::IsAvailable() const {
  return impl_ && impl_->IsAvailable();
}

}  // namespace marco
