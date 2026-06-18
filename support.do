import { NativeImageError } from "./native"
import { ImageEncodeOptions, ImageError, ImageErrorKind } from "./types"

export function imageError(kind: ImageErrorKind, message: string): ImageError {
  return ImageError { kind, message }
}

export function mapNativeError(error: NativeImageError): ImageError {
  kind := case error.kind() {
    0 -> ImageErrorKind.InvalidArgument,
    1 -> ImageErrorKind.InvalidData,
    2 -> ImageErrorKind.OutOfBounds,
    3 -> ImageErrorKind.UnsupportedFormat,
    4 -> ImageErrorKind.DecodeFailed,
    5 -> ImageErrorKind.EncodeFailed,
    6 -> ImageErrorKind.IoFailed,
    _ -> ImageErrorKind.InvalidData,
  }
  return ImageError { kind, message: error.message() }
}

export function validateDimensions(width: int, height: int): Result<long, ImageError> {
  if width <= 0 || height <= 0 {
    return Failure { error: imageError(.InvalidArgument, "image dimensions must be positive") }
  }

  pixelCount := long(width) * long(height)
  if pixelCount > 2305843009213693951L {
    return Failure { error: imageError(.InvalidArgument, "image dimensions are too large") }
  }
  return Success { value: pixelCount * 4L }
}

export function validateOptions(options: ImageEncodeOptions): Result<double, ImageError> {
  if options.quality < 0.0 || options.quality > 1.0 {
    return Failure { error: imageError(.InvalidArgument, "image encoding quality must be between 0 and 1") }
  }
  return Success { value: options.quality }
}
