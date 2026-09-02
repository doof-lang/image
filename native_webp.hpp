#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace doof_image {

bool encodeWebP(
    const std::vector<uint8_t>& premultipliedPixels,
    int32_t width,
    int32_t height,
    double quality,
    bool lossless,
    std::shared_ptr<std::vector<uint8_t>>& output,
    std::string& error
);

}  // namespace doof_image
