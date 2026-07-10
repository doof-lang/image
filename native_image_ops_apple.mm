#include "native_image.hpp"

#import <CoreGraphics/CoreGraphics.h>

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
};

template <typename T>
doof::Result<T, std::shared_ptr<NativeImageError>> failure(ErrorKind kind, const std::string& message) {
    return doof::Failure<std::shared_ptr<NativeImageError>>{std::make_shared<NativeImageError>(static_cast<int32_t>(kind), message)};
}

bool checkedByteCount(int32_t width, int32_t height, size_t& byteCount) {
    if (width <= 0 || height <= 0) {
        return false;
    }
    const uint64_t count = static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4u;
    if (count > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
        return false;
    }
    byteCount = static_cast<size_t>(count);
    return true;
}

bool validRect(int32_t imageWidth, int32_t imageHeight, int32_t x, int32_t y, int32_t width, int32_t height) {
    return x >= 0 && y >= 0 && width > 0 && height > 0 &&
        static_cast<int64_t>(x) + width <= imageWidth &&
        static_cast<int64_t>(y) + height <= imageHeight;
}

CGImageRef createCGImage(const std::vector<uint8_t>& pixels, int32_t width, int32_t height) {
    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, pixels.data(), pixels.size(), nullptr);
    if (provider == nullptr) {
        return nullptr;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (colorSpace == nullptr) {
        CGDataProviderRelease(provider);
        return nullptr;
    }
    CGImageRef image = CGImageCreate(
        static_cast<size_t>(width), static_cast<size_t>(height), 8, 32,
        static_cast<size_t>(width) * 4u, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
        provider, nullptr, false, kCGRenderingIntentDefault
    );
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    return image;
}

}  // namespace

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

    auto extracted = extract(x, y, width, height, 0);
    if (doof::is_failure(extracted)) {
        return doof::Failure<std::shared_ptr<NativeImageError>>{doof::failure_error(extracted)};
    }
    CGImageRef sourceImage = createCGImage(*doof::success_value(extracted), width, height);
    if (sourceImage == nullptr) {
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "could not create the resize source image");
    }

    try {
        std::vector<uint8_t> output(outputByteCount, 0);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (colorSpace == nullptr) {
            CGImageRelease(sourceImage);
            return failure<std::shared_ptr<NativeImage>>(InvalidData, "could not create the sRGB color space");
        }
        CGContextRef context = CGBitmapContextCreate(
            output.data(), static_cast<size_t>(outputWidth), static_cast<size_t>(outputHeight), 8,
            static_cast<size_t>(outputWidth) * 4u, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
        );
        CGColorSpaceRelease(colorSpace);
        if (context == nullptr) {
            CGImageRelease(sourceImage);
            return failure<std::shared_ptr<NativeImage>>(InvalidData, "could not create the resize bitmap context");
        }

        const CGInterpolationQuality quality = resampling == 0
            ? kCGInterpolationNone
            : (resampling == 1 ? kCGInterpolationLow : kCGInterpolationHigh);
        CGContextSetInterpolationQuality(context, quality);
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(
            context,
            CGRectMake(0, 0, static_cast<CGFloat>(outputWidth), static_cast<CGFloat>(outputHeight)),
            sourceImage
        );
        CGContextRelease(context);
        CGImageRelease(sourceImage);
        return doof::Success<std::shared_ptr<NativeImage>>{std::shared_ptr<NativeImage>(new NativeImage(outputWidth, outputHeight, std::move(output)))};
    } catch (const std::bad_alloc&) {
        CGImageRelease(sourceImage);
        return failure<std::shared_ptr<NativeImage>>(InvalidData, "not enough memory to resize the image");
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
            std::memcpy(snapshot.data() + static_cast<size_t>(row) * snapshotRowBytes,
                source->pixels_.data() + sourceOffset, snapshotRowBytes);
        }

        const int64_t clipRight = static_cast<int64_t>(clipX) + clipWidth;
        const int64_t clipBottom = static_cast<int64_t>(clipY) + clipHeight;
        for (int32_t sy = 0; sy < sourceHeight; ++sy) {
            const int64_t dy = static_cast<int64_t>(clipY) + destinationY + sy;
            if (dy < clipY || dy >= clipBottom) {
                continue;
            }
            for (int32_t sx = 0; sx < sourceWidth; ++sx) {
                const int64_t dx = static_cast<int64_t>(clipX) + destinationX + sx;
                if (dx < clipX || dx >= clipRight) {
                    continue;
                }
                const size_t sourceOffset =
                    (static_cast<size_t>(sy) * static_cast<size_t>(sourceWidth) + static_cast<size_t>(sx)) * 4u;
                const size_t destinationOffset =
                    (static_cast<size_t>(dy) * static_cast<size_t>(width_) + static_cast<size_t>(dx)) * 4u;
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
