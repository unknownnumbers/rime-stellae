// SPDX-License-Identifier: GPL-3.0-only
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <future>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using UINT = unsigned int;
using BOOL = bool;
using WCHAR = wchar_t;
using HWND = void*;
using HMENU = void*;
using HMODULE = void*;
enum { IDI_ZH, IDI_EN, IDI_RELOAD, IDR_MENU_POPUP, IDS_STR_UNDER_MAINTENANCE };
enum { WEASEL_IPC_LAST_COMMAND = 1000, WM_WEASEL_SERVICE_NOTIFY = 1200 };

struct CIcon { void LoadIconW(int) {} };
struct CString { void LoadStringW(int) {} };
HMODULE GetModuleHandle(void*) { return nullptr; }
std::wstring get_weasel_ime_name() { return L"Fixture"; }

std::atomic<int> posts{0};
bool accept_post = true;
BOOL PostMessage(HWND target, UINT message, int, int) {
  if (!target || message != WM_WEASEL_SERVICE_NOTIFY)
    throw std::logic_error("invalid tray message");
  ++posts;
  return accept_post;
}

struct CSystemTray {
  HWND target = nullptr;
  std::wstring icon;
  std::function<void()> shell_hook;
  std::thread::id shell_thread;
  unsigned shows = 0;
  BOOL Create(HMODULE, HWND, UINT, const WCHAR*, CIcon, UINT) { return true; }
  void SetTargetWnd(HWND window) { target = window; }
  HWND GetTargetWnd() { return target; }
  void AddIcon() {}
  void RemoveIcon() {}
  bool Visible() { return true; }
  void SetIcon(UINT id) { icon = std::to_wstring(id); }
  void SetIcon(const WCHAR* path) { icon = path; }
  void ShowBalloon(CString, const WCHAR*) {}
  void ShowIcon() {
    ++shows;
    shell_thread = std::this_thread::get_id();
    if (shell_hook)
      shell_hook();
  }
};

namespace weasel {
struct UIStyle {
  bool display_tray_icon = true;
  std::wstring current_zhung_icon = L"cn.ico";
  std::wstring current_ascii_icon = L"red-a.ico";
};
struct Status { bool disabled = false, ascii_mode = false; };
struct UI {
  UIStyle appearance;
  Status mode;
  UIStyle& style() { return appearance; }
  Status& status() { return mode; }
};
}  // namespace weasel

using WeaselSessionId = unsigned;
struct RimeApi {
  std::map<unsigned, bool> options;
  void set_option(unsigned id, const char*, bool val) { options[id] = val; }
} api;
auto* rime_api = &api;

struct RimeWithWeaselHandler {
  struct Session {
    unsigned session_id;
    struct { bool is_ascii_mode = false; } status;
  };
  bool m_global_ascii_mode = false;
  unsigned m_active_session = 1;
  unsigned refreshed = 0;
  std::map<unsigned, Session> m_session_status_map{{1, {101}}, {2, {102}}};
  unsigned to_session_id(unsigned id) { return m_session_status_map.at(id).session_id; }
  void _UpdateUI(unsigned id) { refreshed = id; }
  void SetOption(WeaselSessionId ipc_id, const std::string& opt, bool val);
};

#include "production.h"

void require(bool condition, const char* name) {
  if (!condition)
    throw std::runtime_error(name);
}

void test_blocked_shell() {
  weasel::UI ui;
  WeaselTrayIcon tray(ui);
  tray.Create(&ui);
  std::mutex api_lock;
  std::promise<void> shell_entered, release_shell;
  auto release = release_shell.get_future();
  tray.shell_hook = [&] { shell_entered.set_value(); release.wait(); };
  auto ipc = std::async(std::launch::async, [&] {
    std::lock_guard<std::mutex> lock(api_lock);
#if FIXTURE_BASELINE
    tray.Refresh();
#else
    tray.RequestRefresh();
#endif
  });
#if !FIXTURE_BASELINE
  ipc.get();
  auto window = std::async(std::launch::async, [&] {
    auto id = std::this_thread::get_id();
    tray.ApplyRefresh();
    return id;
  });
#endif
  shell_entered.get_future().wait();
  // Echo can enter the same API mutex while the simulated Shell call is paused.
  bool echo = api_lock.try_lock();
  if (echo)
    api_lock.unlock();
#if FIXTURE_BASELINE
  release_shell.set_value();
  ipc.get();
  require(!echo, "baseline must reproduce the blocked pipe");
#else
  std::promise<void> disabling;
  auto drain = std::async(std::launch::async, [&] {
    disabling.set_value();
    tray.DisableRefresh();
  });
  disabling.get_future().wait();
  bool waiting = drain.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout;
  release_shell.set_value();
  drain.get();
  require(waiting, "shutdown returned during the Shell call");
  require(window.get() == tray.shell_thread, "Shell must run on the window thread");
  require(echo, "Shell held the API mutex");
#endif
}

#if !FIXTURE_BASELINE
void test_latest_snapshot() {
  weasel::UI ui;
  WeaselTrayIcon tray(ui);
  tray.Create(&ui);
  posts = 0;
  tray.RequestRefresh();
  ui.style().current_zhung_icon = L"blue-en.ico";
  tray.RequestRefresh();
  ui.style().current_zhung_icon = L"next.ico";
  require(posts == 1 && tray.shows == 0, "pending requests did not coalesce");
  tray.ApplyRefresh();
  require(tray.icon == L"blue-en.ico", "lost latest captured icon");
  ui.status().ascii_mode = true;
  tray.RequestRefresh();
  tray.ApplyRefresh();
  require(tray.icon == L"red-a.ico", "wrong ASCII icon");

  ui.status().ascii_mode = false;
  accept_post = false;
  tray.RequestRefresh();
  accept_post = true;
  tray.RequestRefresh();
  require(posts == 4, "failed post was not retried");
  tray.ApplyRefresh();
  require(tray.icon == L"next.ico", "retry did not publish the new state");
  tray.RequestRefresh();
  tray.DisableRefresh();
  auto before = tray.shows;
  tray.ApplyRefresh();
  tray.RequestRefresh();
  require(posts == 5 && tray.shows == before, "shutdown kept pending work");
}

void test_option_target() {
  RimeWithWeaselHandler handler;
  handler.SetOption(2, "ascii_mode", true);
  require(api.options.size() == 1 && api.options.at(102) && handler.refreshed == 2,
          "per-session option target changed");
  handler.SetOption(0, "ascii_mode", true);
  require(api.options.at(101) && handler.refreshed == 1, "active-session fallback failed");
  handler.m_global_ascii_mode = true;
  handler.SetOption(2, "ascii_mode", false);
  require(!api.options.at(101) && !api.options.at(102) && handler.refreshed == 1,
          "global option did not refresh the active session");
}
#endif

int main() {
  test_blocked_shell();
#if FIXTURE_BASELINE
  std::cout << "Baseline reproduced: a blocked Shell call held the API mutex.\n";
#else
  test_latest_snapshot();
  test_option_target();
  std::cout << "Passed: pipe progress, window-thread dispatch, latest snapshot, post retry, shutdown, mode target.\n";
#endif
}
