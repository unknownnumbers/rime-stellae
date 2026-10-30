#define NOMINMAX
#include <windows.h>
#include <ShiftKeySnapshotWin.h>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

// Public synthetic fixtures around methods extracted verbatim from the patched
// product. No installed server, engine, schema, registry, or text store is used.
using RimeSessionId = std::uintptr_t;
using WeaselSessionId = DWORD;
using Bool = int;
static constexpr Bool True = 1;
struct NullLog { template<class T> NullLog& operator<<(const T&) { return *this; } };
#define DLOG(level) NullLog{}

struct Seen { RimeSessionId session; int key; int mask; std::string snapshot; };
static std::map<RimeSessionId, std::string> properties;
static std::vector<Seen> seen;
static unsigned property_calls = 0;
static bool throw_from_process = false;
static Bool Process(RimeSessionId session, int key, int mask) {
  seen.push_back({session, key, mask, properties[session]});
  if (throw_from_process) throw std::runtime_error("synthetic process failure");
  return 1;
}
static void SetProperty(RimeSessionId session, const char* name, const char* value) {
  if (std::string(name) != "weasel_shift_snapshot") throw std::runtime_error("unexpected property");
  ++property_calls;
  properties[session] = value;
}
struct FakeApi {
  decltype(&Process) process_key = Process;
  decltype(&SetProperty) set_property = SetProperty;
  Bool get_option(RimeSessionId, const char*) { return 0; }
  void set_option(RimeSessionId, const char*, Bool) {}
};
static FakeApi api;
static FakeApi* rime_api = &api;
static RimeSessionId to_session_id(WeaselSessionId id) { return id + 1000; }
static int expand_ibus_modifier(int mask) { return (mask & 0xff) | ((mask & 0xff00) << 16); }

enum WEASEL_IPC_COMMAND { WEASEL_IPC_PROCESS_KEY_EVENT = WM_APP + 4 };
namespace weasel {
struct RequestHandler {
  using EatLine = std::function<bool(std::wstring&)>;
  virtual ~RequestHandler() = default;
  virtual BOOL ProcessKeyEvent(KeyEvent, DWORD, EatLine) = 0;
};
struct DummyChannel {
  std::wstring stale_scratch = L"shift.v1=7,999,16,2752513\n";
  DummyChannel& operator<<(const std::wstring&) { return *this; }
};
struct ServerImpl {
  RequestHandler* m_pRequestHandler = nullptr;
  std::unique_ptr<DummyChannel> channel = std::make_unique<DummyChannel>();
  DWORD OnKeyEvent(WEASEL_IPC_COMMAND, DWORD, DWORD, const char* = nullptr);
};
}  // namespace weasel
using namespace weasel;

class RimeWithWeaselHandler : public RequestHandler {
 public:
  bool m_disabled = false;
  WeaselSessionId m_active_session = 0;
  int responses = 0;
  BOOL ProcessKeyEvent(KeyEvent, WeaselSessionId, EatLine) override;
  void _Respond(WeaselSessionId, EatLine) { ++responses; }
  void _UpdateUI(WeaselSessionId) {}
};
#include "production-key-handler.inc"
#include "production-engine-handler.inc"

static int passed = 0, failed = 0;
static void Check(const char* name, bool condition) {
  std::cout << (condition ? "PASS " : "FAIL ") << name << "\n";
  condition ? ++passed : ++failed;
}
static KeyInfo Info(UINT32 bits) { return KeyInfo(static_cast<LPARAM>(bits)); }
static std::wstring Body(unsigned flags, unsigned time = 100, unsigned info = 0x002a0001) {
  ShiftKeySnapshot snapshot;
  snapshot.flags = flags;
  snapshot.message_time = time;
  snapshot.original_vkey = VK_SHIFT;
  snapshot.key_info = info;
  return snapshot.Serialize();
}

