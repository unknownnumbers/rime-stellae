// Bounded regression tests for extracted production notification methods.
// SPDX-License-Identifier: GPL-3.0-only
#include <algorithm>
#include <codecvt>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <locale>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

using BOOL = int;
using Bool = int;
using RimeSessionId = std::uintptr_t;
using WeaselSessionId = std::uint32_t;
static constexpr BOOL TRUE = 1, FALSE = 0;
static constexpr Bool True = 1;
struct NullLog { template<class T> NullLog& operator<<(const T&) { return *this; } };
#define DLOG(level) NullLog{}
#define RIME_API_AVAILABLE(api, member) ((api)->member != nullptr)
#define STELLAE_LOG_INFO_GLOB L"*.log"
static constexpr int LANG_ENGLISH = 9, SUBLANG_ENGLISH_US = 1;
static constexpr int LANG_CHINESE = 4, SUBLANG_CHINESE_TRADITIONAL = 1, SUBLANG_CHINESE_SIMPLIFIED = 2;
static constexpr int MAKELANGID(int primary, int sub) { return (sub << 10) | primary; }
static int GetThreadUILanguage() { return MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US); }
static std::wstring u8tow(const std::string& value) {
  return std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>>{}.from_bytes(value);
}
namespace ibus {
static constexpr int Shift_L = 0xffe1, Shift_R = 0xffe2;
namespace Modifier { static constexpr int RELEASE_MASK = 0x4000; }
namespace Keycode { static constexpr int Escape = 0xff1b, XK_c = 'c', XK_C = 'C', XK_bracketleft = '['; }
}
struct ShiftSnapshot { std::string value; std::string PropertyValue() const { return value; } };
struct KeyEvent { int keycode = 0, mask = 0; ShiftSnapshot shift_snapshot; };
static int expand_ibus_modifier(int mask) { return (mask & 0xff) | ((mask & 0xff00) << 16); }
static RimeSessionId to_session_id(WeaselSessionId id) { return id + 1000; }
struct Context { struct { std::wstring str; } aux; };
enum { SCHEMA = 1, FULL_SHAPE = 2 };
struct Status { int type = 0; bool ascii_mode = false; std::wstring schema_name = L"Synthetic schema"; };

