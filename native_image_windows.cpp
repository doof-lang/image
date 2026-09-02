#include "native_image.hpp"
#include "native_webp.hpp"

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <objidl.h>
#include <propvarutil.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace doof_image {
namespace {

using Microsoft::WRL::ComPtr;

enum ErrorKind : int32_t {
    InvalidArgument = 0,
    InvalidData = 1,
    OutOfBounds = 2,
    UnsupportedFormat = 3,
    DecodeFailed = 4,
    EncodeFailed = 5,
    IoFailed = 6,
};

template <typename T>
doof::Result<T, std::shared_ptr<NativeImageError>> failure(ErrorKind kind, const std::string& message) {
    return doof::Failure<std::shared_ptr<NativeImageError>>{
        std::make_shared<NativeImageError>(static_cast<int32_t>(kind), message)
    };
}

doof::Result<void, std::shared_ptr<NativeImageError>> voidFailure(
    ErrorKind kind,
    const std::string& message
) {
    return doof::Failure<std::shared_ptr<NativeImageError>>{
        std::make_shared<NativeImageError>(static_cast<int32_t>(kind), message)
    };
}

bool checkedByteCount(int32_t width, int32_t height, size_t& byteCount) {
    if (width <= 0 || height <= 0 ||
        static_cast<uint64_t>(width) * 4u > std::numeric_limits<UINT>::max()) {
        return false;
    }
    const uint64_t count = static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4u;
    if (count > static_cast<uint64_t>(std::numeric_limits<size_t>::max()) ||
        count > std::numeric_limits<UINT>::max()) {
        return false;
    }
    byteCount = static_cast<size_t>(count);
    return true;
}

bool validRect(
    int32_t imageWidth,
    int32_t imageHeight,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    return x >= 0 && y >= 0 && width > 0 && height > 0 &&
        static_cast<int64_t>(x) + width <= imageWidth &&
        static_cast<int64_t>(y) + height <= imageHeight;
}

class ComApartment {
public:
    ComApartment() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ComApartment() {
        if (result_ == S_OK || result_ == S_FALSE) {
            CoUninitialize();
        }
    }
    bool available() const { return SUCCEEDED(result_) || result_ == RPC_E_CHANGED_MODE; }

private:
    HRESULT result_;
};

HRESULT createFactory(ComPtr<IWICImagingFactory>& factory) {
    HRESULT result = CoCreateInstance(
        CLSID_WICImagingFactory2,
        nullptr,
        CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&factory)
    );
    if (FAILED(result)) {
        result = CoCreateInstance(
            CLSID_WICImagingFactory,
            nullptr,
            CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(&factory)
        );
    }
    return result;
}

bool utf8Path(const std::string& path, std::wstring& output) {
    if (path.empty()) {
        return false;
    }
    const int length = MultiByteToWideChar(
        CP_UTF8,
        MB_ERR_INVALID_CHARS,
        path.data(),
        static_cast<int>(path.size()),
        nullptr,
        0
    );
    if (length <= 0) {
        return false;
    }
    output.resize(static_cast<size_t>(length));
    return MultiByteToWideChar(
        CP_UTF8,
        MB_ERR_INVALID_CHARS,
        path.data(),
        static_cast<int>(path.size()),
        output.data(),
        length
    ) == length;
}

HRESULT memoryStream(const std::vector<uint8_t>& bytes, ComPtr<IStream>& stream) {
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    if (memory == nullptr) {
        return E_OUTOFMEMORY;
    }
    void* destination = GlobalLock(memory);
    if (destination == nullptr) {
        GlobalFree(memory);
        return HRESULT_FROM_WIN32(GetLastError());
    }
    std::memcpy(destination, bytes.data(), bytes.size());
    GlobalUnlock(memory);
    const HRESULT result = CreateStreamOnHGlobal(memory, TRUE, &stream);
    if (FAILED(result)) {
        GlobalFree(memory);
    }
    return result;
}

