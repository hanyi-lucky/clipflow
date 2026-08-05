#include "image_clipboard_plugin.h"

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <objbase.h>

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cstring>
#include <limits>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

// RAII guard guaranteeing CloseClipboard() on every exit path.
class ClipboardCloser {
 public:
  ~ClipboardCloser() { ::CloseClipboard(); }
};

uint16_t ReadU16LE(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8));
}

uint32_t ReadU32LE(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) |
         (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

int32_t ReadI32LE(const uint8_t* p) {
  return static_cast<int32_t>(ReadU32LE(p));
}

uint32_t ReadU32BE(const uint8_t* p) {
  return (static_cast<uint32_t>(p[0]) << 24) |
         (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) |
         static_cast<uint32_t>(p[3]);
}

// Parses PNG width/height from the IHDR chunk (bytes 16..23, big-endian).
// Returns false when the buffer is not a well-formed PNG header.
bool ParsePngDimensions(const std::vector<uint8_t>& png,
                        int32_t* out_width,
                        int32_t* out_height) {
  static const uint8_t kPngSignature[8] = {0x89, 0x50, 0x4E, 0x47,
                                           0x0D, 0x0A, 0x1A, 0x0A};
  if (png.size() < 24 || out_width == nullptr || out_height == nullptr) {
    return false;
  }
  if (std::memcmp(png.data(), kPngSignature, sizeof(kPngSignature)) != 0) {
    return false;
  }
  if (ReadU32BE(png.data() + 8) != 13) {  // IHDR chunk length is always 13.
    return false;
  }
  if (png[12] != 'I' || png[13] != 'H' || png[14] != 'D' ||
      png[15] != 'R') {
    return false;
  }
  const uint32_t width = ReadU32BE(png.data() + 16);
  const uint32_t height = ReadU32BE(png.data() + 20);
  if (width == 0 || height == 0 || width > INT32_MAX || height > INT32_MAX) {
    return false;
  }
  *out_width = static_cast<int32_t>(width);
  *out_height = static_cast<int32_t>(height);
  return true;
}

// Parsed view of a DIB (BITMAPINFOHEADER / V4 / V5) plus its pixel bytes.
struct ParsedDib {
  int32_t width = 0;
  int32_t height = 0;  // Absolute pixel height.
  bool bottom_up = true;
  uint16_t bpp = 0;
  uint32_t red_mask = 0;
  uint32_t green_mask = 0;
  uint32_t blue_mask = 0;
  uint32_t alpha_mask = 0;
  const uint8_t* pixels = nullptr;
  size_t pixel_size = 0;
};

// Parses a DIB byte range. Supports only the variants listed in the Windows
// blueprint support table: 40/108/124-byte headers, 24/32 bpp, BI_RGB /
// BI_BITFIELDS with standard masks, top-down and bottom-up row order.
// Anything else (BITMAPCOREHEADER, 16 bpp, RLE, non-standard masks) returns
// nullopt so the caller can fall back to the text path.
std::optional<ParsedDib> ParseDib(const uint8_t* data, size_t size) {
  if (data == nullptr || size < 40) {
    return std::nullopt;
  }
  const uint32_t bi_size = ReadU32LE(data);
  if (bi_size != sizeof(BITMAPINFOHEADER) && bi_size != sizeof(BITMAPV4HEADER) &&
      bi_size != sizeof(BITMAPV5HEADER)) {
    return std::nullopt;
  }
  if (size < bi_size) {
    return std::nullopt;
  }

  ParsedDib dib;
  dib.width = ReadI32LE(data + 4);
  const int32_t raw_height = ReadI32LE(data + 8);
  dib.bpp = ReadU16LE(data + 14);
  const uint32_t compression = ReadU32LE(data + 16);

  if (dib.width <= 0 || raw_height == 0) {
    return std::nullopt;
  }
  if (dib.bpp != 24 && dib.bpp != 32) {
    return std::nullopt;
  }
  if (compression != BI_RGB && compression != BI_BITFIELDS) {
    return std::nullopt;
  }

  dib.bottom_up = raw_height > 0;
  dib.height = raw_height > 0 ? raw_height : -raw_height;

  size_t header_end = bi_size;
  if (compression == BI_BITFIELDS && bi_size == sizeof(BITMAPINFOHEADER)) {
    // 40-byte header: the three color masks follow the header (12 bytes).
    if (size < bi_size + 12) {
      return std::nullopt;
    }
    dib.red_mask = ReadU32LE(data + 40);
    dib.green_mask = ReadU32LE(data + 44);
    dib.blue_mask = ReadU32LE(data + 48);
    header_end = bi_size + 12;
  } else if (bi_size >= sizeof(BITMAPV4HEADER)) {
    // V4/V5 keep the masks inside the header at fixed offsets.
    dib.red_mask = ReadU32LE(data + 40);
    dib.green_mask = ReadU32LE(data + 44);
    dib.blue_mask = ReadU32LE(data + 48);
    dib.alpha_mask = ReadU32LE(data + 52);
    if (compression == BI_RGB && dib.red_mask == 0 &&
        dib.green_mask == 0 && dib.blue_mask == 0) {
      // BI_RGB has implicit standard masks even when the V4/V5 mask fields
      // are left zeroed by the writer.
      dib.red_mask = 0x00FF0000;
      dib.green_mask = 0x0000FF00;
      dib.blue_mask = 0x000000FF;
      dib.alpha_mask = 0;
    }
  } else {
    // BI_RGB, 40-byte header: implicit standard masks.
    dib.red_mask = 0x00FF0000;
    dib.green_mask = 0x0000FF00;
    dib.blue_mask = 0x000000FF;
  }

  // Reject anything but the standard BGRA/BGR channel order.
  if (dib.red_mask != 0x00FF0000 || dib.green_mask != 0x0000FF00 ||
      dib.blue_mask != 0x000000FF) {
    return std::nullopt;
  }
  if (dib.alpha_mask != 0 && dib.alpha_mask != 0xFF000000) {
    return std::nullopt;
  }

  const size_t stride = (static_cast<size_t>(dib.width) * dib.bpp + 31) / 32 * 4;
  const size_t needed = stride * static_cast<size_t>(dib.height);
  if (header_end > size || size - header_end < needed) {
    return std::nullopt;
  }

  dib.pixels = data + header_end;
  dib.pixel_size = size - header_end;
  return dib;
}

// Converts a parsed DIB into a top-down 32bpp BGRA buffer. 24 bpp rows are
// expanded to B,G,R,0xFF; 32 bpp rows are copied as-is. The alpha byte is
// passed through only when the format declares an alpha mask (V4/V5
// BI_BITFIELDS with 0xFF000000, straight alpha); otherwise it is undefined in
// the DIB spec, so it is forced to 0xFF to avoid fully transparent output.
std::vector<uint8_t> NormalizeDibToBgra(const ParsedDib& dib) {
  if (dib.width <= 0 || dib.height <= 0 || dib.pixels == nullptr) {
    return {};
  }
  const size_t pixel_count = static_cast<size_t>(dib.width) * dib.height;
  if (pixel_count > (std::numeric_limits<size_t>::max)() / 4) {
    return {};
  }
  // Keep the total buffer within the UINT range used by WIC copy calls.
  if (pixel_count * 4 > UINT32_MAX) {
    return {};
  }
  std::vector<uint8_t> out;
  try {
    out.resize(pixel_count * 4);
  } catch (...) {
    return {};
  }
  const size_t src_stride =
      (static_cast<size_t>(dib.width) * dib.bpp + 31) / 32 * 4;
  const size_t bytes_per_px = dib.bpp / 8;
  const bool has_alpha = (dib.alpha_mask == 0xFF000000);
  for (int32_t y = 0; y < dib.height; ++y) {
    // bottom-up DIBs store the last image row first.
    const int32_t src_y = dib.bottom_up ? (dib.height - 1 - y) : y;
    const uint8_t* src = dib.pixels + static_cast<size_t>(src_y) * src_stride;
    uint8_t* dst = out.data() + static_cast<size_t>(y) * dib.width * 4;
    for (int32_t x = 0; x < dib.width; ++x) {
      const uint8_t* px = src + static_cast<size_t>(x) * bytes_per_px;
      dst[0] = px[0];  // B
      dst[1] = px[1];  // G
      dst[2] = px[2];  // R
      dst[3] = has_alpha ? px[3] : 0xFF;
      dst += 4;
    }
  }
  return out;
}

// Copies pixels out of an IWICBitmapSource into a top-down 32bpp BGRA buffer.
std::vector<uint8_t> GetBgraPixels(IWICBitmapSource* source,
                                   UINT width,
                                   UINT height) {
  if (source == nullptr || width == 0 || height == 0 ||
      static_cast<size_t>(width) * height * 4 > UINT32_MAX) {
    return {};
  }
  std::vector<uint8_t> bgra;
  try {
    bgra.resize(static_cast<size_t>(width) * height * 4);
  } catch (...) {
    return {};
  }
  WICRect rect{0, 0, static_cast<INT>(width), static_cast<INT>(height)};
  HRESULT hr = source->CopyPixels(&rect, width * 4,
                                  static_cast<UINT>(bgra.size()),
                                  bgra.data());
  if (FAILED(hr)) {
    return {};
  }
  return bgra;
}

// Builds a bottom-up 32bpp BI_RGB DIB (BITMAPINFOHEADER + pixels) from a
// top-down BGRA buffer. biHeight > 0 means the first DIB row is the image's
// bottom row, so rows are written in reverse order.
std::vector<uint8_t> BuildDibFromBgra(const std::vector<uint8_t>& bgra,
                                      UINT width,
                                      UINT height) {
  if (width == 0 || height == 0 ||
      bgra.size() != static_cast<size_t>(width) * height * 4) {
    return {};
  }
  const size_t pixel_bytes = static_cast<size_t>(width) * height * 4;
  std::vector<uint8_t> dib(sizeof(BITMAPINFOHEADER) + pixel_bytes);
  BITMAPINFOHEADER bi{};
  bi.biSize = sizeof(BITMAPINFOHEADER);
  bi.biWidth = static_cast<LONG>(width);
  bi.biHeight = static_cast<LONG>(height);  // Positive => bottom-up DIB.
  bi.biPlanes = 1;
  bi.biBitCount = 32;
  bi.biCompression = BI_RGB;
  bi.biSizeImage = static_cast<DWORD>(pixel_bytes);
  std::memcpy(dib.data(), &bi, sizeof(bi));
  uint8_t* dst = dib.data() + sizeof(BITMAPINFOHEADER);
  for (UINT y = 0; y < height; ++y) {
    const uint8_t* src =
        bgra.data() + static_cast<size_t>(height - 1 - y) * width * 4;
    std::memcpy(dst + static_cast<size_t>(y) * width * 4, src,
                static_cast<size_t>(width) * 4);
  }
  return dib;
}

// Encodes a BGRA buffer into PNG bytes using WIC. Output is deterministic for
// identical pixels, which keeps the Dart-side sha256 echo-prevention stable.
std::vector<uint8_t> EncodePngFromBgra(IWICImagingFactory* factory,
                                       const std::vector<uint8_t>& bgra,
                                       UINT width,
                                       UINT height) {
  if (factory == nullptr || width == 0 || height == 0 ||
      bgra.size() != static_cast<size_t>(width) * height * 4) {
    return {};
  }
  ComPtr<IWICBitmap> bitmap;
  HRESULT hr = factory->CreateBitmapFromMemory(
      width, height, GUID_WICPixelFormat32bppBGRA, width * 4,
      static_cast<UINT>(bgra.size()),
      const_cast<BYTE*>(bgra.data()), &bitmap);
  if (FAILED(hr)) {
    return {};
  }

  ComPtr<IStream> stream;
  hr = ::CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  if (FAILED(hr)) {
    return {};
  }

  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (FAILED(hr)) {
    return {};
  }
  hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) {
    return {};
  }

  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  hr = encoder->CreateNewFrame(&frame, &props);
  if (FAILED(hr)) {
    return {};
  }
  hr = frame->Initialize(props.Get());
  if (FAILED(hr)) {
    return {};
  }
  hr = frame->SetSize(width, height);
  if (FAILED(hr)) {
    return {};
  }
  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
  hr = frame->SetPixelFormat(&pixel_format);
  if (FAILED(hr)) {
    return {};
  }
  hr = frame->WriteSource(bitmap.Get(), nullptr);
  if (FAILED(hr)) {
    return {};
  }
  hr = frame->Commit();
  if (FAILED(hr)) {
    return {};
  }
  hr = encoder->Commit();
  if (FAILED(hr)) {
    return {};
  }

  HGLOBAL hglobal = nullptr;
  hr = ::GetHGlobalFromStream(stream.Get(), &hglobal);
  if (FAILED(hr) || hglobal == nullptr) {
    return {};
  }
  const size_t size = ::GlobalSize(hglobal);
  if (size == 0) {
    return {};
  }
  const uint8_t* data = static_cast<const uint8_t*>(::GlobalLock(hglobal));
  if (data == nullptr) {
    return {};
  }
  std::vector<uint8_t> png(data, data + size);
  ::GlobalUnlock(hglobal);
  return png;
}

