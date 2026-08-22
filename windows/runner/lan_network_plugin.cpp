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
#include <iphlpapi.h>

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
#include <vector>

namespace {

// Debug log; visible in debugger/OutputDebugString output and flutter run.
void Log(const char* message) {
  ::OutputDebugStringA("[lan_network_plugin] ");
  ::OutputDebugStringA(message);
  ::OutputDebugStringA("\n");
}

// mDNS service type browsed/registered by this plugin (Dart ignores the
// serviceType argument on every platform and this value matches
// LanConstants.lanServiceType).
constexpr wchar_t kServiceQueryName[] = L"_clipflow._tcp.local";

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

std::string DnsStatusMessage(DWORD status) {
  char buffer[64];
  std::snprintf(buffer, sizeof(buffer), "DNS status 0x%04lX",
                static_cast<unsigned long>(status));
  return std::string(buffer);
}

// Machine host name for DnsServiceRegister (probe-verified requirement:
// pszHostName must be non-null or registration fails). Falls back from the
// DNS FQDN to the NetBIOS name.
std::wstring GetMachineHostName() {
  wchar_t buffer[256] = L"";
  DWORD size = 256;
  if (::GetComputerNameExW(ComputerNameDnsFullyQualified, buffer, &size) &&
      buffer[0] != L'\0') {
    return std::wstring(buffer);
  }
  size = 256;
  if (::GetComputerNameExW(ComputerNamePhysicalNetBIOS, buffer, &size) &&
      buffer[0] != L'\0') {
    return std::wstring(buffer);
  }
  return std::wstring();
}

// Primary operational IPv4 (skips loopback/tunnel). Stored network-order in
// the DNS_SERVICE_INSTANCE.ip4Address field (IP4_ADDRESS is a DWORD).
bool GetPrimaryIpv4(IP4_ADDRESS* out) {
  ULONG size = 0;
  ::GetAdaptersAddresses(AF_INET, 0, nullptr, nullptr, &size);
  if (size == 0) {
    return false;
  }
  std::vector<BYTE> buffer(size);
  auto* adapters = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
  if (::GetAdaptersAddresses(AF_INET, 0, nullptr, adapters, &size) !=
      NO_ERROR) {
    return false;
  }
  for (auto* adapter = adapters; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp) {
      continue;
    }
    if (adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK ||
        adapter->IfType == IF_TYPE_TUNNEL) {
      continue;
    }
    for (auto* unicast = adapter->FirstUnicastAddress; unicast != nullptr;
         unicast = unicast->Next) {
      if (unicast->Address.lpSockaddr->sa_family != AF_INET) {
        continue;
      }
      const auto* sin =
          reinterpret_cast<const sockaddr_in*>(unicast->Address.lpSockaddr);
      *out = sin->sin_addr.s_addr;
      return true;
    }
  }
  return false;
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

void LanNetworkPlugin::HandleBrowse(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  (void)call;  // serviceType is ignored on every platform.
  if (!IsSupported()) {
    result->Error("unsupported", "LAN network requires Windows 10 1709+");
    return;
  }
  // Re-entrant browse: cancel the previous browse and its resolves first, then
  // start a fresh generation (matches Android stopDiscovery + discoverServices).
  StopBrowse();
  StartBrowse(std::move(result));
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
  op->host_name = WStringBuffer(GetMachineHostName());
  op->instance.pszHostName = op->host_name.empty() ? nullptr
                                                    : op->host_name.data();
  op->instance.ip4Address = GetPrimaryIpv4(&op->ip4) ? &op->ip4 : nullptr;
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

void LanNetworkPlugin::OnRegisterComplete(DWORD status,
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
  StopBrowse();
}

void LanNetworkPlugin::AddTxt(AdvertiseOp* op, const std::wstring& key,
                              const std::wstring& value) {
  op->keys.push_back(WStringBuffer(key));
  op->values.push_back(WStringBuffer(value));
  op->key_ptrs.push_back(op->keys.back().data());
  op->value_ptrs.push_back(op->values.back().data());
}

void CALLBACK LanNetworkPlugin::OnRegisterCallbackThunk(
    DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
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

void LanNetworkPlugin::StartBrowse(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  browse_generation_++;
  browse_request_.Version = DNS_QUERY_REQUEST_VERSION1;
  browse_request_.InterfaceIndex = 0;
  browse_request_.QueryName = kServiceQueryName;
  browse_request_.pBrowseCallback = &LanNetworkPlugin::OnBrowseCallbackThunk;
  browse_request_.pQueryContext = this;
  browse_cancel_ = {};
  DNS_STATUS status = DnsServiceBrowse(&browse_request_, &browse_cancel_);
  if (status == DNS_REQUEST_PENDING) {
    browse_state_ = BrowseState::kBrowsing;
    result->Success();
  } else {
    browse_state_ = BrowseState::kIdle;
    result->Error("browseFailed", DnsStatusMessage(status));
  }
}

void LanNetworkPlugin::StopBrowse() {
  if (browse_state_ == BrowseState::kBrowsing) {
    DnsServiceBrowseCancel(&browse_cancel_);
    browse_cancel_ = {};
    browse_state_ = BrowseState::kIdle;
  }
  // Cancel every in-flight resolve. The ResolveOp objects are kept in
  // |resolves_| until their completion callbacks arrive (which free them) so
  // the OS never sees a freed DNS_SERVICE_RESOLVE_REQUEST.
  for (auto& entry : resolves_) {
    if (entry.second) {
      DnsServiceResolveCancel(&entry.second->cancel);
    }
  }
  resolving_names_.clear();
  browse_generation_++;  // Invalidates late callbacks from the old generation.
}

void LanNetworkPlugin::OnBrowseResult(
    DWORD status, uint64_t generation,
    const std::vector<std::wstring>& found) {
  if (generation != browse_generation_.load(std::memory_order_acquire)) {
    return;  // Stale browse (superseded by stopAll / re-entrant browse).
  }
  if (status != ERROR_SUCCESS) {
    // The browse start result was already answered; report errors by log only
    // (a browse-level failure after a successful start means no events flow).
    Log("browse callback reported an error status");
    return;
  }
  for (const std::wstring& fqn : found) {
    if (resolving_names_.count(fqn) != 0) {
      continue;  // Already resolving this instance in this generation.
    }
    resolving_names_.insert(fqn);
    StartResolve(fqn, generation);
  }
}

void LanNetworkPlugin::StartResolve(const std::wstring& fqn,
                                    uint64_t generation) {
  auto op = std::make_unique<ResolveOp>();
  op->fqn = fqn;
  op->fqn_buf = WStringBuffer(fqn);
  op->request.Version = DNS_QUERY_REQUEST_VERSION1;
  op->request.InterfaceIndex = 0;
  op->request.QueryName = op->fqn_buf.data();
  op->request.pResolveCompletionCallback =
      &LanNetworkPlugin::OnResolveCompleteThunk;
  uint64_t resolve_id = ++next_resolve_id_;
  auto* ctx = new ResolveContext();
  ctx->self = this;
  ctx->generation = generation;
  ctx->fqn = fqn;
  ctx->resolve_id = resolve_id;
  op->request.pQueryContext = ctx;
  op->cancel = {};
  DNS_STATUS status = DnsServiceResolve(&op->request, &op->cancel);
  if (status == DNS_REQUEST_PENDING) {
    resolves_[resolve_id] = std::move(op);
  } else {
    delete ctx;
    resolving_names_.erase(fqn);
    // Single instance resolve failure: ignore and keep browsing (matches
    // Android onResolveFailed semantics).
  }
}

void LanNetworkPlugin::OnResolveComplete(DWORD status,
                                       const ResolvedService& data) {
  // The completion callback has fired, so the request/op can be freed.
  auto it = resolves_.find(data.resolve_id);
  if (it != resolves_.end()) {
    resolves_.erase(it);
  }
  if (status != ERROR_SUCCESS) {
    return;  // Single resolve failure: ignore, keep browsing.
  }
  if (data.generation != browse_generation_.load(std::memory_order_acquire)) {
    return;  // Stale resolve from a superseded browse.
  }
  if (data.host.empty()) {
    return;  // Dart drops events with an empty host.
  }
  EmitDiscoveryEvent(data);
}

void LanNetworkPlugin::EmitDiscoveryEvent(const ResolvedService& data) {
  if (!event_sink_) {
    return;
  }
  flutter::EncodableMap txt;
  txt[flutter::EncodableValue("proto")] =
      flutter::EncodableValue(data.txt_proto);
  txt[flutter::EncodableValue("device")] =
      flutter::EncodableValue(data.txt_device);
  txt[flutter::EncodableValue("caps")] =
      flutter::EncodableValue(data.txt_caps);
  flutter::EncodableMap event;
  event[flutter::EncodableValue("name")] = flutter::EncodableValue(data.name);
  event[flutter::EncodableValue("host")] = flutter::EncodableValue(data.host);
  event[flutter::EncodableValue("port")] = flutter::EncodableValue(data.port);
  event[flutter::EncodableValue("txt")] =
      flutter::EncodableValue(std::move(txt));
  event_sink_->Success(flutter::EncodableValue(std::move(event)));
}

void LanNetworkPlugin::ExtractResolved(PDNS_SERVICE_INSTANCE instance,
                                       ResolvedService* out) {
  if (instance->pszInstanceName != nullptr) {
    std::wstring fqn = instance->pszInstanceName;
    size_t dot = fqn.find(L'.');
    out->name = WideToUtf8(dot == std::wstring::npos ? fqn : fqn.substr(0, dot));
  }
  // Prefer the numeric IPv4 address (matches Android semantics; dart:io on
  // Windows is not guaranteed to resolve .local mDNS names).
  if (instance->ip4Address != nullptr) {
    IN_ADDR address{};
    address.S_un.S_addr = *instance->ip4Address;
    wchar_t buffer[INET_ADDRSTRLEN] = {};
    if (::InetNtopW(AF_INET, &address, buffer, INET_ADDRSTRLEN) != nullptr) {
      out->host = WideToUtf8(buffer);
    }
  }
  if (out->host.empty() && instance->pszHostName != nullptr) {
    out->host = WideToUtf8(instance->pszHostName);
  }
  out->port = static_cast<int32_t>(instance->wPort);
  // TXT whitelist on the event side too: only proto/device/caps (a port key,
  // if present, is deliberately ignored here).
  if (instance->keys != nullptr && instance->values != nullptr) {
    for (DWORD i = 0; i < instance->dwPropertyCount; ++i) {
      if (instance->keys[i] == nullptr || instance->values[i] == nullptr) {
        continue;
      }
      std::wstring key = instance->keys[i];
      std::string value = WideToUtf8(instance->values[i]);
      if (key == L"proto") {
        out->txt_proto = std::move(value);
      } else if (key == L"device") {
        out->txt_device = std::move(value);
      } else if (key == L"caps") {
        out->txt_caps = std::move(value);
      }
    }
  }
}

void CALLBACK LanNetworkPlugin::OnBrowseCallbackThunk(DWORD status,
                                                    PVOID context,
                                                    PDNS_RECORD record) {
  auto* self = static_cast<LanNetworkPlugin*>(context);
  if (self->stopped_.load(std::memory_order_acquire)) {
    return;
  }
  uint64_t generation = self->browse_generation_.load(std::memory_order_acquire);
  // DNS_RECORD data is only valid for the duration of this callback, so copy
  // every PTR instance name before posting back to the platform thread.
  std::vector<std::wstring> found;
  if (status == ERROR_SUCCESS && record != nullptr) {
    for (PDNS_RECORD current = record; current != nullptr;
         current = current->pNext) {
      if (current->wType != DNS_TYPE_PTR ||
          current->Data.PTR.pNameHost == nullptr) {
        continue;
      }
      if (current->Flags.S.Delete) {
        continue;  // No explicit removal event; Dart expiry handles cleanup.
      }
      found.emplace_back(current->Data.PTR.pNameHost);
    }
  }
  self->PostTask([self, status, generation, found]() {
    if (self->stopped_.load(std::memory_order_acquire)) {
      return;
    }
    self->OnBrowseResult(status, generation, found);
  });
}

void CALLBACK LanNetworkPlugin::OnResolveCompleteThunk(
    DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
  auto* ctx = static_cast<ResolveContext*>(context);
  LanNetworkPlugin* self = ctx->self;
  ResolvedService data;
  data.generation = ctx->generation;
  data.resolve_id = ctx->resolve_id;
  data.fqn = ctx->fqn;
  if (status == ERROR_SUCCESS && instance != nullptr) {
    ExtractResolved(instance, &data);
  }
  delete ctx;  // Consumed: the resolve callback fires exactly once.
  if (self->stopped_.load(std::memory_order_acquire)) {
    return;
  }
  self->PostTask([self, status, data]() {
    if (self->stopped_.load(std::memory_order_acquire)) {
      return;
    }
    self->OnResolveComplete(status, data);
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
