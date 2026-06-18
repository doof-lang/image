#include "native_image.hpp"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace doof_image {
namespace {

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
    return doof::Result<T, std::shared_ptr<NativeImageError>>::failure(
        std::make_shared<NativeImageError>(static_cast<int32_t>(kind), message)
    );
}

bool checkedByteCount(int32_t width, int32_t height, size_t& byteCount) {
    if (width <= 0 || height <= 0) {
        return false;
    }
    const auto w = static_cast<uint64_t>(width);
    const auto h = static_cast<uint64_t>(height);
    const uint64_t count = w * h * 4u;
    if (count > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
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

std::string nsErrorMessage(NSError* error, const std::string& fallback) {
    if (error == nil) {
        return fallback;
    }
    NSString* description = error.localizedDescription;
    return description == nil ? fallback : std::string(description.UTF8String);
}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> decodeSource(
    CGImageSourceRef source
) {
    if (source == nullptr || CGImageSourceGetCount(source) == 0) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "encoded data does not contain an image");
    }

    NSDictionary* options = @{
        (NSString*)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (NSString*)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (NSString*)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        (__bridge CFDictionaryRef)options
    );
    if (image == nullptr) {
        return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "ImageIO could not decode the first image frame");
    }

    const size_t rawWidth = CGImageGetWidth(image);
    const size_t rawHeight = CGImageGetHeight(image);
    if (rawWidth == 0 || rawHeight == 0 ||
        rawWidth > static_cast<size_t>(std::numeric_limits<int32_t>::max()) ||
        rawHeight > static_cast<size_t>(std::numeric_limits<int32_t>::max())) {
        CGImageRelease(image);
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "decoded image dimensions are invalid or too large");
    }

    const int32_t width = static_cast<int32_t>(rawWidth);
    const int32_t height = static_cast<int32_t>(rawHeight);
    size_t byteCount = 0;
    if (!checkedByteCount(width, height, byteCount)) {
        CGImageRelease(image);
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "decoded image dimensions are too large");
    }

    try {
        std::vector<uint8_t> pixels(byteCount, 0);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (colorSpace == nullptr) {
            CGImageRelease(image);
            return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "could not create the sRGB color space");
        }
        CGContextRef context = CGBitmapContextCreate(
            pixels.data(),
            rawWidth,
            rawHeight,
            8,
            rawWidth * 4u,
            colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
        );
        CGColorSpaceRelease(colorSpace);
        if (context == nullptr) {
            CGImageRelease(image);
            return failure<std::shared_ptr<NativeImage>>(DecodeFailed, "could not create an RGBA8 bitmap context");
        }

        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, rawWidth, rawHeight), image);
        CGContextRelease(context);
        CGImageRelease(image);

        return NativeImage::fromPixels(
            width,
            height,
            std::make_shared<std::vector<uint8_t>>(std::move(pixels)),
            0
        );
    } catch (const std::bad_alloc&) {
        CGImageRelease(image);
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "not enough memory to decode the image");
    }
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
        return doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>>::success(
            std::shared_ptr<NativeImage>(new NativeImage(width, height, std::vector<uint8_t>(byteCount, 0)))
        );
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
        return doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>>::success(
            std::shared_ptr<NativeImage>(new NativeImage(width, height, std::move(pixels)))
        );
    } catch (const std::bad_alloc&) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "not enough memory to copy the pixel payload");
    }
}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> NativeImage::loadFile(
    const std::string& path
) {
    @autoreleasepool {
        if (path.empty()) {
            return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "image path must not be empty");
        }
        NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
        if (nsPath == nil) {
            return failure<std::shared_ptr<NativeImage>>(InvalidArgument, "image path is not valid UTF-8");
        }
        NSError* readError = nil;
        NSData* data = [NSData dataWithContentsOfFile:nsPath options:NSDataReadingMappedIfSafe error:&readError];
        if (data == nil) {
            return failure<std::shared_ptr<NativeImage>>(IoFailed, nsErrorMessage(readError, "could not read image file"));
        }
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
        auto result = decodeSource(source);
        if (source != nullptr) {
            CFRelease(source);
        }
        return result;
    }
}

doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> NativeImage::loadBlob(
    const std::shared_ptr<std::vector<uint8_t>>& bytes
) {
    @autoreleasepool {
        if (!bytes || bytes->empty()) {
            return failure<std::shared_ptr<NativeImage>>(InvalidData, "encoded image blob must not be empty");
        }
        NSData* data = [NSData dataWithBytes:bytes->data() length:bytes->size()];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
        auto result = decodeSource(source);
        if (source != nullptr) {
            CFRelease(source);
        }
        return result;
    }
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
            std::memcpy(output->data() + static_cast<size_t>(row) * rowBytes, pixels_.data() + sourceOffset, rowBytes);
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
        return doof::Result<
            std::shared_ptr<std::vector<uint8_t>>,
            std::shared_ptr<NativeImageError>
        >::success(output);
    } catch (const std::bad_alloc&) {
        return failure<std::shared_ptr<std::vector<uint8_t>>>(InvalidData, "not enough memory to extract image pixels");
    }
}


}  // namespace doof_image

