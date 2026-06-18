import { NativeImage, NativeImageError } from "./native"
import { PixelBytes } from "./pixel_bytes"
import { imageError, mapNativeError, validateDimensions, validateOptions } from "./support"
import { ImageEncodeOptions, ImageError, ImageErrorKind, ImageFormat, ImageResampling, PixelAlphaMode } from "./types"

export { PixelBytes } from "./pixel_bytes"
export { ImageEncodeOptions, ImageError, ImageErrorKind, ImageFormat, ImageResampling, PixelAlphaMode } from "./types"

class Region {
  native: NativeImage
  x: int
  y: int
  width: int
  height: int
}

function mapNativeImage(result: Result<NativeImage, NativeImageError>): Result<Image, ImageError> {
  return case result {
    success: Success -> Success { value: Image { native: success.value } },
    failure: Failure -> Failure { error: mapNativeError(failure.error) },
  }
}

function mapNativeBytes(result: Result<readonly byte[], NativeImageError>): Result<readonly byte[], ImageError> {
  return case result {
    success: Success -> Success { value: success.value },
    failure: Failure -> Failure { error: mapNativeError(failure.error) },
  }
}

function mapNativeVoid(result: Result<void, NativeImageError>): Result<void, ImageError> {
  return case result {
    _: Success -> Success {},
    failure: Failure -> Failure { error: mapNativeError(failure.error) },
  }
}

function sourceRegion(source: Image | ImageView): Region {
  return case source {
    image: Image -> Region {
      native: image.native,
      x: 0,
      y: 0,
      width: image.width(),
      height: image.height(),
    },
    view: ImageView -> Region {
      native: view.image.native,
      x: view.x,
      y: view.y,
      width: view.viewWidth,
      height: view.viewHeight,
    },
  }
}

function blit(
  destination: Region,
  source: Image | ImageView,
  x: int,
  y: int,
  sourceOver: bool,
): void {
  sourceRect := sourceRegion(source)
  destination.native.blit(
    sourceRect.native,
    sourceRect.x,
    sourceRect.y,
    sourceRect.width,
    sourceRect.height,
    x,
    y,
    destination.x,
    destination.y,
    destination.width,
    destination.height,
    sourceOver,
  )
}

export class Image {
  private native: NativeImage

  static create(width: int, height: int): Result<Image, ImageError> {
    _ := validateDimensions(width, height) else error {
      return Failure { error: error }
    }
    return mapNativeImage(NativeImage.create(width, height))
  }

  static fromPixelBytes(pixels: PixelBytes): Result<Image, ImageError> {
    return mapNativeImage(
      NativeImage.fromPixels(pixels.width, pixels.height, pixels.bytes, pixels.alphaMode.value),
    )
  }

  static loadFile(path: string): Result<Image, ImageError> {
    return mapNativeImage(NativeImage.loadFile(path))
  }

  static loadBlob(bytes: readonly byte[]): Result<Image, ImageError> {
    if bytes.length == 0 {
      return Failure { error: imageError(.InvalidData, "encoded image blob must not be empty") }
    }
    return mapNativeImage(NativeImage.loadBlob(bytes))
  }

  width(): int => native.width()
  height(): int => native.height()

  view(x: int, y: int, width: int, height: int): Result<ImageView, ImageError> {
    return createView(this, x, y, width, height)
  }

  pixelBytes(alphaMode: PixelAlphaMode = .Premultiplied): Result<PixelBytes, ImageError> {
    try extracted := mapNativeBytes(native.extract(0, 0, width(), height(), alphaMode.value))
    return Success(PixelBytes(width(), height(), extracted, alphaMode))
  }

  resize(
    width: int,
    height: int,
    resampling: ImageResampling = .Linear,
  ): Result<Image, ImageError> {
    _ := validateDimensions(width, height) else error { return Failure { error: error } }
    return mapNativeImage(native.resize(0, 0, this.width(), this.height(), width, height, resampling.value))
  }

  saveFile(
    path: string,
    format: ImageFormat,
    options: ImageEncodeOptions = ImageEncodeOptions(),
  ): Result<void, ImageError> {
    quality := validateOptions(options) else error { return Failure { error: error } }
    return mapNativeVoid(native.saveFile(path, format.value, quality, 0, 0, width(), height()))
  }

