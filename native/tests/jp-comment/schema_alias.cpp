// SPDX-License-Identifier: GPL-3.0-only
#include "JpCommentStyle.h"

#include <iostream>
#include <stdexcept>
#include <string>

namespace {
void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void CheckJapaneseSchema(const std::wstring& schema) {
  using namespace weasel::jp_comment;
  for (const wchar_t label : {L'\u8A13', L'\u97F3', L'\u4E2D'}) {
    const std::wstring raw = L"reading | _" + std::wstring(1, label) + L" value";
    const std::wstring expected = L"reading | " + std::wstring(1, label) + L" value";
    const auto parsed = Parse(schema, raw);
    Require(parsed.text == expected, "A Japanese annotation was not decoded.");
    Require(parsed.labels.size() == 1, "A Japanese annotation lost its label.");
    Require(parsed.labels[0].character == label &&
                parsed.labels[0].position == expected.find(label),
            "A Japanese annotation has the wrong label or position.");
  }

  // Explicit surrogate units also exercise the Windows UTF-16 position contract.
  const std::wstring candidate = L"\u5B78\xD840\xDC00";
  const std::wstring comment = L"[jp:0=\u65E7,1=\u7570]reading | _\u97F3 value";
  const auto labels = ParseCandidate(schema, candidate, comment);
  Require(labels.size() == 2, "A Japanese candidate lost its variant labels.");
  Require(labels[0].position == 0 && labels[0].length == 1 &&
              labels[0].label == L'\u65E7',
          "The first variant label changed.");
  Require(labels[1].position == 1 && labels[1].length == 2 &&
              labels[1].label == L'\u7570',
          "The supplementary candidate label lost its UTF-16 span.");
  Require(Parse(schema, comment).text == L"reading | \u97F3 value",
          "The Japanese presentation header was not removed.");
}

void CheckOtherSchema(const std::wstring& schema) {
  using namespace weasel::jp_comment;
  const std::wstring raw = L"[jp:0=\u65E7]reading | _\u97F3 value";
  const auto parsed = Parse(schema, raw);
  Require(parsed.text == raw && parsed.labels.empty(),
          "A non-Japanese annotation was altered.");
  Require(ParseCandidate(schema, L"\u5B78", raw).empty(),
          "A non-Japanese candidate acquired Japanese labels.");
}
}  // namespace

int main() {
  try {
    CheckJapaneseSchema(L"jp_sela");
    CheckJapaneseSchema(L"jp_stellae");
    CheckOtherSchema(L"cn_stellae");
    CheckOtherSchema(L"pc_research");
    CheckOtherSchema(L"other");
    std::cout << "{\"passed\":true,\"oldAndNewJapaneseSchemaIds\":true,"
                 "\"nonJapaneseSchemasUnchanged\":true,\"utf16SpansPreserved\":true}\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
