// Win32 DNS-SD implementation of the LAN network plugin (advertise + browse).
//
// The runner target compiles with _WIN32_WINNT=0x0601 (see runner/CMakeLists
// and windows/CMakeLists). windns.h declares the DnsService* DNS-SD APIs
// inside a WINAPI_FAMILY partition (desktop), which is visible at 0x0601, but
// we defensively re-raise the version macros to Windows 10 2004 before any
// Windows header so the declarations are guaranteed regardless of SDK layout.
// The #undef/#define below only affects this translation unit; the runner
// global definitions are intentionally left untouched.
#ifndef WINVER
#define WINVER 0x0A00
#endif
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#undef NTDDI_VERSION
#define NTDDI_VERSION 0x0A000000

#include <winsock2.h>
#include <windows.h>
#include <windns.h>
#include <ws2tcpip.h>

#include "lan_network_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <cstdio>
#include <string>
#include <utility>

namespace {

// Debug log; visible in debugger/OutputDebugString output and flutter run.
void Log(const char* message) {
  ::OutputDebugStringA("[lan_network_plugin] ");
  ::OutputDebugStringA(message);
  ::OutputDebugStringA("\n");
}

}  // namespace

LanNetworkPlugin::LanNetworkPlugin(HWND hwnd)
    : hwnd_(hwnd),
      marshal_message_(::RegisterWindowMessageW(L"ClipFlow.LanNetwork.Plugin")) {}

LanNetworkPlugin::~LanNetworkPlugin() {
  // Unregister() is expected to have been called by FlutterWindow::OnDestroy
  // before this destructor runs. A stopped plugin has nothing left to cancel.
}

void LanNetworkPlugin::RegisterWithMessenger(flutter::BinaryMessenger* messenger) {
  method_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "clipflow/lan_network", &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger, "clipflow/lan_network_events",
      &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const auto* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            (void)arguments;
            event_sink_ = std::move(events);
            return nullptr;
          },
          [this](const auto* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            (void)arguments;
            event_sink_.reset();
            return nullptr;
          }));
}

void LanNetworkPlugin::Unregister() {
  stopped_.store(true, std::memory_order_release);
  // M1: no active DNS-SD operations yet; M2/M3 cancel them here.
  DrainQueue();
  if (method_channel_) {
    method_channel_->SetMethodCallHandler(nullptr);
  }
  if (event_channel_) {
    event_channel_->SetStreamHandler(nullptr);
  }
  event_sink_.reset();
  method_channel_.reset();
  event_channel_.reset();
}

bool LanNetworkPlugin::DrainOne() {
  std::function<void()> task;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (task_queue_.empty()) {
      return false;
    }
    task = std::move(task_queue_.front());
    task_queue_.pop_front();
  }
  task();
  return true;
}

void LanNetworkPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "isSupported") {
    HandleIsSupported(std::move(result));
    return;
  }
  if (method == "advertise") {
    HandleAdvertise(call, std::move(result));
    return;
  }
  if (method == "browse") {
    HandleBrowse(call, std::move(result));
    return;
  }
  if (method == "stopAll") {
    HandleStopAll(std::move(result));
    return;
  }
  result->NotImplemented();
}

void LanNetworkPlugin::HandleIsSupported(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  result->Success(flutter::EncodableValue(IsSupported()));
}

// M1 skeleton: advertise is wired in M2. Report success so the Dart LAN
// discovery flow can start; no mDNS traffic is emitted yet.
void LanNetworkPlugin::HandleAdvertise(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  (void)call;
  if (!IsSupported()) {
    result->Error("unsupported", "LAN network requires Windows 10 1709+");
    return;
  }
  Log("advertise: not yet implemented (M2)");
  result->Success();
}

// M1 skeleton: browse is wired in M3. Report success so the Dart LAN
// discovery flow can start; no discovery events are emitted yet.
void LanNetworkPlugin::HandleBrowse(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  (void)call;
  if (!IsSupported()) {
    result->Error("unsupported", "LAN network requires Windows 10 1709+");
    return;
  }
  Log("browse: not yet implemented (M3)");
  result->Success();
}

void LanNetworkPlugin::HandleStopAll(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // stopAll never throws on this platform (matches Dart's swallow semantics).
  Log("stopAll: not yet implemented (M2/M3)");
  result->Success();
}

bool LanNetworkPlugin::IsSupported() {
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) {
    return false;
  }
  RtlGetVersionFn get_version = reinterpret_cast<RtlGetVersionFn>(
      ::GetProcAddress(ntdll, "RtlGetVersion"));
  if (get_version == nullptr) {
    return false;
  }
  RTL_OSVERSIONINFOW version_info{};
  version_info.dwOSVersionInfoSize = sizeof(version_info);
  if (get_version(&version_info) != 0) {
    return false;
  }
  // Windows 10 1709 (build 16299) introduced the built-in mDNS/DNS-SD stack.
  return version_info.dwMajorVersion == 10 &&
         version_info.dwBuildNumber >= 16299;
}

void LanNetworkPlugin::PostTask(std::function<void()> fn) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    task_queue_.push_back(std::move(fn));
  }
  ::PostMessageW(hwnd_, marshal_message_, 0, 0);
}

void LanNetworkPlugin::DrainQueue() {
  while (DrainOne()) {
  }
}
