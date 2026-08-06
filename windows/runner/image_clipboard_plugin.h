#ifndef RUNNER_IMAGE_CLIPBOARD_PLUGIN_H_
#define RUNNER_IMAGE_CLIPBOARD_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <wincodec.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <vector>

// Native implementation of the "clipflow/clipboard" MethodChannel on Windows.
//
// Implements hasImage / getImage / setImage and hasFiles / getFiles / setFiles
// so the shared Dart image and file pipelines work on Windows.  All bytes
// handled here are plain PNG/JPEG; file bytes never cross this channel (only
// metadata does); encryption, compression and hashing happen in the Dart layer
// and are out of scope for this plugin.
class ImageClipboardPlugin {
 public:
  ImageClipboardPlugin();
  ~ImageClipboardPlugin();

  void RegisterWithMessenger(flutter::BinaryMessenger* messenger);
  void Unregister();

 private:
  struct ImageResult {
    std::vector<uint8_t> png;
    int32_t width = 0;
    int32_t height = 0;
  };

  struct ReadResult {
    // True when the clipboard was actually inspected. A transient
    // OpenClipboard failure leaves this false so callers do not cache it.
    bool complete = false;
    std::optional<ImageResult> image;
  };

  enum class SetImageStatus { kSuccess, kDecodeError, kClipError };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool HasImage();
  std::optional<ImageResult> GetImage();
  SetImageStatus SetImage(const std::vector<uint8_t>& bytes);
  bool HasFiles();
  std::vector<std::string> ReadFilePaths();
  bool WriteFilePaths(const std::vector<std::string>& paths);

  Microsoft::WRL::ComPtr<IWICImagingFactory> GetFactory();
  UINT GetPngFormat();

  ReadResult ReadImageFromClipboard();
  std::optional<ImageResult> ReadPngDirect(
      Microsoft::WRL::ComPtr<IWICImagingFactory> factory,
      std::vector<uint8_t> png);
  std::optional<ImageResult> ReadDibAsPng(
      Microsoft::WRL::ComPtr<IWICImagingFactory> factory, HANDLE handle);
  std::optional<ImageResult> ReadImageFileAsPng(
      IWICImagingFactory* factory, const std::string& path);

  Microsoft::WRL::ComPtr<IWICImagingFactory> factory_;
  UINT cf_png_ = 0;

  // Clipboard sequence-number cache (blueprint D6): avoids re-decoding an
  // unchanged clipboard on every 500 ms poll. Any clipboard change (including
  // our own setImage) bumps the sequence number and forces a fresh read.
  UINT last_sequence_ = 0;
  bool has_cache_ = false;
  std::optional<ImageResult> cache_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_IMAGE_CLIPBOARD_PLUGIN_H_