using Notify = void (*)(void*, std::uintptr_t, const char*, const char*);
static Notify notify = nullptr;
static void* notify_owner = nullptr;
static std::map<RimeSessionId, std::map<std::string, std::string>> properties;
static std::map<RimeSessionId, std::map<std::string, bool>> options;
struct Event { RimeSessionId session; std::string type, value; };
static std::vector<Event> events;
struct Seen { RimeSessionId session; int key, mask; std::string snapshot; };
static std::vector<Seen> seen;
static bool mode_on_shift_release = false, mode_on_ctrl_grave = false, change_preedit = false, throw_from_process = false;
static unsigned property_calls = 0;
static void Emit(RimeSessionId session, const char* type, const std::string& value) {
  events.push_back({session, type, value});
  if (notify) notify(notify_owner, session, type, value.c_str());
}
static void SetProperty(RimeSessionId session, const char* name, const char* value) {
  ++property_calls;
  properties[session][name] = value;
  Emit(session, "property", std::string(name) + '=' + value);
}
static void SetOption(RimeSessionId session, const char* name, Bool value) {
  options[session][name] = value != 0;
  Emit(session, "option", std::string(value ? "" : "!") + name);
}
static Bool GetOption(RimeSessionId session, const char* name) { return options[session][name]; }
static const char* GetStateLabel(RimeSessionId, const char* name, Bool value) {
  if (!std::strcmp(name, "research_english")) return value ? "智能英文" : "中文";
  if (!std::strcmp(name, "simplification")) return value ? "SC" : "TC";
  if (!std::strcmp(name, "full_shape")) return value ? "Full" : "Half";
  if (!std::strcmp(name, "ascii_mode")) return value ? "ASCII" : "中文";
  return nullptr;
}
static Bool Process(RimeSessionId session, int key, int mask) {
  seen.push_back({session, key, mask, properties[session]["weasel_shift_snapshot"]});
  if (throw_from_process) throw std::runtime_error("synthetic process failure");
  const bool release = (mask & 0x40000000) != 0;
  if ((mode_on_shift_release && release && key == ibus::Shift_L) ||
      (mode_on_ctrl_grave && !release && key == '`' && (mask & 4))) {
    SetOption(session, "research_english", !GetOption(session, "research_english"));
    if (change_preedit) SetProperty(session, "cn_preedit_spacing", "");
  } else if (mode_on_shift_release && release && key == ibus::Shift_R) {
    SetOption(session, "ascii_mode", !GetOption(session, "ascii_mode"));
  }
  return True;
}
struct FakeApi {
  decltype(&Process) process_key = Process;
  decltype(&SetProperty) set_property = SetProperty;
  decltype(&GetOption) get_option = GetOption;
  decltype(&SetOption) set_option = SetOption;
  decltype(&GetStateLabel) get_state_label = GetStateLabel;
};
static FakeApi api;
static FakeApi* rime_api = &api;
struct FakeUi {
  int updates = 0, shows = 0, last_timeout = 0;
  bool counting = false;
  std::wstring last_tips;
  Status last_status;
  void Update(const Context& context, const Status& status) { ++updates; last_tips = context.aux.str; last_status = status; }
  bool IsCountingDown() const { return counting; }
  void ShowWithTimeout(int timeout) { ++shows; last_timeout = timeout; counting = true; }
};
static bool add_session = false;
class RimeWithWeaselHandler {
 public:
  using EatLine = int;
  bool m_disabled = false;
  WeaselSessionId m_active_session = 0;
  FakeUi ui;
  FakeUi* m_ui = &ui;
  std::map<std::string, bool> m_show_notifications{{"always", true}};
  int m_show_notifications_time = 270;
  int responses = 0, ui_calls = 0;
  std::map<std::string, std::string> response_properties;
  std::string received_type, received_value, received_label, received_option;
  static std::string m_message_type, m_message_value, m_message_label, m_option_name;
  static void OnNotify(void*, std::uintptr_t, const char*, const char*);
  BOOL ProcessKeyEvent(KeyEvent, WeaselSessionId, EatLine);
  bool _ShowMessage(Context&, Status&);
  void _Respond(WeaselSessionId id, EatLine) { ++responses; response_properties = properties[to_session_id(id)]; }
  void _UpdateUI(WeaselSessionId id) {
    ++ui_calls;
    received_type = m_message_type; received_value = m_message_value;
    received_label = m_message_label; received_option = m_option_name;
    Context context;
    Status status;
    status.ascii_mode = GetOption(to_session_id(id), "ascii_mode");
    _ShowMessage(context, status);
#include "production-notification-reset.inc"
  }
};
std::string RimeWithWeaselHandler::m_message_type;
std::string RimeWithWeaselHandler::m_message_value;
std::string RimeWithWeaselHandler::m_message_label;
std::string RimeWithWeaselHandler::m_option_name;
#include "production-notify-handler.inc"
#include "production-engine-handler.inc"
#include "production-show-message.inc"

static int passed = 0, failed = 0;
static void Check(const std::string& name, bool condition) {
  std::cout << (condition ? "PASS " : "FAIL ") << name << '\n';
  condition ? ++passed : ++failed;
}
static void Reset(RimeWithWeaselHandler& handler) {
  properties.clear(); options.clear(); events.clear(); seen.clear(); property_calls = 0;
  mode_on_shift_release = mode_on_ctrl_grave = change_preedit = throw_from_process = false;
  add_session = false;
  handler.ui = FakeUi{}; handler.responses = handler.ui_calls = 0;
  handler.response_properties.clear(); handler.m_disabled = false;
  handler.m_show_notifications = {{"always", true}}; handler.m_show_notifications_time = 270;
  RimeWithWeaselHandler::m_message_type.clear(); RimeWithWeaselHandler::m_message_value.clear();
  RimeWithWeaselHandler::m_message_label.clear(); RimeWithWeaselHandler::m_option_name.clear();
  notify = RimeWithWeaselHandler::OnNotify; notify_owner = &handler;
}
static void Send(RimeWithWeaselHandler& handler, int key, int mask, const std::string& snapshot = "", unsigned id = 10) {
  KeyEvent event{key, mask, {snapshot}};
  handler.ProcessKeyEvent(event, id, 0);
}
static void Tap(RimeWithWeaselHandler& handler, int key) {
  Send(handler, key, 0, "v1:5:100:16:2752513");
  Send(handler, key, ibus::Modifier::RELEASE_MASK, "v1:1:101:16:3223977985");
}

