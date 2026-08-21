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

// Mutable wide-character buffer (null-terminated) for fields the OS may touch.
std::vector<wchar_t> WStringBuffer(const std::wstring& text) {
  std::vector<wchar_t> buffer(text.size() + 1, L'\0');
  for (size_t i = 0; i < text.size(); ++i) {
    buffer[i] = text[i];
  }
  return buffer;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  int size = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                   static_cast<int>(wide.size()), nullptr, 0,
                                   nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        utf8.data(), size, nullptr, nullptr);
  return utf8;
}

std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), size);
  return wide;
}

std::string DnsStatusMessage(DNS_STATUS status) {
  char buffer[64];
  std::snprintf(buffer, sizeof(buffer), "DNS status 0x%04lX",
                static_cast<unsigned long>(status));
  return std::string(buffer);
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
  // Teardown: do not complete in-flight results (the engine is going away);
  // just stop and clean up. Late DNS-SD callbacks see stopped_ and no-op.
  StopAllInternal(false);
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

void LanNetworkPlugin::HandleAdvertise(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!IsSupported()) {
    result->Error("unsupported", "LAN network requires Windows 10 1709+");
    return;
  }

  std::string device_id;
  std::string caps = "t";
  int32_t port = 0;
  bool valid_port = false;
  const flutter::EncodableValue* arguments = call.arguments();
  if (arguments != nullptr &&
      std::holds_alternative<flutter::EncodableMap>(*arguments)) {
    const flutter::EncodableMap& map =
        std::get<flutter::EncodableMap>(*arguments);
    auto it = map.find(flutter::EncodableValue("deviceId"));
    if (it != map.end() && std::holds_alternative<std::string>(it->second)) {
      device_id = std::get<std::string>(it->second);
    }
    it = map.find(flutter::EncodableValue("caps"));
    if (it != map.end() && std::holds_alternative<std::string>(it->second)) {
      caps = std::get<std::string>(it->second);
    }
    it = map.find(flutter::EncodableValue("port"));
    if (it != map.end()) {
      if (std::holds_alternative<int32_t>(it->second)) {
        port = std::get<int32_t>(it->second);
        valid_port = port > 0;
      } else if (std::holds_alternative<int64_t>(it->second)) {
        int64_t wide_port = std::get<int64_t>(it->second);
        valid_port = wide_port > 0 && wide_port <= 65535;
        if (valid_port) {
          port = static_cast<int32_t>(wide_port);
        }
      }
    }
  }
  if (device_id.empty() || !valid_port) {
    result->Error("badArgs", "deviceId/port required");
    return;
  }

  std::wstring device_wide = WideFromUtf8(device_id);
  std::wstring caps_wide = WideFromUtf8(caps);
  switch (adv_state_) {
    case AdvertiseState::kIdle:
      adv_result_ = std::move(result);
      adv_device_id_ = std::move(device_wide);
      adv_caps_ = std::move(caps_wide);
      adv_port_ = port;
      StartRegister();
      break;
    case AdvertiseState::kPendingRegister:
      // Re-entrant while a registration is in flight: supersede it. The old
      // result's work has been replaced, so complete it now, then route
      // through the deregister flow so the new request takes over.
      if (adv_result_) {
        adv_result_->Success();
        adv_result_.reset();
      }
      adv_result_ = std::move(result);
      adv_pending_device_id_ = std::move(device_wide);
      adv_pending_caps_ = std::move(caps_wide);
      adv_pending_port_ = port;
      adv_state_ = AdvertiseState::kPendingDeregister;
      DnsServiceRegisterCancel(&adv_cancel_);
      break;
    case AdvertiseState::kRegistered:
      // Re-entrant while registered: gracefully deregister (sends the mDNS
      // goodbye) and register the new instance once the callback returns.
      adv_result_ = std::move(result);
      adv_pending_device_id_ = std::move(device_wide);
      adv_pending_caps_ = std::move(caps_wide);
      adv_pending_port_ = port;
      adv_state_ = AdvertiseState::kPendingDeregister;
      if (adv_op_) {
        DnsServiceDeRegister(&adv_op_->request, nullptr);
      } else {
        CompletePendingRegistration();
      }
      break;
    case AdvertiseState::kPendingDeregister:
      // Already deregistering: replace the pending advertise request.
      if (adv_result_) {
        adv_result_->Success();
        adv_result_.reset();
      }
      adv_result_ = std::move(result);
      adv_pending_device_id_ = std::move(device_wide);
      adv_pending_caps_ = std::move(caps_wide);
      adv_pending_port_ = port;
      break;
  }
}

// M1/M2 boundary: browse is wired in M3. Report success so the Dart LAN
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
  StopAllInternal(true);
  result->Success();
}

