import class NativeImageError from "native_image.hpp" as doof_image::NativeImageError {
  isolated kind(): int
  isolated message(): string
}

import class NativeImage from "native_image.hpp" as doof_image::NativeImage {
  isolated static create(width: int, height: int): Result<NativeImage, NativeImageError>
  isolated static fromPixels(
    width: int,
    height: int,
    bytes: readonly byte[],
    alphaMode: int,
  ): Result<NativeImage, NativeImageError>
  isolated static loadFile(path: string): Result<NativeImage, NativeImageError>
  isolated static loadBlob(bytes: readonly byte[]): Result<NativeImage, NativeImageError>

  isolated width(): int
  isolated height(): int
  isolated extract(
    x: int,
    y: int,
    width: int,
    height: int,
    alphaMode: int,
  ): Result<readonly byte[], NativeImageError>
  isolated resize(
    x: int,
    y: int,
    width: int,
    height: int,
    outputWidth: int,
    outputHeight: int,
    resampling: int,
  ): Result<NativeImage, NativeImageError>
  isolated saveFile(
    path: string,
    format: int,
    quality: double,
    x: int,
    y: int,
    width: int,
    height: int,
  ): Result<none, NativeImageError>
  isolated saveBlob(
    format: int,
    quality: double,
    x: int,
    y: int,
    width: int,
    height: int,
  ): Result<readonly byte[], NativeImageError>
  isolated blit(
    source: NativeImage,
    sourceX: int,
    sourceY: int,
    sourceWidth: int,
    sourceHeight: int,
    destinationX: int,
    destinationY: int,
    clipX: int,
    clipY: int,
    clipWidth: int,
    clipHeight: int,
    sourceOver: bool,
  ): none
}

export { NativeImage, NativeImageError }
