// SPDX-License-Identifier: GPL-3.0-only
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string_view>
#include <vector>

using std::max;
using std::min;
using DWORD = std::uint32_t;
using LONG = std::int32_t;
using HWND = void*;
using BOOL = int;
#define WINAPI
struct POINT { LONG x, y; };
using LPPOINT = POINT*;
struct RECT { LONG left, top, right, bottom; };
struct Message { DWORD Msg, wParam, lParam; };
constexpr DWORD WEASEL_IPC_UPDATE_INPUT_POS = 8;
constexpr DWORD ERROR_SUCCESS = 0, ERROR_MORE_DATA = 234, ERROR_INVALID_DATA = 13;
constexpr DWORD ERROR_GEN_FAILURE = 31, ERROR_INVALID_PARAMETER = 87;
static_assert(sizeof(Message) == 12 && sizeof(RECT) == 16);

void Check(bool matched, const char* name) {
  if (!matched) throw std::runtime_error(name);
}
bool Same(RECT a, RECT b) {
  return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom;
}

// Captures one message-mode write; response content is unused for positions.
enum class TransactionPhase { NotAttempted, WriteAttempted };
struct CaptureChannel {
  using Msg = Message;
  using Res = DWORD;
  struct Outcome {
    TransactionPhase phase = TransactionPhase::NotAttempted;
    DWORD reply = 0, error = 0;
  };
  static constexpr size_t _ResSize = sizeof(Res), _MsgSize = sizeof(Msg), buff_size = 1024;
  std::unique_ptr<char[]> buffer = std::make_unique<char[]>(buff_size);
  std::vector<char> wire;
  bool response_data_valid = false, has_body = false;
  int hpipe = 1;
  size_t writes = 0;
  char* SendBuffer() { return buffer.get() + _MsgSize; }
  bool _Ensure(DWORD*) { return true; }
  void _AbandonTransaction() {}
  void ClearBufferStream() {}
  void _Receive(int, DWORD*, size_t, TransactionPhase&) {}
  void _WritePipe(int, size_t size, char* bytes) {
    ++writes;
    wire.assign(bytes, bytes + size);
  }
#include "transaction.inc"
};
struct ClientImpl {
  DWORD session_id = 31;
  CaptureChannel channel;
  bool _Active() const { return true; }
  void _SendMessageOutcome(DWORD command, DWORD packed, DWORD id, std::string_view body) {
    Message header{command, packed, id};
    Check(channel.TransactOutcome(header, body).error == 0, "position transaction");
  }
  void UpdateInputPosition(const RECT&);
};
struct PipeServer {
  using Res = Message;
  static constexpr DWORD buff_size = 1024;
  struct Worker { std::unique_ptr<char[]> request_buffer = std::make_unique<char[]>(buff_size); };
  std::string_view unread;
  DWORD _ReadPipe(Worker*, void* target, DWORD size, DWORD& read) {
    read = static_cast<DWORD>(min(unread.size(), static_cast<size_t>(size)));
    memcpy(target, unread.data(), read);
    unread.remove_prefix(read);
    return unread.empty() ? ERROR_SUCCESS : ERROR_MORE_DATA;
  }
  const char* _ReceiveRequest(Worker*, Res&);
};
struct Handler {
  RECT rect{};
  DWORD session = 0;
  void UpdateInputPosition(RECT input, DWORD id) { rect = input; session = id; }
};
struct ServerImpl {
  Handler* m_pRequestHandler;
  void* m_hUser32Module = nullptr;
  DWORD OnUpdateInputPosition(DWORD, DWORD, const char*);
};
static int dpiCalls;
BOOL ConvertPoint(HWND, LPPOINT) { ++dpiCalls; return 1; }
auto GetProcAddress(void*, const char*) { return &ConvertPoint; }
#include "position.inc"

int main() {
  ClientImpl client;
  Handler handler;
  ServerImpl server{&handler};
  PipeServer pipe;
  PipeServer::Worker worker;
  Message header{};
  auto receive = [&]() {
    auto& wire = client.channel.wire;
    pipe.unread = {wire.data(), wire.size()};
    const auto body = pipe._ReceiveRequest(&worker, header);
    Check(header.Msg == WEASEL_IPC_UPDATE_INPUT_POS && header.lParam == client.session_id, "position/session");
    server.OnUpdateInputPosition(header.wParam, header.lParam, body);
    Check(handler.session == client.session_id, "delivered session");
  };
  auto checkPosition = [&](RECT input, RECT expected, bool extended) {
    const bool empty = Same(input, RECT{});
    const auto previous = client.channel.writes;
    dpiCalls = 0;
    client.UpdateInputPosition(input);
    Check(client.channel.writes == previous + 1, "one position write");
    Check(client.channel.wire.size() == sizeof(header) + (extended ? sizeof(RECT) : 0), "position frame size");
    receive();
    Check(Same(handler.rect, expected) && dpiCalls == (empty ? 0 : 2), "delivered rectangle or invalidation");
  };
  checkPosition({200, 33, 201, 51}, {200, 33, 206, 51}, false);
  checkPosition({3841, 351, 3842, 374}, {3840, 350, 3846, 372}, false);
  checkPosition({4094, 350, 4095, 372}, {4094, 350, 4100, 372}, false);
  checkPosition({0, 0, 1, 0}, {0, 0, 6, 0}, false);
  checkPosition({}, {}, false);
  const RECT extended[] = {
      {4095, 350, 4096, 372}, {5000, 350, 5001, 372}, {5119, -493, 5120, -470},
      {-5300, -6100, -5291, -6000}, {107, 6099, 107, 6508}, {107, 350, 109, 605},
      {0, std::numeric_limits<LONG>::min(), 3, std::numeric_limits<LONG>::max()}};
  for (auto rect : extended) checkPosition(rect, rect, true);

  // A .2 server ignores the body. A .2 client sends this header alone.
  client.UpdateInputPosition({5000, 351, 5001, 374});
  receive();
  Check(header.wParam == 0x8b0af7ffu, "legacy header from current client");
  client.channel.wire.resize(sizeof(Message));
  receive();
  Check(Same(handler.rect, RECT{4094, 350, 4100, 372}), "legacy header after full rectangle");
  client.UpdateInputPosition({-5300, -6000, -5290, -5990});
  client.channel.wire.resize(sizeof(Message));
  receive();
  Check(Same(handler.rect, RECT{-4096, -4096, -4090, -4086}), "signed legacy header");
  for (size_t length : {sizeof(Message) + 1, sizeof(Message) + sizeof(RECT) + 1}) {
    client.channel.wire.resize(length);
    bool rejected = false;
    try { receive(); } catch (DWORD error) { rejected = error == ERROR_INVALID_DATA; }
    Check(rejected, "incomplete or oversized position body");
  }
  std::cout << "PASS exact and legacy position frames, both axes, DPI path and invalidation\n";
}
