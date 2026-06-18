#pragma once

#include "doof_runtime.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace doof_image {

class NativeImageError {
public:
    NativeImageError(int32_t kind, std::string message);

    int32_t kind() const;
    std::string message() const;

private:
    int32_t kind_;
    std::string message_;
};

class NativeImage {
public:
    static doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> create(
        int32_t width,
        int32_t height
    );
    static doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> fromPixels(
        int32_t width,
        int32_t height,
        const std::shared_ptr<std::vector<uint8_t>>& bytes,
        int32_t alphaMode
    );
    static doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> loadFile(
        const std::string& path
    );
    static doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> loadBlob(
        const std::shared_ptr<std::vector<uint8_t>>& bytes
    );

    int32_t width() const;
    int32_t height() const;
    doof::Result<std::shared_ptr<std::vector<uint8_t>>, std::shared_ptr<NativeImageError>> extract(
        int32_t x,
        int32_t y,
        int32_t width,
        int32_t height,
        int32_t alphaMode
    ) const;
    doof::Result<std::shared_ptr<NativeImage>, std::shared_ptr<NativeImageError>> resize(
        int32_t x,
        int32_t y,
        int32_t width,
        int32_t height,
        int32_t outputWidth,
        int32_t outputHeight,
        int32_t resampling
    ) const;
    doof::Result<void, std::shared_ptr<NativeImageError>> saveFile(
        const std::string& path,
        int32_t format,
        double quality,
        int32_t x,
        int32_t y,
        int32_t width,
        int32_t height
    ) const;
    doof::Result<std::shared_ptr<std::vector<uint8_t>>, std::shared_ptr<NativeImageError>> saveBlob(
        int32_t format,
        double quality,
        int32_t x,
        int32_t y,
        int32_t width,
        int32_t height
    ) const;
    void blit(
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
    );

private:
    NativeImage(int32_t width, int32_t height, std::vector<uint8_t> pixels);

    int32_t width_;
    int32_t height_;
    std::vector<uint8_t> pixels_;
};

}  // namespace doof_image