int main() {
  BYTE state[256] = {};
  state[VK_SHIFT] = state[VK_LSHIFT] = 0x80;
  const HKL layout = GetKeyboardLayout(0);
  KeyEvent left(ibus::Shift_L, 0);
  auto capture = CaptureShiftSnapshot(left, Info(0x002a0001), TRUE, state, layout, VK_SHIFT, 100);
  Check("capture-left-fresh", capture.flags == 5);
  Check("capture-message-identity", capture.message_time == 100 && capture.original_vkey == VK_SHIFT && capture.key_info == 0x002a0001);
  state['A'] = 0x80;
  Check("capture-printable-held", CaptureShiftSnapshot(left, Info(0x002a0001), TRUE, state, layout, VK_SHIFT, 101).flags == 7);
  state['A'] = 0;
  state[VK_OEM_PLUS] = 0x80;
  Check("capture-symbol-held", (CaptureShiftSnapshot(left, Info(0x002a0001), TRUE, state, layout, VK_SHIFT, 101).flags & ShiftKeySnapshot::PrintableAnyDown) != 0);
  state[VK_OEM_PLUS] = 0;
  Check("capture-repeat-down", CaptureShiftSnapshot(left, Info(0x402a0001), TRUE, state, layout, VK_SHIFT, 102).flags == 21);
  state[VK_RSHIFT] = 0x80;
  Check("capture-both-shifts", CaptureShiftSnapshot(left, Info(0x002a0001), TRUE, state, layout, VK_SHIFT, 103).flags == 13);
  Check("capture-failed-read-invalid", !CaptureShiftSnapshot(left, Info(0x002a0001), FALSE, state, layout, VK_SHIFT, 104).valid());
  Check("capture-null-imm-state-invalid", !CaptureShiftSnapshot(left, Info(0x002a0001), TRUE, nullptr, layout, VK_SHIFT, 104).valid());
  state[VK_LSHIFT] = 0;
  Check("capture-contradictory-down-invalid", !CaptureShiftSnapshot(left, Info(0x002a0001), TRUE, state, layout, VK_SHIFT, 104).valid());
  state[VK_RSHIFT] = state[VK_SHIFT] = 0;
  KeyEvent left_up(ibus::Shift_L, ibus::RELEASE_MASK);
  Check("capture-up-all-released", CaptureShiftSnapshot(left_up, Info(0xc02a0001), TRUE, state, layout, VK_SHIFT, 105).flags == 1);
  KeyEvent letter('a', 0);
  Check("capture-only-shift", !CaptureShiftSnapshot(letter, Info(0x001e0001), TRUE, state, layout, 'A', 106).valid());

  const auto valid_body = Body(5);
  const auto parsed = ShiftKeySnapshot::Parse(valid_body.c_str());
  Check("codec-roundtrip", parsed.valid() && parsed.flags == 5 && parsed.message_time == 100 && parsed.key_info == 0x002a0001);
  Check("codec-property-format", parsed.PropertyValue() == "v1:5:100:16:2752513");
  const wchar_t* invalid[] = {nullptr, L"", L"shift.v1=5\n", L"shift.v2=5,100,16,2752513\n",
      L"shift.v1=0,100,16,2752513\n", L"shift.v1=33,100,16,2752513\n",
      L"shift.v1=5,4294967296,16,2752513\n", L"shift.v1=5,100,65,2752513\n",
      L"shift.v1=5,100,16,2752513\nextra", L"shift.v1=-1,100,16,2752513\n"};
  unsigned index = 0;
  for (auto body : invalid) {
    const std::string label = "codec-reject-" + std::to_string(index++);
    Check(label.c_str(), !ShiftKeySnapshot::Parse(body).valid());
  }
  left.shift_snapshot = parsed;
  const UINT32 wire = static_cast<UINT32>(left);
  Check("key-word-legacy-32-bits", wire == static_cast<UINT32>(ibus::Shift_L));
  Check("legacy-key-constructor-invalid", !KeyEvent(wire).shift_snapshot.valid());

  RimeWithWeaselHandler handler;
  ServerImpl server;
  server.m_pRequestHandler = &handler;
  auto send = [&](KeyEvent key, DWORD owner, const wchar_t* body) {
    return server.OnKeyEvent(WEASEL_IPC_PROCESS_KEY_EVENT, static_cast<UINT32>(key), owner,
                            reinterpret_cast<const char*>(body));
  };
  Check("product-current-body-handled", send(left, 10, valid_body.c_str()) == TRUE);
  Check("product-property-during-key", seen.back().snapshot == "v1:5:100:16:2752513" && seen.back().session == 1010);
  Check("product-property-cleared-after-key", properties[1010].empty());
  send(left, 10, nullptr);
  Check("product-null-body-never-reuses-scratch", seen.back().snapshot == "invalid" && !server.channel->stale_scratch.empty());
  Check("product-legacy-property-cleared", properties[1010].empty());
  send(left, 11, valid_body.c_str());
  Check("product-session-owner-preserved", seen.back().session == 1011 && properties[1010].empty() && properties[1011].empty());
  const auto before_nonshift_calls = property_calls;
  send(letter, 10, valid_body.c_str());
  Check("product-nonshift-ignores-body", seen.back().key == 'a' && seen.back().snapshot.empty());
  Check("product-nonshift-no-property-notifications", property_calls == before_nonshift_calls);
  send(left, 10, L"shift.v1=5,4294967296,16,2752513\n");
  Check("product-malformed-body-invalid", seen.back().snapshot == "invalid");
  throw_from_process = true;
  bool observed_throw = false;
  try { send(left, 10, valid_body.c_str()); } catch (const std::runtime_error&) { observed_throw = true; }
  Check("product-property-cleared-on-unwind", observed_throw && properties[1010].empty());
  throw_from_process = false;
  handler.m_disabled = true;
  const auto old_seen = seen.size();
  Check("product-disabled-no-key", send(left, 10, valid_body.c_str()) == FALSE && seen.size() == old_seen);
  std::cout << "RESULT passed=" << passed << " failed=" << failed << "\n";
  return failed ? 1 : 0;
}