uint16_t frameOrientation(IWICBitmapFrameDecode* frame) {
    ComPtr<IWICMetadataQueryReader> reader;
    if (FAILED(frame->GetMetadataQueryReader(&reader))) {
        return 1;
    }
    static const wchar_t* queries[] = {
        L"/app1/ifd/{ushort=274}",
        L"/ifd/{ushort=274}",
        L"/xmp/tiff:Orientation",
    };
    for (const wchar_t* query : queries) {
        PROPVARIANT value;
        PropVariantInit(&value);
        const HRESULT result = reader->GetMetadataByName(query, &value);
        uint16_t orientation = 1;
        if (SUCCEEDED(result)) {
            if (value.vt == VT_UI2) {
                orientation = value.uiVal;
            } else if (value.vt == VT_UI4) {
                orientation = static_cast<uint16_t>(value.ulVal);
            }
        }
        PropVariantClear(&value);
        if (SUCCEEDED(result) && orientation >= 1 && orientation <= 8) {
            return orientation;
        }
    }
    return 1;
}

WICBitmapTransformOptions orientationTransform(uint16_t orientation) {
    switch (orientation) {
        case 2: return WICBitmapTransformFlipHorizontal;
        case 3: return WICBitmapTransformRotate180;
        case 4: return WICBitmapTransformFlipVertical;
        case 5: return static_cast<WICBitmapTransformOptions>(
            WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal
        );
        case 6: return WICBitmapTransformRotate90;
        case 7: return static_cast<WICBitmapTransformOptions>(
            WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal
        );
        case 8: return WICBitmapTransformRotate270;
        default: return WICBitmapTransformRotate0;
    }
}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> decodeFrame(
    IWICImagingFactory* factory,
    IWICBitmapDecoder* decoder
) {
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, &frame))) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "encoded data does not contain an image");
    }

    ComPtr<IWICBitmapSource> oriented = frame;
    const WICBitmapTransformOptions transform = orientationTransform(frameOrientation(frame.Get()));
    ComPtr<IWICBitmapFlipRotator> rotator;
    if (transform != WICBitmapTransformRotate0) {
        if (FAILED(factory->CreateBitmapFlipRotator(&rotator)) ||
            FAILED(rotator->Initialize(frame.Get(), transform))) {
            return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "WIC could not apply image orientation");
        }
        oriented = rotator;
    }

    UINT rawWidth = 0;
    UINT rawHeight = 0;
    if (FAILED(oriented->GetSize(&rawWidth, &rawHeight)) || rawWidth == 0 || rawHeight == 0 ||
        rawWidth > static_cast<UINT>(std::numeric_limits<int32_t>::max()) ||
        rawHeight > static_cast<UINT>(std::numeric_limits<int32_t>::max())) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "decoded image dimensions are invalid or too large");
    }

    size_t byteCount = 0;
    const int32_t width = static_cast<int32_t>(rawWidth);
    const int32_t height = static_cast<int32_t>(rawHeight);
    if (!checkedByteCount(width, height, byteCount)) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "decoded image dimensions are too large");
    }

    ComPtr<IWICFormatConverter> converter;
    if (FAILED(factory->CreateFormatConverter(&converter)) ||
        FAILED(converter->Initialize(
            oriented.Get(),
            GUID_WICPixelFormat32bppPRGBA,
            WICBitmapDitherTypeNone,
            nullptr,
            0.0,
            WICBitmapPaletteTypeCustom
        ))) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "WIC could not convert the image to RGBA8");
    }

    try {
        auto pixels = std::make_shared<std::vector<uint8_t>>(byteCount);
        const UINT stride = rawWidth * 4u;
        if (FAILED(converter->CopyPixels(
            nullptr,
            stride,
            static_cast<UINT>(byteCount),
            pixels->data()
        ))) {
            return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "WIC could not decode the image pixels");
        }
        return NativeImage::fromPixels(width, height, pixels, 0);
    } catch (const std::bad_alloc&) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "not enough memory to decode the image");
    }
}

const GUID* containerFormat(int32_t format) {
    switch (format) {
        case 0: return &GUID_ContainerFormatPng;
        case 1: return &GUID_ContainerFormatJpeg;
        case 2: return &GUID_ContainerFormatHeif;
        case 3: return &GUID_ContainerFormatTiff;
        case 4: return &GUID_ContainerFormatGif;
        default: return nullptr;
    }
}