// Copies an HGLOBAL clipboard object into a std::vector.
std::vector<uint8_t> CopyClipboardBytes(HANDLE handle) {
  if (handle == nullptr) {
    return {};
  }
  const size_t size = ::GlobalSize(handle);
  if (size == 0) {
    return {};
  }
  const uint8_t* p = static_cast<const uint8_t*>(::GlobalLock(handle));
  if (p == nullptr) {
    return {};
  }
  std::vector<uint8_t> bytes;
  try {
    bytes.assign(p, p + size);
  } catch (...) {
    bytes.clear();
  }
  ::GlobalUnlock(handle);
  return bytes;
}

// Decodes an in-memory PNG/JPEG with WIC (content sniffing) and returns the
// frame dimensions. Used as a fallback when CF_PNG bytes fail IHDR parsing.
bool DecodeImageDimensions(IWICImagingFactory* factory,
                           const std::vector<uint8_t>& bytes,
                           UINT* out_width,
                           UINT* out_height) {
  if (factory == nullptr || bytes.empty() || out_width == nullptr ||
      out_height == nullptr) {
    return false;
  }
  ComPtr<IStream> stream;
  if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
    return false;
  }
  ULONG written = 0;
  if (FAILED(stream->Write(bytes.data(), static_cast<ULONG>(bytes.size()),
                           &written)) ||
      written != bytes.size()) {
    return false;
  }
  LARGE_INTEGER position{};
  if (FAILED(stream->Seek(position, STREAM_SEEK_SET, nullptr))) {
    return false;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder))) {
    return false;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame))) {
    return false;
  }
  UINT width = 0, height = 0;
  if (FAILED(frame->GetSize(&width, &height)) || width == 0 || height == 0) {
    return false;
  }
  *out_width = width;
  *out_height = height;
  return true;
}