  saveBlob(
    format: ImageFormat,
    options: ImageEncodeOptions = ImageEncodeOptions(),
  ): Result<readonly byte[], ImageError> {
    quality := validateOptions(options) else error { return Failure { error: error } }
    return mapNativeBytes(native.saveBlob(format.value, quality, 0, 0, width(), height()))
  }

  copyFrom(source: Image | ImageView, x: int, y: int): void {
    blit(Region { native, x: 0, y: 0, width: width(), height: height() }, source, x, y, false)
  }

  sourceOver(source: Image | ImageView, x: int, y: int): void {
    blit(Region { native, x: 0, y: 0, width: width(), height: height() }, source, x, y, true)
  }
}

function createView(
  image: Image,
  x: int,
  y: int,
  width: int,
  height: int,
): Result<ImageView, ImageError> {
  if width <= 0 || height <= 0 {
    return Failure { error: imageError(.InvalidArgument, "image view dimensions must be positive") }
  }
  if x < 0 || y < 0 || long(x) + long(width) > long(image.width()) || long(y) + long(height) > long(image.height()) {
    return Failure { error: imageError(.OutOfBounds, "image view must be fully inside its image") }
  }
  return Success { value: ImageView { image, x, y, viewWidth: width, viewHeight: height } }
}

export class ImageView {
  private image: Image
  private x: int
  private y: int
  private viewWidth: int
  private viewHeight: int

  width(): int => viewWidth
  height(): int => viewHeight

  view(x: int, y: int, width: int, height: int): Result<ImageView, ImageError> {
    if width <= 0 || height <= 0 {
      return Failure { error: imageError(.InvalidArgument, "image view dimensions must be positive") }
    }
    if x < 0 || y < 0 || long(x) + long(width) > long(viewWidth) || long(y) + long(height) > long(viewHeight) {
      return Failure { error: imageError(.OutOfBounds, "nested image view must be fully inside its parent view") }
    }
    return Success {
      value: ImageView {
        image,
        x: this.x + x,
        y: this.y + y,
        viewWidth: width,
        viewHeight: height,
      },
    }
  }

  pixelBytes(alphaMode: PixelAlphaMode = .Premultiplied): Result<PixelBytes, ImageError> {
    extracted := mapNativeBytes(image.native.extract(x, y, viewWidth, viewHeight, alphaMode.value)) else error {
      return Failure { error: error }
    }
    return Success (PixelBytes(viewWidth, viewHeight, extracted, alphaMode))
  }

  resize(
    width: int,
    height: int,
    resampling: ImageResampling = .Linear,
  ): Result<Image, ImageError> {
    _ := validateDimensions(width, height) else error { return Failure { error: error } }
    return mapNativeImage(
      image.native.resize(x, y, viewWidth, viewHeight, width, height, resampling.value),
    )
  }

  saveFile(
    path: string,
    format: ImageFormat,
    options: ImageEncodeOptions = ImageEncodeOptions(),
  ): Result<void, ImageError> {
    quality := validateOptions(options) else error { return Failure { error: error } }
    return mapNativeVoid(image.native.saveFile(path, format.value, quality, x, y, viewWidth, viewHeight))
  }

  saveBlob(
    format: ImageFormat,
    options: ImageEncodeOptions = ImageEncodeOptions(),
  ): Result<readonly byte[], ImageError> {
    quality := validateOptions(options) else error { return Failure { error: error } }
    return mapNativeBytes(image.native.saveBlob(format.value, quality, x, y, viewWidth, viewHeight))
  }

  copyFrom(source: Image | ImageView, x: int, y: int): void {
    blit(
      Region { native: image.native, x: this.x, y: this.y, width: viewWidth, height: viewHeight },
      source,
      x,
      y,
      false,
    )
  }

  sourceOver(source: Image | ImageView, x: int, y: int): void {
    blit(
      Region { native: image.native, x: this.x, y: this.y, width: viewWidth, height: viewHeight },
      source,
      x,
      y,
      true,
    )
  }
}
