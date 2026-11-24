// SPDX-License-Identifier: GPL-3.0-only
// Included only in the disposable CI server.
#include <cstdint>

namespace {

// Examine the same DirectWrite layout already submitted to the panel. Unlike
// the configured family name, DrawGlyphRun observes actual fallback resolution.
class AppearanceGlyphProbe final : public IDWriteTextRenderer {
 public:
  explicit AppearanceGlyphProbe(IDWriteFontCollection* fonts) : fonts_(fonts) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object)
      return E_POINTER;
    *object = nullptr;
    if (iid != __uuidof(IUnknown) && iid != __uuidof(IDWritePixelSnapping) &&
        iid != __uuidof(IDWriteTextRenderer))
      return E_NOINTERFACE;
    *object = static_cast<IDWriteTextRenderer*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override { return --references_; }

  HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void*, BOOL* disabled) override {
    *disabled = TRUE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetCurrentTransform(void*, DWRITE_MATRIX* matrix) override {
    *matrix = {1, 0, 0, 1, 0, 0};
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void*, FLOAT* scale) override {
    *scale = 1;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DrawGlyphRun(
      void*, FLOAT, FLOAT, DWRITE_MEASURING_MODE, const DWRITE_GLYPH_RUN* glyphs,
      const DWRITE_GLYPH_RUN_DESCRIPTION*, IUnknown*) override {
    if (!family.empty() || !glyphs || !glyphs->glyphCount ||
        !glyphs->glyphIndices[0])
      return S_OK;
    Microsoft::WRL::ComPtr<IDWriteFont> font;
    Microsoft::WRL::ComPtr<IDWriteFontFamily> resolved;
    Microsoft::WRL::ComPtr<IDWriteLocalizedStrings> names;
    if (FAILED(fonts_->GetFontFromFontFace(glyphs->fontFace, font.GetAddressOf())) ||
        FAILED(font->GetFontFamily(resolved.GetAddressOf())) ||
        FAILED(resolved->GetFamilyNames(names.GetAddressOf())))
      return E_FAIL;
    UINT32 index = 0;
    BOOL found = FALSE;
    if (FAILED(names->FindLocaleName(L"en-us", &index, &found)))
      return E_FAIL;
    if (!found)
      index = 0;
    UINT32 length = 0;
    if (FAILED(names->GetStringLength(index, &length)))
      return E_FAIL;
    std::wstring name(length + 1, L'\0');
    if (FAILED(names->GetString(index, name.data(), length + 1)))
      return E_FAIL;
    name.resize(length);
    family = std::move(name);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DrawUnderline(
      void*, FLOAT, FLOAT, const DWRITE_UNDERLINE*, IUnknown*) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DrawStrikethrough(
      void*, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH*, IUnknown*) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DrawInlineObject(
      void*, FLOAT, FLOAT, IDWriteInlineObject*, BOOL, BOOL, IUnknown*) override {
    return S_OK;
  }

  std::wstring family;

 private:
  ULONG references_ = 1;
  IDWriteFontCollection* fonts_;
};

// Hash UTF-16 code units without recording any draft or candidate text.
void MixAppearanceText(std::uint64_t& hash, const std::wstring& text) {
  for (wchar_t letter : text) {
    hash ^= static_cast<std::uint16_t>(letter);
    hash *= 1099511628211ull;
  }
}

std::uint64_t AppearanceTextFingerprint(const std::wstring& text) {
  std::uint64_t hash = 14695981039346656037ull;
  MixAppearanceText(hash, text);
  return hash;
}

class AppearancePaintTrace {
 public:
  AppearancePaintTrace() : previous_(active) {
    const DWORD length = GetEnvironmentVariableW(
        L"STELLAE_TEST_PAINT_TRACE", path_, ARRAYSIZE(path_));
    active = length && length < ARRAYSIZE(path_) ? this : nullptr;
  }
  ~AppearancePaintTrace() { active = previous_; }

  void ObserveLayout(IDWriteTextLayout* layout, IDWriteFactory* factory) {
    if (!family_.empty() || !layout || !factory)
      return;
    Microsoft::WRL::ComPtr<IDWriteFontCollection> fonts;
    if (FAILED(factory->GetSystemFontCollection(fonts.GetAddressOf())))
      return;
    AppearanceGlyphProbe glyphs(fonts.Get());
    if (SUCCEEDED(layout->Draw(nullptr, &glyphs, 0, 0)))
      family_ = std::move(glyphs.family);
  }

  void Append(HWND window,
              const weasel::Context& context,
              const weasel::UIStyle& style) const {
    if (!submitted || family_.empty() || context.preedit.str.empty() ||
        context.cinfo.candies.empty() ||
        context.cinfo.highlighted >= context.cinfo.candies.size())
      return;
    std::uint64_t draft = AppearanceTextFingerprint(context.preedit.str);
    for (const auto& candidate : context.cinfo.candies) {
      MixAppearanceText(draft, L"\n");
      MixAppearanceText(draft, candidate.str);
    }
    const auto selected = AppearanceTextFingerprint(
        context.cinfo.candies[context.cinfo.highlighted].str);
    const std::wstring line =
        std::to_wstring(reinterpret_cast<UINT_PTR>(window)) + L"\t" +
        std::to_wstring(draft) + L"\t" + std::to_wstring(selected) + L"\t" +
        std::to_wstring(context.cinfo.candies.size()) + L"\t" + family_ + L"\t" +
        std::to_wstring(static_cast<std::uint32_t>(style.back_color)) + L"\t" +
        std::to_wstring(static_cast<std::uint32_t>(style.candidate_text_color)) + L"\t" +
        std::to_wstring(static_cast<std::uint32_t>(style.hilited_candidate_back_color)) + L"\t" +
        std::to_wstring(static_cast<std::uint32_t>(style.hilited_candidate_text_color)) + L"\n";
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, line.data(),
        static_cast<int>(line.size()), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0)
      return;
    std::string utf8(bytes, '\0');
    if (!WideCharToMultiByte(CP_UTF8, 0, line.data(), static_cast<int>(line.size()),
                           utf8.data(), bytes, nullptr, nullptr))
      return;
    HANDLE trace = CreateFileW(path_, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (trace == INVALID_HANDLE_VALUE)
      return;
    DWORD written = 0;
    WriteFile(trace, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
    CloseHandle(trace);
  }

  static thread_local AppearancePaintTrace* active;
  bool submitted = false;

 private:
  AppearancePaintTrace* previous_;
  wchar_t path_[4096] = {};
  std::wstring family_;
};

thread_local AppearancePaintTrace* AppearancePaintTrace::active = nullptr;

}  // namespace