// Creates a GMEM_MOVEABLE HGLOBAL from a byte vector (ownership stays with
// the caller).
HGLOBAL MakeGlobalFromBytes(const std::vector<uint8_t>& data) {
  if (data.empty()) {
    return nullptr;
  }
  HGLOBAL handle = ::GlobalAlloc(GMEM_MOVEABLE, data.size());
  if (handle == nullptr) {
    return nullptr;
  }
  void* p = ::GlobalLock(handle);
  if (p == nullptr) {
    ::GlobalFree(handle);
    return nullptr;
  }
  std::memcpy(p, data.data(), data.size());
  ::GlobalUnlock(handle);
  return handle;
}

// Defensive extraction of image bytes from the channel arguments. Dart sends
// Uint8List (std::vector<uint8_t>), but callers may also pass a plain
// List<int> (EncodableList of int32) or a typed Int32List/Int64List.
std::vector<uint8_t> ParseBytes(const flutter::EncodableValue& value) {
  if (std::holds_alternative<std::vector<uint8_t>>(value)) {
    return std::get<std::vector<uint8_t>>(value);
  }
  if (std::holds_alternative<std::vector<int32_t>>(value)) {
    const std::vector<int32_t>& ints = std::get<std::vector<int32_t>>(value);
    std::vector<uint8_t> out;
    out.reserve(ints.size());
    for (int32_t v : ints) {
      out.push_back(static_cast<uint8_t>(v));
    }
    return out;
  }
  if (std::holds_alternative<std::vector<int64_t>>(value)) {
    const std::vector<int64_t>& ints = std::get<std::vector<int64_t>>(value);
    std::vector<uint8_t> out;
    out.reserve(ints.size());
    for (int64_t v : ints) {
      out.push_back(static_cast<uint8_t>(v));
    }
    return out;
  }
  if (std::holds_alternative<flutter::EncodableList>(value)) {
    const flutter::EncodableList& list =
        std::get<flutter::EncodableList>(value);
    std::vector<uint8_t> out;
    out.reserve(list.size());
    for (const flutter::EncodableValue& item : list) {
      if (std::holds_alternative<int32_t>(item)) {
        out.push_back(static_cast<uint8_t>(std::get<int32_t>(item)));
      } else if (std::holds_alternative<int64_t>(item)) {
        out.push_back(static_cast<uint8_t>(std::get<int64_t>(item)));
      }
    }
    return out;
  }
  return {};
}

}  // namespace