HRESULT setEncoderQuality(IPropertyBag2* properties, int32_t format, double quality) {
    if (format != 1 && format != 2) {
        return S_OK;
    }
    PROPBAG2 option{};
    option.pstrName = const_cast<wchar_t*>(L"ImageQuality");
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_R4;
    value.fltVal = static_cast<float>(quality);
    return properties->Write(1, &option, &value);
}

HRESULT writeEncodedFrame(
    IWICImagingFactory* factory,
    IWICBitmapEncoder* encoder,
    const std::vector<uint8_t>& pixels,
    int32_t width,
    int32_t height,
    int32_t format,
    double quality
) {
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> properties;
    HRESULT result = encoder->CreateNewFrame(&frame, &properties);
    if (FAILED(result)) {
        return result;
    }
    result = setEncoderQuality(properties.Get(), format, quality);
    if (FAILED(result)) {
        return result;
    }
    result = frame->Initialize(properties.Get());
    if (FAILED(result)) {
        return result;
    }
    result = frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height));
    if (FAILED(result)) {
        return result;
    }

    WICPixelFormatGUID destinationFormat = format == 1
        ? GUID_WICPixelFormat24bppBGR
        : GUID_WICPixelFormat32bppRGBA;
    if (format == 4) {
        destinationFormat = GUID_WICPixelFormat8bppIndexed;
    }
    result = frame->SetPixelFormat(&destinationFormat);
    if (FAILED(result)) {
        return result;
    }

    ComPtr<IWICBitmap> source;
    result = factory->CreateBitmapFromMemory(
        static_cast<UINT>(width),
        static_cast<UINT>(height),
        GUID_WICPixelFormat32bppPRGBA,
        static_cast<UINT>(width) * 4u,
        static_cast<UINT>(pixels.size()),
        const_cast<BYTE*>(pixels.data()),
        &source
    );
    if (FAILED(result)) {
        return result;
    }

    ComPtr<IWICFormatConverter> converter;
    result = factory->CreateFormatConverter(&converter);
    if (FAILED(result)) {
        return result;
    }
    const WICBitmapPaletteType paletteType = IsEqualGUID(destinationFormat, GUID_WICPixelFormat8bppIndexed)
        ? WICBitmapPaletteTypeMedianCut
        : WICBitmapPaletteTypeCustom;
    result = converter->Initialize(
        source.Get(),
        destinationFormat,
        WICBitmapDitherTypeNone,
        nullptr,
        0.0,
        paletteType
    );
    if (FAILED(result)) {
        return result;
    }
    result = frame->WriteSource(converter.Get(), nullptr);
    if (FAILED(result)) {
        return result;
    }
    result = frame->Commit();
    if (FAILED(result)) {
        return result;
    }
    return encoder->Commit();
}

}  // namespace

NativeImageError::NativeImageError(int32_t kind, std::string message)
    : kind_(kind), message_(std::move(message)) {}

int32_t NativeImageError::kind() const { return kind_; }
std::string NativeImageError::message() const { return message_; }

