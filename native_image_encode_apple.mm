#include "native_image.hpp"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <cstdint>
#include <cstring>
#include <new>
#include <string>
#include <vector>

namespace doof_image {
namespace {

enum ErrorKind : int32_t {
    InvalidArgument = 0,
    UnsupportedFormat = 3,
    EncodeFailed = 5,
    IoFailed = 6,
};

template <typename T>
doof::Result<T, std::shared_ptr<NativeImageError>> failure(ErrorKind kind, const std::string& message) {
    return doof::Result<T, std::shared_ptr<NativeImageError>>::failure(
        std::make_shared<NativeImageError>(static_cast<int32_t>(kind), message)
    );
}

doof::Result<void, std::shared_ptr<NativeImageError>> voidFailure(
    ErrorKind kind,
    const std::string& message
) {
    return doof::Result<void, std::shared_ptr<NativeImageError>>::failure(
        std::make_shared<NativeImageError>(static_cast<int32_t>(kind), message)
    );
}

CFStringRef formatType(int32_t format) {
    switch (format) {
        case 0: return CFSTR("public.png");
        case 1: return CFSTR("public.jpeg");
        case 2: return CFSTR("public.heic");
        case 3: return CFSTR("public.tiff");
        case 4: return CFSTR("com.compuserve.gif");
        default: return nullptr;
    }
}

bool destinationSupports(CFStringRef type) {
    if (type == nullptr) {
        return false;
    }
    CFArrayRef types = CGImageDestinationCopyTypeIdentifiers();
    if (types == nullptr) {
        return false;
    }
    const bool found = CFArrayContainsValue(types, CFRangeMake(0, CFArrayGetCount(types)), type);
    CFRelease(types);
    return found;
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
        static_cast<size_t>(width),
        static_cast<size_t>(height),
        8,
        32,
        static_cast<size_t>(width) * 4u,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
        provider,
        nullptr,
        false,
        kCGRenderingIntentDefault
    );
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    return image;
}

NSDictionary* encodeProperties(int32_t format, double quality) {
    if (format == 1 || format == 2) {
        return @{ (NSString*)kCGImageDestinationLossyCompressionQuality: @(quality) };
    }
    return @{};
}

}  // namespace

doof::Result<void, std::shared_ptr<NativeImageError>> NativeImage::saveFile(
    const std::string& path,
    int32_t format,
    double quality,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) const {
    @autoreleasepool {
        if (path.empty()) {
            return voidFailure(InvalidArgument, "image path must not be empty");
        }
        CFStringRef type = formatType(format);
        if (!destinationSupports(type)) {
            return voidFailure(UnsupportedFormat, "the requested image encoder is not available on this OS");
        }
        auto extracted = extract(x, y, width, height, 0);
        if (extracted.isFailure()) {
            return doof::Result<void, std::shared_ptr<NativeImageError>>::failure(extracted.error());
        }
        const auto& bytes = *extracted.value();
        CGImageRef image = createCGImage(bytes, width, height);
        if (image == nullptr) {
            return voidFailure(EncodeFailed, "could not create an image for encoding");
        }
        NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
        if (nsPath == nil) {
            CGImageRelease(image);
            return voidFailure(InvalidArgument, "image path is not valid UTF-8");
        }
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:nsPath],
            type,
            1,
            nullptr
        );
        if (destination == nullptr) {
            CGImageRelease(image);
            return voidFailure(IoFailed, "could not create the image output file");
        }
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)encodeProperties(format, quality));
        const bool ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(image);
        if (!ok) {
            return voidFailure(IoFailed, "ImageIO could not write the encoded image file");
        }
        return doof::Result<void, std::shared_ptr<NativeImageError>>::success();
    }
}

doof::Result<std::shared_ptr<std::vector<uint8_t>>, std::shared_ptr<NativeImageError>> NativeImage::saveBlob(
    int32_t format,
    double quality,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) const {
    @autoreleasepool {
        CFStringRef type = formatType(format);
        if (!destinationSupports(type)) {
            return failure<std::shared_ptr<std::vector<uint8_t>>>(UnsupportedFormat, "the requested image encoder is not available on this OS");
        }
        auto extracted = extract(x, y, width, height, 0);
        if (extracted.isFailure()) {
            return doof::Result<
                std::shared_ptr<std::vector<uint8_t>>,
                std::shared_ptr<NativeImageError>
            >::failure(extracted.error());
        }
        const auto& bytes = *extracted.value();
        CGImageRef image = createCGImage(bytes, width, height);
        if (image == nullptr) {
            return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "could not create an image for encoding");
        }
        NSMutableData* data = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)data,
            type,
            1,
            nullptr
        );
        if (destination == nullptr) {
            CGImageRelease(image);
            return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "could not create an in-memory image encoder");
        }
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)encodeProperties(format, quality));
        const bool ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(image);
        if (!ok) {
            return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "ImageIO could not finalize the encoded image blob");
        }
        try {
            auto output = std::make_shared<std::vector<uint8_t>>(data.length);
            if (data.length > 0) {
                std::memcpy(output->data(), data.bytes, data.length);
            }
            return doof::Result<
                std::shared_ptr<std::vector<uint8_t>>,
                std::shared_ptr<NativeImageError>
            >::success(output);
        } catch (const std::bad_alloc&) {
            return failure<std::shared_ptr<std::vector<uint8_t>>>(EncodeFailed, "not enough memory to return the encoded image blob");
        }
    }
}

}  // namespace doof_image