ImageClipboardPlugin::ImageClipboardPlugin() = default;

ImageClipboardPlugin::~ImageClipboardPlugin() = default;

void ImageClipboardPlugin::RegisterWithMessenger(
    flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "clipflow/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleMethodCall(call, std::move(result));
      });
}

void ImageClipboardPlugin::Unregister() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  channel_.reset();
  // Release the COM factory here (during WM_DESTROY, before ::CoUninitialize
  // in wWinMain); the plugin itself is destroyed after COM is torn down.
  factory_.Reset();
}

Microsoft::WRL::ComPtr<IWICImagingFactory>
ImageClipboardPlugin::GetFactory() {
  if (!factory_) {
    HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory_));
    if (FAILED(hr)) {
      factory_.Reset();
    }
  }
  return factory_;
}

UINT ImageClipboardPlugin::GetPngFormat() {
  if (cf_png_ == 0) {
    cf_png_ = ::RegisterClipboardFormat(L"PNG");
  }
  return cf_png_;
}

bool ImageClipboardPlugin::HasImage() {
  if (::IsClipboardFormatAvailable(CF_DIB) ||
      ::IsClipboardFormatAvailable(CF_DIBV5)) {
    return true;
  }
  const UINT cf_png = GetPngFormat();
  return cf_png != 0 && ::IsClipboardFormatAvailable(cf_png);
}