int main() {
  RimeWithWeaselHandler handler;
  const RimeSessionId session = to_session_id(10);
  Reset(handler); mode_on_shift_release = true;
  Send(handler, ibus::Shift_L, 0, "v1:5:100:16:2752513");
  Check("shift-down-has-no-mode-popup", handler.ui.shows == 0 && !GetOption(session, "research_english"));
  Check("snapshot-valid-during-engine-call", seen.back().snapshot == "v1:5:100:16:2752513");
  Check("snapshot-cleared-after-down", properties[session]["weasel_shift_snapshot"].empty());
  Send(handler, ibus::Shift_L, ibus::Modifier::RELEASE_MASK, "v1:1:101:16:3223977985");
  Check("left-shift-toggles-mode", GetOption(session, "research_english"));
  Check("left-shift-option-survives-cleanup", handler.received_type == "option" && handler.received_value == "research_english");
  Check("left-shift-smart-english-popup", handler.ui.shows == 1 && handler.ui.last_tips == L"智能英文");
  Check("left-shift-timeout-remains-270", handler.ui.last_timeout == 270);
  Check("snapshot-cleared-after-up", properties[session]["weasel_shift_snapshot"].empty());
  Check("response-sees-cleared-snapshot", handler.response_properties["weasel_shift_snapshot"].empty());
  Check("raw-property-notifications-still-emitted", std::count_if(events.begin(), events.end(), [](const Event& e){ return e.type == "property"; }) == 4);
  Check("production-reset-clears-pending-message", RimeWithWeaselHandler::m_message_type.empty() && RimeWithWeaselHandler::m_message_label.empty());
  Tap(handler, ibus::Shift_L);
  Check("left-shift-back-to-chinese", !GetOption(session, "research_english"));
  Check("left-shift-chinese-popup", handler.ui.shows == 2 && handler.ui.last_tips == L"中文");

  Reset(handler); mode_on_shift_release = true;
  Tap(handler, ibus::Shift_R);
  Check("right-shift-ascii-option-survives-cleanup", handler.received_type == "option" && handler.received_value == "ascii_mode");
  Check("right-shift-ascii-icon-popup", handler.ui.shows == 1 && handler.ui.last_status.ascii_mode && handler.ui.last_tips.empty());
  Tap(handler, ibus::Shift_R);
  Check("right-shift-back-icon-popup", handler.ui.shows == 2 && !handler.ui.last_status.ascii_mode);

  Reset(handler); mode_on_ctrl_grave = true;
  Send(handler, '`', 4);
  Check("ctrl-grave-mode-popup-unchanged", handler.ui.shows == 1 && handler.ui.last_tips == L"智能英文");
  Check("ctrl-grave-no-snapshot-property", property_calls == 0 && seen.back().snapshot.empty());
  Send(handler, '`', 4);
  Check("ctrl-grave-return-popup-unchanged", handler.ui.shows == 2 && handler.ui.last_tips == L"中文");

  Reset(handler); mode_on_shift_release = true; change_preedit = true;
  properties[session]["cn_preedit_spacing"] = "1:3:4:4|3";
  Tap(handler, ibus::Shift_L);
  Check("preedit-property-does-not-replace-option", handler.received_type == "option" && handler.ui.shows == 1);
  Check("preedit-metadata-change-remains-visible", properties[session]["cn_preedit_spacing"].empty() && handler.response_properties["cn_preedit_spacing"].empty());
  Check("snapshot-metadata-still-cleared-with-preedit", handler.response_properties["weasel_shift_snapshot"].empty());

  Reset(handler);
  SetProperty(session, "cn_preedit_spacing", "1:3:4:4|3");
  handler._Respond(10, 0); handler._UpdateUI(10);
  Check("property-only-produces-no-popup", handler.ui.shows == 0);
  Check("property-only-metadata-is-preserved", handler.response_properties["cn_preedit_spacing"] == "1:3:4:4|3");

  Reset(handler);
  Send(handler, ibus::Shift_L, 0, "v1:5:100:16:2752513");
  Send(handler, 'A', 1);
  Send(handler, ibus::Shift_L, ibus::Modifier::RELEASE_MASK, "v1:1:101:16:3223977985");
  Check("no-option-chord-produces-no-popup", handler.ui.shows == 0 && !GetOption(session, "research_english"));
  Check("nonshift-call-has-no-snapshot", seen[1].snapshot.empty());
  Check("no-option-chord-clears-snapshot", properties[session]["weasel_shift_snapshot"].empty());

  Reset(handler); throw_from_process = true;
  bool caught = false;
  try { Send(handler, ibus::Shift_L, 0, "v1:5:100:16:2752513"); } catch(const std::runtime_error&) { caught = true; }
  Check("exception-still-clears-snapshot", caught && properties[session]["weasel_shift_snapshot"].empty());
  Check("exception-emits-clear-notification", property_calls == 2 && events.back().type == "property");
  Check("exception-does-not-run-ui-update", handler.ui_calls == 0 && handler.ui.shows == 0);
  Reset(handler); handler.m_disabled = true;
  Send(handler, ibus::Shift_L, 0, "v1:5:100:16:2752513");
  Check("disabled-path-remains-inactive", seen.empty() && property_calls == 0 && handler.ui_calls == 0);

  for (const std::string message : {"schema", "deploy"}) {
    Reset(handler);
    Emit(session, message.c_str(), message == "schema" ? "synthetic/Synthetic schema" : "success");
    SetProperty(session, "weasel_shift_snapshot", "");
    handler._UpdateUI(10);
    Check(message + "-survives-property", handler.received_type == message && handler.ui.shows == 1);
    Check(message + "-label-unchanged", handler.ui.last_tips == (message == "schema" ? L"Synthetic schema" : L"Deployed"));
  }
  for (const std::string option : {"simplification", "full_shape"}) {
    Reset(handler); SetOption(session, option.c_str(), 1); SetProperty(session, "cn_preedit_spacing", ""); handler._UpdateUI(10);
    Check(option + "-survives-property", handler.received_type == "option" && handler.received_option == option && handler.ui.shows == 1);
    Check(option + "-label-unchanged", handler.ui.last_tips == (option == "simplification" ? L"SC" : L"Full"));
    if (option == "full_shape") Check("full-shape-status-type-unchanged", handler.ui.last_status.type == FULL_SHAPE);
  }
  Reset(handler); SetOption(session, "research_english", 0); handler._UpdateUI(10);
  Check("false-option-label-unchanged", handler.ui.shows == 1 && handler.ui.last_tips == L"中文");
  Reset(handler); handler.m_show_notifications.clear(); SetOption(session, "research_english", 1); handler._UpdateUI(10);
  Check("notifications-disabled-remain-disabled", handler.ui.shows == 0);
  Reset(handler); handler.m_show_notifications_time = 0; SetOption(session, "research_english", 1); handler._UpdateUI(10);
  Check("zero-notification-time-kept", handler.ui.shows == 0 && handler.ui.updates == 1);
  Reset(handler); add_session = true; SetOption(session, "research_english", 1); handler._UpdateUI(10);
  Check("add-session-suppression-kept", handler.ui.shows == 0);
  Reset(handler); handler.m_show_notifications.clear(); add_session = true; Emit(session, "deploy", "start"); handler._UpdateUI(10);
  Check("deployment-notice-bypass-kept", handler.ui.shows == 1 && handler.ui.last_tips == L"Deploying RIME");

  Reset(handler); Emit(session, "option", "research_english");
  const auto pending_type = handler.m_message_type, pending_value = handler.m_message_value;
  RimeWithWeaselHandler::OnNotify(nullptr, session, "property", "x=y");
  RimeWithWeaselHandler::OnNotify(&handler, session, nullptr, "x=y");
  RimeWithWeaselHandler::OnNotify(&handler, session, "property", nullptr);
  Check("null-input-guards-preserved", handler.m_message_type == pending_type && handler.m_message_value == pending_value);
  Reset(handler); Emit(session, "unused-message", "ignored"); handler._UpdateUI(10);
  Check("other-unused-message-behavior-kept", handler.ui.shows == 0);
  std::cout << "RESULT passed=" << passed << " failed=" << failed << '\n';
  return failed ? 1 : 0;
}