NativeImage::NativeImage(int32_t width, int32_t height, std::vector<uint8_t> pixels)
    : width_(width), height_(height), pixels_(std::move(pixels)) {}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> NativeImage::create(
    int32_t width,
    int32_t height
) {
    size_t byteCount = 0;
    if (!checkedByteCount(width, height, byteCount)) {
        return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "image dimensions must be positive and representable");
    }
    try {
        return doof::Success<std::shared_ptr<NativeImage>>{
            std::shared_ptr<NativeImage>(new NativeImage(width, height, std::vector<uint8_t>(byteCount, 0)))
        };
    } catch (const std::bad_alloc&) {
        return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "not enough memory to create the image");
    }
}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> NativeImage::fromPixels(
    int32_t width,
    int32_t height,
    const std::shared_ptr<std::vector<uint8_t>>& bytes,
    int32_t alphaMode
) {
    size_t byteCount = 0;
    if (!checkedByteCount(width, height, byteCount)) {
        return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "image dimensions must be positive and representable");
    }
    if (!bytes || bytes->size() != byteCount) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "pixel payload length must equal width * height * 4");
    }
    if (alphaMode < 0 || alphaMode > 1) {
        return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "unknown pixel alpha mode");
    }
    try {
        std::vector<uint8_t> pixels(*bytes);
        if (alphaMode == 1) {
            for (size_t offset = 0; offset < pixels.size(); offset += 4u) {
                const uint32_t alpha = pixels[offset + 3u];
                for (size_t channel = 0; channel < 3u; ++channel) {
                    pixels[offset + channel] = static_cast<uint8_t>(
                        (static_cast<uint32_t>(pixels[offset + channel]) * alpha + 127u) / 255u
                    );
                }
            }
        }
        return doof::Success<std::shared_ptr<NativeImage>>{
            std::shared_ptr<NativeImage>(new NativeImage(width, height, std::move(pixels)))
        };
    } catch (const std::bad_alloc&) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "not enough memory to copy the pixel payload");
    }
}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> NativeImage::loadFile(
    const std::string& path
) {
    if (path.empty()) {
        return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "image path must not be empty");
    }
    std::wstring widePath;
    if (!utf8Path(path, widePath)) {
        return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "image path is not valid UTF-8");
    }
    if (GetFileAttributesW(widePath.c_str()) == INVALID_FILE_ATTRIBUTES) {
        return failure<std::shared_ptr<NativeImage>>(IoFailed, "could not read image file");
    }
    ComApartment apartment;
    ComPtr<IWICImagingFactory> factory;
    if (!apartment.available() || FAILED(createFactory(factory))) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "Windows Imaging Component is unavailable");
    }
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(factory->CreateDecoderFromFilename(
        widePath.c_str(),
        nullptr,
        GENERIC_READ,
        WICDecodeMetadataCacheOnDemand,
        &decoder
    ))) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "WIC could not open the encoded image");
    }
    return decodeFrame(factory.Get(), decoder.Get());
}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> NativeImage::loadBlob(
    const std::shared_ptr<std::vector<uint8_t>>& bytes
) {
    if (!bytes || bytes->empty()) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "encoded image blob must not be empty");
    }
    ComApartment apartment;
    ComPtr<IWICImagingFactory> factory;
    if (!apartment.available() || FAILED(createFactory(factory))) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "Windows Imaging Component is unavailable");
    }
    ComPtr<IStream> stream;
    if (FAILED(memoryStream(*bytes, stream))) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "not enough memory to read the encoded image");
    }
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(factory->CreateDecoderFromStream(
        stream.Get(),
        nullptr,
        WICDecodeMetadataCacheOnDemand,
        &decoder
    ))) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "encoded data does not contain a supported image");
    }
    return decodeFrame(factory.Get(), decoder.Get());
}

int32_t NativeImage::width() const { return width_; }
int32_t NativeImage::height() const { return height_; }