std::optional<ImageClipboardPlugin::ImageResult>
ImageClipboardPlugin::GetImage() {
  const UINT sequence = ::GetClipboardSequenceNumber();
  if (has_cache_ && sequence == last_sequence_) {
    return cache_;
  }
  ReadResult read = ReadImageFromClipboard();
  if (!read.complete) {
    // Transient OpenClipboard contention: do not cache; retry next poll.
    return std::nullopt;
  }
  has_cache_ = true;
  last_sequence_ = sequence;
  cache_ = std::move(read.image);
  return cache_;
}

ImageClipboardPlugin::ReadResult ImageClipboardPlugin::ReadImageFromClipboard() {
  ReadResult result;
  if (!::OpenClipboard(nullptr)) {
    return result;
  }
  ClipboardCloser closer;
  result.complete = true;

  ComPtr<IWICImagingFactory> factory = GetFactory();
  if (!factory) {
    return result;
  }
  const UINT cf_png = GetPngFormat();

  // 1) CF_PNG: byte passthrough (fastest, lossless, keeps echo-hash stable).
  if (cf_png != 0 && ::IsClipboardFormatAvailable(cf_png)) {
    HANDLE handle = ::GetClipboardData(cf_png);
    if (handle != nullptr) {
      std::vector<uint8_t> png = CopyClipboardBytes(handle);
      if (!png.empty()) {
        std::optional<ImageResult> direct =
            ReadPngDirect(factory, std::move(png));
        if (direct.has_value()) {
          result.image = std::move(direct);
          return result;
        }
      }
    }
  }

  // 2) CF_DIB / CF_DIBV5: parse DIB variants and normalize to PNG via WIC.
  UINT dib_format = 0;
  if (::IsClipboardFormatAvailable(CF_DIBV5)) {
    dib_format = CF_DIBV5;
  } else if (::IsClipboardFormatAvailable(CF_DIB)) {
    dib_format = CF_DIB;
  }
  if (dib_format != 0) {
    HANDLE handle = ::GetClipboardData(dib_format);
    if (handle != nullptr) {
      std::optional<ImageResult> converted = ReadDibAsPng(factory, handle);
      if (converted.has_value()) {
        result.image = std::move(converted);
        return result;
      }
    }
  }
  return result;
}

