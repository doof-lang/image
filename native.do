import class NativeImageError from "native_image.hpp" as doof_image::NativeImageError {
  kind(): int
  message(): string
}

import class NativeImage from "native_image.hpp" as doof_image::NativeImage {
  static create(width: int, height: int): Result<NativeImage, NativeImageError>
  static fromPixels(
    width: int,
    height: int,
    bytes: readonly byte[],
    alphaMode: int,
  ): Result<NativeImage, NativeImageError>
  static loadFile(path: string): Result<NativeImage, NativeImageError>
  static loadBlob(bytes: readonly byte[]): Result<NativeImage, NativeImageError>

  width(): int
  height(): int
  extract(
    x: int,
    y: int,
    width: int,
    height: int,
    alphaMode: int,
  ): Result<readonly byte[], NativeImageError>
  resize(
    x: int,
    y: int,
    width: int,
    height: int,
    outputWidth: int,
    outputHeight: int,
    resampling: int,
  ): Result<NativeImage, NativeImageError>
  saveFile(
    path: string,
    format: int,
    quality: double,
    x: int,
    y: int,
    width: int,
    height: int,
  ): Result<void, NativeImageError>
  saveBlob(
    format: int,
    quality: double,
    x: int,
    y: int,
    width: int,
    height: int,
  ): Result<readonly byte[], NativeImageError>
  blit(
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
  ): void
}

export { NativeImage, NativeImageError }