doof::Result<std::shared_ptr<std::vector<uint8_t>>, std::shared_ptr<NativeImageError>> NativeImage::extract(
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height,
    int32_t alphaMode
) const {
    if (!validRect(width_, height_, x, y, width, height)) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(OutOfBounds, "pixel extraction rectangle is outside the image");
    }
    if (alphaMode < 0 || alphaMode > 1) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(InvalidArgument, "unknown pixel alpha mode");
    }
    size_t byteCount = 0;
    checkedByteCount(width, height, byteCount);
    try {
        auto output = std::make_shared<std::vector<uint8_t>>(byteCount);
        const size_t rowBytes = static_cast<size_t>(width) * 4u;
        for (int32_t row = 0; row < height; ++row) {
            const size_t sourceOffset =
                (static_cast<size_t>(y + row) * static_cast<size_t>(width_) + static_cast<size_t>(x)) * 4u;
            std::memcpy(
                output->data() + static_cast<size_t>(row) * rowBytes,
                pixels_.data() + sourceOffset,
                rowBytes
            );
        }
        if (alphaMode == 1) {
            for (size_t offset = 0; offset < output->size(); offset += 4u) {
                const uint32_t alpha = (*output)[offset + 3u];
                for (size_t channel = 0; channel < 3u; ++channel) {
                    (*output)[offset + channel] = alpha == 0
                        ? 0
                        : static_cast<uint8_t>(std::min(
                            (static_cast<uint32_t>((*output)[offset + channel]) * 255u + alpha / 2u) / alpha,
                            255u
                        ));
                }
            }
        }
        return doof::Success<std::shared_ptr<std::vector<uint8_t>>>{output};
    } catch (const std::bad_alloc&) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(InvalidData, "not enough memory to extract image pixels");
    }
}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> NativeImage::resize(
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height,
    int32_t outputWidth,
    int32_t outputHeight,
    int32_t resampling
) const {
    if (!validRect(width_, height_, x, y, width, height)) {
        return failure<std::shared_ptr<NativeImage>>(OutOfBounds, "resize source rectangle is outside the image");
    }
    size_t outputByteCount = 0;
    if (!checkedByteCount(outputWidth, outputHeight, outputByteCount)) {
        return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "resize dimensions must be positive and representable");
    }
    if (resampling < 0 || resampling > 2) {
        return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "unknown image resampling mode");
    }
    ComApartment apartment;
    ComPtr<IWICImagingFactory> factory;
    if (!apartment.available() || FAILED(createFactory(factory))) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "Windows Imaging Component is unavailable");
    }
    ComPtr<IWICBitmap> source;
    HRESULT result = factory->CreateBitmapFromMemory(
        static_cast<UINT>(width_),
        static_cast<UINT>(height_),
        GUID_WICPixelFormat32bppPRGBA,
        static_cast<UINT>(width_) * 4u,
        static_cast<UINT>(pixels_.size()),
        const_cast<BYTE*>(pixels_.data()),
        &source
    );
    ComPtr<IWICBitmapClipper> clipper;
    WICRect rectangle{x, y, width, height};
    if (SUCCEEDED(result)) {
        result = factory->CreateBitmapClipper(&clipper);
    }
    if (SUCCEEDED(result)) {
        result = clipper->Initialize(source.Get(), &rectangle);
    }
    ComPtr<IWICBitmapScaler> scaler;
    if (SUCCEEDED(result)) {
        result = factory->CreateBitmapScaler(&scaler);
    }
    const WICBitmapInterpolationMode interpolation = resampling == 0
        ? WICBitmapInterpolationModeNearestNeighbor
        : (resampling == 1 ? WICBitmapInterpolationModeLinear : WICBitmapInterpolationModeFant);
    if (SUCCEEDED(result)) {
        result = scaler->Initialize(
            clipper.Get(),
            static_cast<UINT>(outputWidth),
            static_cast<UINT>(outputHeight),
            interpolation
        );
    }
    if (FAILED(result)) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "WIC could not resize the image");
    }
    try {
        std::vector<uint8_t> output(outputByteCount);
        if (FAILED(scaler->CopyPixels(
            nullptr,
            static_cast<UINT>(outputWidth) * 4u,
            static_cast<UINT>(outputByteCount),
            output.data()
        ))) {
            return failure<std::shared_ptr<NativeImage>>(InvalidData, "WIC could not return the resized pixels");
        }
        return doof::Success<std::shared_ptr<NativeImage>>{
            std::shared_ptr<NativeImage>(new NativeImage(outputWidth, outputHeight, std::move(output)))
        };
    } catch (const std::bad_alloc&) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "not enough memory to resize the image");
    }
}