std::optional<ImageClipboardPlugin::ImageResult>
ImageClipboardPlugin::ReadPngDirect(
    Microsoft::WRL::ComPtr<IWICImagingFactory> factory,
    std::vector<uint8_t> png) {
  ImageResult result;
  result.png = std::move(png);
  if (ParsePngDimensions(result.png, &result.width, &result.height)) {
    return result;
  }
  // IHDR parse failed: fall back to WIC decode just for dimensions, keeping
  // the original bytes.
  UINT width = 0, height = 0;
  if (DecodeImageDimensions(factory.Get(), result.png, &width, &height)) {
    result.width = static_cast<int32_t>(width);
    result.height = static_cast<int32_t>(height);
    return result;
  }
  return std::nullopt;
}

std::optional<ImageClipboardPlugin::ImageResult>
ImageClipboardPlugin::ReadDibAsPng(
    Microsoft::WRL::ComPtr<IWICImagingFactory> factory, HANDLE handle) {
  if (!factory || handle == nullptr) {
    return std::nullopt;
  }
  const size_t size = ::GlobalSize(handle);
  if (size == 0) {
    return std::nullopt;
  }
  const uint8_t* data = static_cast<const uint8_t*>(::GlobalLock(handle));
  if (data == nullptr) {
    return std::nullopt;
  }
  std::optional<ParsedDib> parsed = ParseDib(data, size);
  ::GlobalUnlock(handle);
  if (!parsed.has_value()) {
    return std::nullopt;
  }

  std::vector<uint8_t> bgra = NormalizeDibToBgra(*parsed);
  if (bgra.empty()) {
    return std::nullopt;
  }
  std::vector<uint8_t> png = EncodePngFromBgra(
      factory.Get(), bgra, static_cast<UINT>(parsed->width),
      static_cast<UINT>(parsed->height));
  if (png.empty()) {
    return std::nullopt;
  }

  ImageResult result;
  result.png = std::move(png);
  result.width = parsed->width;
  result.height = parsed->height;
  return result;
}

