// SPDX-License-Identifier: GPL-3.0-only
// Actual production mode/icon functions with bounded configuration/UI boundaries.
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <string>

namespace fs = std::filesystem;
using Bool = int;
struct RimeConfig {
  std::map<std::string, std::string> strings;
  std::map<std::string, Bool> bools;
  std::map<std::string, int> ints;
};
struct FakeApi {
  bool config_get_string(RimeConfig* config, const char* key, char* value,
                         size_t length) {
    auto item = config->strings.find(key);
    if (item == config->strings.end()) return false;
    if (length) {
      const auto copied = (std::min)(length, item->second.size());
      std::copy_n(item->second.begin(), copied, value);
      value[copied] = 0;
    }
    return true;
  }
  bool config_get_bool(RimeConfig* config, const char* key, Bool* value) {
    auto item = config->bools.find(key);
    if (item == config->bools.end()) return false;
    *value = item->second;
    return true;
  }
  bool config_get_int(RimeConfig* config, const char* key, int* value) {
    auto item = config->ints.find(key);
    if (item == config->ints.end()) return false;
    *value = item->second;
    return true;
  }
};
static FakeApi fake_api;
static FakeApi* rime_api = &fake_api;
static fs::path root;
static fs::path WeaselUserDataPath() { return root / "user"; }
static fs::path WeaselSharedDataPath() { return root / "shared"; }
static std::wstring u8tow(const char* value) {
  const std::string text(value);
  return std::wstring(text.begin(), text.end());
}
struct UIStyle {
  enum LayoutType { LAYOUT_VERTICAL, LAYOUT_HORIZONTAL };
  LayoutType layout_type = LAYOUT_HORIZONTAL;
  int candidate_spacing = 16;
  int comment_font_point = 12;
  std::wstring current_zhung_icon = L"base-zh.ico";
  std::wstring current_ascii_icon = L"native-ascii.ico";
  std::wstring current_full_icon = L"native-full.ico";
  std::wstring current_half_icon = L"native-half.ico";
  bool inline_preedit = false;
};
struct SessionStatus {
  std::string mode_schema_id;
  std::string mode_option;
  bool mode_horizontal[2] = {true, true};
  int mode_spacing[2] = {16, 16};
  int mode_comment_font_point[2] = {12, 12};
  std::wstring mode_zhung_icon[2];
  UIStyle style;
  bool __synced = true;
};
#include "production-load-icon.inc"
#include "production-apply-mode.inc"
static void LoadModeBlock(SessionStatus& session_status, UIStyle& style,
                          RimeConfig& config, const std::string& schema_id) {
  const int BUF_SIZE = 255;
  char buffer[BUF_SIZE + 1] = {0};
#include "production-load-mode.inc"
}
static int passed = 0;
static int failed = 0;
static void Check(const char* name, bool value) {
  std::cout << (value ? "PASS " : "FAIL ") << name << '\n';
  value ? ++passed : ++failed;
}
static void Touch(const fs::path& path) {
  fs::create_directories(path.parent_path());
  std::ofstream stream(path, std::ios::binary);
  stream << "synthetic icon marker";
}
static RimeConfig ModeConfig() {
  RimeConfig config;
  config.strings["style/mode_layout/option"] = "research_english";
  config.strings["style/mode_layout/on/icon"] = "icons/En.ico";
  config.bools["style/mode_layout/off/horizontal"] = true;
  config.bools["style/mode_layout/on/horizontal"] = false;
  config.ints["style/mode_layout/off/candidate_spacing"] = 16;
  config.ints["style/mode_layout/on/candidate_spacing"] = 4;
  config.ints["style/mode_layout/off/comment_font_point"] = 12;
  config.ints["style/mode_layout/on/comment_font_point"] = 14;
  return config;
}
int main(int argc, char** argv) {
  if (argc != 2) return 10;
  root = fs::absolute(argv[1]);
  if (fs::exists(root)) return 11;
  fs::create_directories(WeaselUserDataPath());
  fs::create_directories(WeaselSharedDataPath());
  Touch(WeaselUserDataPath() / "icons/En.ico");
  Touch(WeaselSharedDataPath() / "icons/En.ico");
  Touch(WeaselSharedDataPath() / "icons/shared.ico");
  Touch(WeaselUserDataPath() / "icons/off.ico");
  Touch(WeaselSharedDataPath() / "icons/directory.ico");
  fs::create_directories(WeaselUserDataPath() / "icons/directory.ico");
  const auto en = (WeaselUserDataPath() / "icons/En.ico").wstring();
  const auto shared = (WeaselSharedDataPath() / "icons/shared.ico").wstring();
  const auto off = (WeaselUserDataPath() / "icons/off.ico").wstring();
  RimeConfig paths;
  paths.strings["both"] = "icons/En.ico";
  paths.strings["shared"] = "icons/shared.ico";
  paths.strings["missing"] = "icons/absent.ico";
  paths.strings["directory"] = "icons/directory.ico";
  paths.strings["empty"] = "";
  Check("resolver-user-precedes-shared", LoadSchemaIcon(paths, "both", nullptr) == en);
  Check("resolver-shared-fallback", LoadSchemaIcon(paths, "shared", nullptr) == shared);
  Check("resolver-missing-file-empty", LoadSchemaIcon(paths, "missing", nullptr).empty());
  Check("resolver-directory-is-not-file", LoadSchemaIcon(paths, "directory", nullptr) ==
        (WeaselSharedDataPath() / "icons/directory.ico").wstring());
  Check("resolver-legacy-key-fallback", LoadSchemaIcon(paths, "absent", "shared") == shared);
  Check("resolver-present-primary-keeps-existing-semantics", LoadSchemaIcon(paths, "missing", "shared").empty());
  Check("resolver-empty-config-keeps-default", LoadSchemaIcon(paths, "empty", nullptr).empty());
  Check("resolver-missing-key-keeps-default", LoadSchemaIcon(paths, "absent", nullptr).empty());
  Check("resolver-primary-key-precedes-alias", LoadSchemaIcon(paths, "both", "shared") == en);

  SessionStatus session;
  UIStyle style;
  RimeConfig config = ModeConfig();
  LoadModeBlock(session, style, config, "fixture_chinese");
  Check("loader-records-option", session.mode_option == "research_english");
  Check("loader-records-schema", session.mode_schema_id == "fixture_chinese");
  Check("loader-off-inherits-base-icon", session.mode_zhung_icon[0] == L"base-zh.ico");
  Check("loader-on-configured-icon", session.mode_zhung_icon[1] == en);
  Check("loader-existing-layout-preserved", session.mode_horizontal[0] && !session.mode_horizontal[1]);
  Check("loader-existing-spacing-preserved", session.mode_spacing[0] == 16 && session.mode_spacing[1] == 4);
  Check("loader-existing-comment-preserved", session.mode_comment_font_point[0] == 12 && session.mode_comment_font_point[1] == 14);
  Check("apply-on-reports-change", ApplyModeStyle(session, 1, style));
  Check("apply-on-selects-En-icon", style.current_zhung_icon == en);
  Check("apply-on-keeps-layout-overlay", style.layout_type == UIStyle::LAYOUT_VERTICAL &&
        style.candidate_spacing == 4 && style.comment_font_point == 14);
  Check("apply-on-repeat-clean", !ApplyModeStyle(session, 1, style));
  Check("apply-off-reports-change", ApplyModeStyle(session, 0, style));
  Check("apply-off-restores-base-icon", style.current_zhung_icon == L"base-zh.ico");
  Check("apply-off-repeat-clean", !ApplyModeStyle(session, 0, style));
  Check("apply-native-ascii-icon-unchanged", style.current_ascii_icon == L"native-ascii.ico");
  Check("apply-shape-icons-unchanged", style.current_full_icon == L"native-full.ico" &&
        style.current_half_icon == L"native-half.ico");
  Check("apply-inline-behavior-unchanged", !style.inline_preedit);

  SessionStatus icon_only;
  icon_only.mode_zhung_icon[0] = L"base-zh.ico";
  icon_only.mode_zhung_icon[1] = en;
  UIStyle icon_style;
  bool dirty = ApplyModeStyle(icon_only, 1, icon_style);
  if (dirty) icon_only.__synced = false;
  Check("icon-only-change-reports-dirty", dirty);
  Check("icon-only-change-invalidates-style-sync", !icon_only.__synced);
  Check("icon-only-change-selects-icon", icon_style.current_zhung_icon == en);
  Check("icon-only-change-keeps-layout", icon_style.layout_type == UIStyle::LAYOUT_HORIZONTAL &&
        icon_style.candidate_spacing == 16 && icon_style.comment_font_point == 12);
  Check("icon-only-change-repeat-clean", !ApplyModeStyle(icon_only, 1, icon_style));
  Check("icon-only-off-reports-change", ApplyModeStyle(icon_only, 0, icon_style));
  Check("icon-only-off-restores-icon", icon_style.current_zhung_icon == L"base-zh.ico");

  UIStyle cached;
  UIStyle metadata_copy = cached;
  Check("metadata-copy-reflects-current-mode", ApplyModeStyle(icon_only, 1, metadata_copy) &&
        metadata_copy.current_zhung_icon == en);
  Check("metadata-copy-does-not-mutate-cached-style", cached.current_zhung_icon == L"base-zh.ico");
  Check("metadata-copy-does-not-consume-sync", session.__synced);

  config = ModeConfig();
  config.strings["style/mode_layout/off/icon"] = "icons/off.ico";
  LoadModeBlock(session, cached, config, "fixture_custom");
  Check("loader-explicit-off-icon", session.mode_zhung_icon[0] == off);
  ApplyModeStyle(session, 1, cached);
  ApplyModeStyle(session, 0, cached);
  Check("apply-restores-explicit-off-icon", cached.current_zhung_icon == off);

  config = ModeConfig();
  config.strings["style/mode_layout/on/icon"] = "icons/shared.ico";
  UIStyle second_base;
  second_base.current_zhung_icon = L"second-schema.ico";
  LoadModeBlock(session, second_base, config, "fixture_second");
  Check("schema-switch-reinitializes-off-icon", session.mode_zhung_icon[0] == L"second-schema.ico");
  Check("schema-switch-loads-new-on-icon", session.mode_zhung_icon[1] == shared);
  ApplyModeStyle(session, 1, second_base);
  ApplyModeStyle(session, 0, second_base);
  Check("schema-switch-restores-new-base", second_base.current_zhung_icon == L"second-schema.ico");

  UIStyle no_config_style;
  no_config_style.current_zhung_icon = L"third-schema.ico";
  RimeConfig no_config;
  LoadModeBlock(session, no_config_style, no_config, "fixture_no_overlay");
  Check("no-config-clears-old-option", session.mode_option.empty());
  Check("no-config-resets-both-icons", session.mode_zhung_icon[0] == L"third-schema.ico" &&
        session.mode_zhung_icon[1] == L"third-schema.ico");
  Check("no-config-keeps-style", no_config_style.current_zhung_icon == L"third-schema.ico");
  config = ModeConfig();
  config.strings["style/mode_layout/on/icon"] = "icons/absent.ico";
  LoadModeBlock(session, no_config_style, config, "fixture_missing_icon");
  Check("missing-icon-falls-back-both-states", session.mode_zhung_icon[0] == L"third-schema.ico" &&
        session.mode_zhung_icon[1] == L"third-schema.ico");
  ApplyModeStyle(session, 1, no_config_style);
  Check("missing-icon-does-not-clear-base", no_config_style.current_zhung_icon == L"third-schema.ico");
  config.strings.erase("style/mode_layout/on/icon");
  no_config_style.current_zhung_icon.clear();
  LoadModeBlock(session, no_config_style, config, "fixture_default_icon");
  Check("default-icon-empty-path-preserved", session.mode_zhung_icon[0].empty() && session.mode_zhung_icon[1].empty());
  ApplyModeStyle(session, 1, no_config_style);
  Check("default-icon-remains-native-default", no_config_style.current_zhung_icon.empty());
  config.ints["style/mode_layout/on/candidate_spacing"] = -7;
  LoadModeBlock(session, no_config_style, config, "fixture_spacing");
  Check("existing-negative-spacing-clamp", session.mode_spacing[1] == 0);
  std::cout << "RESULT passed=" << passed << " failed=" << failed << '\n';
  return failed ? 1 : 0;
}
