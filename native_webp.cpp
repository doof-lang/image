#include "native_webp.hpp"

#include <webp/encode.h>

#include <cstddef>
#include <new>

namespace doof_image {

bool encodeWebP(
    const std::vector<uint8_t>& premultipliedPixels,
    int32_t width,
    int32_t height,
    double quality,
    bool lossless,
    std::shared_ptr<std::vector<uint8_t>>& output,
    std::string& error
) {
    if (width <= 0 || height <= 0 || width > 16383 || height > 16383) {
        error = "WebP image dimensions must be between 1 and 16383 pixels";
        return false;
    }
    try {
        std::vector<uint8_t> straightPixels(premultipliedPixels.size());
        for (size_t index = 0; index < premultipliedPixels.size(); index += 4) {
            const uint32_t alpha = premultipliedPixels[index + 3];
            straightPixels[index + 3] = static_cast<uint8_t>(alpha);
            if (alpha == 0) {
                straightPixels[index] = 0;
                straightPixels[index + 1] = 0;
                straightPixels[index + 2] = 0;
                continue;
            }
            for (size_t channel = 0; channel < 3; ++channel) {
                const uint32_t premultiplied = premultipliedPixels[index + channel];
                const uint32_t straight = (premultiplied * 255u + alpha / 2u) / alpha;
                straightPixels[index + channel] = static_cast<uint8_t>(straight > 255u ? 255u : straight);
            }
        }

        uint8_t* encoded = nullptr;
        const int stride = width * 4;
        const size_t encodedSize = lossless
            ? WebPEncodeLosslessRGBA(straightPixels.data(), width, height, stride, &encoded)
            : WebPEncodeRGBA(
                straightPixels.data(),
                width,
                height,
                stride,
                static_cast<float>(quality * 100.0),
                &encoded
            );
        if (encodedSize == 0 || encoded == nullptr) {
            error = "libwebp could not encode the image";
            return false;
        }

        std::unique_ptr<uint8_t, void (*)(void*)> encodedOwner(encoded, WebPFree);
        output = std::make_shared<std::vector<uint8_t>>(encoded, encoded + encodedSize);
        return true;
    } catch (const std::bad_alloc&) {
        error = "not enough memory to encode the WebP image";
        return false;
    }
}

}  // namespace doof_image