doof::Result<void, std::shared_ptr<NativeImageError>> NativeImage::saveFile(
    const std::string& path,
    int32_t format,
    double quality,
    bool lossless,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) const {
    if (path.empty()) {
        return voidFailure(InvalidArgument, "image path must not be empty");
    }
    std::wstring widePath;
    if (!utf8Path(path, widePath)) {
        return voidFailure(InvalidArgument, "image path is not valid UTF-8");
    }
    if (format == 5) {
        auto extracted = extract(x, y, width, height, 0);
        if (doof::is_failure(extracted)) {
            return doof::Failure<std::shared_ptr<NativeImageError>>{doof::failure_error(extracted)};
        }
        std::shared_ptr<std::vector<uint8_t>> encoded;
        std::string error;
        if (!encodeWebP(*doof::success_value(extracted), width, height, quality, lossless, encoded, error)) {
            return voidFailure(EncodeFailed, error);
        }
        FILE* file = _wfopen(widePath.c_str(), L"wb");
        if (file == nullptr) {
            return voidFailure(IoFailed, "could not create the WebP image output file");
        }
        const bool written = std::fwrite(encoded->data(), 1, encoded->size(), file) == encoded->size();
        const bool closed = std::fclose(file) == 0;
        if (!written || !closed) {
            return voidFailure(IoFailed, "could not write the encoded WebP image file");
        }
        return doof::Success<void>{};
    }
    const GUID* container = containerFormat(format);
    if (container == nullptr) {
        return voidFailure(UnsupportedFormat, "the requested image encoder is not available on this OS");
    }
    auto extracted = extract(x, y, width, height, 0);
    if (doof::is_failure(extracted)) {
        return doof::Failure<std::shared_ptr<NativeImageError>>{doof::failure_error(extracted)};
    }
    ComApartment apartment;
    ComPtr<IWICImagingFactory> factory;
    if (!apartment.available() || FAILED(createFactory(factory))) {
        return voidFailure(EncodeFailed, "Windows Imaging Component is unavailable");
    }
    ComPtr<IWICBitmapEncoder> encoder;
    const HRESULT encoderResult = factory->CreateEncoder(*container, nullptr, &encoder);
    if (FAILED(encoderResult)) {
        return voidFailure(UnsupportedFormat, "the requested image encoder is not available on this OS");
    }
    ComPtr<IWICStream> stream;
    if (FAILED(factory->CreateStream(&stream)) ||
        FAILED(stream->InitializeFromFilename(widePath.c_str(), GENERIC_WRITE)) ||
        FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) {
        return voidFailure(IoFailed, "could not create the image output file");
    }
    if (FAILED(writeEncodedFrame(
        factory.Get(), encoder.Get(), *doof::success_value(extracted), width, height, format, quality
    ))) {
        return voidFailure(IoFailed, "WIC could not write the encoded image file");
    }
    return doof::Success<void>{};
}

doof::Result<std::shared_ptr<std::vector<uint8_t>>, std::shared_ptr<NativeImageError>> NativeImage::saveBlob(
    int32_t format,
    double quality,
    bool lossless,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) const {
    if (format == 5) {
        auto extracted = extract(x, y, width, height, 0);
        if (doof::is_failure(extracted)) {
            return doof::Failure<std::shared_ptr<NativeImageError>>{doof::failure_error(extracted)};
        }
        std::shared_ptr<std::vector<uint8_t>> encoded;
        std::string error;
        if (!encodeWebP(*doof::success_value(extracted), width, height, quality, lossless, encoded, error)) {
            return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, error);
        }
        return doof::Success<std::shared_ptr<std::vector<uint8_t>>>{encoded};
    }
    const GUID* container = containerFormat(format);
    if (container == nullptr) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(UnsupportedFormat, "the requested image encoder is not available on this OS");
    }
    auto extracted = extract(x, y, width, height, 0);
    if (doof::is_failure(extracted)) {
        return doof::Failure<std::shared_ptr<NativeImageError>>{doof::failure_error(extracted)};
    }
    ComApartment apartment;
    ComPtr<IWICImagingFactory> factory;
    if (!apartment.available() || FAILED(createFactory(factory))) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "Windows Imaging Component is unavailable");
    }
    ComPtr<IWICBitmapEncoder> encoder;
    if (FAILED(factory->CreateEncoder(*container, nullptr, &encoder))) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(UnsupportedFormat, "the requested image encoder is not available on this OS");
    }
    ComPtr<IStream> stream;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) ||
        FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "could not create an in-memory image encoder");
    }
    if (FAILED(writeEncodedFrame(
        factory.Get(), encoder.Get(), *doof::success_value(extracted), width, height, format, quality
    ))) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "WIC could not finalize the encoded image blob");
    }
    HGLOBAL memory = nullptr;
    STATSTG stats{};
    if (FAILED(GetHGlobalFromStream(stream.Get(), &memory)) || memory == nullptr ||
        FAILED(stream->Stat(&stats, STATFLAG_NONAME)) || stats.cbSize.QuadPart > std::numeric_limits<size_t>::max()) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "could not return the encoded image blob");
    }
    void* data = GlobalLock(memory);
    if (data == nullptr && stats.cbSize.QuadPart != 0) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "could not read the encoded image blob");
    }
    try {
        auto output = std::make_shared<std::vector<uint8_t>>(static_cast<size_t>(stats.cbSize.QuadPart));
        if (!output->empty()) {
            std::memcpy(output->data(), data, output->size());
        }
        if (data != nullptr) {
            GlobalUnlock(memory);
        }
        return doof::Success<std::shared_ptr<std::vector<uint8_t>>>{output};
    } catch (const std::bad_alloc&) {
        if (data != nullptr) {
            GlobalUnlock(memory);
        }
        return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "not enough memory to return the encoded image blob");
    }
}

