#ifndef RUNNER_LAN_NETWORK_PLUGIN_H_
#define RUNNER_LAN_NETWORK_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <windns.h>

#include <atomic>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

// Native implementation of the "clipflow/lan_network" MethodChannel and the
// "clipflow/lan_network_events" EventChannel on Windows.
//
// Backed by the Win32 DNS-SD APIs (windns.h / dnsapi.lib): DnsServiceRegister
// advertises `_clipflow._tcp`, DnsServiceBrowse + DnsServiceResolve discover
// peers, and each discovery result is pushed through the EventChannel as
// `{name, host, port, txt:{proto, device, caps}}`.
//
// Thread model: the DNS-SD completion callbacks run on system thread-pool
// threads. Every callback marshals back to the Flutter platform thread via a
// registered window message (PostMessage to the main HWND), so the state
// machine, MethodResults and EventSink are only ever touched on the platform
// thread (mirroring Android mainHandler.post).
class LanNetworkPlugin {
 public:
  explicit LanNetworkPlugin(HWND hwnd);
  ~LanNetworkPlugin();

  void RegisterWithMessenger(flutter::BinaryMessenger* messenger);
  void Unregister();

  // Registered window message used to wake the platform thread when a DNS-SD
  // callback has queued work. Consumed by FlutterWindow::MessageHandler.
  UINT MarshalMessage() const { return marshal_message_; }

  // Platform thread: runs a single queued task (no-op when the queue is empty
  // or the plugin has been stopped). Returns true when a task was executed.
  bool DrainOne();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleIsSupported(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleAdvertise(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleBrowse(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleStopAll(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Windows 10 1709 (build 16299) ships the built-in mDNS/DNS-SD stack used by
  // windns.h's DnsService* APIs. Below that the plugin reports unsupported and
  // the Dart layer silently falls back to Cloud-only sync.
  bool IsSupported();

  // Queues |fn| on the platform thread (producer: DNS-SD callback threads).
  void PostTask(std::function<void()> fn);
  // Executes any queued tasks synchronously (platform thread, on teardown).
  void DrainQueue();

  // ---- Advertise state machine (platform thread only) ----
  //
  // The register completion callback is shared by DnsServiceRegister and
  // DnsServiceDeRegister; it fires once per operation. RegisterContext is
  // owned by AdvertiseOp and lives until the operation's callback has been
  // processed on the platform thread (it is read by the thunk before the task
  // is posted, so freeing it there is safe).
  struct RegisterContext {
    LanNetworkPlugin* self;
    uint64_t operation_id;
  };

  struct AdvertiseOp {
    std::unique_ptr<RegisterContext> context;
    std::vector<wchar_t> instance_name;
    std::vector<std::vector<wchar_t>> keys;
    std::vector<std::vector<wchar_t>> values;
    std::vector<PWSTR> key_ptrs;
    std::vector<PWSTR> value_ptrs;
    DNS_SERVICE_INSTANCE instance{};
    DNS_SERVICE_REGISTER_REQUEST request{};
  };

  enum class AdvertiseState {
    kIdle,
    kPendingRegister,
    kRegistered,
    kPendingDeregister,
  };

  void StartRegister();
  void OnRegisterComplete(DNS_STATUS status, uint64_t operation_id);
  void CompletePendingRegistration();
  void StopAllInternal(bool complete_inflight);
  static void AddTxt(AdvertiseOp* op, const std::wstring& key,
                     const std::wstring& value);
  static void CALLBACK OnRegisterCallbackThunk(DNS_STATUS status,
                                               PVOID context,
                                               PDNS_SERVICE_INSTANCE instance);

  AdvertiseState adv_state_ = AdvertiseState::kIdle;
  std::unique_ptr<AdvertiseOp> adv_op_;
  DNS_SERVICE_CANCEL adv_cancel_{};
  uint64_t adv_operation_id_ = 0;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> adv_result_;
  // Pending advertise request captured while a deregistration is in flight
  // (re-entrant advertise).
  std::optional<std::wstring> adv_pending_device_id_;
  std::optional<std::wstring> adv_pending_caps_;
  std::optional<int32_t> adv_pending_port_;
  std::wstring adv_device_id_;
  std::wstring adv_caps_;
  int32_t adv_port_ = 0;

  HWND hwnd_ = nullptr;
  UINT marshal_message_ = 0;
  std::atomic<bool> stopped_{false};
  std::mutex queue_mutex_;
  std::deque<std::function<void()>> task_queue_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  // Assigned on EventChannel listen; reset on cancel/teardown. Only ever
  // touched on the platform thread.
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
};

#endif  // RUNNER_LAN_NETWORK_PLUGIN_H_