ImageClipboardPlugin::SetImageStatus ImageClipboardPlugin::SetImage(
    const std::vector<uint8_t>& bytes) {
  ComPtr<IWICImagingFactory> factory = GetFactory();
  if (!factory || bytes.empty()) {
    return SetImageStatus::kDecodeError;
  }

  // Decode by content sniffing (PNG or JPEG); the Dart-side "format" argument
  // is deliberately not trusted for decoder selection.
  ComPtr<IStream> input_stream;
  if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &input_stream))) {
    return SetImageStatus::kDecodeError;
  }
  ULONG written = 0;
  if (FAILED(input_stream->Write(bytes.data(),
                                 static_cast<ULONG>(bytes.size()),
                                 &written)) ||
      written != bytes.size()) {
    return SetImageStatus::kDecodeError;
  }
  LARGE_INTEGER position{};
  if (FAILED(input_stream->Seek(position, STREAM_SEEK_SET, nullptr))) {
    return SetImageStatus::kDecodeError;
  }

  ComPtr<IWICBitmapDecoder> decoder;
  HRESULT hr = factory->CreateDecoderFromStream(
      input_stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder);
  if (FAILED(hr)) {
    return SetImageStatus::kDecodeError;
  }

  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) {
    return SetImageStatus::kDecodeError;
  }

  UINT width = 0, height = 0;
  hr = frame->GetSize(&width, &height);
  if (FAILED(hr) || width == 0 || height == 0 || width > INT32_MAX ||
      height > INT32_MAX) {
    return SetImageStatus::kDecodeError;
  }

  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) {
    return SetImageStatus::kDecodeError;
  }
  hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) {
    return SetImageStatus::kDecodeError;
  }

  std::vector<uint8_t> bgra = GetBgraPixels(converter.Get(), width, height);
  if (bgra.empty()) {
    return SetImageStatus::kDecodeError;
  }
  std::vector<uint8_t> dib = BuildDibFromBgra(bgra, width, height);
  // CF_PNG must carry real PNG bytes, never raw JPEG.
  std::vector<uint8_t> png = EncodePngFromBgra(factory.Get(), bgra, width, height);
  if (dib.empty() || png.empty()) {
    return SetImageStatus::kDecodeError;
  }

  // Single clipboard transaction, with retry on contention (10 x 10 ms).
  bool opened = false;
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (::OpenClipboard(nullptr)) {
      opened = true;
      break;
    }
    if (attempt < 9) {
      ::Sleep(10);
    }
  }
  if (!opened) {
    return SetImageStatus::kClipError;
  }

  bool success = false;
  if (::EmptyClipboard()) {
    HGLOBAL h_dib = MakeGlobalFromBytes(dib);
    HGLOBAL h_png = MakeGlobalFromBytes(png);
    if (h_dib != nullptr && h_png != nullptr) {
      // On success the system owns the handle; GlobalFree only on failure.
      HANDLE dib_set = ::SetClipboardData(CF_DIB, h_dib);
      HANDLE png_set = ::SetClipboardData(GetPngFormat(), h_png);
      success = (dib_set != nullptr && png_set != nullptr);
      if (dib_set == nullptr) {
        ::GlobalFree(h_dib);
      }
      if (png_set == nullptr) {
        ::GlobalFree(h_png);
      }
    } else {
      if (h_dib != nullptr) {
        ::GlobalFree(h_dib);
      }
      if (h_png != nullptr) {
        ::GlobalFree(h_png);
      }
    }
  }
  ::CloseClipboard();
  return success ? SetImageStatus::kSuccess : SetImageStatus::kClipError;
}

void ImageClipboardPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "hasImage") {
    result->Success(flutter::EncodableValue(HasImage()));
    return;
  }
  if (method == "getImage") {
    std::optional<ImageResult> image = GetImage();
    if (!image.has_value()) {
      // Null (not an empty map): the Dart contract treats this as "no image".
      result->Success();
      return;
    }
    flutter::EncodableMap map;
    map[flutter::EncodableValue("bytes")] =
        flutter::EncodableValue(std::move(image->png));
    map[flutter::EncodableValue("format")] =
        flutter::EncodableValue(std::string("png"));
    map[flutter::EncodableValue("width")] =
        flutter::EncodableValue(image->width);
    map[flutter::EncodableValue("height")] =
        flutter::EncodableValue(image->height);
    result->Success(flutter::EncodableValue(std::move(map)));
    return;
  }
  if (method == "setImage") {
    const flutter::EncodableValue* arguments = call.arguments();
    if (arguments == nullptr ||
        !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
      result->Error("BAD_ARGS", "bytes is required");
      return;
    }
    const flutter::EncodableMap& map =
        std::get<flutter::EncodableMap>(*arguments);
    auto it = map.find(flutter::EncodableValue("bytes"));
    if (it == map.end()) {
      result->Error("BAD_ARGS", "bytes is required");
      return;
    }
    const std::vector<uint8_t> bytes = ParseBytes(it->second);
    if (bytes.empty()) {
      result->Error("BAD_ARGS", "bytes is required");
      return;
    }
    switch (SetImage(bytes)) {
      case SetImageStatus::kSuccess:
        result->Success(flutter::EncodableValue(true));
        break;
      case SetImageStatus::kDecodeError:
        result->Error("DECODE_ERROR", "failed to decode image bytes");
        break;
      case SetImageStatus::kClipError:
        result->Error("CLIP_ERROR", "failed to write image to clipboard");
        break;
    }
    return;
  }
  result->NotImplemented();
}