void LanNetworkPlugin::StartRegister() {
  ++adv_operation_id_;
  auto op = std::make_unique<AdvertiseOp>();
  op->context = std::make_unique<RegisterContext>();
  op->context->self = this;
  op->context->operation_id = adv_operation_id_;

  std::wstring instance_name = adv_device_id_ + L"._clipflow._tcp.local";
  op->instance_name = WStringBuffer(instance_name);
  op->instance.pszInstanceName = op->instance_name.data();
  op->instance.pszHostName = nullptr;
  op->instance.ip4Address = nullptr;
  op->instance.ip6Address = nullptr;
  op->instance.wPort = static_cast<WORD>(adv_port_);
  op->instance.wPriority = 0;
  op->instance.wWeight = 0;
  // TXT whitelist: proto/device/caps (+port, ignored by Dart). No account
  // derived data, passwords, tokens, salt or fingerprints may ever be added.
  AddTxt(op.get(), L"proto", L"1");
  AddTxt(op.get(), L"device", adv_device_id_);
  AddTxt(op.get(), L"caps", adv_caps_);
  AddTxt(op.get(), L"port", std::to_wstring(adv_port_));
  op->instance.dwPropertyCount = static_cast<DWORD>(op->key_ptrs.size());
  op->instance.keys = op->key_ptrs.data();
  op->instance.values = op->value_ptrs.data();
  op->instance.dwInterfaceIndex = 0;

  op->request.Version = DNS_QUERY_REQUEST_VERSION1;
  op->request.InterfaceIndex = 0;
  op->request.pServiceInstance = &op->instance;
  op->request.pRegisterCompletionCallback =
      &LanNetworkPlugin::OnRegisterCallbackThunk;
  op->request.pQueryContext = op->context.get();
  op->request.hCredentials = nullptr;
  op->request.unicastEnabled = FALSE;

  adv_cancel_ = {};
  DNS_STATUS status = DnsServiceRegister(&op->request, &adv_cancel_);
  if (status == DNS_REQUEST_PENDING) {
    adv_state_ = AdvertiseState::kPendingRegister;
    adv_op_ = std::move(op);
  } else {
    adv_state_ = AdvertiseState::kIdle;
    if (adv_result_) {
      adv_result_->Error("registerFailed", DnsStatusMessage(status));
      adv_result_.reset();
    }
  }
}

void LanNetworkPlugin::OnRegisterComplete(DNS_STATUS status,
                                          uint64_t operation_id) {
  if (operation_id != adv_operation_id_) {
    return;  // Stale callback from a superseded operation.
  }
  switch (adv_state_) {
    case AdvertiseState::kPendingRegister:
      if (status == ERROR_SUCCESS) {
        adv_state_ = AdvertiseState::kRegistered;
        if (adv_result_) {
          adv_result_->Success();
          adv_result_.reset();
        }
      } else if (status == ERROR_CANCELLED) {
        // The in-flight registration was cancelled (re-entrant advertise or
        // stopAll); nothing was registered, continue the pending flow.
        adv_op_.reset();
        adv_cancel_ = {};
        CompletePendingRegistration();
      } else {
        adv_state_ = AdvertiseState::kIdle;
        adv_op_.reset();
        adv_cancel_ = {};
        if (adv_result_) {
          adv_result_->Error("registerFailed", DnsStatusMessage(status));
          adv_result_.reset();
        }
      }
      break;
    case AdvertiseState::kPendingDeregister:
      // Deregistration (or the cancelled pending registration) finished.
      adv_op_.reset();
      adv_cancel_ = {};
      CompletePendingRegistration();
      break;
    default:
      // kIdle/kRegistered with a late callback: nothing left to do.
      adv_op_.reset();
      adv_cancel_ = {};
      break;
  }
}

void LanNetworkPlugin::CompletePendingRegistration() {
  adv_op_.reset();
  adv_cancel_ = {};
  if (adv_pending_device_id_.has_value() && adv_pending_caps_.has_value() &&
      adv_pending_port_.has_value()) {
    adv_device_id_ = std::move(*adv_pending_device_id_);
    adv_caps_ = std::move(*adv_pending_caps_);
    adv_port_ = *adv_pending_port_;
    adv_pending_device_id_.reset();
    adv_pending_caps_.reset();
    adv_pending_port_.reset();
    StartRegister();
  } else {
    adv_state_ = AdvertiseState::kIdle;
  }
}

void LanNetworkPlugin::StopAllInternal(bool complete_inflight) {
  if (adv_result_) {
    if (complete_inflight) {
      adv_result_->Success();
    }
    adv_result_.reset();
  }
  adv_pending_device_id_.reset();
  adv_pending_caps_.reset();
  adv_pending_port_.reset();
  switch (adv_state_) {
    case AdvertiseState::kRegistered:
      adv_state_ = AdvertiseState::kPendingDeregister;
      if (adv_op_) {
        DnsServiceDeRegister(&adv_op_->request, nullptr);
      } else {
        adv_state_ = AdvertiseState::kIdle;
      }
      break;
    case AdvertiseState::kPendingRegister:
      DnsServiceRegisterCancel(&adv_cancel_);
      break;
    default:
      break;
  }
}

void LanNetworkPlugin::AddTxt(AdvertiseOp* op, const std::wstring& key,
                              const std::wstring& value) {
  op->keys.push_back(WStringBuffer(key));
  op->values.push_back(WStringBuffer(value));
  op->key_ptrs.push_back(op->keys.back().data());
  op->value_ptrs.push_back(op->values.back().data());
}

void CALLBACK LanNetworkPlugin::OnRegisterCallbackThunk(
    DNS_STATUS status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
  auto* ctx = static_cast<RegisterContext*>(context);
  LanNetworkPlugin* self = ctx->self;
  uint64_t operation_id = ctx->operation_id;
  (void)instance;
  if (self->stopped_.load(std::memory_order_acquire)) {
    return;
  }
  self->PostTask([self, status, operation_id]() {
    if (self->stopped_.load(std::memory_order_acquire)) {
      return;
    }
    self->OnRegisterComplete(status, operation_id);
  });
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