void NativeImage::blit(
    const std::shared_ptr<NativeImage>& source,
    int32_t sourceX,
    int32_t sourceY,
    int32_t sourceWidth,
    int32_t sourceHeight,
    int32_t destinationX,
    int32_t destinationY,
    int32_t clipX,
    int32_t clipY,
    int32_t clipWidth,
    int32_t clipHeight,
    bool sourceOver
) {
    if (!source || !validRect(source->width_, source->height_, sourceX, sourceY, sourceWidth, sourceHeight) ||
        !validRect(width_, height_, clipX, clipY, clipWidth, clipHeight)) {
        return;
    }
    try {
        std::vector<uint8_t> snapshot(static_cast<size_t>(sourceWidth) * static_cast<size_t>(sourceHeight) * 4u);
        const size_t snapshotRowBytes = static_cast<size_t>(sourceWidth) * 4u;
        for (int32_t row = 0; row < sourceHeight; ++row) {
            const size_t sourceOffset =
                (static_cast<size_t>(sourceY + row) * static_cast<size_t>(source->width_) + static_cast<size_t>(sourceX)) * 4u;
            std::memcpy(
                snapshot.data() + static_cast<size_t>(row) * snapshotRowBytes,
                source->pixels_.data() + sourceOffset,
                snapshotRowBytes
            );
        }
        const int64_t clipRight = static_cast<int64_t>(clipX) + clipWidth;
        const int64_t clipBottom = static_cast<int64_t>(clipY) + clipHeight;
        for (int32_t sourceRow = 0; sourceRow < sourceHeight; ++sourceRow) {
            const int64_t destinationRow = static_cast<int64_t>(clipY) + destinationY + sourceRow;
            if (destinationRow < clipY || destinationRow >= clipBottom) {
                continue;
            }
            for (int32_t sourceColumn = 0; sourceColumn < sourceWidth; ++sourceColumn) {
                const int64_t destinationColumn = static_cast<int64_t>(clipX) + destinationX + sourceColumn;
                if (destinationColumn < clipX || destinationColumn >= clipRight) {
                    continue;
                }
                const size_t sourceOffset =
                    (static_cast<size_t>(sourceRow) * static_cast<size_t>(sourceWidth) + static_cast<size_t>(sourceColumn)) * 4u;
                const size_t destinationOffset =
                    (static_cast<size_t>(destinationRow) * static_cast<size_t>(width_) + static_cast<size_t>(destinationColumn)) * 4u;
                if (!sourceOver) {
                    std::memcpy(pixels_.data() + destinationOffset, snapshot.data() + sourceOffset, 4u);
                    continue;
                }
                const uint32_t inverseAlpha = 255u - snapshot[sourceOffset + 3u];
                for (size_t channel = 0; channel < 4u; ++channel) {
                    const uint32_t composed = snapshot[sourceOffset + channel] +
                        (pixels_[destinationOffset + channel] * inverseAlpha + 127u) / 255u;
                    pixels_[destinationOffset + channel] = static_cast<uint8_t>(std::min(composed, 255u));
                }
            }
        }
    } catch (const std::bad_alloc&) {
        // Preserve the destination if the overlap-safety snapshot cannot be allocated.
    }
}

}  // namespace doof_image
